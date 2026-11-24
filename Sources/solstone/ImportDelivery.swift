// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

private let importLog = Logger(subsystem: "app.solstone.observer", category: "import")

/// Sends one save, one start, and one inspect. The live one streams the file; tests fake it.
protocol ImportTransport: Sendable {
    func save(_ item: ImportItemDescriptor, serverURL: String) async -> ImportOutcome
    func start(path: String, timestamp: String, serverURL: String) async -> ImportOutcome
    func inspect(importID: String, serverURL: String) async -> ImportInspectOutcome
}

enum ImportReconcileResult: Equatable, Sendable {
    case clean
    /// The journal returned 401/403; the batch halted without deleting local bytes.
    case authStop
    /// Pairing or admission changed mid-batch.
    case pairingLeft
}

enum ImportRunResult: Equatable, Sendable {
    /// Every item it took was delivered, refused or saved.
    case clean
    /// At least one item is to be tried again later.
    case retry
    /// The journal refused this pairing; the run stopped.
    case authStop
    /// The pairing or the gate changed during the run; it stopped sending.
    case pairingLeft
    /// The Mac is going to sleep or delivery was cancelled; waiting items stay pending for wake.
    case pausedForSleep
    /// The journal's version doesn't take imports, or isn't known; nothing was sent.
    case held
}

/// One owner event-log line for an import left to retry. The id is this Mac's own random one.
func importRetryLine(id: String, stage: String, cause: String) -> String {
    "kind=import id=\(id) step=\(stage) outcome=retry cause=\(cause)"
}

private func shouldPauseForSleep(_ isSleeping: @Sendable () async -> Bool) async -> Bool {
    if Task.isCancelled { return true }
    return await isSleeping()
}

/// Delivers held imports to the paired journal, oldest first. Each item's exchange (save, then
/// start) is marked in the store so the owner can't remove it mid-flight, and each answer is
/// recorded and the exchange ended under the store's lock. An answer from the journal a request
/// went to counts even if the owner re-paired meanwhile: that journal has it. A save answer that
/// arrives after a re-pair sends no start. A retry moves on to the next item.
func deliverImports(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    serverURL: String,
    instance: String,
    journalVersion: String,
    gate: ImportVersionGate,
    stillCurrent: @Sendable () async -> Bool,
    isSleeping: @Sendable () async -> Bool = { false },
    now: @Sendable () -> Date,
    log: @Sendable (String) -> Void = { importLog.notice("\($0, privacy: .public)") }
) async -> ImportRunResult {
    guard gate == .supported else { return .held }
    var anyRetry = false
    var result = ImportRunResult.clean
    defer { store.finish() }
    for candidate in store.eligible(instance: instance, journalVersion: journalVersion, now: now()) {
        if await shouldPauseForSleep(isSleeping) {
            result = .pausedForSleep
            break
        }
        guard await stillCurrent() else {
            result = .pairingLeft
            break
        }
        guard store.beginExchange(candidate.id, instance: instance, journalVersion: journalVersion) == .done else { continue }
        let step = await deliverOne(
            transport: transport, store: store, id: candidate.id, saved: candidate.progress,
            serverURL: serverURL, instance: instance, journalVersion: journalVersion,
            stillCurrent: stillCurrent, isSleeping: isSleeping
        )
        store.endExchange(candidate.id)
        switch step {
        case .done:
            break
        case .retry(let stage, let cause):
            log(importRetryLine(id: candidate.id, stage: stage, cause: cause))
            store.markRetry(candidate.id, instance: instance, now: now())
            anyRetry = true
        case .authStop:
            result = .authStop
        case .pairingLeft:
            result = .pairingLeft
        case .pausedForSleep:
            result = .pausedForSleep
        }
        if result != .clean { break }
    }
    if result == .clean && anyRetry { result = .retry }
    return result
}

private enum ImportItemStep {
    case done
    case retry(stage: String, cause: String)
    case authStop
    case pairingLeft
    case pausedForSleep
}

private func deliverOne(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    id: String,
    saved: (path: String, timestamp: String)?,
    serverURL: String,
    instance: String,
    journalVersion: String,
    stillCurrent: @Sendable () async -> Bool,
    isSleeping: @Sendable () async -> Bool
) async -> ImportItemStep {
    var progress = saved
    if progress == nil {
        guard let descriptor = store.item(id) else { return .done }
        let outcome = await transport.save(descriptor, serverURL: serverURL)
        if case .saved(let path, let timestamp) = outcome {
            guard await stillCurrent() else { return .pairingLeft }
            if store.recordSaved(id, path: path, timestamp: timestamp, instance: instance) == .gone { return .done }
            progress = (path, timestamp)
            if await shouldPauseForSleep(isSleeping) { return .pausedForSleep }
        } else {
            if case .retry = outcome, await shouldPauseForSleep(isSleeping) {
                return .pausedForSleep
            }
            return settle(store: store, id: id, outcome: outcome, stage: "save", instance: instance, journalVersion: journalVersion)
        }
    }
    guard let progress else { return .done }
    if await shouldPauseForSleep(isSleeping) { return .pausedForSleep }
    guard await stillCurrent() else { return .pairingLeft }
    let outcome = await transport.start(path: progress.path, timestamp: progress.timestamp, serverURL: serverURL)
    if case .retry = outcome, await shouldPauseForSleep(isSleeping) {
        return .pausedForSleep
    }
    return settle(
        store: store, id: id, outcome: outcome, stage: "start",
        savedTimestamp: progress.timestamp, instance: instance, journalVersion: journalVersion
    )
}

private func settle(
    store: ImportCustodyStore,
    id: String,
    outcome: ImportOutcome,
    stage: String,
    savedTimestamp: String? = nil,
    instance: String,
    journalVersion: String
) -> ImportItemStep {
    switch outcome {
    case .delivered(let importID):
        _ = store.recordDelivered(id, instance: instance, importID: importID)
        return .done
    case .readyToReview(let responseImportID, let error, let reasonCode, let kind):
        if let importID = validImportID(responseImportID) ?? validImportID(savedTimestamp) {
            _ = store.recordReadyToReview(
                id, importID: importID, error: error, reasonCode: reasonCode, kind: kind, instance: instance
            )
        } else {
            _ = store.recordAttention(
                id,
                error: error.isEmpty ? importGenericRefusal : error,
                reasonCode: reasonCode,
                kind: kind,
                instance: instance,
                journalVersion: journalVersion
            )
        }
        return .done
    case .needsAttention(let error, let reasonCode, let kind):
        _ = store.recordAttention(id, error: error, reasonCode: reasonCode ?? "", kind: kind, instance: instance, journalVersion: journalVersion)
        return .done
    case .authStop:
        return .authStop
    case .retry(let cause):
        return .retry(stage: stage, cause: cause)
    case .saved:
        // At start this means the journal answered something else: try again later.
        return .retry(stage: stage, cause: "answer-saved")
    }
}

/// Safely reconciles `ready to review` items against `GET /app/import/api/<id>`.
/// Re-verifies `(id, saved_import_id, saved_instance_id)` under the store lock before mutating,
/// persists any 24h recent receipt durably before deleting local bytes, preserves bytes on
/// `pending + eligible/unknown/absent`, marks `404` as `reviewExpired` keeping local bytes,
/// halts immediately on `401`/`403`, and ignores transient/malformed errors per item.
func reconcileReviewImports(
    transport: any ImportTransport,
    store: ImportCustodyStore,
    serverURL: String,
    instance: String,
    stillCurrent: @Sendable () async -> Bool
) async -> ImportReconcileResult {
    defer { store.finish() }
    for candidate in store.reviewCandidates(instance: instance) {
        guard await stillCurrent() else { return .pairingLeft }
        let outcome = await transport.inspect(importID: candidate.importID, serverURL: serverURL)
        switch outcome {
        case .confirmed:
            _ = store.reconcileConfirmed(
                candidate.id,
                expectedImportID: candidate.importID,
                expectedInstanceID: candidate.instanceID
            )
        case .expired:
            _ = store.reconcileExpired(
                candidate.id,
                expectedImportID: candidate.importID,
                expectedInstanceID: candidate.instanceID
            )
        case .stillPending, .unchanged:
            break
        case .authStop:
            return .authStop
        }
    }
    return .clean
}

// MARK: - the live transport

/// Streams a save's multipart body from the copy on disk, never holding the file in memory, over
/// the paired connection, and sends the start as JSON. A redirect is not followed.
struct ImportLiveTransport: ImportTransport {
    static let savePath = "/app/import/api/save"
    static let startPath = "/app/import/api/start"
    static let inspectPrefix = "/app/import/api/"
    /// The journal labels the import's origin from this; older journals show no label for it.
    static let importedVia = "macos"
    static let chunkSize = 64 * 1024

    func save(_ item: ImportItemDescriptor, serverURL: String) async -> ImportOutcome {
        guard let url = URL(string: serverURL + Self.savePath) else { return .retry(cause: "io-address") }
        let boundary = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body = ImportMultipartBody(boundary: boundary, item: item)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.contentLength), forHTTPHeaderField: "Content-Length")
        request.attachLoopbackCapability()
        let answer = await ImportStreamedRequest.send(request, body: body)
        return Self.classify(.save, answer)
    }

    func start(path: String, timestamp: String, serverURL: String) async -> ImportOutcome {
        guard let url = URL(string: serverURL + Self.startPath),
              let json = try? JSONSerialization.data(withJSONObject: ["path": path, "timestamp": timestamp], options: [.sortedKeys]) else {
            return .retry(cause: "io-address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = json
        request.attachLoopbackCapability()
        let answer = await ImportStreamedRequest.send(request, body: nil)
        return Self.classify(.start, answer)
    }

    func inspect(importID: String, serverURL: String) async -> ImportInspectOutcome {
        guard isValidImportID(importID),
              let url = URL(string: serverURL + Self.inspectPrefix + importID) else {
            return .unchanged
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.attachLoopbackCapability()
        let answer = await ImportStreamedRequest.send(request, body: nil)
        switch answer {
        case .failed:
            return .unchanged
        case .answered(let status, let loopbackRefused, let data):
            return classifyImportInspectResponse(status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }

    private static func classify(_ operation: ImportOperation, _ answer: ImportStreamedRequest.Answer) -> ImportOutcome {
        switch answer {
        case .failed(let cause):
            return .retry(cause: cause)
        case .answered(let status, let loopbackRefused, let data):
            return classifyImportResponse(operation, status: status, body: data, loopbackRefused: status == 403 && loopbackRefused)
        }
    }
}

/// The save's body: prefix, the file read in chunks, suffix. Its length is known before it starts.
struct ImportMultipartBody: Sendable {
    let prefix: Data
    let suffix: Data
    let fileURL: URL
    let fileLength: Int64
    var contentLength: Int64 { Int64(prefix.count) + fileLength + Int64(suffix.count) }

    init(boundary: String, item: ImportItemDescriptor) {
        let filename = importWireFilename(item.displayName)
        let mime = item.mime.filter { $0 != "\r" && $0 != "\n" }
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"client_item_id\"\r\n\r\n\(item.id)\r\n"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"imported_via\"\r\n\r\n\(ImportLiveTransport.importedVia)\r\n"
        if let handoff = item.handoff {
            func field(_ name: String, _ value: String) -> String {
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            }
            head += field("area", handoff.area)
            if !ImportHandoff.unhintedAreas.contains(handoff.area) { head += field("source_hint", handoff.area) }
            head += field("context", handoff.context)
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        if !mime.isEmpty { head += "Content-Type: \(mime)\r\n" }
        head += "\r\n"
        prefix = Data(head.utf8)
        suffix = Data("\r\n--\(boundary)--\r\n".utf8)
        fileURL = item.payloadURL
        fileLength = item.size
    }

    /// Writes the whole body to `write`, reading the file through `read` in chunks of at most
    /// `chunk` bytes. Stops, returning false, when a write fails or the file ends early.
    func stream(
        chunk: Int = ImportLiveTransport.chunkSize,
        read: (FileHandle, Int) throws -> Data = { handle, count in try handle.read(upToCount: count) ?? Data() },
        write: (Data) -> Bool
    ) -> Bool {
        guard write(prefix) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < fileLength {
            let want = Int(min(Int64(chunk), fileLength - sent))
            guard let data = try? read(handle, want), !data.isEmpty, data.count <= want else { return false }
            guard write(data) else { return false }
            sent += Int64(data.count)
        }
        return write(suffix)
    }
}

/// One request through its own session, with a streamed body when it has one. The delegate hands
/// over the body stream once; a second ask for one fails the request, which the caller retries.
final class ImportStreamedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Answer: Sendable {
        /// `loopbackRefused`: the answer carries this Mac's loopback proxy's own refusal mark.
        case answered(status: Int, loopbackRefused: Bool, data: Data)
        case failed(cause: String)
    }

    private let lock = NSLock()
    private let body: ImportMultipartBody?
    private var input: InputStream?
    private var task: URLSessionTask?
    private var cancelled = false
    private var handedOver = false
    private var data = Data()
    private var response: HTTPURLResponse?
    private var finish: ((Answer) -> Void)?
    private static let maximumAnswerBytes = 1024 * 1024

    private init(body: ImportMultipartBody?) {
        self.body = body
    }

    static func send(_ request: URLRequest, body: ImportMultipartBody?, configuration: URLSessionConfiguration? = nil) async -> Answer {
        let delegate = ImportStreamedRequest(body: body)
        let config = configuration ?? UploadClient.defaultSessionConfiguration()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task: URLSessionTask
                if body != nil {
                    task = session.uploadTask(withStreamedRequest: request)
                } else {
                    task = session.dataTask(with: request)
                }
                delegate.start(task: task) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(task: URLSessionTask, finish: @escaping (Answer) -> Void) {
        let alreadyCancelled: Bool = lock.withLock {
            if cancelled { return true }
            self.task = task
            self.finish = finish
            return false
        }
        if alreadyCancelled {
            finish(.failed(cause: "io-cancelled"))
            return
        }
        task.resume()
        let cancelledDuringResume: Bool = lock.withLock { cancelled }
        if cancelledDuringResume {
            task.cancel()
        }
    }

    private func cancel() {
        let activeTask: URLSessionTask? = lock.withLock {
            cancelled = true
            return task
        }
        activeTask?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        let proceed: Bool = lock.withLock {
            defer { handedOver = true }
            return !handedOver && !cancelled
        }
        guard proceed, let body else {
            completionHandler(nil)
            return
        }
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: ImportLiveTransport.chunkSize, inputStream: &input, outputStream: &output)
        guard let input, let output else {
            completionHandler(nil)
            return
        }
        let abortedAfterStreams: Bool = lock.withLock {
            if cancelled { return true }
            self.input = input
            return false
        }
        if abortedAfterStreams {
            input.close()
            output.close()
            completionHandler(nil)
            return
        }
        // The writer blocks while the session reads, so it has a thread of its own.
        let box = ImportStreamBox(output)
        let writer = Thread {
            let output = box.stream
            output.open()
            defer { output.close() }
            _ = body.stream { chunk in
                var offset = 0
                while offset < chunk.count {
                    let written = chunk.withUnsafeBytes { raw -> Int in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                        return output.write(base + offset, maxLength: chunk.count - offset)
                    }
                    if written <= 0 { return false }
                    offset += written
                }
                return true
            }
        }
        writer.name = "import-body"
        writer.start()
        completionHandler(input)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over: Bool = lock.withLock {
            data.append(chunk)
            return data.count > Self.maximumAnswerBytes
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (answer, done): (Answer, ((Answer) -> Void)?) = lock.withLock {
            defer {
                finish = nil
                self.task = nil
                input?.close()
                input = nil
            }
            if let response, error == nil {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: data), finish)
            }
            if cancelled {
                return (.failed(cause: "io-cancelled"), finish)
            }
            if let response {
                let marked = response.value(forHTTPHeaderField: "X-SPL-Loopback-Refused") != nil
                return (.answered(status: response.statusCode, loopbackRefused: marked, data: data), finish)
            }
            let code = (error as? URLError)?.code.rawValue ?? -1
            return (.failed(cause: "io-urlerror\(code < 0 ? "-" : "")\(abs(code))"), finish)
        }
        done?(answer)
    }
}

/// Hands an output stream to the one thread that writes it.
private final class ImportStreamBox: @unchecked Sendable {
    let stream: OutputStream
    init(_ stream: OutputStream) { self.stream = stream }
}
