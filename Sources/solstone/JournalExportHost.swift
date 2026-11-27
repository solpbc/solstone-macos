// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Crypto
import Darwin
import Foundation
import os
import UniformTypeIdentifiers

private let exportHostLog = Logger(subsystem: "app.solstone.observer", category: "export")

/// The journal page's native export-save contract, version 2, read from the copy
/// packaged with the app. Runs over the `window.solstoneJournalHost` v2 channel.
struct JournalExportContract: Equatable, Sendable {
    let version: Int
    let capability: String
    let start: String
    let status: String
    let pause: String
    let resume: String
    let cancel: String
    let reveal: String
    let deviceSpace: String
    let event: String
    let unsupported: String
    /// The packaged JSON bytes, handed to the page script as they are.
    let json: String

    static let supportedVersion = 2

    init?(data: Data?) {
        guard let data, let json = String(data: data, encoding: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? Int, version == Self.supportedVersion,
              let capability = object["capability"] as? String, !capability.isEmpty,
              let start = object["start"] as? String, !start.isEmpty,
              let status = object["status"] as? String, !status.isEmpty,
              let pause = object["pause"] as? String, !pause.isEmpty,
              let resume = object["resume"] as? String, !resume.isEmpty,
              let cancel = object["cancel"] as? String, !cancel.isEmpty,
              let reveal = object["reveal"] as? String, !reveal.isEmpty,
              let deviceSpace = object["deviceSpace"] as? String, !deviceSpace.isEmpty,
              let event = object["event"] as? String, !event.isEmpty,
              let unsupported = object["unsupported"] as? String, !unsupported.isEmpty
        else { return nil }
        self.version = version
        self.capability = capability
        self.start = start
        self.status = status
        self.pause = pause
        self.resume = resume
        self.cancel = cancel
        self.reveal = reveal
        self.deviceSpace = deviceSpace
        self.event = event
        self.unsupported = unsupported
        self.json = json.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func packaged(appBundle: Bundle = .main) -> JournalExportContract? {
        JournalExportContract(
            data: JournalWebHostContract.packagedBytes(appBundle: appBundle, resource: "export-host-contract")
        )
    }
}

/// Validated `export.start` request from `/app/export/`.
struct JournalExportStartRequest: Equatable, Sendable {
    let exportID: String
    let downloadPath: String
    let filename: String
    let sizeBytes: Int64
    let sha256: String
    let etag: String
    let mode: String?

    static func parse(_ message: [String: Any]) -> JournalExportStartRequest? {
        guard let exportID = message["export_id"] as? String,
              isSafeExportID(exportID),
              let downloadPath = message["download_path"] as? String,
              downloadPath == "/app/export/api/ready/\(exportID)/download",
              let rawFilename = message["filename"] as? String,
              let sizeNumber = message["size_bytes"] as? NSNumber,
              CFGetTypeID(sizeNumber) != CFBooleanGetTypeID(),
              let sha256 = message["sha256"] as? String,
              isValidSHA256(sha256),
              let etag = message["etag"] as? String, !etag.isEmpty, etag.utf8.count <= 256
        else { return nil }
        let sizeBytes = sizeNumber.int64Value
        guard sizeBytes > 0 else { return nil }
        let filename = sanitizeFilename(rawFilename)
        let mode = message["mode"] as? String
        return JournalExportStartRequest(
            exportID: exportID,
            downloadPath: downloadPath,
            filename: filename,
            sizeBytes: sizeBytes,
            sha256: sha256.lowercased(),
            etag: etag,
            mode: mode
        )
    }

    static func isSafeExportID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !leaf.isEmpty
            && !leaf.hasPrefix(".")
            && leaf.utf8.count <= 200
            && !leaf.contains("/")
            && !leaf.contains(":")
            && !leaf.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        return ok ? leaf : "solstone-journal.zip"
    }
}

/// Snapshot of the active/paused/completed native export save shown to `/app/export/`.
struct JournalExportStatusSnapshot: Equatable, Sendable {
    var exportID: String?
    var phase: String
    var platform: String = "macos"
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    var rateBytesPerSec: Double?
    var transport: String?
    var destinationDisplay: String?
    var canReveal: Bool = false
    var verified: Bool = false
    var pauseReason: String?
    var errorCode: String?
    var requiredBytes: Int64?
    var availableBytes: Int64?
    var mode: String?

    static let idle = JournalExportStatusSnapshot(phase: "idle")

    func toJSON(replyID: String? = nil) -> [String: Any] {
        var obj: [String: Any] = [
            "phase": phase,
            "platform": platform,
            "bytes_written": bytesWritten,
            "total_bytes": totalBytes,
            "can_reveal": canReveal,
            "verified": verified,
        ]
        if let replyID { obj["id"] = replyID }
        if let exportID { obj["export_id"] = exportID }
        if let rateBytesPerSec, rateBytesPerSec.isFinite, rateBytesPerSec >= 0 {
            obj["rate_bytes_per_sec"] = rateBytesPerSec
        }
        if let transport { obj["transport"] = transport }
        if let destinationDisplay { obj["destination_display"] = destinationDisplay }
        if let pauseReason { obj["pause_reason"] = pauseReason }
        if let errorCode { obj["error_code"] = errorCode }
        if let requiredBytes { obj["required_bytes"] = requiredBytes }
        if let availableBytes { obj["available_bytes"] = availableBytes }
        if let mode { obj["mode"] = mode }
        return obj
    }
}

/// Abstracts save-panel presentation so tests run headlessly.
typealias JournalExportSavePanelPresenter = @MainActor (_ suggestedFilename: String, _ window: NSWindow?) async -> URL?
typealias JournalExportVolumeSpaceProbe = @Sendable (_ url: URL) -> Int64?
typealias JournalExportFileRevealer = @MainActor (_ url: URL) -> Void
typealias JournalExportRequestPreparer = @Sendable (_ request: inout URLRequest) -> Void

@MainActor
enum JournalExportSavePanel {
    static func present(suggestedFilename: String, over window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK else { return nil }
        return panel.url
    }
}

enum JournalExportVolumeSpace {
    static func availableBytes(for url: URL) -> Int64? {
        let probeURL: URL = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        guard let values = try? probeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important >= 0 {
            return important
        }
        if let available = values.volumeAvailableCapacity, available >= 0 {
            return Int64(available)
        }
        return nil
    }

    static func headroomBytes(for exportSizeBytes: Int64) -> Int64 {
        min(Int64(64 * 1024 * 1024), max(Int64(1 * 1024 * 1024), exportSizeBytes / 100))
    }

    static func requiredBytes(for exportSizeBytes: Int64, existingPartialBytes: Int64 = 0) -> Int64 {
        let credited = min(max(0, existingPartialBytes), max(0, exportSizeBytes))
        let remaining = max(0, exportSizeBytes - credited)
        return remaining.saturatingAdd(headroomBytes(for: exportSizeBytes))
    }
}

/// Thread-safe cooperative cancellation flag shared between `@MainActor` control
/// paths and background file I/O / SHA-256 verification loops.
final class ExportCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Serializes final destination publication against cancellation and superseding
/// attempts so a cancelled or stale worker can never overwrite the chosen file.
final class ExportPublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UInt64 = 0

    func setActiveGeneration(_ generation: UInt64) {
        lock.lock()
        activeGeneration = generation
        lock.unlock()
    }

    func invalidateIfCurrent(_ generation: UInt64) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = 0
        }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock()
        activeGeneration = 0
        lock.unlock()
    }

    func runIfActive<T>(
        generation: UInt64,
        cancelFlag: ExportCancellationFlag,
        _ body: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation, !cancelFlag.isCancelled, !Task.isCancelled else {
            throw CancellationError()
        }
        return try body()
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = self.addingReportingOverflow(other)
        return overflow ? Int64.max : sum
    }
}

/// Bounded-memory streaming HTTP chunk reader backed by `URLSessionDataDelegate`.
///
/// Enforces explicit backpressure via `URLSessionDataTask.suspend()` / `resume()`
/// so a slow destination drive cannot cause unbounded in-memory buffering on
/// multi-hundred-GB exports, and installs the response waiter before calling
/// `task.resume()` so fast loopback responses cannot race ahead of the waiter.
final class ExportStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let defaultHighWaterBytes = 2 * 1024 * 1024
    static let defaultLowWaterBytes = 512 * 1024

    private let lock = NSCondition()
    private let highWaterBytes: Int
    private let lowWaterBytes: Int
    private let shouldCancelAtHeaders: (@Sendable (HTTPURLResponse) -> Bool)?

    private var attachedTask: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, BoundedExportStream), Error>?
    private var pendingResponse: HTTPURLResponse?
    private var deliveredResponse = false
    private var cancelledAtHeaders = false

    private var chunks: [Data] = []
    private var chunkHead = 0
    private var bufferedBytes = 0
    private var peakBufferedBytes = 0
    private var isTaskSuspended = false
    private var pendingRead: CheckedContinuation<Data?, Error>?
    private var isCompleted = false
    private var completionError: Error?
    private var isCancelled = false

    init(
        highWaterBytes: Int = ExportStreamDelegate.defaultHighWaterBytes,
        lowWaterBytes: Int = ExportStreamDelegate.defaultLowWaterBytes,
        shouldCancelAtHeaders: (@Sendable (HTTPURLResponse) -> Bool)? = nil
    ) {
        self.highWaterBytes = max(64 * 1024, highWaterBytes)
        self.lowWaterBytes = max(16 * 1024, min(lowWaterBytes, highWaterBytes / 2))
        self.shouldCancelAtHeaders = shouldCancelAtHeaders
    }

    var maxBufferedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakBufferedBytes
    }

    /// Starts `task` AFTER installing the response waiter so fast responses
    /// cannot race ahead of continuation registration.
    func startAndAwaitResponse(task: URLSessionDataTask) async throws -> (HTTPURLResponse, BoundedExportStream) {
        let stream = BoundedExportStream(delegate: self)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.attachedTask = task
                if isCancelled {
                    lock.unlock()
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let response = pendingResponse {
                    pendingResponse = nil
                    deliveredResponse = true
                    lock.unlock()
                    continuation.resume(returning: (response, stream))
                    return
                }
                if let error = completionError {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                if isCompleted {
                    lock.unlock()
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                self.responseContinuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancelStream()
        }
    }

    func nextChunk() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var taskToResume: URLSessionDataTask?
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if chunkHead < chunks.count {
                    let next = chunks[chunkHead]
                    chunks[chunkHead] = Data()
                    chunkHead += 1
                    if chunkHead == chunks.count {
                        chunks.removeAll(keepingCapacity: true)
                        chunkHead = 0
                    } else if chunkHead >= 32 && chunkHead * 2 >= chunks.count {
                        chunks.removeFirst(chunkHead)
                        chunkHead = 0
                    }
                    bufferedBytes = max(0, bufferedBytes - next.count)
                    if isTaskSuspended && !isCompleted && bufferedBytes <= lowWaterBytes {
                        isTaskSuspended = false
                        taskToResume = attachedTask
                        lock.broadcast()
                    }
                    lock.unlock()
                    taskToResume?.resume()
                    continuation.resume(returning: next)
                    return
                }
                if isCompleted {
                    let error = completionError
                    lock.unlock()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }
                pendingRead = continuation
                lock.unlock()
            }
        } onCancel: {
            self.cancelStream()
        }
    }

    func cancelStream() {
        var taskToCancel: URLSessionDataTask?
        var respCont: CheckedContinuation<(HTTPURLResponse, BoundedExportStream), Error>?
        var readCont: CheckedContinuation<Data?, Error>?
        lock.lock()
        isCancelled = true
        isCompleted = true
        if completionError == nil {
            completionError = CancellationError()
        }
        chunks.removeAll(keepingCapacity: false)
        chunkHead = 0
        bufferedBytes = 0
        isTaskSuspended = false
        taskToCancel = attachedTask
        attachedTask = nil
        respCont = responseContinuation
        responseContinuation = nil
        readCont = pendingRead
        pendingRead = nil
        lock.broadcast()
        lock.unlock()
        taskToCancel?.cancel()
        respCont?.resume(throwing: CancellationError())
        readCont?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failAll(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        let stream = BoundedExportStream(delegate: self)
        let cancelBody = shouldCancelAtHeaders?(http) == true
        lock.lock()
        if isCancelled {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if cancelBody {
            cancelledAtHeaders = true
            isCompleted = true
        }
        let cont = responseContinuation
        responseContinuation = nil
        if cont != nil {
            deliveredResponse = true
        } else {
            pendingResponse = http
        }
        lock.unlock()
        cont?.resume(returning: (http, stream))
        completionHandler(cancelBody ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var readCont: CheckedContinuation<Data?, Error>?
        var shouldSuspend = false
        lock.lock()
        while !isCancelled && !isCompleted && bufferedBytes >= highWaterBytes {
            if !isTaskSuspended {
                isTaskSuspended = true
                lock.unlock()
                dataTask.suspend()
                lock.lock()
                continue
            }
            lock.wait()
        }
        if isCancelled || isCompleted {
            lock.unlock()
            return
        }
        if let waiter = pendingRead {
            pendingRead = nil
            readCont = waiter
        } else {
            chunks.append(data)
            bufferedBytes += data.count
            if bufferedBytes > peakBufferedBytes {
                peakBufferedBytes = bufferedBytes
            }
            if !isTaskSuspended && bufferedBytes >= highWaterBytes {
                isTaskSuspended = true
                shouldSuspend = true
            }
        }
        lock.unlock()
        if shouldSuspend {
            dataTask.suspend()
        }
        readCont?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasHeaderCancel = cancelledAtHeaders
        lock.unlock()
        if wasHeaderCancel {
            return
        }
        if let error {
            failAll(error)
            return
        }
        var respCont: CheckedContinuation<(HTTPURLResponse, BoundedExportStream), Error>?
        var readCont: CheckedContinuation<Data?, Error>?
        var respError: Error?
        lock.lock()
        isCompleted = true
        if !deliveredResponse, let cont = responseContinuation {
            responseContinuation = nil
            respCont = cont
            respError = URLError(.badServerResponse)
        }
        if chunkHead >= chunks.count, let waiter = pendingRead {
            pendingRead = nil
            readCont = waiter
        }
        lock.unlock()
        if let respCont, let respError {
            respCont.resume(throwing: respError)
        }
        readCont?.resume(returning: nil)
    }

    private func failAll(_ error: Error) {
        var respCont: CheckedContinuation<(HTTPURLResponse, BoundedExportStream), Error>?
        var readCont: CheckedContinuation<Data?, Error>?
        lock.lock()
        isCompleted = true
        if completionError == nil {
            completionError = error
        }
        let deliveredErr = completionError ?? error
        respCont = responseContinuation
        responseContinuation = nil
        readCont = pendingRead
        pendingRead = nil
        lock.broadcast()
        lock.unlock()
        respCont?.resume(throwing: deliveredErr)
        readCont?.resume(throwing: deliveredErr)
    }
}

/// Async chunk reader backed by `ExportStreamDelegate` with strict high/low-water backpressure.
struct BoundedExportStream: Sendable {
    let delegate: ExportStreamDelegate

    func nextChunk() async throws -> Data? {
        try await delegate.nextChunk()
    }

    func cancel() {
        delegate.cancelStream()
    }
}

/// App-scoped manager owning native journal export downloads on macOS.
/// Survives navigating away from `/app/export/` and closing/reopening the Journal window;
/// cancelled cleanly on unpair or app termination.
@MainActor
final class JournalExportTransferManager {
    private struct ActiveTransfer {
        let request: JournalExportStartRequest
        let destinationURL: URL
        var partURL: URL
        let initialTransport: String?
        var attemptGeneration: UInt64
        var bytesWritten: Int64
        var cancelFlag: ExportCancellationFlag = ExportCancellationFlag()
        var task: Task<Void, Never>?
        var session: URLSession?
        var dataTask: URLSessionDataTask?
        var delegate: ExportStreamDelegate?
        var userPaused: Bool = false
        var userCancelled: Bool = false
    }

    private let prepareRequest: JournalExportRequestPreparer
    private let volumeSpaceProbe: JournalExportVolumeSpaceProbe
    private let revealFile: JournalExportFileRevealer
    private let onVerifyChunkRead: (@Sendable (Int64) -> Void)?
    private let publishGate = ExportPublishGate()
    private var nextAttemptGeneration: UInt64 = 0
    private var active: ActiveTransfer?
    private var savedURL: URL?
    private var savedExportID: String?
    private(set) var snapshot: JournalExportStatusSnapshot = .idle
    private var sleepActivity: NSObjectProtocol?
    private var statusListeners: [UUID: @MainActor (JournalExportStatusSnapshot) -> Void] = [:]
    private var lastBaseURLProvider: (@MainActor () -> URL?)?
    private var lastTransportProvider: (@MainActor () -> String?)?

    init(
        prepareRequest: @escaping JournalExportRequestPreparer = { $0.attachLoopbackCapability() },
        volumeSpaceProbe: @escaping JournalExportVolumeSpaceProbe = JournalExportVolumeSpace.availableBytes(for:),
        revealFile: @escaping JournalExportFileRevealer = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        onVerifyChunkRead: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.prepareRequest = prepareRequest
        self.volumeSpaceProbe = volumeSpaceProbe
        self.revealFile = revealFile
        self.onVerifyChunkRead = onVerifyChunkRead
    }

    func addStatusListener(_ listener: @escaping @MainActor (JournalExportStatusSnapshot) -> Void) -> UUID {
        let token = UUID()
        statusListeners[token] = listener
        return token
    }

    func removeStatusListener(_ token: UUID) {
        statusListeners.removeValue(forKey: token)
    }

    private func publish(_ next: JournalExportStatusSnapshot) {
        snapshot = next
        for listener in statusListeners.values {
            listener(next)
        }
    }

    private func beginSleepInhibit() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Saving journal export"
        )
    }

    private func endSleepInhibit() {
        if let token = sleepActivity {
            ProcessInfo.processInfo.endActivity(token)
            sleepActivity = nil
        }
    }

    static func partURL(for destinationURL: URL, exportID: String) -> URL {
        let dir = destinationURL.deletingLastPathComponent()
        return dir.appendingPathComponent(".solstone-export-\(exportID).part")
    }

    nonisolated static func partURL(for destinationURL: URL, exportID: String, generation: UInt64) -> URL {
        let dir = destinationURL.deletingLastPathComponent()
        return dir.appendingPathComponent(".solstone-export-\(exportID)-\(generation).part")
    }

    /// Scans `directoryURL` for the largest valid regular non-symlink partial matching
    /// `.solstone-export-<exportID>.part` or `.solstone-export-<exportID>-<gen>.part`
    /// so an interrupted save (from the first or any later attempt across app restarts)
    /// is credited during preflight and resumed cleanly.
    nonisolated static func discoverExistingPartFile(
        in directoryURL: URL,
        exportID: String,
        maxSize: Int64
    ) -> (url: URL, size: Int64)? {
        guard maxSize > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
              )
        else { return nil }
        let legacyName = ".solstone-export-\(exportID).part"
        let genPrefix = ".solstone-export-\(exportID)-"
        var best: (url: URL, size: Int64, mtimeSec: Int, mtimeNsec: Int)?
        for url in entries {
            let name = url.lastPathComponent
            let matches: Bool
            if name == legacyName {
                matches = true
            } else if name.hasPrefix(genPrefix), name.hasSuffix(".part") {
                let mid = name.dropFirst(genPrefix.count).dropLast(5)
                matches = !mid.isEmpty && mid.allSatisfy(\.isASCII) && mid.allSatisfy(\.isNumber)
            } else {
                matches = false
            }
            guard matches else { continue }
            var st = stat()
            let rc = url.path.withCString { Darwin.lstat($0, &st) }
            guard rc == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == Darwin.geteuid() else { continue }
            let size = Int64(st.st_size)
            guard size > 0, size <= maxSize else { continue }
            let mtimeSec = Int(st.st_mtimespec.tv_sec)
            let mtimeNsec = Int(st.st_mtimespec.tv_nsec)
            if let cur = best {
                if size > cur.size
                    || (size == cur.size && (mtimeSec > cur.mtimeSec || (mtimeSec == cur.mtimeSec && mtimeNsec > cur.mtimeNsec))) {
                    best = (url, size, mtimeSec, mtimeNsec)
                }
            } else {
                best = (url, size, mtimeSec, mtimeNsec)
            }
        }
        return best.map { ($0.url, $0.size) }
    }

    /// Adopts `preferredSource` into `targetPartURL` and cleans only stale owned regular
    /// partial files for `exportID`. If renaming `preferredSource` fails, `preferredSource`
    /// is preserved intact and returned so nothing is lost, and non-regular items (symlinks,
    /// directories, FIFOs) are never deleted.
    nonisolated static func adoptOrCleanExistingPartials(
        in directoryURL: URL,
        exportID: String,
        preferredSource: URL?,
        targetPartURL: URL,
        renameFile: (_ from: URL, _ to: URL) -> Bool = { src, dst in
            src.path.withCString { s in
                dst.path.withCString { d in
                    Darwin.rename(s, d) == 0
                }
            }
        }
    ) -> URL {
        let targetName = targetPartURL.lastPathComponent
        var adoptedURL = targetPartURL
        var preservedNames: Set<String> = [targetName]
        if let src = preferredSource {
            let srcName = src.lastPathComponent
            if srcName != targetName {
                if renameFile(src, targetPartURL) {
                    adoptedURL = targetPartURL
                } else {
                    adoptedURL = src
                    preservedNames.insert(srcName)
                }
            }
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return adoptedURL }
        let legacyName = ".solstone-export-\(exportID).part"
        let genPrefix = ".solstone-export-\(exportID)-"
        let uid = Darwin.geteuid()
        for url in entries where !preservedNames.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            let matches: Bool
            if name == legacyName {
                matches = true
            } else if name.hasPrefix(genPrefix), name.hasSuffix(".part") {
                let mid = name.dropFirst(genPrefix.count).dropLast(5)
                matches = !mid.isEmpty && mid.allSatisfy(\.isASCII) && mid.allSatisfy(\.isNumber)
            } else {
                matches = false
            }
            guard matches else { continue }
            var st = stat()
            let rc = url.path.withCString { Darwin.lstat($0, &st) }
            guard rc == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == uid else { continue }
            _ = url.path.withCString { Darwin.unlink($0) }
        }
        return adoptedURL
    }

    static func displayDestination(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    func deviceSpaceSnapshot() -> [String: Any] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        var out: [String: Any] = ["platform": "macos"]
        if let free = volumeSpaceProbe(downloads) {
            out["free_bytes"] = free
        }
        return out
    }

    func start(
        request: JournalExportStartRequest,
        window: NSWindow?,
        presentSavePanel: JournalExportSavePanelPresenter,
        baseURLProvider: @escaping @MainActor () -> URL?,
        transportProvider: @escaping @MainActor () -> String?
    ) async -> JournalExportStatusSnapshot {
        // If already running for this export, return current snapshot.
        if let current = active, current.request.exportID == request.exportID,
           snapshot.phase == "transferring" || snapshot.phase == "verifying" {
            return snapshot
        }
        // Clean up any stale prior partial before starting a new save.
        if let prior = active {
            cancelActiveInternal(prior, deletePart: true)
            active = nil
        }
        savedURL = nil
        savedExportID = nil
        lastBaseURLProvider = baseURLProvider
        lastTransportProvider = transportProvider

        publish(JournalExportStatusSnapshot(
            exportID: request.exportID,
            phase: "picking",
            bytesWritten: 0,
            totalBytes: request.sizeBytes,
            transport: transportProvider(),
            mode: request.mode
        ))

        guard let destinationURL = await presentSavePanel(request.filename, window) else {
            publish(.idle)
            return snapshot
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        let existingPart = Self.discoverExistingPartFile(
            in: parentDir,
            exportID: request.exportID,
            maxSize: request.sizeBytes
        )
        let required = JournalExportVolumeSpace.requiredBytes(
            for: request.sizeBytes,
            existingPartialBytes: existingPart?.size ?? 0
        )
        if let free = volumeSpaceProbe(destinationURL), free < required {
            let failed = JournalExportStatusSnapshot(
                exportID: request.exportID,
                phase: "error",
                bytesWritten: 0,
                totalBytes: request.sizeBytes,
                transport: transportProvider(),
                destinationDisplay: Self.displayDestination(for: destinationURL),
                errorCode: "insufficient_device_space",
                requiredBytes: required,
                availableBytes: free,
                mode: request.mode
            )
            publish(failed)
            return failed
        }

        nextAttemptGeneration &+= 1
        let gen = nextAttemptGeneration
        let targetPartURL = Self.partURL(for: destinationURL, exportID: request.exportID, generation: gen)
        let partURL: URL
        if let existingPart {
            partURL = Self.adoptOrCleanExistingPartials(
                in: parentDir,
                exportID: request.exportID,
                preferredSource: existingPart.url,
                targetPartURL: targetPartURL
            )
        } else {
            partURL = targetPartURL
        }
        let transfer = ActiveTransfer(
            request: request,
            destinationURL: destinationURL,
            partURL: partURL,
            initialTransport: transportProvider(),
            attemptGeneration: gen,
            bytesWritten: existingPart?.size ?? 0
        )
        active = transfer
        launchStreamingAttempt()
        return snapshot
    }

    func pause(exportID: String?) -> JournalExportStatusSnapshot {
        guard var current = active else { return snapshot }
        if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return snapshot }
        guard snapshot.phase == "transferring" else { return snapshot }
        publishGate.invalidateIfCurrent(current.attemptGeneration)
        current.cancelFlag.cancel()
        nextAttemptGeneration &+= 1
        current.attemptGeneration = nextAttemptGeneration
        current.userPaused = true
        current.delegate?.cancelStream()
        current.dataTask?.cancel()
        current.session?.invalidateAndCancel()
        current.task?.cancel()
        current.delegate = nil
        current.dataTask = nil
        current.session = nil
        current.task = nil
        active = current
        endSleepInhibit()
        publish(JournalExportStatusSnapshot(
            exportID: current.request.exportID,
            phase: "paused",
            bytesWritten: current.bytesWritten,
            totalBytes: current.request.sizeBytes,
            transport: lastTransportProvider?(),
            destinationDisplay: Self.displayDestination(for: current.destinationURL),
            pauseReason: "paused",
            mode: current.request.mode
        ))
        return snapshot
    }

    func resume(
        exportID: String?,
        baseURLProvider: @escaping @MainActor () -> URL?,
        transportProvider: @escaping @MainActor () -> String?
    ) -> JournalExportStatusSnapshot {
        guard var current = active else { return snapshot }
        if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return snapshot }
        guard snapshot.phase == "paused" else { return snapshot }
        lastBaseURLProvider = baseURLProvider
        lastTransportProvider = transportProvider
        current.userPaused = false
        current.userCancelled = false
        active = current
        launchStreamingAttempt()
        return snapshot
    }

    func cancel(exportID: String?) -> JournalExportStatusSnapshot {
        if let current = active {
            if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return snapshot }
            nextAttemptGeneration &+= 1
            publishGate.invalidateAll()
            cancelActiveInternal(current, deletePart: true)
            active = nil
        }
        savedURL = nil
        savedExportID = nil
        endSleepInhibit()
        publish(.idle)
        return snapshot
    }

    func reveal(exportID: String?) -> [String: Any] {
        guard let savedURL else { return ["revealed": false] }
        if let exportID, !exportID.isEmpty, let savedExportID, savedExportID != exportID {
            return ["revealed": false]
        }
        revealFile(savedURL)
        return ["revealed": true]
    }

    func cancelForUnpair() {
        if let current = active {
            nextAttemptGeneration &+= 1
            publishGate.invalidateAll()
            cancelActiveInternal(current, deletePart: true)
            active = nil
        }
        savedURL = nil
        savedExportID = nil
        endSleepInhibit()
        publish(.idle)
    }

    /// Called when the tunnel reconnects or changes route (`lan` <-> `relay`).
    func handleTransportChange(newTransport: String?) {
        guard let current = active, snapshot.phase == "transferring" else { return }
        if current.initialTransport == "local", newTransport == "relay" {
            // Pause honestly instead of silently spending relay bandwidth on a large export.
            var updated = current
            publishGate.invalidateIfCurrent(current.attemptGeneration)
            updated.cancelFlag.cancel()
            nextAttemptGeneration &+= 1
            updated.attemptGeneration = nextAttemptGeneration
            updated.userPaused = true
            updated.delegate?.cancelStream()
            updated.dataTask?.cancel()
            updated.session?.invalidateAndCancel()
            updated.task?.cancel()
            updated.delegate = nil
            updated.dataTask = nil
            updated.session = nil
            updated.task = nil
            active = updated
            endSleepInhibit()
            publish(JournalExportStatusSnapshot(
                exportID: current.request.exportID,
                phase: "paused",
                bytesWritten: current.bytesWritten,
                totalBytes: current.request.sizeBytes,
                transport: newTransport,
                destinationDisplay: Self.displayDestination(for: current.destinationURL),
                pauseReason: "relay_switched",
                mode: current.request.mode
            ))
        }
    }

    private func cancelActiveInternal(_ transfer: ActiveTransfer, deletePart: Bool) {
        var mutable = transfer
        mutable.userCancelled = true
        publishGate.invalidateIfCurrent(transfer.attemptGeneration)
        mutable.cancelFlag.cancel()
        mutable.delegate?.cancelStream()
        mutable.dataTask?.cancel()
        mutable.session?.invalidateAndCancel()
        mutable.task?.cancel()
        if deletePart {
            try? FileManager.default.removeItem(at: transfer.partURL)
        }
        endSleepInhibit()
    }

    private func isCurrentAttempt(_ generation: UInt64, exportID: String) -> Bool {
        guard let current = active else { return false }
        return current.attemptGeneration == generation
            && current.request.exportID == exportID
            && !current.userPaused
            && !current.userCancelled
    }

    private func launchStreamingAttempt() {
        guard var current = active else { return }
        guard let baseURL = lastBaseURLProvider?(),
              let downloadURL = URL(string: current.request.downloadPath, relativeTo: baseURL)?.absoluteURL
        else {
            endSleepInhibit()
            publish(JournalExportStatusSnapshot(
                exportID: current.request.exportID,
                phase: "paused",
                bytesWritten: current.bytesWritten,
                totalBytes: current.request.sizeBytes,
                transport: lastTransportProvider?(),
                destinationDisplay: Self.displayDestination(for: current.destinationURL),
                pauseReason: "disconnected",
                mode: current.request.mode
            ))
            return
        }

        // Invalidate any prior in-flight attempt before starting a new one.
        current.cancelFlag.cancel()
        current.delegate?.cancelStream()
        current.dataTask?.cancel()
        current.session?.invalidateAndCancel()
        current.task?.cancel()
        nextAttemptGeneration &+= 1
        let generation = nextAttemptGeneration
        let cancelFlag = ExportCancellationFlag()
        let nextPartURL = Self.partURL(
            for: current.destinationURL,
            exportID: current.request.exportID,
            generation: generation
        )
        if current.partURL.lastPathComponent != nextPartURL.lastPathComponent,
           FileManager.default.fileExists(atPath: current.partURL.path) {
            let renamed = current.partURL.path.withCString { src in
                nextPartURL.path.withCString { dst in
                    Darwin.rename(src, dst) == 0
                }
            }
            if renamed {
                current.partURL = nextPartURL
            }
        } else {
            current.partURL = nextPartURL
        }
        current.attemptGeneration = generation
        current.cancelFlag = cancelFlag
        publishGate.setActiveGeneration(generation)

        // Confirm on-disk partial byte offset before requesting a byte range.
        // A full-length partial (e.g. app quit during verification) is preserved
        // and verified after a 1-byte live eligibility/erasure/ETag check instead
        // of re-downloading the entire archive from byte 0.
        let diskOffset = Self.existingPartSize(at: current.partURL)
        let isFullPartial = (diskOffset == current.request.sizeBytes && diskOffset > 0)
        let resumeOffset: Int64 = (diskOffset > 0 && diskOffset < current.request.sizeBytes) ? diskOffset : 0
        let initialBytesWritten = isFullPartial ? diskOffset : resumeOffset
        current.bytesWritten = initialBytesWritten
        beginSleepInhibit()

        let request = current.request
        let partURL = current.partURL
        let destinationURL = current.destinationURL
        let transportNow = lastTransportProvider?()
        let prepare = self.prepareRequest
        let publishGate = self.publishGate
        let verifyHook = self.onVerifyChunkRead

        publish(JournalExportStatusSnapshot(
            exportID: request.exportID,
            phase: "transferring",
            bytesWritten: initialBytesWritten,
            totalBytes: request.sizeBytes,
            transport: transportNow,
            destinationDisplay: Self.displayDestination(for: destinationURL),
            mode: request.mode
        ))

        let expectedSize = request.sizeBytes
        let headerCancelCheck: (@Sendable (HTTPURLResponse) -> Bool)?
        if isFullPartial {
            headerCancelCheck = { (http: HTTPURLResponse) -> Bool in
                guard http.statusCode == 200 else { return false }
                if let rawETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawETag.isEmpty {
                    return true
                }
                if let lenStr = http.value(forHTTPHeaderField: "Content-Length")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let len = Int64(lenStr),
                   len != expectedSize {
                    return true
                }
                return false
            }
        } else {
            headerCancelCheck = nil
        }
        let delegate = ExportStreamDelegate(shouldCancelAtHeaders: headerCancelCheck)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 48
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var urlRequest = URLRequest(url: downloadURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if isFullPartial {
            let lastByte = request.sizeBytes - 1
            urlRequest.setValue("bytes=\(lastByte)-\(lastByte)", forHTTPHeaderField: "Range")
            urlRequest.setValue(request.etag, forHTTPHeaderField: "If-Range")
        } else if resumeOffset > 0 {
            urlRequest.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            urlRequest.setValue(request.etag, forHTTPHeaderField: "If-Range")
        }
        prepare(&urlRequest)

        let dataTask = session.dataTask(with: urlRequest)
        current.delegate = delegate
        current.session = session
        current.dataTask = dataTask

        let task = Task { [weak self] in
            defer {
                delegate.cancelStream()
                session.finishTasksAndInvalidate()
            }
            do {
                let (http, stream) = try await delegate.startAndAwaitResponse(task: dataTask)
                guard self?.isCurrentAttempt(generation, exportID: request.exportID) == true else { return }
                let status = http.statusCode

                if status == 401 || status == 403 {
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(generation: generation, exportID: request.exportID, code: "export_requester_revoked")
                    return
                }
                if status == 404 || status == 410 {
                    var bodyData = Data()
                    while let chunk = try await stream.nextChunk() {
                        if bodyData.count < 8192 { bodyData.append(chunk) }
                    }
                    let serverCode = Self.extractErrorCode(from: bodyData)
                    let mapped: String
                    if serverCode == "export_invalidated_by_erasure" {
                        mapped = "export_invalidated_by_erasure"
                    } else {
                        mapped = "export_expired"
                    }
                    guard self?.isCurrentAttempt(generation, exportID: request.exportID) == true else { return }
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(generation: generation, exportID: request.exportID, code: mapped)
                    return
                }
                if status == 416 {
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(generation: generation, exportID: request.exportID, code: "save_failed")
                    return
                }
                guard status == 200 || status == 206 else {
                    self?.handleStreamDrop(generation: generation, exportID: request.exportID, bytesWritten: initialBytesWritten)
                    return
                }

                let rawETag = http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasValidator = rawETag.map { !$0.isEmpty } ?? false
                let contentLengthHeader = http.value(forHTTPHeaderField: "Content-Length").flatMap {
                    Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let lengthMatches = (contentLengthHeader == nil || contentLengthHeader == request.sizeBytes)

                if isFullPartial && status == 200 && (hasValidator || !lengthMatches) {
                    delegate.cancelStream()
                    guard hasValidator, Self.matchesStrongETag(rawETag, expected: request.etag), lengthMatches else {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                        return
                    }
                    // Range-ignoring 200 with matching strong validator: body cancelled at headers;
                    // proceed directly to cooperative local SHA-256 verification before publish.
                } else if isFullPartial && status == 206 {
                    let lastByte = request.sizeBytes - 1
                    guard Self.matchesContentRange(
                        http.value(forHTTPHeaderField: "Content-Range"),
                        expectedStart: lastByte,
                        expectedTotal: request.sizeBytes
                    ), Self.matchesStrongETag(
                        http.value(forHTTPHeaderField: "ETag"),
                        expected: request.etag
                    ) else {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                        return
                    }
                    var probeBytes = 0
                    while let chunk = try await stream.nextChunk() {
                        if cancelFlag.isCancelled || Task.isCancelled { return }
                        probeBytes += chunk.count
                        if probeBytes > 1 {
                            try? FileManager.default.removeItem(at: partURL)
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                            return
                        }
                    }
                    guard probeBytes == 1 else {
                        self?.handleStreamDrop(generation: generation, exportID: request.exportID, bytesWritten: diskOffset)
                        return
                    }
                } else {
                    let startOffset: Int64
                    if status == 206 {
                        guard Self.matchesContentRange(
                            http.value(forHTTPHeaderField: "Content-Range"),
                            expectedStart: resumeOffset,
                            expectedTotal: request.sizeBytes
                        ), Self.matchesStrongETag(
                            http.value(forHTTPHeaderField: "ETag"),
                            expected: request.etag
                        ) else {
                            try? FileManager.default.removeItem(at: partURL)
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                            return
                        }
                        startOffset = resumeOffset
                    } else {
                        startOffset = 0
                    }

                    let writeTask = Task.detached(priority: .userInitiated) { [weak self] () -> Result<Int64, Error> in
                        do {
                            if cancelFlag.isCancelled || Task.isCancelled {
                                throw CancellationError()
                            }
                            let fd = try Self.openPrivatePartFile(at: partURL, truncate: startOffset == 0)
                            defer { Darwin.close(fd) }
                            if startOffset > 0 {
                                guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) == off_t(startOffset) else {
                                    throw POSIXError(.EIO)
                                }
                            }
                            var written = startOffset
                            var windowStart = ContinuousClock.now
                            var windowBytes: Int64 = 0
                            var lastEmit = ContinuousClock.now
                            while let chunk = try await stream.nextChunk() {
                                if cancelFlag.isCancelled || Task.isCancelled {
                                    throw CancellationError()
                                }
                                if written + Int64(chunk.count) > request.sizeBytes {
                                    throw POSIXError(.EFBIG)
                                }
                                try Self.writeAll(fd: fd, data: chunk)
                                written += Int64(chunk.count)
                                windowBytes += Int64(chunk.count)
                                let now = ContinuousClock.now
                                if now - lastEmit >= .milliseconds(250) {
                                    let elapsed = now - windowStart
                                    let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                                    let rate = secs > 0.05 ? Double(windowBytes) / secs : nil
                                    if secs >= 2.0 {
                                        windowStart = now
                                        windowBytes = 0
                                    }
                                    lastEmit = now
                                    let progress = written
                                    await self?.updateProgress(
                                        generation: generation,
                                        exportID: request.exportID,
                                        bytesWritten: progress,
                                        rateBytesPerSec: rate
                                    )
                                }
                            }
                            if cancelFlag.isCancelled || Task.isCancelled {
                                throw CancellationError()
                            }
                            if Darwin.fsync(fd) != 0 {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                            return .success(written)
                        } catch {
                            return .failure(error)
                        }
                    }
                    let writeResult: Result<Int64, Error> = await withTaskCancellationHandler {
                        await writeTask.value
                    } onCancel: {
                        cancelFlag.cancel()
                        writeTask.cancel()
                    }

                    guard self?.isCurrentAttempt(generation, exportID: request.exportID) == true else { return }

                    switch writeResult {
                    case .failure(let error):
                        if cancelFlag.isCancelled || Task.isCancelled || error is CancellationError { return }
                        let onDisk = Self.existingPartSize(at: partURL)
                        if Self.isDiskSpaceError(error) {
                            try? FileManager.default.removeItem(at: partURL)
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "insufficient_device_space")
                        } else if let posix = error as? POSIXError, posix.code == .EFBIG {
                            try? FileManager.default.removeItem(at: partURL)
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                        } else if Self.isDestinationWriteError(error) {
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "dest_write_failed")
                        } else {
                            self?.handleStreamDrop(generation: generation, exportID: request.exportID, bytesWritten: onDisk)
                        }
                        return
                    case .success(let finalWritten):
                        guard finalWritten == request.sizeBytes else {
                            self?.handleStreamDrop(generation: generation, exportID: request.exportID, bytesWritten: finalWritten)
                            return
                        }
                    }
                }

                self?.enterVerifying(generation: generation, exportID: request.exportID, totalBytes: request.sizeBytes)

                let verifyTask = Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                    do {
                        let actual = try Self.sha256File(
                            at: partURL,
                            shouldCancel: { cancelFlag.isCancelled || Task.isCancelled },
                            onChunkRead: verifyHook
                        )
                        return .success(actual)
                    } catch {
                        return .failure(error)
                    }
                }
                let verifyResult: Result<String, Error> = await withTaskCancellationHandler {
                    await verifyTask.value
                } onCancel: {
                    cancelFlag.cancel()
                    verifyTask.cancel()
                }

                guard self?.isCurrentAttempt(generation, exportID: request.exportID) == true else { return }

                switch verifyResult {
                case .failure(let error):
                    if cancelFlag.isCancelled || Task.isCancelled || error is CancellationError { return }
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(generation: generation, exportID: request.exportID, code: "dest_write_failed")
                case .success(let actualSHA):
                    guard actualSHA == request.sha256 else {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(generation: generation, exportID: request.exportID, code: "checksum_mismatch")
                        return
                    }
                    guard self?.isCurrentAttempt(generation, exportID: request.exportID) == true else { return }
                    do {
                        try publishGate.runIfActive(generation: generation, cancelFlag: cancelFlag) {
                            try Self.publishVerifiedPart(partURL: partURL, to: destinationURL)
                        }
                        self?.finishSaved(
                            generation: generation,
                            exportID: request.exportID,
                            destinationURL: destinationURL,
                            totalBytes: request.sizeBytes
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        if self?.isCurrentAttempt(generation, exportID: request.exportID) == true {
                            try? FileManager.default.removeItem(at: partURL)
                            self?.finishFailure(generation: generation, exportID: request.exportID, code: "dest_write_failed")
                        }
                    }
                }
            } catch {
                if cancelFlag.isCancelled || Task.isCancelled || error is CancellationError { return }
                let onDisk = Self.existingPartSize(at: partURL)
                self?.handleStreamDrop(generation: generation, exportID: request.exportID, bytesWritten: onDisk)
            }
        }
        current.task = task
        active = current
    }

    private func updateProgress(generation: UInt64, exportID: String, bytesWritten: Int64, rateBytesPerSec: Double?) {
        guard var current = active,
              current.attemptGeneration == generation,
              current.request.exportID == exportID,
              !current.userPaused, !current.userCancelled,
              snapshot.phase == "transferring"
        else { return }
        current.bytesWritten = bytesWritten
        active = current
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "transferring",
            bytesWritten: bytesWritten,
            totalBytes: current.request.sizeBytes,
            rateBytesPerSec: rateBytesPerSec,
            transport: lastTransportProvider?(),
            destinationDisplay: Self.displayDestination(for: current.destinationURL),
            mode: current.request.mode
        ))
    }

    private func enterVerifying(generation: UInt64, exportID: String, totalBytes: Int64) {
        guard var current = active,
              current.attemptGeneration == generation,
              current.request.exportID == exportID,
              !current.userPaused, !current.userCancelled
        else { return }
        current.bytesWritten = totalBytes
        active = current
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "verifying",
            bytesWritten: totalBytes,
            totalBytes: totalBytes,
            transport: lastTransportProvider?(),
            destinationDisplay: Self.displayDestination(for: current.destinationURL),
            mode: current.request.mode
        ))
    }

    private func handleStreamDrop(generation: UInt64, exportID: String, bytesWritten: Int64) {
        guard var current = active,
              current.attemptGeneration == generation,
              current.request.exportID == exportID else { return }
        if current.userPaused || current.userCancelled { return }
        current.bytesWritten = bytesWritten
        current.delegate = nil
        current.task = nil
        current.dataTask = nil
        current.session = nil
        active = current
        endSleepInhibit()
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "paused",
            bytesWritten: bytesWritten,
            totalBytes: current.request.sizeBytes,
            transport: lastTransportProvider?(),
            destinationDisplay: Self.displayDestination(for: current.destinationURL),
            pauseReason: "disconnected",
            mode: current.request.mode
        ))
    }

    private func finishFailure(generation: UInt64, exportID: String, code: String) {
        guard let current = active,
              current.attemptGeneration == generation,
              current.request.exportID == exportID else { return }
        if current.userCancelled { return }
        let dest = Self.displayDestination(for: current.destinationURL)
        let mode = current.request.mode
        let total = current.request.sizeBytes
        active = nil
        endSleepInhibit()
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "error",
            bytesWritten: 0,
            totalBytes: total,
            transport: lastTransportProvider?(),
            destinationDisplay: dest,
            errorCode: code,
            mode: mode
        ))
    }

    private func finishSaved(generation: UInt64, exportID: String, destinationURL: URL, totalBytes: Int64) {
        guard let current = active,
              current.attemptGeneration == generation,
              current.request.exportID == exportID,
              !current.userPaused, !current.userCancelled else { return }
        let mode = current.request.mode
        active = nil
        savedURL = destinationURL
        savedExportID = exportID
        endSleepInhibit()
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "saved",
            bytesWritten: totalBytes,
            totalBytes: totalBytes,
            transport: lastTransportProvider?(),
            destinationDisplay: Self.displayDestination(for: destinationURL),
            canReveal: true,
            verified: true,
            mode: mode
        ))
    }

    // MARK: - Low-level file helpers

    nonisolated private static func existingPartSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return max(0, size.int64Value)
    }

    nonisolated private static func openPrivatePartFile(at url: URL, truncate: Bool) throws -> Int32 {
        var flags: Int32 = O_CREAT | O_RDWR | O_NOFOLLOW
        if truncate { flags |= O_TRUNC }
        let fd = url.path.withCString { Darwin.open($0, flags, mode_t(0o600)) }
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        return fd
    }

    nonisolated private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        }
    }

    nonisolated static func sha256File(
        at url: URL,
        shouldCancel: @Sendable () -> Bool = { false },
        onChunkRead: (@Sendable (Int64) -> Void)? = nil
    ) throws -> String {
        if shouldCancel() || Task.isCancelled {
            throw CancellationError()
        }
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var totalRead: Int64 = 0
        while true {
            if shouldCancel() || Task.isCancelled {
                throw CancellationError()
            }
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            totalRead += Int64(n)
            onChunkRead?(totalRead)
            if shouldCancel() || Task.isCancelled {
                throw CancellationError()
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
        }
        if shouldCancel() || Task.isCancelled {
            throw CancellationError()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func publishVerifiedPart(partURL: URL, to destinationURL: URL) throws {
        // Atomic same-volume rename preserves any existing destination file until this single step succeeds.
        let rc = partURL.path.withCString { src in
            destinationURL.path.withCString { dst in
                Darwin.rename(src, dst)
            }
        }
        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = destinationURL.path.withCString { Darwin.chmod($0, mode_t(0o600)) }
    }

    nonisolated private static func matchesContentRange(_ header: String?, expectedStart: Int64, expectedTotal: Int64) -> Bool {
        guard let header, header.hasPrefix("bytes ") else { return false }
        let rest = header.dropFirst(6)
        let parts = rest.split(separator: "/")
        guard parts.count == 2,
              let total = Int64(parts[1]), total == expectedTotal else { return false }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start == expectedStart,
              end >= start,
              end < expectedTotal else { return false }
        return true
    }

    nonisolated private static func matchesStrongETag(_ header: String?, expected: String) -> Bool {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !wanted.hasPrefix("W/"),
              let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.hasPrefix("W/") else { return false }
        return raw == wanted
    }

    nonisolated private static func extractErrorCode(from data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = obj["code"] as? String else { return nil }
        return code
    }

    nonisolated private static func isDiskSpaceError(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT {
            return true
        }
        return false
    }

    nonisolated private static func isDestinationWriteError(_ error: Error) -> Bool {
        error is POSIXError
    }
}

/// Per-window message handler adapter connecting `JournalImportHost` (`window.solstoneJournalHost` v2)
/// to the app-scoped `JournalExportTransferManager`.
@MainActor
final class JournalExportHost {
    let contract: JournalExportContract
    let manager: JournalExportTransferManager
    private let liveBaseURL: @MainActor () -> URL?
    private let transportKind: @MainActor () -> String?
    private let presentSavePanel: JournalExportSavePanelPresenter
    weak var presentationWindow: NSWindow?
    private let windowProvider: @MainActor () -> NSWindow?
    private var listenerToken: UUID?
    private var eventEmitter: (@MainActor ([String: Any]) -> Void)?

    init(
        contract: JournalExportContract,
        manager: JournalExportTransferManager,
        liveBaseURL: @escaping @MainActor () -> URL?,
        transportKind: @escaping @MainActor () -> String? = { nil },
        presentSavePanel: @escaping JournalExportSavePanelPresenter = JournalExportSavePanel.present(suggestedFilename:over:),
        windowProvider: (@MainActor () -> NSWindow?)? = nil
    ) {
        self.contract = contract
        self.manager = manager
        self.liveBaseURL = liveBaseURL
        self.transportKind = transportKind
        self.presentSavePanel = presentSavePanel
        self.windowProvider = windowProvider ?? { nil }
    }

    func attachEventEmitter(_ emitter: @escaping @MainActor ([String: Any]) -> Void) {
        detachEventEmitter()
        eventEmitter = emitter
        listenerToken = manager.addStatusListener { [weak self] snapshot in
            self?.eventEmitter?(snapshot.toJSON())
        }
    }

    func detachEventEmitter() {
        if let token = listenerToken {
            manager.removeStatusListener(token)
            listenerToken = nil
        }
        eventEmitter = nil
    }

    func handles(type: String) -> Bool {
        type == contract.start
            || type == contract.status
            || type == contract.pause
            || type == contract.resume
            || type == contract.cancel
            || type == contract.reveal
            || type == contract.deviceSpace
    }

    func handle(_ message: [String: Any], type: String) async -> [String: Any] {
        let id = (message["id"] as? String) ?? ""
        switch type {
        case contract.deviceSpace:
            var reply = manager.deviceSpaceSnapshot()
            reply["id"] = id
            return reply
        case contract.status:
            return manager.snapshot.toJSON(replyID: id)
        case contract.start:
            guard let request = JournalExportStartRequest.parse(message) else {
                exportHostLog.notice("export-host: refused invalid export.start payload")
                return ["type": contract.unsupported, "id": id]
            }
            let snap = await manager.start(
                request: request,
                window: presentationWindow ?? windowProvider(),
                presentSavePanel: presentSavePanel,
                baseURLProvider: liveBaseURL,
                transportProvider: transportKind
            )
            return snap.toJSON(replyID: id)
        case contract.pause:
            let exportID = message["export_id"] as? String
            return manager.pause(exportID: exportID).toJSON(replyID: id)
        case contract.resume:
            let exportID = message["export_id"] as? String
            return manager.resume(
                exportID: exportID,
                baseURLProvider: liveBaseURL,
                transportProvider: transportKind
            ).toJSON(replyID: id)
        case contract.cancel:
            let exportID = message["export_id"] as? String
            return manager.cancel(exportID: exportID).toJSON(replyID: id)
        case contract.reveal:
            let exportID = message["export_id"] as? String
            var reply = manager.reveal(exportID: exportID)
            reply["id"] = id
            return reply
        default:
            return ["type": contract.unsupported, "id": id]
        }
    }
}
