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

    static func requiredBytes(for exportSizeBytes: Int64) -> Int64 {
        let headroom = min(Int64(64 * 1024 * 1024), max(Int64(1 * 1024 * 1024), exportSizeBytes / 100))
        return exportSizeBytes.saturatingAdd(headroom)
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (sum, overflow) = self.addingReportingOverflow(other)
        return overflow ? Int64.max : sum
    }
}

/// Low-memory streaming HTTP chunk reader backed by `URLSessionDataDelegate`.
private final class ExportStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<(HTTPURLResponse, AsyncThrowingStream<Data, Error>), Error>?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Error>?
    private var deliveredResponse = false
    private var finished = false

    func awaitResponse() async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let (s, c) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
            self.stream = s
            self.streamContinuation = c
            self.responseContinuation = continuation
            lock.unlock()
        }
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
        lock.lock()
        let cont = responseContinuation
        responseContinuation = nil
        let stream = self.stream
        deliveredResponse = true
        lock.unlock()
        if let cont, let stream {
            cont.resume(returning: (http, stream))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let c = streamContinuation
        lock.unlock()
        c?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            failAll(error)
        } else {
            lock.lock()
            if !deliveredResponse, let cont = responseContinuation {
                responseContinuation = nil
                finished = true
                let c = streamContinuation
                streamContinuation = nil
                lock.unlock()
                cont.resume(throwing: URLError(.badServerResponse))
                c?.finish(throwing: URLError(.badServerResponse))
                return
            }
            finished = true
            let c = streamContinuation
            streamContinuation = nil
            lock.unlock()
            c?.finish()
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let cont = responseContinuation
        responseContinuation = nil
        let c = streamContinuation
        streamContinuation = nil
        finished = true
        lock.unlock()
        cont?.resume(throwing: error)
        c?.finish(throwing: error)
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
        let partURL: URL
        let initialTransport: String?
        var bytesWritten: Int64
        var task: Task<Void, Never>?
        var session: URLSession?
        var dataTask: URLSessionDataTask?
        var userPaused: Bool = false
        var userCancelled: Bool = false
    }

    private let prepareRequest: JournalExportRequestPreparer
    private let volumeSpaceProbe: JournalExportVolumeSpaceProbe
    private let revealFile: JournalExportFileRevealer
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
        }
    ) {
        self.prepareRequest = prepareRequest
        self.volumeSpaceProbe = volumeSpaceProbe
        self.revealFile = revealFile
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

        let required = JournalExportVolumeSpace.requiredBytes(for: request.sizeBytes)
        if let free = volumeSpaceProbe(destinationURL), free < required {
            let failed = JournalExportStatusSnapshot(
                exportID: request.exportID,
                phase: "failed",
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

        let partURL = Self.partURL(for: destinationURL, exportID: request.exportID)
        let transfer = ActiveTransfer(
            request: request,
            destinationURL: destinationURL,
            partURL: partURL,
            initialTransport: transportProvider(),
            bytesWritten: 0
        )
        active = transfer
        launchStreamingAttempt()
        return snapshot
    }

    func pause(exportID: String?) -> JournalExportStatusSnapshot {
        guard var current = active else { return snapshot }
        if let exportID, !exportID.isEmpty, current.request.exportID != exportID { return snapshot }
        guard snapshot.phase == "transferring" else { return snapshot }
        current.userPaused = true
        current.dataTask?.cancel()
        current.session?.invalidateAndCancel()
        current.task?.cancel()
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
            updated.userPaused = true
            updated.dataTask?.cancel()
            updated.session?.invalidateAndCancel()
            updated.task?.cancel()
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
        mutable.dataTask?.cancel()
        mutable.session?.invalidateAndCancel()
        mutable.task?.cancel()
        if deletePart {
            try? FileManager.default.removeItem(at: transfer.partURL)
        }
        endSleepInhibit()
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

        // Confirm on-disk partial byte offset before requesting a byte range.
        let diskOffset = Self.existingPartSize(at: current.partURL)
        let resumeOffset = (diskOffset > 0 && diskOffset < current.request.sizeBytes) ? diskOffset : 0
        current.bytesWritten = resumeOffset
        beginSleepInhibit()

        let request = current.request
        let partURL = current.partURL
        let destinationURL = current.destinationURL
        let transportNow = lastTransportProvider?()
        let prepare = self.prepareRequest

        publish(JournalExportStatusSnapshot(
            exportID: request.exportID,
            phase: "transferring",
            bytesWritten: resumeOffset,
            totalBytes: request.sizeBytes,
            transport: transportNow,
            destinationDisplay: Self.displayDestination(for: destinationURL),
            mode: request.mode
        ))

        let delegate = ExportStreamDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 48
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var urlRequest = URLRequest(url: downloadURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if resumeOffset > 0 {
            urlRequest.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
            urlRequest.setValue(request.etag, forHTTPHeaderField: "If-Range")
        }
        prepare(&urlRequest)

        let dataTask = session.dataTask(with: urlRequest)
        current.session = session
        current.dataTask = dataTask

        let task = Task { [weak self] in
            defer { session.finishTasksAndInvalidate() }
            dataTask.resume()
            do {
                let (http, stream) = try await delegate.awaitResponse()
                let status = http.statusCode

                if status == 401 || status == 403 {
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "export_requester_revoked")
                    return
                }
                if status == 404 || status == 410 {
                    var bodyData = Data()
                    for try await chunk in stream {
                        if bodyData.count < 8192 { bodyData.append(chunk) }
                    }
                    let serverCode = Self.extractErrorCode(from: bodyData)
                    let mapped: String
                    if serverCode == "export_invalidated_by_erasure" {
                        mapped = "export_invalidated_by_erasure"
                    } else {
                        mapped = "export_expired"
                    }
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: mapped)
                    return
                }
                if status == 416 {
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "save_failed")
                    return
                }
                guard status == 200 || status == 206 else {
                    self?.handleStreamDrop(exportID: request.exportID, bytesWritten: resumeOffset)
                    return
                }

                let startOffset: Int64
                if status == 206 {
                    guard Self.matchesContentRange(
                        http.value(forHTTPHeaderField: "Content-Range"),
                        expectedStart: resumeOffset,
                        expectedTotal: request.sizeBytes
                    ) else {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "save_failed")
                        return
                    }
                    startOffset = resumeOffset
                } else {
                    startOffset = 0
                }

                let writeResult: Result<Int64, Error> = await Task.detached(priority: .userInitiated) { [weak self] in
                    do {
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
                        for try await chunk in stream {
                            try Task.checkCancellation()
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
                                    exportID: request.exportID,
                                    bytesWritten: progress,
                                    rateBytesPerSec: rate
                                )
                            }
                        }
                        if Darwin.fsync(fd) != 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        return .success(written)
                    } catch {
                        return .failure(error)
                    }
                }.value

                switch writeResult {
                case .failure(let error):
                    if Task.isCancelled { return }
                    let onDisk = Self.existingPartSize(at: partURL)
                    if Self.isDiskSpaceError(error) {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    } else if Self.isDestinationWriteError(error) {
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    } else {
                        self?.handleStreamDrop(exportID: request.exportID, bytesWritten: onDisk)
                    }
                    return
                case .success(let finalWritten):
                    guard finalWritten == request.sizeBytes else {
                        self?.handleStreamDrop(exportID: request.exportID, bytesWritten: finalWritten)
                        return
                    }
                }

                self?.enterVerifying(exportID: request.exportID, totalBytes: request.sizeBytes)

                let verifyResult: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let actual = try Self.sha256File(at: partURL)
                        return .success(actual)
                    } catch {
                        return .failure(error)
                    }
                }.value

                switch verifyResult {
                case .failure:
                    try? FileManager.default.removeItem(at: partURL)
                    self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                case .success(let actualSHA):
                    guard actualSHA == request.sha256 else {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "checksum_mismatch")
                        return
                    }
                    do {
                        try Self.publishVerifiedPart(partURL: partURL, to: destinationURL)
                        self?.finishSaved(
                            exportID: request.exportID,
                            destinationURL: destinationURL,
                            totalBytes: request.sizeBytes
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: partURL)
                        self?.finishFailure(exportID: request.exportID, code: "dest_write_failed")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                let onDisk = Self.existingPartSize(at: partURL)
                self?.handleStreamDrop(exportID: request.exportID, bytesWritten: onDisk)
            }
        }
        current.task = task
        active = current
    }

    private func updateProgress(exportID: String, bytesWritten: Int64, rateBytesPerSec: Double?) {
        guard var current = active, current.request.exportID == exportID,
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

    private func enterVerifying(exportID: String, totalBytes: Int64) {
        guard var current = active, current.request.exportID == exportID,
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

    private func handleStreamDrop(exportID: String, bytesWritten: Int64) {
        guard var current = active, current.request.exportID == exportID else { return }
        if current.userPaused || current.userCancelled { return }
        current.bytesWritten = bytesWritten
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

    private func finishFailure(exportID: String, code: String) {
        guard let current = active, current.request.exportID == exportID else { return }
        if current.userCancelled { return }
        let dest = Self.displayDestination(for: current.destinationURL)
        let mode = current.request.mode
        let total = current.request.sizeBytes
        active = nil
        endSleepInhibit()
        publish(JournalExportStatusSnapshot(
            exportID: exportID,
            phase: "failed",
            bytesWritten: 0,
            totalBytes: total,
            transport: lastTransportProvider?(),
            destinationDisplay: dest,
            errorCode: code,
            mode: mode
        ))
    }

    private func finishSaved(exportID: String, destinationURL: URL, totalBytes: Int64) {
        guard let current = active, current.request.exportID == exportID else { return }
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

    nonisolated private static func sha256File(at url: URL) throws -> String {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if n == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
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
