// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import solstone

/// Records begin/end counts and currently active count for `ImportEngine`'s delivery activity hold.
private final class ImportActivitySpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var reasons: [String] = []

    func begin(_ reason: String) -> @Sendable () -> Void {
        lock.withLock {
            begins += 1
            active += 1
            maxActive = max(maxActive, active)
            reasons.append(reason)
        }
        return { [weak self] in
            self?.lock.withLock {
                self?.ends += 1
                self?.active -= 1
            }
        }
    }

    var counts: (begins: Int, ends: Int, active: Int) {
        lock.withLock { (begins, ends, active) }
    }
}

/// In-process URLProtocol that stalls a request until cancelled, proving `ImportStreamedRequest`
/// forwards Swift `Task` cancellation into `URLSessionTask.cancel()` without opening a socket.
private final class StallingImportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var startedContinuation: CheckedContinuation<Void, Never>?
    nonisolated(unsafe) private static var didStart = false
    nonisolated(unsafe) private static var didStop = false

    static func reset() {
        lock.withLock {
            startedContinuation = nil
            didStart = false
            didStop = false
        }
    }

    static var stopped: Bool { lock.withLock { didStop } }

    static func waitUntilStarted() async {
        await withCheckedContinuation { c in
            let already: Bool = lock.withLock {
                if didStart { return true }
                startedContinuation = c
                return false
            }
            if already { c.resume() }
        }
    }

    static func waitUntilStopped(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if stopped { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let notify: CheckedContinuation<Void, Never>? = Self.lock.withLock {
            Self.didStart = true
            let c = Self.startedContinuation
            Self.startedContinuation = nil
            return c
        }
        notify?.resume()
    }

    override func stopLoading() {
        Self.lock.withLock { Self.didStop = true }
    }
}

/// A transport whose answers the test sets, and which can hold a save until the test lets it go.
private final class FakeImportTransport: ImportTransport, @unchecked Sendable {
    struct RecordedChunkCall: Equatable, Sendable {
        var uploadID: String
        var offset: Int64
        var length: Int
        var sha256: String
        var serverURL: String
    }

    private struct FakeUploadSession {
        var uploadID: String
        var clientItemID: String
        var totalBytes: Int64
        var chunkBytes: Int64
        var expectedSHA256: String
        var received: Data
        var nextOffset: Int64
    }

    private let lock = NSLock()
    private var saves: [String: [ImportOutcome]] = [:]
    private var starts: [ImportOutcome] = []
    private var inspects: [String: [ImportInspectOutcome]] = [:]
    private var probeQueue: [ImportCapabilityProbeOutcome] = []
    private var createQueue: [ImportUploadCreateOutcome] = []
    private var chunkQueue: [ImportUploadChunkOutcome] = []
    private var statusQueue: [ImportUploadStatusOutcome] = []
    private var commitQueue: [ImportUploadCommitOutcome] = []
    private var abortQueue: [ImportUploadAbortOutcome] = []
    private var sessions: [String: FakeUploadSession] = [:]
    private var nextSessionSeq = 0
    private var holdChunkAtOffset: Int64?
    private var holdChunkCancellableFlag = false
    private var onCommitEnter: (@Sendable () -> Void)?

    var defaultProbe: ImportCapabilityProbeOutcome = .unsupported
    private(set) var saveCalls: [String] = []
    private(set) var startCalls: [String] = []
    private(set) var inspectCalls: [String] = []
    private(set) var probeCalls: [String] = []
    private(set) var createCalls: [(request: ImportUploadCreateRequest, serverURL: String)] = []
    private(set) var chunkCalls: [RecordedChunkCall] = []
    private(set) var statusCalls: [(uploadID: String, serverURL: String)] = []
    private(set) var commitCalls: [(uploadID: String, sha256: String, serverURL: String)] = []
    private(set) var abortCalls: [(uploadID: String, serverURL: String)] = []

    var defaultSave: ImportOutcome = .saved(path: "/journal/imports/x/p", timestamp: "20261111_120000")
    var defaultStart: ImportOutcome = .delivered(importID: "20261111_120000")
    var defaultInspect: ImportInspectOutcome = .stillPending
    private var hold: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var holdNextCancellableFlag = false
    private var holdNextInspectFlag = false
    private var heldStarted: CheckedContinuation<Void, Never>?
    private var onSaveEnter: (@Sendable () -> Void)?

    func answerSave(_ id: String, _ outcomes: ImportOutcome...) { lock.withLock { saves[id, default: []] += outcomes } }
    func answerStart(_ outcomes: ImportOutcome...) { lock.withLock { starts += outcomes } }
    func answerInspect(_ importID: String, _ outcomes: ImportInspectOutcome...) { lock.withLock { inspects[importID, default: []] += outcomes } }
    func enableResumable(thresholdBytes: Int64 = 8 * 1024, chunkBytes: Int64 = 4 * 1024, maxFileBytes: Int64 = importMaxBytes) {
        lock.withLock {
            defaultProbe = .supported(ImportResumableCapabilities(
                thresholdBytes: thresholdBytes,
                chunkBytes: chunkBytes,
                maxFileBytes: maxFileBytes
            ))
        }
    }
    func answerProbe(_ outcomes: ImportCapabilityProbeOutcome...) { lock.withLock { probeQueue += outcomes } }
    func answerCreate(_ outcomes: ImportUploadCreateOutcome...) { lock.withLock { createQueue += outcomes } }
    func answerChunk(_ outcomes: ImportUploadChunkOutcome...) { lock.withLock { chunkQueue += outcomes } }
    func answerStatus(_ outcomes: ImportUploadStatusOutcome...) { lock.withLock { statusQueue += outcomes } }
    func answerCommit(_ outcomes: ImportUploadCommitOutcome...) { lock.withLock { commitQueue += outcomes } }
    func answerAbort(_ outcomes: ImportUploadAbortOutcome...) { lock.withLock { abortQueue += outcomes } }
    func holdChunk(at offset: Int64, cancellable: Bool = true) {
        lock.withLock { holdChunkAtOffset = offset; holdChunkCancellableFlag = cancellable }
    }
    func setOnCommitEnter(_ hook: (@Sendable () -> Void)?) { lock.withLock { onCommitEnter = hook } }
    func receivedBytes(for uploadID: String) -> Data? { lock.withLock { sessions[uploadID]?.received } }
    private var dropAck = false
    func loseNextChunkAck() { lock.withLock { dropAck = true } }

    func setServerOffset(for uploadID: String, offset: Int64) {
        lock.withLock { sessions[uploadID]?.nextOffset = offset }
    }
    var calls: Int { lock.withLock { saveCalls.count + startCalls.count } }

    func setOnSaveEnter(_ hook: (@Sendable () -> Void)?) { lock.withLock { onSaveEnter = hook } }
    func holdNextSave() { lock.withLock { holdNext = true; holdNextCancellableFlag = false } }
    func holdNextSaveCancellable() { lock.withLock { holdNext = true; holdNextCancellableFlag = true } }
    func holdNextInspect() { lock.withLock { holdNextInspectFlag = true } }
    func waitUntilHeld() async {
        await withCheckedContinuation { c in
            let already: Bool = lock.withLock {
                if hold != nil { return true }
                heldStarted = c
                return false
            }
            if already { c.resume() }
        }
    }
    func release() { lock.withLock { let h = hold; hold = nil; return h }?.resume() }

    func save(_ item: ImportItemDescriptor, serverURL: String) async -> ImportOutcome {
        let (shouldHold, cancellable, hook): (Bool, Bool, (@Sendable () -> Void)?) = lock.withLock {
            saveCalls.append(item.id)
            let h = holdNext
            let c = holdNextCancellableFlag
            holdNext = false
            holdNextCancellableFlag = false
            return (h, c, onSaveEnter)
        }
        hook?()
        if shouldHold {
            if cancellable {
                var wasCancelled = false
                await withTaskCancellationHandler {
                    await withCheckedContinuation { c in
                        let (alreadyCancelled, started): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                            if Task.isCancelled { return (true, nil) }
                            hold = c
                            let s = heldStarted
                            heldStarted = nil
                            return (false, s)
                        }
                        if alreadyCancelled {
                            c.resume()
                        } else {
                            started?.resume()
                        }
                    }
                } onCancel: {
                    let h: CheckedContinuation<Void, Never>? = lock.withLock {
                        let current = hold
                        hold = nil
                        return current
                    }
                    h?.resume()
                }
                wasCancelled = Task.isCancelled
                if wasCancelled {
                    return .retry(cause: "io-cancelled")
                }
            } else {
                await withCheckedContinuation { c in
                    let started: CheckedContinuation<Void, Never>? = lock.withLock {
                        hold = c
                        let s = heldStarted
                        heldStarted = nil
                        return s
                    }
                    started?.resume()
                }
            }
        }
        return lock.withLock {
            if var queued = saves[item.id], !queued.isEmpty {
                let next = queued.removeFirst()
                saves[item.id] = queued
                return next
            }
            return defaultSave
        }
    }

    func start(path: String, timestamp: String, serverURL: String) async -> ImportOutcome {
        lock.withLock {
            startCalls.append(path)
            return starts.isEmpty ? defaultStart : starts.removeFirst()
        }
    }

    func inspect(importID: String, serverURL: String) async -> ImportInspectOutcome {
        let shouldHold: Bool = lock.withLock {
            inspectCalls.append(importID)
            defer { holdNextInspectFlag = false }
            return holdNextInspectFlag
        }
        if shouldHold {
            await withCheckedContinuation { c in
                let started: CheckedContinuation<Void, Never>? = lock.withLock {
                    hold = c
                    let s = heldStarted
                    heldStarted = nil
                    return s
                }
                started?.resume()
            }
        }
        return lock.withLock {
            if var queued = inspects[importID], !queued.isEmpty {
                let next = queued.removeFirst()
                inspects[importID] = queued
                return next
            }
            return defaultInspect
        }
    }

    func probeResumableCapabilities(serverURL: String) async -> ImportCapabilityProbeOutcome {
        lock.withLock {
            probeCalls.append(serverURL)
            if !probeQueue.isEmpty { return probeQueue.removeFirst() }
            return defaultProbe
        }
    }

    func createUpload(_ request: ImportUploadCreateRequest, serverURL: String) async -> ImportUploadCreateOutcome {
        lock.withLock {
            createCalls.append((request, serverURL))
            if !createQueue.isEmpty { return createQueue.removeFirst() }
            if let existing = sessions.values.first(where: { $0.clientItemID == request.clientItemID }) {
                return .open(
                    uploadID: existing.uploadID,
                    nextOffset: existing.nextOffset,
                    totalBytes: existing.totalBytes,
                    chunkBytes: existing.chunkBytes,
                    expiresAt: "2026-12-02T00:00:00Z"
                )
            }
            let chunkBytes: Int64
            if case .supported(let caps) = defaultProbe {
                chunkBytes = caps.chunkBytes
            } else {
                chunkBytes = 4 * 1024
            }
            nextSessionSeq += 1
            let uid = "upload-\(nextSessionSeq)"
            sessions[uid] = FakeUploadSession(
                uploadID: uid,
                clientItemID: request.clientItemID,
                totalBytes: request.totalBytes,
                chunkBytes: chunkBytes,
                expectedSHA256: request.sha256,
                received: Data(),
                nextOffset: 0
            )
            return .open(
                uploadID: uid,
                nextOffset: 0,
                totalBytes: request.totalBytes,
                chunkBytes: chunkBytes,
                expiresAt: "2026-12-02T00:00:00Z"
            )
        }
    }

    func putUploadChunk(uploadID: String, offset: Int64, data: Data, chunkSHA256: String, serverURL: String) async -> ImportUploadChunkOutcome {
        let (shouldHold, cancellable): (Bool, Bool) = lock.withLock {
            chunkCalls.append(RecordedChunkCall(uploadID: uploadID, offset: offset, length: data.count, sha256: chunkSHA256, serverURL: serverURL))
            if holdChunkAtOffset == offset {
                let c = holdChunkCancellableFlag
                holdChunkAtOffset = nil
                holdChunkCancellableFlag = false
                return (true, c)
            }
            return (false, false)
        }
        if shouldHold {
            if cancellable {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { c in
                        let (alreadyCancelled, started): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                            if Task.isCancelled { return (true, nil) }
                            hold = c
                            let s = heldStarted
                            heldStarted = nil
                            return (false, s)
                        }
                        if alreadyCancelled {
                            c.resume()
                        } else {
                            started?.resume()
                        }
                    }
                } onCancel: {
                    let h: CheckedContinuation<Void, Never>? = lock.withLock {
                        let current = hold
                        hold = nil
                        return current
                    }
                    h?.resume()
                }
                if Task.isCancelled {
                    return .retry(cause: "io-cancelled")
                }
            } else {
                await withCheckedContinuation { c in
                    let started: CheckedContinuation<Void, Never>? = lock.withLock {
                        hold = c
                        let s = heldStarted
                        heldStarted = nil
                        return s
                    }
                    started?.resume()
                }
            }
        }
        return lock.withLock {
            if !chunkQueue.isEmpty { return chunkQueue.removeFirst() }
            guard var session = sessions[uploadID] else { return .uploadNotFound }
            if offset != session.nextOffset {
                return .offsetMismatch(nextOffset: session.nextOffset)
            }
            guard importDataSHA256(data) == chunkSHA256 else {
                return .chunkChecksumMismatch(nextOffset: session.nextOffset)
            }
            session.received.append(data)
            session.nextOffset += Int64(data.count)
            sessions[uploadID] = session
            if dropAck {
                dropAck = false
                return .retry(cause: "io-urlerror-1005", urlError: .networkConnectionLost)
            }
            return .accepted(
                nextOffset: session.nextOffset,
                totalBytes: session.totalBytes,
                complete: session.nextOffset >= session.totalBytes,
                expiresAt: "2026-12-02T00:00:00Z"
            )
        }
    }

    func uploadStatus(uploadID: String, serverURL: String) async -> ImportUploadStatusOutcome {
        lock.withLock {
            statusCalls.append((uploadID, serverURL))
            if !statusQueue.isEmpty { return statusQueue.removeFirst() }
            guard let session = sessions[uploadID] else { return .uploadNotFound }
            return .open(
                uploadID: session.uploadID,
                nextOffset: session.nextOffset,
                totalBytes: session.totalBytes,
                chunkBytes: session.chunkBytes,
                phase: .sending,
                expiresAt: "2026-12-02T00:00:00Z"
            )
        }
    }

    func commitUpload(uploadID: String, sha256: String, serverURL: String) async -> ImportUploadCommitOutcome {
        let hook = lock.withLock {
            commitCalls.append((uploadID, sha256, serverURL))
            return onCommitEnter
        }
        hook?()
        return lock.withLock {
            if !commitQueue.isEmpty { return commitQueue.removeFirst() }
            guard let session = sessions[uploadID] else { return .uploadNotFound }
            if session.nextOffset < session.totalBytes {
                return .incompleteUpload(nextOffset: session.nextOffset)
            }
            let actual = importDataSHA256(session.received)
            guard actual == sha256 else {
                sessions.removeValue(forKey: uploadID)
                return .wholeFileChecksumMismatch(error: "checksum mismatch")
            }
            sessions.removeValue(forKey: uploadID)
            return .staged(path: "/journal/imports/20261125_120000/payload", timestamp: "20261125_120000")
        }
    }

    func abortUpload(uploadID: String, serverURL: String) async -> ImportUploadAbortOutcome {
        lock.withLock {
            abortCalls.append((uploadID, serverURL))
            sessions.removeValue(forKey: uploadID)
            if !abortQueue.isEmpty { return abortQueue.removeFirst() }
            return .deleted
        }
    }
}

private final class ImportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Import engine", .serialized)
struct ImportEngineTests {
    private let facts = ImportFacts(
        paired: true, markConfirmed: true, syncPaused: false, pairingRefused: false,
        instance: "journal-a", version: "2.0.75", serverURL: "http://127.0.0.1:1"
    )

    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ dir: URL, _ name: String, _ text: String = "some bytes") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeEngine(_ root: URL, _ transport: FakeImportTransport, clock: ImportTestClock = ImportTestClock()) -> ImportEngine {
        ImportEngine(
            directory: root, transport: transport, clock: { clock.now() },
            freeSpace: { 100 * 1024 * 1024 * 1024 }, storeFsync: { _ in }
        )
    }

    private func addedID(_ result: ImportAddResult, _ index: Int = 0) throws -> String {
        guard case .added(let id) = result.outcomes[index].outcome else {
            Issue.record("not added: \(result.outcomes[index])")
            throw CancellationError()
        }
        return id
    }

    // MARK: - rules

    @Test func theVersionGateComparesEachPartAsANumber() {
        for version in ["2.0.52", "v2.0.52", "2.0.52-dev", "2.0.100", "2.1.0", "3.0.0"] {
            #expect(importVersionGate(version) == .supported, "\(version)")
        }
        for version in ["2.0.51", "garbage", "2.0", ""] {
            #expect(importVersionGate(version) == .tooOld, "\(version)")
        }
        #expect(importVersionGate(nil) == .unknown)
    }

    @Test func everyFileIsTakenAndTheJournalDecidesWhatItIs() {
        #expect(importIntakeDecision(.pdf) == .accept(mime: "application/pdf"))
        #expect(importIntakeDecision(.plainText) == .accept(mime: "text/plain"))
        #expect(importIntakeDecision(.heic) == .convertToJPEG)
        #expect(importIntakeDecision(.zip) == .accept(mime: "application/zip"))
        for type: UTType in [.tiff, .svg, .mpeg4Movie, .quickTimeMovie, .html, .zip] {
            if case .accept = importIntakeDecision(type) {} else { Issue.record("\(type.identifier) refused") }
        }
        #expect(importIntakeDecision(nil) == .accept(mime: "application/octet-stream"))
    }

    @Test func namesKeepTheirKindAndFitTheJournal() {
        #expect(importIntakeName("scan", mime: "application/pdf") == "scan.pdf")
        #expect(importIntakeName("photo.heic", mime: "image/heic", convertedToJPEG: true) == "photo.jpg")
        #expect(importIntakeName(nil, mime: "text/plain") == "file.txt")
        #expect(importIntakeName("extensionless", mime: "application/octet-stream") == "extensionless")
        #expect(importIntakeName("conversations.zip", mime: "application/zip") == "conversations.zip")
        let long = String(repeating: "é", count: 70) + ".pdf"
        let wire = importWireFilename(long)
        #expect(wire.utf8.count <= 128)
        #expect(wire.hasSuffix(".pdf"))
        #expect(importWireFilename("a\"b\\c\r\nd.pdf") == "cd.pdf")
        #expect(importWireFilename("a\"b\r\nc.pdf") == "abc.pdf")
        #expect(importWireFilename("dir/inner.pdf") == "inner.pdf")
    }

    @Test func everyContractVectorClassifiesAsTheJournalMeansIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("vendor/contracts/mobile-import/v1.vectors.json"))
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = (top["vectors"] as? [String: Any]) ?? top
        func answer(_ name: String, _ operation: ImportOperation) throws -> ImportOutcome {
            let vector = try #require(vectors[name] as? [String: Any], "\(name)")
            let status = try #require(vector["status"] as? Int)
            let body = try JSONSerialization.data(withJSONObject: vector["body"] ?? [:])
            return classifyImportResponse(operation, status: status, body: body)
        }
        if case .saved = try answer("save_staged_200", .save) {} else { Issue.record("save_staged_200") }
        if case .saved = try answer("save_replay_200", .save) {} else { Issue.record("save_replay_200") }
        for name in ["start_queued_200", "start_inprocess_200", "start_queued_replay_200", "start_inprocess_replay_200"] {
            if case .delivered(let row) = try answer(name, .start) { #expect(row?.isEmpty == false, "\(name)") } else { Issue.record("\(name)") }
        }
        if case .delivered = try answer("save_already_imported_400", .save) {} else { Issue.record("save already imported") }
        if case .delivered = try answer("start_already_imported_400", .start) {} else { Issue.record("start already imported") }
        if case .needsAttention = try answer("save_client_item_conflict_400", .save) {} else { Issue.record("conflict kept") }
        if case .needsAttention = try answer("start_nothing_to_import_409", .start) {} else { Issue.record("nothing to import") }
    }

    @Test func answersTheVectorsDoNotCover() {
        #expect(classifyImportResponse(.start, status: 200, body: Data(#"{"status":"ok","task_id":"t"}"#.utf8)) == .retry(cause: "answer-incomplete"))
        #expect(classifyImportResponse(.save, status: 200, body: Data("not json".utf8)) == .retry(cause: "unreadable-answer"))
        #expect(classifyImportResponse(.save, status: 403, body: Data()) == .authStop)
        #expect(classifyImportResponse(.save, status: 401, body: Data()) == .authStop)
        #expect(classifyImportResponse(.save, status: 403, body: Data(), loopbackRefused: true) == .retry(cause: "loopback-refused"))
        #expect(classifyImportResponse(.save, status: 503, body: Data()) == .retry(cause: "http-503"))
        if case .needsAttention(let error, _, _) = classifyImportResponse(.save, status: 302, body: Data()) {
            #expect(error == importGenericRefusal)
        } else { Issue.record("302") }
        if case .needsAttention(_, let code, _) = classifyImportResponse(.save, status: 400, body: Data(#"{"error":"no","reason_code":"invalid_operation_for_state","detail":"content already imported"}"#.utf8)) {
            #expect(code == "invalid_operation_for_state")
        } else { Issue.record("no kind stays attention") }
    }

    @Test func theBackoffStartsShortEscalatesAndNeverTraps() {
        #expect(importRetryBackoff(attempt: Int.min) == 5)
        #expect(importRetryBackoff(attempt: 0) == 5)
        #expect(importRetryBackoff(attempt: 1) == 5)
        #expect(importRetryBackoff(attempt: 2) == 15)
        #expect(importRetryBackoff(attempt: 3) == 60)
        #expect(importRetryBackoff(attempt: 4) == 5 * 60)
        #expect(importRetryBackoff(attempt: 5) == 15 * 60)
        #expect(importRetryBackoff(attempt: 6) == 30 * 60)
        #expect(importRetryBackoff(attempt: 7) == 60 * 60)
        #expect(importRetryBackoff(attempt: 8) == 2 * 3600)
        #expect(importRetryBackoff(attempt: 9) == 4 * 3600)
        #expect(importRetryBackoff(attempt: 100) == 4 * 3600)
        #expect(importRetryBackoff(attempt: Int.max) == 4 * 3600)
    }

    // MARK: - the body

    @Test func theBodyStreamsTheFileInChunksAndMatchesItsLength() throws {
        let dir = try tempDir("body")
        let payload = dir.appendingPathComponent("payload")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: payload)
        let item = ImportItemDescriptor(id: "abc", payloadURL: payload, displayName: "a\"b.pdf", mime: "application/pdf", size: Int64(bytes.count))
        let body = ImportMultipartBody(boundary: "BOUNDARY", item: item)
        var out = Data()
        var largestRead = 0
        let ok = body.stream(chunk: 4096, read: { handle, count in
            largestRead = max(largestRead, count)
            return try handle.read(upToCount: count) ?? Data()
        }, write: { out.append($0); return true })
        #expect(ok)
        #expect(Int64(out.count) == body.contentLength)
        #expect(largestRead <= 4096)
        let text = String(decoding: out.prefix(400), as: UTF8.self)
        #expect(text.contains("name=\"client_item_id\"\r\n\r\nabc\r\n"))
        #expect(text.contains("name=\"imported_via\"\r\n\r\nmacos\r\n"))
        #expect(text.contains("filename=\"ab.pdf\""))
        #expect(out.range(of: bytes) != nil)
    }

    // MARK: - custody

    @Test func aSaveThenStartDeliversAndRemovesTheCopy() async throws {
        let dir = try tempDir("deliver")
        let root = dir.appendingPathComponent("store")
        let source = try file(dir, "scan.pdf")
        let transport = FakeImportTransport()
        let engine = makeEngine(root, transport)
        let id = try addedID(await engine.add([source]))
        try FileManager.default.removeItem(at: source)
        let snapshot = await engine.tick(facts)
        #expect(transport.saveCalls == [id])
        #expect(transport.startCalls.count == 1)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.deliveredToCurrentJournal)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }

    @Test func aFailedStartIsTriedAloneAfterItsBackoffAndAcrossARelaunch() async throws {
        let dir = try tempDir("start-retry")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let first = makeEngine(root, transport, clock: clock)
        let id = try addedID(await first.add([try file(dir, "note.txt")]))
        transport.answerStart(.retry(cause: "http-503"))
        _ = await first.tick(facts)
        #expect(transport.saveCalls.count == 1)
        _ = await first.tick(facts)
        #expect(transport.startCalls.count == 1)

        // Before the 5-second first step elapses, the failed start is still held.
        clock.advance(4)
        _ = await first.tick(facts)
        #expect(transport.startCalls.count == 1)

        // A relaunch over the same folder sends only the start, once the short first backoff elapses.
        clock.advance(2)
        let second = makeEngine(root, transport, clock: clock)
        let snapshot = await second.tick(facts)
        #expect(transport.saveCalls.count == 1)
        #expect(transport.startCalls.count == 2)
        #expect(snapshot.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }

    @Test func transientSaveFailureEscalatesThroughShortFirstStepsAndTunnelReconnectClearsBackoff() async throws {
        let dir = try tempDir("short-backoff")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)
        let id = try addedID(await engine.add([try file(dir, "clip.pdf")]))
        transport.answerSave(id, .retry(cause: "http-502"), .retry(cause: "http-503"), .retry(cause: "http-503"))

        // Attempt 1 fails -> 5s backoff.
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 1)
        #expect(await engine.nextRetryDelay(for: facts) == 5)
        clock.advance(4)
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 1)

        // At 5s, attempt 2 runs and fails -> 15s backoff.
        clock.advance(1)
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 2)
        #expect(await engine.nextRetryDelay(for: facts) == 15)
        clock.advance(14)
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 2)

        // At 15s, attempt 3 runs and fails -> 60s backoff.
        clock.advance(1)
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 3)
        #expect(await engine.nextRetryDelay(for: facts) == 60)

        // When the delivery gate is closed (paused or offline) or the timer already elapsed,
        // nextRetryDelay reports nil so ImportSource never busy-loops on a closed gate.
        var paused = facts
        paused.syncPaused = true
        #expect(await engine.nextRetryDelay(for: paused) == nil)
        var offline = facts
        offline.serverURL = nil
        #expect(await engine.nextRetryDelay(for: offline) == nil)
        clock.advance(60)
        #expect(await engine.nextRetryDelay(for: facts) == nil)
        clock.advance(-60)

        // A tunnel reconnect clears pending retry backoff so the waiting import delivers immediately.
        await engine.tunnelReconnected()
        #expect(await engine.nextRetryDelay(for: facts) == nil)
        let snapshot = await engine.tick(facts)
        #expect(transport.saveCalls.count == 4)
        #expect(transport.startCalls.count == 1)
        #expect(snapshot.rows.isEmpty)
    }

    @Test @MainActor func importSourceSchedulesShortRetryWakeInsteadOfWaitingForIdlePoll() async throws {
        let dir = try tempDir("source-retry-wake")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)

        final class SleepGate: @unchecked Sendable {
            private let lock = NSLock()
            private var delays: [Duration] = []
            private var continuation: CheckedContinuation<Void, any Error>?
            private var waiting: CheckedContinuation<Void, Never>?
            private var cancelled = false

            var recordedDelays: [Duration] { lock.withLock { delays } }

            func sleep(_ duration: Duration) async throws {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { c in
                        let (alreadyCancelled, notify): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                            if cancelled { return (true, nil) }
                            delays.append(duration)
                            continuation = c
                            let w = waiting
                            waiting = nil
                            return (false, w)
                        }
                        if alreadyCancelled {
                            c.resume(throwing: CancellationError())
                        } else {
                            notify?.resume()
                        }
                    }
                } onCancel: {
                    let c: CheckedContinuation<Void, any Error>? = lock.withLock {
                        cancelled = true
                        let current = continuation
                        continuation = nil
                        return current
                    }
                    c?.resume(throwing: CancellationError())
                }
            }

            func waitForSleep() async {
                await withCheckedContinuation { c in
                    let already: Bool = lock.withLock {
                        if continuation != nil { return true }
                        waiting = c
                        return false
                    }
                    if already { c.resume() }
                }
            }

            func release() {
                let c: CheckedContinuation<Void, any Error>? = lock.withLock {
                    let current = continuation
                    continuation = nil
                    return current
                }
                c?.resume()
            }
        }

        let gate = SleepGate()
        let fileURL = try file(dir, "blip.pdf")
        let id = try addedID(await engine.add([fileURL]))
        transport.answerSave(id, .retry(cause: "http-503"))

        let testFacts = facts
        let source = ImportSource(
            engine: engine,
            facts: { testFacts },
            serverURL: { testFacts.serverURL },
            runsLoop: true,
            retrySleep: { try await gate.sleep($0) }
        )
        defer { source.shutdown() }
        await source.start()

        // The initial loop nudge fails once and immediately schedules a 5-second retry wake.
        await gate.waitForSleep()
        #expect(transport.saveCalls.count == 1)
        #expect(gate.recordedDelays == [.seconds(5)])

        // Advance past the 5s backoff and release the retry wake -> delivers without waiting 15s.
        clock.advance(5)
        gate.release()
        let deadline = ContinuousClock.now + .seconds(2)
        while transport.startCalls.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.saveCalls.count == 2)
        #expect(transport.startCalls.count == 1)
    }

    @Test func tunnelReconnectClearsPendingRetryBackoffWhilePreservingSavedProgressAndReviewState() async throws {
        let dir = try tempDir("reconnect-preserve")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)

        let startRetryID = try addedID(await engine.add([try file(dir, "saved.pdf")]))
        clock.advance(1)
        let reviewID = try addedID(await engine.add([try file(dir, "health.zip")]))

        transport.answerSave(startRetryID, .saved(path: "/p/saved", timestamp: "20261124_100001"))
        transport.answerSave(reviewID, .saved(path: "/p/review", timestamp: "20261124_100002"))
        transport.answerStart(
            .retry(cause: "http-503"),
            .readyToReview(importID: "20261124_100002", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required")
        )
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == 2)
        #expect(transport.startCalls.count == 2)
        #expect(await engine.nextRetryDelay(for: facts) == 5)

        // Tunnel reconnect clears retry backoff, preserves saved progress (no second /save),
        // and leaves ready_to_review untouched.
        await engine.tunnelReconnected()
        let snap = await engine.tick(facts)
        #expect(transport.saveCalls.count == 2)
        #expect(transport.startCalls.count == 3)
        #expect(snap.rows.map(\.id) == [reviewID])
        #expect(snap.rows.first?.kind == .readyToReview)
    }

    @Test func oneItemThatKeepsFailingDoesNotHoldUpTheNext() async throws {
        let dir = try tempDir("head-of-line")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(dir.appendingPathComponent("store"), transport, clock: clock)
        let stuck = try addedID(await engine.add([try file(dir, "a.pdf")]))
        clock.advance(1)
        _ = try addedID(await engine.add([try file(dir, "b.pdf")]))
        transport.answerSave(stuck, .retry(cause: "http-500"))
        let snapshot = await engine.tick(facts)
        #expect(snapshot.rows.map(\.id) == [stuck])
        #expect(transport.startCalls.count == 1)
    }

    @Test func anAuthStopSendsNothingUntilItsHoldEnds() async throws {
        let dir = try tempDir("auth")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(dir.appendingPathComponent("store"), transport, clock: clock)
        let id = try addedID(await engine.add([try file(dir, "a.pdf")]))
        transport.answerSave(id, .authStop)
        var snapshot = await engine.tick(facts)
        #expect(snapshot.waiting == .waiting)
        #expect(snapshot.rows.first?.kind == .waiting)
        #expect(snapshot.countsAsWaiting == 1)
        for _ in 0..<5 { _ = await engine.tick(facts) }
        #expect(transport.calls == 1)
        clock.advance(15 * 60 + 1)
        snapshot = await engine.tick(facts)
        #expect(transport.saveCalls.count == 2)
        #expect(snapshot.rows.isEmpty)
    }

    @Test func aRefusalKeepsTheCopyAndSaysWhy() async throws {
        let dir = try tempDir("refused")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = makeEngine(root, transport)
        let id = try addedID(await engine.add([try file(dir, "a.pdf")]))
        transport.answerStart(.needsAttention(error: "your journal can't take this kind of file", reasonCode: "import_metadata_failed", kind: nil))
        let snapshot = await engine.tick(facts)
        let row = try #require(snapshot.rows.first)
        #expect(row.kind == .refused("your journal can't take this kind of file"))
        #expect(row.retryable)
        #expect(row.savedAtJournal)
        #expect(snapshot.needsOwner)
        #expect(snapshot.countsAsWaiting == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
        #expect(await engine.remove(id) == .removed(savedAtJournal: true))

        // The same journal at the same version doesn't send it again on its own.
        let other = try addedID(await engine.add([try file(dir, "b.pdf")]))
        transport.answerSave(other, .needsAttention(error: "no", reasonCode: "client_item_conflict", kind: "client_item_conflict"))
        _ = await engine.tick(facts)
        let before = transport.calls
        for _ in 0..<5 { _ = await engine.tick(facts) }
        #expect(transport.calls == before)
        #expect(await engine.snapshot(facts).rows.first?.retryable == false)

        // Another journal does.
        var elsewhere = facts
        elsewhere.instance = "journal-b"
        #expect(await engine.snapshot(elsewhere).rows.first?.kind == .goingAgain)
        _ = await engine.tick(elsewhere)
        #expect(transport.calls == before + 2)
    }

    @Test func noJournalIdentityOrAnUnknownVersionSendsNothing() async throws {
        let dir = try tempDir("identity")
        let transport = FakeImportTransport()
        let engine = makeEngine(dir.appendingPathComponent("store"), transport)
        _ = try addedID(await engine.add([try file(dir, "a.pdf")]))
        var absent = facts
        absent.instance = nil
        absent.version = nil
        let snapshot = await engine.tick(absent)
        #expect(snapshot.waiting == .checkingJournal)
        var unknown = facts
        unknown.version = nil
        _ = await engine.tick(unknown)
        var old = facts
        old.version = "2.0.51"
        let tooOld = await engine.tick(old)
        #expect(transport.calls == 0)
        #expect(tooOld.waiting == .journalTooOld)
        #expect(tooOld.countsAsWaiting == 0)
        #expect(tooOld.needsOwner)
        var revoked = facts
        revoked.pairingRefused = true
        #expect(await engine.tick(revoked).waiting == .pairingRefused)
        #expect(transport.calls == 0)
    }

    @Test func anItemInAnExchangeCantBeRemovedAndARepairSendsNoStart() async throws {
        let dir = try tempDir("exclusion")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = makeEngine(root, transport)
        let id = try addedID(await engine.add([try file(dir, "a.pdf")]))
        transport.holdNextSave()
        let run = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()
        #expect(await engine.remove(id) == .busy)
        _ = await engine.tick(facts)
        var other = facts
        other.instance = "journal-b"
        _ = await engine.snapshot(other)
        transport.release()
        _ = await run.value
        #expect(transport.saveCalls == [id])
        #expect(transport.startCalls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }

    @Test func addsTakeAnyFileRefuseWhatCantBeHeldAndLeaveNothingBehind() async throws {
        let dir = try tempDir("add")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = ImportEngine(directory: root, transport: transport, freeSpace: { 100 * 1024 * 1024 * 1024 }, maxBytes: 8, storeFsync: { _ in })
        let folder = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await engine.add([
            try file(dir, "ok.txt", "small"),
            try file(dir, "movie.mov", "mov"),
            folder,
            try file(dir, "big.pdf", "much more than eight bytes"),
            try file(dir, "notes.md", "md"),
        ])
        #expect(result.outcomes.map(\.name) == ["ok.txt", "movie.mov", "folder", "big.pdf", "notes.md"])
        if case .added = result.outcomes[0].outcome {} else { Issue.record("text added") }
        if case .added = result.outcomes[1].outcome {} else { Issue.record("movie added") }
        #expect(result.outcomes[2].outcome == .refused(.unsupportedType))
        #expect(result.outcomes[3].outcome == .refused(.tooLarge))
        if case .added = result.outcomes[4].outcome {} else { Issue.record("markdown added") }
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path)) ?? []
        #expect(staging.isEmpty)

        let full = ImportEngine(directory: dir.appendingPathComponent("full"), transport: transport, freeSpace: { importMinFreeBytes }, storeFsync: { _ in })
        #expect(await full.add([try file(dir, "x.txt")]).outcomes[0].outcome == .refused(.noSpace))
    }

    @Test func aHEICBecomesAJPEGThatKeepsItsDateAndOrientation() async throws {
        let dir = try tempDir("heic")
        let heic = dir.appendingPathComponent("photo.heic")
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        guard let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return // This Mac can't write HEIC; nothing to convert from.
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:11 09:30:00"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        let root = dir.appendingPathComponent("store")
        let engine = makeEngine(root, FakeImportTransport())
        let id = try addedID(await engine.add([heic]))
        let rows = await engine.snapshot(facts).rows
        #expect(rows.first?.name == "photo.jpg")
        let stored = root.appendingPathComponent(id).appendingPathComponent("payload")
        let source = try #require(CGImageSourceCreateWithURL(stored as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(read[kCGImagePropertyOrientation] as? Int == 6)
        let exif = read[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:11 09:30:00")
    }

    // MARK: - recovery and the record

    @Test func recoveryReapsUnfinishedAddsAndMarksMissingCopies() async throws {
        let dir = try tempDir("recover")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let first = makeEngine(root, transport)
        let kept = try addedID(await first.add([try file(dir, "kept.pdf")]))
        let lost = try addedID(await first.add([try file(dir, "lost.pdf")]))
        try FileManager.default.removeItem(at: root.appendingPathComponent(lost))
        let orphan = root.appendingPathComponent("0f0f0f0f-0000-0000-0000-000000000000", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(".staging/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)

        let second = makeEngine(root, transport)
        var offline = facts
        offline.serverURL = nil
        let rows = await second.snapshot(offline).rows
        #expect(Set(rows.map { $0.id }) == Set([kept, lost]))
        #expect(rows.first { $0.id == lost }?.kind == .missingCopy)
        #expect(rows.first { $0.id == kept }?.kind == .waiting)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        _ = await second.tick(facts)
        #expect(transport.saveCalls == [kept])
    }

    @Test func anUnreadableRecordChangesNothingAndSendsNothing() async throws {
        let dir = try tempDir("unreadable")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let id = try addedID(await makeEngine(root, transport).add([try file(dir, "a.pdf")]))
        let record = root.appendingPathComponent("custody.json")
        try Data("{ not json".utf8).write(to: record)
        let damaged = makeEngine(root, transport)
        let snapshot = await damaged.tick(facts)
        #expect(snapshot.storeUnreadable)
        #expect(await damaged.remove(id) == .storeUnreadable)
        #expect(await damaged.retry(id) == .storeUnreadable)
        #expect(await damaged.add([try file(dir, "b.pdf")]).outcomes.first?.outcome == .refused(.noSpace))
        _ = await damaged.tick(facts)
        #expect(transport.calls == 0)
        #expect(try Data(contentsOf: record) == Data("{ not json".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }

    @Test func anInterruptedAddIsReportedUntilDismissed() async throws {
        let dir = try tempDir("interrupted")
        let root = dir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent(".intake-running").path, contents: nil)
        let engine = makeEngine(root, FakeImportTransport())
        #expect(await engine.snapshot(facts).interruptedAdd)
        await engine.dismissInterrupted()
        #expect(await !engine.snapshot(facts).interruptedAdd)
    }

    // MARK: - preview confirmation, safe reconciliation, 24h receipts, and totals

    @Test func importIDValidatorRequiresStrictASCII() {
        #expect(isValidImportID("20261122_123456"))
        #expect(!isValidImportID(nil))
        #expect(!isValidImportID(""))
        #expect(!isValidImportID("20261122_12345"))
        #expect(!isValidImportID("20261122_1234567"))
        #expect(!isValidImportID("20261122-123456"))
        #expect(!isValidImportID("../20261122_123456"))
        // Arabic-Indic digits must be rejected even though Unicode \d matches them.
        #expect(!isValidImportID("٢٠٢٦١١٢٢_١٢٣٤٥٦"))
    }

    @Test func previewRequired409ClassifiesOnlyExplicitConfirmationKindsAsReadyToReview() {
        func classify409(_ body: [String: Any]) -> ImportOutcome {
            let data = try! JSONSerialization.data(withJSONObject: body)
            return classifyImportResponse(.start, status: 409, body: data)
        }
        for kind in ["body_confirmation_required", "confirmation_required", "health_confirmation_required"] {
            let outcome = classify409([
                "reason_code": "import_preview_required",
                "kind": kind,
                "import_id": "20261122_120000",
                "error": "review before starting",
            ])
            #expect(outcome == .readyToReview(importID: "20261122_120000", error: "review before starting", reasonCode: "import_preview_required", kind: kind))
        }
        for nonConfirmKind in ["plan_failed", "nothing_to_import", "source_changed", "invalid_request", "not_found", "already_running", "unknown_kind"] {
            let outcome = classify409([
                "reason_code": "import_preview_required",
                "kind": nonConfirmKind,
                "import_id": "20261122_120000",
                "error": "could not start",
            ])
            if case .needsAttention(_, let code, let k) = outcome {
                #expect(code == "import_preview_required")
                #expect(k == nonConfirmKind)
            } else {
                Issue.record("expected needsAttention for \(nonConfirmKind), got \(outcome)")
            }
        }
        // Absent kind -> needsAttention.
        if case .needsAttention(_, let code, let k) = classify409(["reason_code": "import_preview_required", "error": "nope"]) {
            #expect(code == "import_preview_required")
            #expect(k == nil)
        } else {
            Issue.record("expected needsAttention when kind is absent")
        }
    }

    @Test func confirmationRequiredEntersReadyToReviewFallsBackToSaveTimestampAndRejectsInvalidID() async throws {
        let dir = try tempDir("review-state")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)

        // 1. body_confirmation_required with valid import_id -> readyToReview, bytes kept, not auto-retried.
        let id1 = try addedID(await engine.add([try file(dir, "export.zip", "health-bytes")]))
        transport.defaultSave = .saved(path: "/imports/export.zip", timestamp: "20261122_120100")
        transport.answerStart(.readyToReview(importID: "20261122_120100", error: "review within an hour", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        var snap = await engine.tick(facts)
        let row1 = try #require(snap.rows.first { $0.id == id1 })
        #expect(row1.kind == .readyToReview)
        #expect(row1.importID == "20261122_120100")
        #expect(row1.reviewKind == "body_confirmation_required")
        #expect(!row1.retryable)
        #expect(row1.savedAtJournal)
        #expect(snap.readyToReviewCount == 1)
        #expect(snap.countsAsWaiting == 0)
        #expect(!snap.hasFault)
        #expect(!snap.needsOwner)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id1).appendingPathComponent("payload").path))

        // Must NOT auto-retry on subsequent ticks or journal version bump.
        let callsAfterReview = transport.calls
        var bumped = facts
        bumped.version = "2.0.99"
        _ = await engine.tick(facts)
        _ = await engine.tick(bumped)
        #expect(transport.calls == callsAfterReview)

        // 2. confirmation_required omitting response import_id falls back to persisted /save timestamp.
        let id2 = try addedID(await engine.add([try file(dir, "notes.enex", "evernote")]))
        transport.defaultSave = .saved(path: "/imports/notes.enex", timestamp: "20261122_120200")
        transport.answerStart(.readyToReview(importID: nil, error: "preview needed", reasonCode: "import_preview_required", kind: "confirmation_required"))
        snap = await engine.tick(facts)
        let row2 = try #require(snap.rows.first { $0.id == id2 })
        #expect(row2.kind == .readyToReview)
        #expect(row2.importID == "20261122_120200")

        // 3. confirmation_required with invalid/missing import_id in BOTH response and /save timestamp -> needsAttention.
        let id3 = try addedID(await engine.add([try file(dir, "weird.bin", "weird")]))
        transport.defaultSave = .saved(path: "/imports/weird.bin", timestamp: "not-a-timestamp")
        transport.answerStart(.readyToReview(importID: nil, error: "preview needed", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        snap = await engine.tick(facts)
        let row3 = try #require(snap.rows.first { $0.id == id3 })
        if case .refused = row3.kind {} else { Issue.record("invalid import_id must enter needsAttention, got \(row3.kind)") }
        #expect(snap.hasFault)
    }

    @Test func planFailedAndOtherPreviewRefusalsStayNonRetryableNeedsAttentionAndNeverAutoRetryOnVersionBump() async throws {
        let dir = try tempDir("plan-failed")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = makeEngine(root, transport)
        let id = try addedID(await engine.add([try file(dir, "unknown.bin", "blob")]))
        transport.answerStart(.needsAttention(error: "can't read this file", reasonCode: "import_preview_required", kind: "plan_failed"))
        var snap = await engine.tick(facts)
        let row = try #require(snap.rows.first { $0.id == id })
        #expect(row.kind == .refused("can't read this file"))
        #expect(!row.retryable)
        #expect(snap.hasFault)
        #expect(snap.readyToReviewCount == 0)

        // Version bump on the same journal instance must NOT auto-retry `import_preview_required` refusals.
        let before = transport.calls
        var upgraded = facts
        upgraded.version = "2.1.0"
        snap = await engine.tick(upgraded)
        #expect(transport.calls == before)
        #expect(snap.rows.first?.kind == .refused("can't read this file"))
    }

    @Test func inspectClassifierFollowsContractV2FailClosedRules() {
        func check(_ status: Int, _ json: String, loopback: Bool = false) -> ImportInspectOutcome {
            classifyImportInspectResponse(status: status, body: Data(json.utf8), loopbackRefused: loopback)
        }
        for terminal in ["running", "success", "failed", "unconfirmed", "noted", "unavailable"] {
            #expect(check(200, #"{"status":"\#(terminal)"}"#) == .confirmed, "\(terminal)")
        }
        #expect(check(200, #"{"status":"pending","saved_start":{"active":true,"state":"eligible"}}"#) == .confirmed)
        #expect(check(200, #"{"status":"pending","saved_start":{"active":false,"state":"consumed"}}"#) == .confirmed)
        // Must NEVER delete on pending + eligible/unknown/absent saved_start.
        #expect(check(200, #"{"status":"pending","saved_start":{"active":false,"state":"eligible"}}"#) == .stillPending)
        #expect(check(200, #"{"status":"pending","saved_start":{"active":false,"state":"unknown"}}"#) == .stillPending)
        #expect(check(200, #"{"status":"pending"}"#) == .stillPending)
        #expect(check(200, #"{"status":"pending","saved_start":null}"#) == .stillPending)
        // 404 -> expired; 401/403 -> authStop; loopback 403 -> unchanged.
        #expect(check(404, #"{}"#) == .expired)
        #expect(check(401, #"{}"#) == .authStop)
        #expect(check(403, #"{}"#) == .authStop)
        #expect(check(403, #"{}"#, loopback: true) == .unchanged)
        // 400/429/5xx/malformed JSON -> unchanged (preserve bytes).
        #expect(check(400, #"{}"#) == .unchanged)
        #expect(check(429, #"{}"#) == .unchanged)
        #expect(check(503, #"{}"#) == .unchanged)
        #expect(check(200, "not-json") == .unchanged)
    }

    @Test func safeReconciliationConfirmsExpiresHaltsOnAuthAndResetsOnRePair() async throws {
        let dir = try tempDir("reconcile")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)

        // Stage two ready-to-review items (even while waiting == 0 afterward).
        let idA = try addedID(await engine.add([try file(dir, "health-a.zip", "aaa")]))
        clock.advance(1)
        let idB = try addedID(await engine.add([try file(dir, "health-b.zip", "bbb")]))
        transport.answerSave(idA, .saved(path: "/p/a", timestamp: "20261122_100001"))
        transport.answerSave(idB, .saved(path: "/p/b", timestamp: "20261122_100002"))
        transport.answerStart(
            .readyToReview(importID: "20261122_100001", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required"),
            .readyToReview(importID: "20261122_100002", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required")
        )
        var snap = await engine.tick(facts)
        #expect(snap.countsAsWaiting == 0)
        #expect(snap.readyToReviewCount == 2)

        // Still pending + transient error on sibling -> both kept with local bytes intact.
        transport.answerInspect("20261122_100001", .stillPending)
        transport.answerInspect("20261122_100002", .unchanged)
        snap = await engine.reconcile(facts)
        #expect(snap.readyToReviewCount == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(idA).appendingPathComponent("payload").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(idB).appendingPathComponent("payload").path))

        // 401/403 on first item halts batch immediately without inspecting second or deleting bytes.
        let callsBeforeAuth = transport.inspectCalls.count
        transport.answerInspect("20261122_100001", .authStop)
        snap = await engine.reconcile(facts)
        #expect(transport.inspectCalls.count == callsBeforeAuth + 1)
        #expect(snap.waiting == .pairingRefused)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(idA).appendingPathComponent("payload").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(idB).appendingPathComponent("payload").path))

        // Reconnect clears auth hold; now A confirms (deletes bytes + saves 24h receipt) and B expires (keeps bytes!).
        await engine.tunnelReconnected()
        transport.answerInspect("20261122_100001", .confirmed)
        transport.answerInspect("20261122_100002", .expired)
        snap = await engine.reconcile(facts)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(idA).path))
        #expect(snap.recentReceipts.count == 1)
        #expect(snap.recentReceipts[0].filename == "health-a.zip")
        #expect(snap.recentReceipts[0].importID == "20261122_100001")
        let rowB = try #require(snap.rows.first { $0.id == idB })
        #expect(rowB.kind == .reviewExpired)
        #expect(rowB.reviewExpired)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(idB).appendingPathComponent("payload").path))

        // sendAgain re-uploads B via /save + /start (fresh timestamp).
        transport.answerSave(idB, .saved(path: "/p/b2", timestamp: "20261122_110002"))
        transport.answerStart(.readyToReview(importID: "20261122_110002", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        #expect(await engine.sendAgain(idB) == .done)
        snap = await engine.tick(facts)
        #expect(snap.rows.first { $0.id == idB }?.kind == .readyToReview)
        #expect(snap.rows.first { $0.id == idB }?.importID == "20261122_110002")

        // Re-pair to Journal B resets readyToReview back to waiting (never querying Journal B with Journal A's import_id).
        var journalB = facts
        journalB.instance = "journal-b"
        let inspectCountBeforeRepair = transport.inspectCalls.count
        snap = await engine.reconcile(journalB)
        #expect(transport.inspectCalls.count == inspectCountBeforeRepair)
        #expect(snap.rows.first { $0.id == idB }?.kind == .waiting)
        #expect(snap.rows.first { $0.id == idB }?.importID == nil)
        #expect(snap.recentReceipts.isEmpty) // Journal A's receipts hidden when paired to Journal B.
    }

    @Test func reconciliationDiscardsStaleResponseWhenSendAgainRunsMidRequest() async throws {
        let dir = try tempDir("reconcile-race")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = makeEngine(root, transport)
        let id = try addedID(await engine.add([try file(dir, "race.zip", "payload-bytes")]))
        transport.answerSave(id, .saved(path: "/p/r", timestamp: "20261122_120999"))
        transport.answerStart(.readyToReview(importID: "20261122_120999", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        _ = await engine.tick(facts)

        transport.holdNextInspect()
        transport.answerInspect("20261122_120999", .confirmed)
        let reconcileTask = Task { await engine.reconcile(facts) }
        await transport.waitUntilHeld()
        // Owner triggers sendAgain while GET is in flight.
        #expect(await engine.sendAgain(id) == .done)
        transport.release()
        let snap = await reconcileTask.value
        // Stale confirmed response MUST be discarded: item stays waiting and local bytes remain on disk!
        #expect(snap.rows.first { $0.id == id }?.kind == .waiting)
        #expect(snap.recentReceipts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent("payload").path))
    }

    @Test func recentReceiptsCapAtFiveNewestPruneAfter24HoursPersistAcrossReloadAndKeepHighCapHandoffLookup() async throws {
        let dir = try tempDir("receipts")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let engine = makeEngine(root, transport, clock: clock)

        // Deliver 8 items (mix of main-window picks and journal-page handoffs).
        var handoffIDs: [String] = []
        for i in 1...8 {
            clock.advance(60)
            let url = try file(dir, "file-\(i).pdf", "content-\(i)")
            let handoff = i % 2 == 0 ? ImportHandoff(area: "quick", context: "{}") : nil
            let itemID = try addedID(await engine.add([url], handoff: handoff))
            if handoff != nil { handoffIDs.append(itemID) }
            let ts = String(format: "20261122_12%04d", i)
            transport.answerSave(itemID, .saved(path: "/p/\(i)", timestamp: ts))
            transport.answerStart(.delivered(importID: i == 7 ? nil : ts))
            _ = await engine.tick(facts)
        }

        // High-cap in-memory handoff lookup remembers ALL handed-over items (even beyond UI cap 5).
        for hid in handoffIDs {
            if case .delivered = await engine.handoffStatus(hid) {} else {
                Issue.record("expected high-cap handoff receipt for \(hid)")
            }
        }

        // UI recentReceipts caps at 5 newest (file-8 down to file-4) covering both main-window & handoff picks.
        var snap = await engine.snapshot(facts)
        #expect(snap.recentReceipts.map(\.filename) == ["file-8.pdf", "file-7.pdf", "file-6.pdf", "file-5.pdf", "file-4.pdf"])
        #expect(snap.recentReceipts[0].importID == "20261122_120008")
        // file-7 had nil import_id from start -> falls back to save timestamp unless save timestamp is also non-valid;
        // verify reload persistence!
        let reloaded = makeEngine(root, transport, clock: clock)
        snap = await reloaded.snapshot(facts)
        #expect(snap.recentReceipts.map(\.filename) == ["file-8.pdf", "file-7.pdf", "file-6.pdf", "file-5.pdf", "file-4.pdf"])

        // Unpaired or unconfirmed hides recent receipts and `more imports`.
        var unpaired = facts
        unpaired.paired = false
        var unconfirmed = facts
        unconfirmed.markConfirmed = false
        #expect(await reloaded.snapshot(unpaired).recentReceipts.isEmpty)
        #expect(!(await reloaded.snapshot(unpaired).canOpenJournalImport))
        #expect(await reloaded.snapshot(unconfirmed).recentReceipts.isEmpty)
        #expect(!(await reloaded.snapshot(unconfirmed).canOpenJournalImport))

        // Advance >24h -> all older receipts pruned.
        clock.advance(24 * 3600 + 60)
        #expect(await reloaded.snapshot(facts).recentReceipts.isEmpty)
    }

    @Test func legacyCustodyJSONWithoutNewFieldsDecodesCleanly() throws {
        let dir = try tempDir("legacy-custody")
        let legacyJSON = """
        {
          "version": 1,
          "items": [
            {
              "id": "legacy-1",
              "payloadKind": "file",
              "displayName": "old.pdf",
              "mime": "application/pdf",
              "byteSize": 5,
              "state": "pending",
              "createdAt": 0,
              "attemptCount": 0
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: dir.appendingPathComponent("custody.json"))
        let payloadDir = dir.appendingPathComponent("legacy-1", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: payloadDir.appendingPathComponent("payload"))

        let store = ImportCustodyStore(root: dir, fsync: { _ in })
        #expect(!store.unreadable)
        let list = store.items(instance: "j", journalVersion: "2.0.75")
        #expect(list.count == 1)
        #expect(list[0].displayName == "old.pdf")
        #expect(list[0].importID == nil)
        #expect(!list[0].reviewExpired)
        #expect(store.recentReceipts(forInstance: "j").isEmpty)
    }

    @Test func sourceTotalsIncrementsOncePerIntakeAndNeverDoubleCountsOnSendAgain() async throws {
        let dir = try tempDir("totals-intake")
        let root = dir.appendingPathComponent("store")
        let totalsDir = dir.appendingPathComponent("totals")
        let clock = ImportTestClock()
        let totals = SourceTotals(directory: totalsDir, clock: .init(now: clock.now(), timeZone: TimeZone(secondsFromGMT: 0)!))
        let transport = FakeImportTransport()
        let engine = ImportEngine(
            directory: root, transport: transport, clock: { clock.now() },
            freeSpace: { 100 * 1024 * 1024 * 1024 }, storeFsync: { _ in }, sourceTotals: totals
        )

        let id = try addedID(await engine.add([try file(dir, "export.zip", "health")]))
        #expect(totals.view()?.importsTotal == 1)
        #expect(totals.view()?.importsLast != nil)

        transport.answerSave(id, .saved(path: "/p/1", timestamp: "20261122_130001"))
        transport.answerStart(.readyToReview(importID: "20261122_130001", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        _ = await engine.tick(facts)
        transport.answerInspect("20261122_130001", .expired)
        _ = await engine.reconcile(facts)
        #expect(await engine.sendAgain(id) == .done)
        transport.answerSave(id, .saved(path: "/p/2", timestamp: "20261122_130002"))
        transport.answerStart(.delivered(importID: "20261122_130002"))
        _ = await engine.tick(facts)

        // Still 1 — never double-counted on sendAgain or delivery!
        #expect(totals.view()?.importsTotal == 1)
    }

    // MARK: - App Nap / idle-sleep hold and sleep/wake lifecycle

    private func makeEngine(
        _ root: URL,
        _ transport: FakeImportTransport,
        clock: ImportTestClock = ImportTestClock(),
        activity: ImportActivitySpy
    ) -> ImportEngine {
        ImportEngine(
            directory: root, transport: transport, clock: { clock.now() },
            freeSpace: { 100 * 1024 * 1024 * 1024 }, storeFsync: { _ in },
            beginActivity: { activity.begin($0) }
        )
    }

    @Test func deliveryActivityHoldSkipsIdleAndReleasesExactlyOnceOnEveryExitPath() async throws {
        let dir = try tempDir("activity-exits")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let spy = ImportActivitySpy()
        let engine = makeEngine(root, transport, clock: clock, activity: spy)

        // Empty queue takes no activity hold.
        _ = await engine.tick(facts)
        #expect(spy.counts == (0, 0, 0))

        // Closed gate takes no activity hold even with an item queued.
        let id1 = try addedID(await engine.add([try file(dir, "1.pdf")]))
        var paused = facts
        paused.syncPaused = true
        _ = await engine.tick(paused)
        #expect(spy.counts == (0, 0, 0))

        // Normal delivery holds the activity while transport runs and releases on exit.
        let sawActiveDuringSave = NSLock()
        nonisolated(unsafe) var activeDuringSave = 0
        transport.setOnSaveEnter {
            sawActiveDuringSave.withLock { activeDuringSave = spy.counts.active }
        }
        _ = await engine.tick(facts)
        transport.setOnSaveEnter(nil)
        #expect(sawActiveDuringSave.withLock { activeDuringSave } == 1)
        #expect(spy.counts == (1, 1, 0))
        _ = id1

        // Transient retry releases hold, and subsequent ticks while backed off take no hold.
        let idRetry = try addedID(await engine.add([try file(dir, "2.pdf")]))
        transport.answerSave(idRetry, .retry(cause: "http-503"))
        _ = await engine.tick(facts)
        #expect(spy.counts == (2, 2, 0))
        _ = await engine.tick(facts)
        #expect(spy.counts == (2, 2, 0))
        await engine.tunnelReconnected()
        _ = await engine.tick(facts)
        #expect(spy.counts == (3, 3, 0))

        // Auth stop releases hold.
        let idAuth = try addedID(await engine.add([try file(dir, "3.pdf")]))
        transport.answerSave(idAuth, .authStop)
        _ = await engine.tick(facts)
        #expect(spy.counts == (4, 4, 0))
        await engine.tunnelReconnected()
        _ = await engine.tick(facts)
        #expect(spy.counts == (5, 5, 0))

        // Refusal (needsAttention) releases hold.
        let idRefused = try addedID(await engine.add([try file(dir, "4.pdf")]))
        transport.answerSave(idRefused, .needsAttention(error: "no", reasonCode: "client_item_conflict", kind: "client_item_conflict"))
        _ = await engine.tick(facts)
        #expect(spy.counts == (6, 6, 0))

        // Ready to review releases hold.
        let idReview = try addedID(await engine.add([try file(dir, "5.zip")]))
        transport.answerSave(idReview, .saved(path: "/p/5", timestamp: "20261124_110005"))
        transport.answerStart(.readyToReview(importID: "20261124_110005", error: "review", reasonCode: "import_preview_required", kind: "body_confirmation_required"))
        _ = await engine.tick(facts)
        #expect(spy.counts == (7, 7, 0))

        // Re-pair mid-save releases hold.
        let idRepair = try addedID(await engine.add([try file(dir, "6.pdf")]))
        transport.holdNextSave()
        let repairRun = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()
        #expect(spy.counts == (8, 7, 1))
        var other = facts
        other.instance = "journal-b"
        _ = await engine.snapshot(other)
        transport.release()
        _ = await repairRun.value
        #expect(spy.counts == (8, 8, 0))
        _ = idRepair

        // Direct task cancellation mid-save releases hold immediately and exactly once.
        let idCancel = try addedID(await engine.add([try file(dir, "7.pdf")]))
        transport.holdNextSaveCancellable()
        let cancelRun = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()
        #expect(spy.counts == (9, 8, 1))
        cancelRun.cancel()
        _ = await cancelRun.value
        #expect(spy.counts == (9, 9, 0))
        _ = idCancel
    }

    @Test func willSleepPausesActiveDeliveryReleasesHoldWithoutBackoffAndWakeResumesCleanly() async throws {
        let dir = try tempDir("sleep-pause-resume")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let spy = ImportActivitySpy()
        let engine = makeEngine(root, transport, clock: clock, activity: spy)

        let id = try addedID(await engine.add([try file(dir, "big.zip", "payload")]))
        transport.holdNextSaveCancellable()
        let delivery = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()
        #expect(spy.counts == (1, 0, 1))

        // Owner closes the lid -> willSleep immediately releases the hold and cancels in-flight save.
        await engine.willSleep()
        #expect(spy.counts == (1, 1, 0))
        let pausedSnap = await delivery.value
        #expect(pausedSnap.rows.first?.id == id)
        #expect(pausedSnap.rows.first?.kind == .waiting)
        // Sleep pause must NOT record retry backoff.
        #expect(await engine.nextRetryDelay(for: facts) == nil)

        // While asleep, tick() does not send or re-acquire a power assertion.
        let savesBeforeSleepTick = transport.saveCalls.count
        _ = await engine.tick(facts)
        #expect(transport.saveCalls.count == savesBeforeSleepTick)
        #expect(spy.counts == (1, 1, 0))

        // On wake, delivery resumes cleanly without waiting on any backoff and releases its hold on completion.
        await engine.didWake()
        let resumedSnap = await engine.tick(facts)
        #expect(transport.saveCalls.count == savesBeforeSleepTick + 1)
        #expect(transport.startCalls.count == 1)
        #expect(resumedSnap.rows.isEmpty)
        #expect(spy.counts == (2, 2, 0))
    }

    @Test func sleepRightAfterSavePreservesSavedProgressAndWakeRunsStartOnly() async throws {
        let dir = try tempDir("sleep-after-save")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let spy = ImportActivitySpy()
        let engine = makeEngine(root, transport, clock: clock, activity: spy)

        let id = try addedID(await engine.add([try file(dir, "archive.zip", "bytes")]))
        transport.answerSave(id, .saved(path: "/imports/archive.zip", timestamp: "20261124_120000"))
        // Non-cancellable hold simulates save completing right as willSleep fires.
        transport.holdNextSave()
        let delivery = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()

        await engine.willSleep()
        #expect(spy.counts == (1, 1, 0))
        transport.release()
        let snapAfterSleep = await delivery.value
        #expect(transport.saveCalls == [id])
        #expect(transport.startCalls.isEmpty)
        #expect(snapAfterSleep.rows.first?.savedAtJournal == true)

        // On wake, only /start runs (no duplicate /save).
        await engine.didWake()
        let finalSnap = await engine.tick(facts)
        #expect(transport.saveCalls == [id])
        #expect(transport.startCalls == ["/imports/archive.zip"])
        #expect(finalSnap.rows.isEmpty)
        #expect(spy.counts == (2, 2, 0))
    }

    @Test func immediateWakeWhileSleepPauseIsDrainingWaitsAndResumesWithoutSkipping() async throws {
        let dir = try tempDir("wake-drain-race")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let spy = ImportActivitySpy()
        let engine = makeEngine(root, transport, clock: clock, activity: spy)

        let id = try addedID(await engine.add([try file(dir, "race.zip", "bytes")]))
        transport.answerSave(id, .retry(cause: "io-cancelled"))
        // Non-cancellable hold lets us trigger didWake() BEFORE the cancelled save finishes unwinding.
        transport.holdNextSave()
        let firstTick = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()

        await engine.willSleep()
        #expect(spy.counts == (1, 1, 0))

        // Start didWake() while firstTick is still unwinding.
        let wakeTask = Task { await engine.didWake() }
        try await Task.sleep(for: .milliseconds(20))
        // Now let the sleep-cancelled transport call unwind.
        transport.release()
        _ = await firstTick.value
        await wakeTask.value

        // Engine is guaranteed idle and awake now; tick() resumes and delivers cleanly.
        let resumedSnap = await engine.tick(facts)
        #expect(transport.saveCalls == [id, id])
        #expect(transport.startCalls.count == 1)
        #expect(resumedSnap.rows.isEmpty)
        #expect(spy.counts == (2, 2, 0))
    }

    @Test @MainActor func importSourceWorkspaceSleepAndWakeNotificationsPauseAndResumeDelivery() async throws {
        let dir = try tempDir("source-sleep-wake")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        let spy = ImportActivitySpy()
        let engine = makeEngine(root, transport, clock: clock, activity: spy)
        let center = NotificationCenter()

        let id = try addedID(await engine.add([try file(dir, "video.mov", "bytes")]))
        transport.holdNextSaveCancellable()

        let testFacts = facts
        let source = ImportSource(
            engine: engine,
            facts: { testFacts },
            serverURL: { testFacts.serverURL },
            runsLoop: false,
            workspaceCenter: center
        )
        await source.start()
        source.nudge()
        await transport.waitUntilHeld()
        #expect(spy.counts == (1, 0, 1))

        // Workspace willSleep pauses active delivery and releases the hold.
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        let pauseDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < pauseDeadline {
            let running = await engine.isRunning
            if spy.counts.active == 0 && !running && source.snapshot.rows.first?.kind == .waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(spy.counts == (1, 1, 0))
        #expect(source.snapshot.rows.first?.id == id)
        #expect(source.snapshot.rows.first?.kind == .waiting)

        // Workspace didWake resumes delivery cleanly and finishes it.
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < resumeDeadline {
            if source.snapshot.rows.isEmpty && spy.counts.active == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.saveCalls == [id, id])
        #expect(transport.startCalls.count == 1)
        #expect(source.snapshot.rows.isEmpty)
        #expect(spy.counts == (2, 2, 0))

        // shutdown() removes observers so further notifications are ignored.
        source.shutdown()
        let callsAfterShutdown = transport.calls
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.calls == callsAfterShutdown)
    }

    @Test func streamedRequestCancelsURLSessionTaskOnSwiftTaskCancellation() async throws {
        StallingImportURLProtocol.reset()
        let dir = try tempDir("stream-cancel")
        let payload = dir.appendingPathComponent("payload")
        // Larger than the 64 KiB bound buffer so the body writer thread blocks on backpressure.
        try Data(repeating: 0x5A, count: 512 * 1024).write(to: payload)
        let item = ImportItemDescriptor(
            id: "cancel-stream-1",
            payloadURL: payload,
            displayName: "large.bin",
            mime: "application/octet-stream",
            size: 512 * 1024
        )
        let body = ImportMultipartBody(boundary: "CANCELTEST", item: item)
        var request = URLRequest(url: URL(string: "http://import-cancel.invalid/app/import/api/save")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=CANCELTEST", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.contentLength), forHTTPHeaderField: "Content-Length")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingImportURLProtocol.self]

        let sendTask = Task {
            await ImportStreamedRequest.send(request, body: body, configuration: config)
        }
        await StallingImportURLProtocol.waitUntilStarted()
        sendTask.cancel()
        let answer = await sendTask.value
        #expect(await StallingImportURLProtocol.waitUntilStopped())
        if case .failed(let cause, _) = answer {
            #expect(cause == "io-cancelled")
        } else {
            Issue.record("expected .failed(cause: \"io-cancelled\"), got \(answer)")
        }
    }

    // MARK: - resumable big-file import uploads

    private func deterministicFile(_ dir: URL, _ name: String, byteCount: Int) throws -> (url: URL, data: Data, sha256: String) {
        var bytes = Data(count: byteCount)
        bytes.withUnsafeMutableBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<byteCount {
                ptr[i] = UInt8((i &* 31 &+ (i >> 8) &* 17 &+ 7) & 0xFF)
            }
        }
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return (url, bytes, importDataSHA256(bytes))
    }

    private func makeResumableEngine(
        _ root: URL,
        _ transport: FakeImportTransport,
        clock: ImportTestClock = ImportTestClock(),
        activity: ImportActivitySpy? = nil,
        chunkJitterUnit: @escaping @Sendable () -> Double = { 0.5 },
        onProgress: @escaping @Sendable () -> Void = {}
    ) -> ImportEngine {
        let beginAct: @Sendable (String) -> (@Sendable () -> Void)
        if let activity {
            beginAct = { reason in activity.begin(reason) }
        } else {
            beginAct = { _ in { } }
        }
        return ImportEngine(
            directory: root,
            transport: transport,
            clock: { clock.now() },
            freeSpace: { 100 * 1024 * 1024 * 1024 },
            storeFsync: { _ in },
            beginActivity: beginAct,
            chunkJitterUnit: chunkJitterUnit,
            onProgress: onProgress
        )
    }

    @Test func resumableParsersClassifiersBackoffAndFormattingMatchContract() throws {
        // Capability parsing
        #expect(parseSystemStatusResumableCapability(Data(#"{"capabilities":["resumable_import_uploads","other"]}"#.utf8)) == true)
        #expect(parseSystemStatusResumableCapability(Data(#"{"capabilities":["other"]}"#.utf8)) == false)
        #expect(parseSystemStatusResumableCapability(Data(#"{}"#.utf8)) == false)
        #expect(parseSystemStatusResumableCapability(Data("bad".utf8)) == nil)

        let sources = Data(#"{"sources":[],"resumable":{"threshold_bytes":16777216,"chunk_bytes":4194304,"max_file_bytes":4294967296}}"#.utf8)
        let caps = try #require(parseSourcesResumableCapabilities(sources))
        #expect(caps == ImportResumableCapabilities(thresholdBytes: 16_777_216, chunkBytes: 4_194_304, maxFileBytes: 4_294_967_296))
        // Reject chunk size above 8 MiB bridge ceiling
        let badChunk = Data(#"{"resumable":{"threshold_bytes":16777216,"chunk_bytes":16777216,"max_file_bytes":4294967296}}"#.utf8)
        #expect(parseSourcesResumableCapabilities(badChunk) == nil)
        #expect(parseSourcesResumableCapabilities(Data(#"{"sources":[]}"#.utf8)) == nil)

        // Create response classifier
        #expect(classifyUploadCreateResponse(status: 404, body: Data()) == .unsupported)
        #expect(classifyUploadCreateResponse(status: 405, body: Data()) == .unsupported)
        #expect(classifyUploadCreateResponse(status: 401, body: Data()) == .authStop)
        #expect(classifyUploadCreateResponse(status: 403, body: Data(), loopbackRefused: true) == .retry(cause: "loopback-refused"))
        #expect(classifyUploadCreateResponse(status: 409, body: Data(#"{"reason_code":"journal_busy","error":"busy"}"#.utf8)) == .retry(cause: "http-409-busy"))
        #expect(classifyUploadCreateResponse(
            status: 507,
            body: Data(#"{"error":"full","reason_code":"insufficient_journal_space","required_bytes":100,"available_bytes":10}"#.utf8)
        ) == .insufficientSpace(error: "full", requiredBytes: 100, availableBytes: 10))
        #expect(classifyUploadCreateResponse(
            status: 200,
            body: Data(#"{"status":"already_staged","replay":true,"save_response":{"path":"/p/a","timestamp":"20261125_010203"}}"#.utf8)
        ) == .alreadyStaged(path: "/p/a", timestamp: "20261125_010203"))
        #expect(classifyUploadCreateResponse(
            status: 200,
            body: Data(#"{"status":"already_imported","import_id":"20261125_010204","reason_code":"invalid_operation_for_state","kind":"already_imported"}"#.utf8)
        ) == .alreadyImported(importID: "20261125_010204"))

        // Chunk response classifier
        #expect(classifyUploadChunkResponse(status: 409, body: Data(#"{"reason_code":"offset_mismatch","next_offset":8192}"#.utf8)) == .offsetMismatch(nextOffset: 8192))
        #expect(classifyUploadChunkResponse(status: 409, body: Data()) == .offsetMismatch(nextOffset: nil))
        #expect(classifyUploadChunkResponse(status: 409, body: Data(#"{"reason_code":"journal_busy"}"#.utf8)) == .retry(cause: "http-409-busy"))
        #expect(classifyUploadChunkResponse(status: 422, body: Data(#"{"reason_code":"chunk_checksum_mismatch","next_offset":4096}"#.utf8)) == .chunkChecksumMismatch(nextOffset: 4096))
        #expect(classifyUploadChunkResponse(status: 400, body: Data(#"{"reason_code":"incomplete_chunk_body"}"#.utf8)) == .retry(cause: "http-400-incomplete-chunk"))
        #expect(classifyUploadChunkResponse(status: 404, body: Data()) == .uploadNotFound)
        #expect(classifyUploadChunkResponse(status: 507, body: Data(#"{"error":"disk full","reason_code":"insufficient_journal_space"}"#.utf8)) == .insufficientSpace(error: "disk full"))
        #expect(classifyUploadChunkResponse(status: 503, body: Data()) == .retry(cause: "http-503"))

        // Commit response classifier
        #expect(classifyUploadCommitResponse(status: 422, body: Data(#"{"reason_code":"whole_file_checksum_mismatch","error":"corrupted"}"#.utf8)) == .wholeFileChecksumMismatch(error: "corrupted"))
        #expect(classifyUploadCommitResponse(status: 409, body: Data(#"{"reason_code":"incomplete_upload","next_offset":4096}"#.utf8)) == .incompleteUpload(nextOffset: 4096))
        #expect(classifyUploadCommitResponse(status: 404, body: Data()) == .uploadNotFound)
        #expect(classifyUploadCommitResponse(status: 500, body: Data()) == .retry(cause: "http-500"))

        // Chunk retry ladder: [1, 2, 5, 10, 30, 60] ±20%
        let exact = [1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 60.0]
        for (idx, expected) in exact.enumerated() {
            #expect(importChunkRetryBackoff(attempt: idx + 1, jitterUnit: 0.5) == expected)
            #expect(abs(importChunkRetryBackoff(attempt: idx + 1, jitterUnit: 0.0) - expected * 0.8) < 0.0001)
            #expect(abs(importChunkRetryBackoff(attempt: idx + 1, jitterUnit: 1.0) - expected * 1.2) < 0.0001)
        }

        // Binary byte formatting matches journal transfer strip scale
        #expect(importFormatBytes(0) == "0 B")
        #expect(importFormatBytes(512) == "512 B")
        #expect(importFormatBytes(2048) == "2 KB")
        #expect(importFormatBytes(4 * 1024 * 1024) == "4.0 MB")
        #expect(importFormatBytes(4 * 1024 * 1024 * 1024) == "4.0 GB")
    }

    @Test func resumableGatingHonorsServerAdvertisedThresholdAndFallsBackOnOldJournalAnd405() async throws {
        let dir = try tempDir("resumable-gate")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        // Custom non-default threshold & chunk size proves nothing is hardcoded.
        transport.enableResumable(thresholdBytes: 10 * 1024, chunkBytes: 3 * 1024)
        let engine = makeResumableEngine(root, transport)

        // Below advertised threshold (9 KiB < 10 KiB) -> uses /save unchanged.
        let small = try deterministicFile(dir, "small.bin", byteCount: 9 * 1024)
        let smallID = try addedID(await engine.add([small.url]))
        _ = await engine.tick(facts)
        #expect(transport.saveCalls == [smallID])
        #expect(transport.createCalls.isEmpty)
        #expect(transport.chunkCalls.isEmpty)
        #expect(transport.startCalls.count == 1)

        // At/above advertised threshold (10 KiB >= 10 KiB) -> uses /uploads with 3 KiB chunks (3 + 3 + 3 + 1 KiB).
        let big = try deterministicFile(dir, "big.bin", byteCount: 10 * 1024)
        let bigID = try addedID(await engine.add([big.url]))
        _ = await engine.tick(facts)
        #expect(transport.saveCalls == [smallID])
        #expect(transport.createCalls.count == 1)
        #expect(transport.createCalls[0].request.clientItemID == bigID)
        #expect(transport.createCalls[0].request.sha256 == big.sha256)
        #expect(transport.createCalls[0].request.deviceNoun == "mac")
        #expect(transport.createCalls[0].request.importedVia == "macos")
        #expect(transport.chunkCalls.map(\.offset) == [0, 3072, 6144, 9216])
        #expect(transport.chunkCalls.map(\.length) == [3072, 3072, 3072, 1024])
        #expect(transport.commitCalls.count == 1)
        #expect(transport.commitCalls[0].sha256 == big.sha256)
        #expect(transport.startCalls.count == 2)

        // 405 Method Not Allowed on POST /uploads (version skew) -> invalidates cache and falls back cleanly to /save.
        let skew = try deterministicFile(dir, "skew.bin", byteCount: 12 * 1024)
        let skewID = try addedID(await engine.add([skew.url]))
        transport.answerCreate(.unsupported)
        let snap = await engine.tick(facts)
        #expect(snap.rows.isEmpty)
        #expect(transport.saveCalls.contains(skewID))
        #expect(transport.startCalls.count == 3)

        // Next large item uses cached .unsupported directly without retrying POST /uploads.
        let createCountBefore = transport.createCalls.count
        let afterSkew = try deterministicFile(dir, "after-skew.bin", byteCount: 12 * 1024)
        let afterID = try addedID(await engine.add([afterSkew.url]))
        _ = await engine.tick(facts)
        #expect(transport.createCalls.count == createCountBefore)
        #expect(transport.saveCalls.contains(afterID))
    }

    @Test func resumablePreUploadDedupAndCheckingPhaseBeforeCommit() async throws {
        let dir = try tempDir("resumable-dedup")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport)

        // Pre-upload already_staged skips chunks and goes straight to /start.
        let f1 = try deterministicFile(dir, "staged.zip", byteCount: 10 * 1024)
        _ = try addedID(await engine.add([f1.url], handoff: ImportHandoff(area: "chatgpt", context: #"{"setting":"x"}"#)))
        transport.answerCreate(.alreadyStaged(path: "/p/staged", timestamp: "20261125_100001"))
        let snap1 = await engine.tick(facts)
        #expect(snap1.rows.isEmpty)
        #expect(transport.chunkCalls.isEmpty)
        #expect(transport.commitCalls.isEmpty)
        #expect(transport.startCalls == ["/p/staged"])
        #expect(transport.createCalls[0].request.handoff?.area == "chatgpt")

        // Pre-upload already_imported marks delivered with 0 chunks and 0 /start calls.
        let f2 = try deterministicFile(dir, "imported.zip", byteCount: 10 * 1024)
        _ = try addedID(await engine.add([f2.url]))
        transport.answerCreate(.alreadyImported(importID: "20261125_100002"))
        let snap2 = await engine.tick(facts)
        #expect(snap2.rows.isEmpty)
        #expect(transport.chunkCalls.isEmpty)
        #expect(transport.startCalls.count == 1)

        // Normal resumable upload exposes .checking phase during commit (and .sending before commit).
        let directDir = try tempDir("resumable-checking-phase")
        let directStore = ImportCustodyStore(root: directDir.appendingPathComponent("store"), fsync: { _ in })
        let f3 = try deterministicFile(directDir, "check.zip", byteCount: 8 * 1024)
        let id3 = try #require(directStore.begin())
        try f3.data.write(to: directStore.stagingPayloadURL(id3))
        #expect(directStore.publish(id3, displayName: "check.zip", mime: "application/zip", size: 8 * 1024))

        let phaseLock = NSLock()
        nonisolated(unsafe) var statusAtCommit: ImportHandoffStatus?
        transport.setOnCommitEnter {
            let current = directStore.handoffStatus(id3, missingCopyReason: "missing", currentInstance: "journal-a")
            phaseLock.withLock { statusAtCommit = current }
        }
        defer { transport.setOnCommitEnter(nil) }
        let run = await deliverImports(
            transport: transport,
            store: directStore,
            serverURL: "http://127.0.0.1:1",
            instance: "journal-a",
            journalVersion: "2.1.0",
            gate: .supported,
            stillCurrent: { true },
            now: { Date() }
        )
        #expect(run == .clean)
        let observed = phaseLock.withLock { statusAtCommit }
        #expect(observed == .uploading(
            sizeBytes: 8 * 1024,
            progress: ImportHandoffProgress(bytesSent: 8 * 1024, bytesTotal: 8 * 1024, resumable: true, phase: .checking)
        ))
    }

    @Test func resumableHandles409OffsetMismatchBodyless409And422ChunkChecksumMismatch() async throws {
        let dir = try tempDir("resumable-409-422")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport)

        let payload = try deterministicFile(dir, "video.mov", byteCount: 12 * 1024)
        _ = try addedID(await engine.add([payload.url]))

        // Chunk 0 (offset 0): journal already has 0..4096 -> returns 409 offset_mismatch(nextOffset: 4096)
        // Chunk 1 (offset 4096): transient bitflip -> 422 chunk_checksum_mismatch(nextOffset: 4096), re-read & resend succeeds
        // Chunk 2 (offset 8192): proxy strips 409 body -> bodyless 409(nextOffset: nil) triggers GET /uploads/{id} resync!
        transport.answerChunk(
            .offsetMismatch(nextOffset: 4096),
            .chunkChecksumMismatch(nextOffset: 4096),
            .accepted(nextOffset: 8192, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .offsetMismatch(nextOffset: nil),
            .accepted(nextOffset: 12 * 1024, totalBytes: 12 * 1024, complete: true, expiresAt: nil)
        )
        transport.answerStatus(
            .open(uploadID: "upload-1", nextOffset: 8192, totalBytes: 12 * 1024, chunkBytes: 4 * 1024, phase: .sending, expiresAt: nil)
        )
        transport.answerCommit(.staged(path: "/p/video", timestamp: "20261125_110000"))

        let snap = await engine.tick(facts)
        #expect(snap.rows.isEmpty)
        // Offsets sent: 0 -> sought to 4096 -> 422 retried 4096 -> 8192 (bodyless 409 -> GET resync) -> 8192 accepted.
        #expect(transport.chunkCalls.map(\.offset) == [0, 4096, 4096, 8192, 8192])
        #expect(transport.statusCalls.count == 1)
        #expect(transport.commitCalls.count == 1)
        #expect(transport.startCalls == ["/p/video"])
    }

    @Test func resumableTransientRetryLadderReconnectWakeAndPortSwitchZeroDuplicateChunks() async throws {
        let dir = try tempDir("resumable-ladder-reconnect")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let clock = ImportTestClock()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport, clock: clock, chunkJitterUnit: { 0.5 })

        let payload = try deterministicFile(dir, "archive.tar", byteCount: 16 * 1024)
        let id = try addedID(await engine.add([payload.url]))

        // Chunk 0 succeeds (offset 0 -> 4096), then chunk 1 hits 503.
        transport.answerChunk(
            .accepted(nextOffset: 4096, totalBytes: 16 * 1024, complete: false, expiresAt: nil),
            .retry(cause: "http-503")
        )
        let snap1 = await engine.tick(facts)
        #expect(snap1.hasFault == false)
        #expect(snap1.hasPaused == true)
        #expect(snap1.countsAsWaiting == 1)
        #expect(snap1.rows.first?.kind == .paused)
        #expect(snap1.rows.first?.progress == ImportResumableProgress(bytesSent: 4096, bytesTotal: 16 * 1024, phase: .paused, resuming: false))
        #expect(await engine.nextRetryDelay(for: facts) == 1.0)

        // Repeated failures follow 2s -> 5s -> 10s -> 30s -> 60s -> 60s without ever marking fault.
        let expectedDelays: [TimeInterval] = [2, 5, 10, 30, 60, 60]
        var lastAdvance: TimeInterval = 1
        for expected in expectedDelays {
            clock.advance(lastAdvance)
            transport.answerStatus(.retry(cause: "http-503"))
            let s = await engine.tick(facts)
            #expect(s.hasFault == false)
            #expect(s.rows.first?.kind == .paused)
            #expect(await engine.nextRetryDelay(for: facts) == expected)
            lastAdvance = expected
        }

        // Now tunnel reconnects on a NEW loopback port -> clears backoff immediately without advancing clock!
        var reconnectedFacts = facts
        reconnectedFacts.serverURL = "http://127.0.0.1:59999"
        await engine.tunnelReconnected()
        #expect(await engine.nextRetryDelay(for: reconnectedFacts) == nil)

        // Make fake session match journal state (4096 confirmed bytes from chunk 0).
        transport.setServerOffset(for: "upload-1", offset: 4096)
        // Queue status + chunks for remaining 12 KiB (offsets 4096, 8192, 12288) on new port.
        transport.answerStatus(.open(uploadID: "upload-1", nextOffset: 4096, totalBytes: 16 * 1024, chunkBytes: 4 * 1024, phase: .sending, expiresAt: nil))
        transport.answerChunk(
            .accepted(nextOffset: 8192, totalBytes: 16 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 12288, totalBytes: 16 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 16384, totalBytes: 16 * 1024, complete: true, expiresAt: nil)
        )
        transport.answerCommit(.staged(path: "/p/archive", timestamp: "20261125_120001"))

        let finalSnap = await engine.tick(reconnectedFacts)
        #expect(finalSnap.rows.isEmpty)
        // Offset 0 was NEVER re-sent! Only [0, 4096 (failed), 4096, 8192, 12288].
        let offsetsSent = transport.chunkCalls.map(\.offset)
        #expect(offsetsSent == [0, 4096, 4096, 8192, 12288])
        #expect(transport.chunkCalls.suffix(3).allSatisfy { $0.serverURL == "http://127.0.0.1:59999" })
        #expect(transport.commitCalls.first?.serverURL == "http://127.0.0.1:59999")
        #expect(transport.startCalls == ["/p/archive"])
        _ = id
    }

    @Test func slowOrPartialReceiptsHoldTheReducedChunkSize() {
        let reduced: Int64 = 512 * 1024
        var growth = ImportChunkGrowth(advertised: 4 * 1024 * 1024)
        for _ in 0..<6 {
            let next = growth.afterReceipt(current: reduced, sent: reduced, confirmed: reduced, elapsed: .seconds(4))
            #expect(next == reduced)
        }
        let first = growth.afterReceipt(current: reduced, sent: reduced, confirmed: reduced, elapsed: .milliseconds(100))
        let partial = growth.afterReceipt(current: reduced, sent: reduced, confirmed: reduced / 2, elapsed: .milliseconds(100))
        let fresh = growth.afterReceipt(current: reduced, sent: reduced, confirmed: reduced, elapsed: .milliseconds(100))
        let second = growth.afterReceipt(current: reduced, sent: reduced, confirmed: reduced, elapsed: .milliseconds(100))
        #expect([first, partial, fresh, second] == [reduced, reduced, reduced, 2 * reduced])
    }

    @Test func interruptedChunksReconcileAcrossReconnectAndRegrowAfterFastReceipts() async throws {
        let unit = 256 * 1024
        let dir = try tempDir("chunk-timeout")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 1, chunkBytes: Int64(4 * unit))
        let clock = ImportTestClock()
        let original = makeResumableEngine(root, transport, clock: clock)
        let payload = try deterministicFile(dir, "relay.zip", byteCount: 16 * unit)
        _ = try addedID(await original.add([payload.url]))
        transport.loseNextChunkAck()
        let lost = await original.tick(facts)
        #expect(lost.rows.first?.progress?.bytesSent == 0)

        let resumed = makeResumableEngine(root, transport, clock: clock)
        var route = facts
        route.serverURL = "http://127.0.0.1:59999"
        await resumed.tunnelReconnected()
        transport.answerStatus(.retry(cause: "io-urlerror-1001"))
        _ = await resumed.tick(route)
        #expect(transport.chunkCalls.count == 1)

        // The first PUT was stored. GET must skip it at the original size.
        transport.answerChunk(.retry(cause: "io-urlerror-1001", urlError: .timedOut))
        await resumed.tunnelReconnected()
        let slow = await resumed.tick(route)
        #expect(slow.rows.first?.progress?.bytesSent == Int64(4 * unit))
        // No bytes from the next two timed-out PUTs reached the journal.
        transport.answerChunk(.retry(cause: "io-urlerror-1005", urlError: .networkConnectionLost))
        await resumed.tunnelReconnected()
        _ = await resumed.tick(route)
        await resumed.tunnelReconnected()
        let done = await resumed.tick(route)
        #expect(done.rows.isEmpty)
        #expect(transport.chunkCalls.map(\.length) == [4, 4, 2, 1, 1, 2, 2, 4, 2].map { $0 * unit })
        #expect(transport.chunkCalls.map(\.offset) == [0, 4, 4, 4, 5, 6, 8, 10, 14].map { Int64($0 * unit) })
        #expect(transport.commitCalls.map(\.sha256) == [payload.sha256])
        #expect(transport.startCalls.count == 1)
        #expect(transport.createCalls.count == 1)
    }

    @Test func resumableSurvivesAppRestartFromCustodyJsonWithoutRehashingOrDuplicateChunks() async throws {
        let dir = try tempDir("resumable-restart")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine1 = makeResumableEngine(root, transport)

        let payload = try deterministicFile(dir, "export.zip", byteCount: 16 * 1024)
        let id = try addedID(await engine1.add([payload.url]))

        // Upload chunks 0 and 1, then fail chunk 2 (simulating process termination after 8 KiB confirmed).
        transport.holdChunk(at: 8192, cancellable: true)
        let run1 = Task { await engine1.tick(facts) }
        await transport.waitUntilHeld()
        run1.cancel()
        _ = await run1.value

        // Brand-new ImportEngine reloads custody.json from disk.
        let engine2 = makeResumableEngine(root, transport)
        let relaunchSnap = await engine2.snapshot(facts)
        #expect(relaunchSnap.rows.count == 1)
        #expect(relaunchSnap.rows[0].id == id)
        #expect(relaunchSnap.rows[0].kind == .paused)
        #expect(relaunchSnap.rows[0].progress == ImportResumableProgress(bytesSent: 8192, bytesTotal: 16 * 1024, phase: .paused, resuming: false))

        // Verify persisted sha256 + uploadID + offset survived custody.json reload.
        let reloadedStore = ImportCustodyStore(root: root, fsync: { _ in })
        let desc = try #require(reloadedStore.item(id))
        #expect(desc.sha256 == payload.sha256)
        #expect(desc.uploadID == "upload-1")
        #expect(desc.uploadOffset == 8192)
        #expect(desc.uploadInstanceID == facts.instance)

        // Resume on relaunched engine: resyncs via GET /uploads/{id}, sends ONLY offsets 8192 and 12288!
        let finalSnap = await engine2.tick(facts)
        #expect(finalSnap.rows.isEmpty)
        #expect(transport.createCalls.count == 1)
        #expect(transport.statusCalls.count == 1)
        // Chunk calls before cancel: [0, 4096, 8192 (cancelled)]. After restart: [8192, 12288].
        // Neither 0 nor 4096 was ever re-sent!
        #expect(transport.chunkCalls.filter { $0.offset == 0 }.count == 1)
        #expect(transport.chunkCalls.filter { $0.offset == 4096 }.count == 1)
        #expect(transport.commitCalls.count == 1)
        #expect(transport.commitCalls[0].sha256 == payload.sha256)
    }

    @Test func resumableSleepReleasesActivityHoldPausesWithoutBackoffAndWakeResumesAtChunkBoundary() async throws {
        let dir = try tempDir("resumable-sleep")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let spy = ImportActivitySpy()
        let engine = makeResumableEngine(root, transport, activity: spy)
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)

        let payload = try deterministicFile(dir, "sleep.mov", byteCount: 16 * 1024)
        _ = try addedID(await engine.add([payload.url]))

        // Let chunk 0 (0..4096) succeed, then hold chunk 1 (4096..8192).
        transport.holdChunk(at: 4096, cancellable: true)
        let delivery = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()
        #expect(spy.counts == (1, 0, 1))

        // Lid close -> willSleep releases hold immediately, cancels chunk 1, marks paused with NO backoff.
        await engine.willSleep()
        #expect(spy.counts == (1, 1, 0))
        let pausedSnap = await delivery.value
        #expect(pausedSnap.rows.first?.kind == .paused)
        #expect(pausedSnap.rows.first?.progress?.bytesSent == 4096)
        #expect(await engine.nextRetryDelay(for: facts) == nil)

        // While asleep, tick does nothing and takes no activity hold.
        _ = await engine.tick(facts)
        #expect(spy.counts == (1, 1, 0))

        // Wake -> resyncs via GET /uploads/{id} and finishes 4096..16384 without re-sending chunk 0!
        await engine.didWake()
        let doneSnap = await engine.tick(facts)
        #expect(doneSnap.rows.isEmpty)
        #expect(spy.counts == (2, 2, 0))
        #expect(transport.chunkCalls.filter { $0.offset == 0 }.count == 1)
        #expect(transport.statusCalls.count == 1)
        #expect(transport.commitCalls.count == 1)
    }

    @Test func resumablePairingSwitchClearsRemoteSessionKeepsLocalFileAndStartsAtZero() async throws {
        let dir = try tempDir("resumable-pair-switch")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport)

        let payload = try deterministicFile(dir, "pairswitch.zip", byteCount: 12 * 1024)
        let id = try addedID(await engine.add([payload.url]))

        // Confirm chunk 0 on journal-a, then pause on chunk 1.
        transport.answerChunk(
            .accepted(nextOffset: 4096, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .retry(cause: "http-503")
        )
        let paused = await engine.tick(facts)
        #expect(paused.rows.first?.kind == .paused)
        #expect(paused.rows.first?.progress?.bytesSent == 4096)

        // Switch paired journal to journal-b.
        var journalB = facts
        journalB.instance = "journal-b"
        journalB.serverURL = "http://127.0.0.1:50002"
        let switchedSnap = await engine.snapshot(journalB)
        #expect(switchedSnap.rows.first?.kind == .waiting)
        #expect(switchedSnap.rows.first?.progress == nil)

        // Custody file + sha256 preserved, uploadID/offset cleared.
        let storeCheck = ImportCustodyStore(root: root, fsync: { _ in })
        let desc = try #require(storeCheck.item(id))
        #expect(desc.uploadID == nil)
        #expect(desc.uploadOffset == nil)
        #expect(desc.uploadInstanceID == nil)
        #expect(desc.sha256 == payload.sha256)

        // Delivers fresh from offset 0 on journal-b (new POST /uploads -> upload-2, full 0..12288).
        transport.answerCreate(.open(uploadID: "upload-b", nextOffset: 0, totalBytes: 12 * 1024, chunkBytes: 4 * 1024, expiresAt: nil))
        transport.answerChunk(
            .accepted(nextOffset: 4096, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 8192, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 12288, totalBytes: 12 * 1024, complete: true, expiresAt: nil)
        )
        transport.answerCommit(.staged(path: "/p/b", timestamp: "20261125_130000"))

        let doneB = await engine.tick(journalB)
        #expect(doneB.rows.isEmpty)
        let bChunks = transport.chunkCalls.filter { $0.uploadID == "upload-b" }
        #expect(bChunks.map(\.offset) == [0, 4096, 8192])
    }

    @Test func resumableRealFaults507422404LostCommitAndMissingCopy() async throws {
        let dir = try tempDir("resumable-faults")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport)

        // 1) 507 insufficient_journal_space mid-upload -> retryable needs attention, preserves upload session on retry!
        let f507 = try deterministicFile(dir, "space.zip", byteCount: 12 * 1024)
        let id507 = try addedID(await engine.add([f507.url]))
        transport.answerChunk(
            .accepted(nextOffset: 4096, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .insufficientSpace(error: "not enough free space")
        )
        let snap507 = await engine.tick(facts)
        #expect(snap507.hasFault == true)
        #expect(snap507.rows.first?.reasonCode == "insufficient_journal_space")
        #expect(snap507.rows.first?.retryable == true)
        #expect(await engine.retry(id507) == .done)
        // After retry, resyncs at 4096 and does NOT re-send offset 0!
        transport.setServerOffset(for: "upload-1", offset: 4096)
        transport.answerStatus(.open(uploadID: "upload-1", nextOffset: 4096, totalBytes: 12 * 1024, chunkBytes: 4 * 1024, phase: .sending, expiresAt: nil))
        transport.answerChunk(
            .accepted(nextOffset: 8192, totalBytes: 12 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 12288, totalBytes: 12 * 1024, complete: true, expiresAt: nil)
        )
        transport.answerCommit(.staged(path: "/p/507", timestamp: "20261125_140001"))
        #expect((await engine.tick(facts)).rows.isEmpty)
        #expect(transport.chunkCalls.filter { $0.uploadID == "upload-1" && $0.offset == 0 }.count == 1)

        // 2) 422 whole_file_checksum_mismatch on commit -> retryable attention, clears session & sha256.
        let f422 = try deterministicFile(dir, "corrupt.zip", byteCount: 8 * 1024)
        let id422 = try addedID(await engine.add([f422.url]))
        transport.answerCommit(.wholeFileChecksumMismatch(error: "file mismatch"))
        let snap422 = await engine.tick(facts)
        #expect(snap422.hasFault == true)
        #expect(snap422.rows.first?.reasonCode == "whole_file_checksum_mismatch")
        #expect(snap422.rows.first?.retryable == true)
        #expect(ImportCustodyStore(root: root, fsync: { _ in }).item(id422)?.sha256 == nil)
        #expect(await engine.retry(id422) == .done)
        #expect((await engine.tick(facts)).rows.isEmpty)

        // 3) 404 upload_not_found on open PUT -> retryable attention; retry opens fresh POST /uploads (NOT /save).
        let f404 = try deterministicFile(dir, "expired.zip", byteCount: 8 * 1024)
        let id404 = try addedID(await engine.add([f404.url]))
        transport.answerChunk(.uploadNotFound)
        let snap404 = await engine.tick(facts)
        #expect(snap404.hasFault == true)
        #expect(snap404.rows.first?.reasonCode == "upload_not_found")
        #expect(snap404.rows.first?.retryable == true)
        let savesBefore404Retry = transport.saveCalls.count
        #expect(await engine.retry(id404) == .done)
        #expect((await engine.tick(facts)).rows.isEmpty)
        #expect(transport.saveCalls.count == savesBefore404Retry)

        // 4) Lost commit response (404 on commit) -> probes POST /uploads once and recovers via already_staged!
        let fLost = try deterministicFile(dir, "lostcommit.zip", byteCount: 8 * 1024)
        _ = try addedID(await engine.add([fLost.url]))
        transport.answerCommit(.uploadNotFound)
        transport.answerCreate(
            .open(uploadID: "upload-lost", nextOffset: 0, totalBytes: 8 * 1024, chunkBytes: 4 * 1024, expiresAt: nil),
            .alreadyStaged(path: "/p/recovered", timestamp: "20261125_140004")
        )
        transport.answerChunk(
            .accepted(nextOffset: 4096, totalBytes: 8 * 1024, complete: false, expiresAt: nil),
            .accepted(nextOffset: 8192, totalBytes: 8 * 1024, complete: true, expiresAt: nil)
        )
        let snapLost = await engine.tick(facts)
        #expect(snapLost.rows.isEmpty)
        #expect(transport.startCalls.last == "/p/recovered")

        // 5) Missing/unreadable local custody file -> missingCopy attention.
        let fMissing = try deterministicFile(dir, "missing.zip", byteCount: 8 * 1024)
        let idMissing = try addedID(await engine.add([fMissing.url]))
        let payloadPath = root.appendingPathComponent(idMissing, isDirectory: true).appendingPathComponent("payload")
        try FileManager.default.removeItem(at: payloadPath)
        let snapMissing = await engine.tick(facts)
        #expect(snapMissing.hasFault == true)
        #expect(snapMissing.rows.first?.kind == .missingCopy)
    }

    @Test func resumableOwnerCancelAbortsActiveAndPausedUploadsAndDeletesOnJournal() async throws {
        let dir = try tempDir("resumable-cancel")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        transport.enableResumable(thresholdBytes: 8 * 1024, chunkBytes: 4 * 1024)
        let engine = makeResumableEngine(root, transport)

        // 1) Cancel an actively uploading resumable item mid-chunk -> cancels task, removes locally, calls DELETE /uploads/{id}.
        let f1 = try deterministicFile(dir, "active.mov", byteCount: 16 * 1024)
        let id1 = try addedID(await engine.add([f1.url]))
        transport.holdChunk(at: 4096, cancellable: true)
        let activeTick = Task { await engine.tick(facts) }
        await transport.waitUntilHeld()

        let cancelResult = await engine.cancel(id1, serverURL: facts.serverURL, instance: facts.instance)
        #expect(cancelResult == .removed(savedAtJournal: false))
        _ = await activeTick.value
        #expect((await engine.snapshot(facts)).rows.isEmpty)
        #expect(transport.abortCalls.map(\.uploadID) == ["upload-1"])

        // 2) Cancel a paused resumable item -> removes locally and calls DELETE /uploads/{id}.
        let f2 = try deterministicFile(dir, "paused.mov", byteCount: 12 * 1024)
        let id2 = try addedID(await engine.add([f2.url]))
        transport.answerChunk(.retry(cause: "http-503"))
        let pausedSnap = await engine.tick(facts)
        #expect(pausedSnap.rows.first?.kind == .paused)

        let cancelPaused = await engine.cancel(id2, serverURL: facts.serverURL, instance: facts.instance)
        #expect(cancelPaused == .removed(savedAtJournal: false))
        #expect((await engine.snapshot(facts)).rows.isEmpty)
        #expect(transport.abortCalls.count == 2)
    }

    @Test func liveTransportChunkWireFramingEnforcesContractHeadersOverRealTCP() async throws {
        // Minimal POSIX TCP loopback server capturing exact raw HTTP/1.1 bytes off the wire.
        final class RawCaptureServer: @unchecked Sendable {
            struct CapturedRequest: Sendable {
                var requestLine: String
                var headers: [String: String]
                var body: Data
            }

            let listenFD: Int32
            let port: UInt16
            private let lock = NSLock()
            private var requests: [CapturedRequest] = []
            private var closed = false

            init() throws {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = 0
                addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let bindRC = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindRC == 0, listen(fd, 8) == 0 else {
                    Darwin.close(fd)
                    throw POSIXError(.EADDRINUSE)
                }
                var bound = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                _ = withUnsafeMutablePointer(to: &bound) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &len)
                    }
                }
                self.listenFD = fd
                self.port = UInt16(bigEndian: bound.sin_port)
            }

            func start(responder: @escaping @Sendable (CapturedRequest) -> (Int, String)) {
                Thread { [self] in
                    while true {
                        let clientFD = accept(listenFD, nil, nil)
                        if clientFD < 0 { break }
                        handleClient(clientFD, responder: responder)
                    }
                }.start()
            }

            private func handleClient(_ fd: Int32, responder: @Sendable (CapturedRequest) -> (Int, String)) {
                defer { Darwin.close(fd) }
                var raw = Data()
                var buf = [UInt8](repeating: 0, count: 65536)
                let sep = Data("\r\n\r\n".utf8)
                var headerEnd: Data.Index?
                while headerEnd == nil {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { return }
                    raw.append(buf, count: n)
                    headerEnd = raw.range(of: sep)?.upperBound
                }
                guard let bodyStart = headerEnd else { return }
                let headData = raw[..<raw.index(bodyStart, offsetBy: -4)]
                let headString = String(decoding: headData, as: UTF8.self)
                let lines = headString.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? ""
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let expectedLen = Int(headers["content-length"] ?? "0") ?? 0
                var body = Data(raw[bodyStart...])
                while body.count < expectedLen {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { break }
                    body.append(buf, count: n)
                }
                let captured = CapturedRequest(requestLine: requestLine, headers: headers, body: body)
                lock.withLock { requests.append(captured) }
                let (status, jsonBody) = responder(captured)
                let respBody = Data(jsonBody.utf8)
                let respHead = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(respBody.count)\r\nConnection: close\r\n\r\n"
                var wire = Data(respHead.utf8)
                wire.append(respBody)
                wire.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    var sent = 0
                    while sent < wire.count {
                        let w = Darwin.send(fd, base + sent, wire.count - sent, 0)
                        if w <= 0 { break }
                        sent += w
                    }
                }
            }

            func captured() -> [CapturedRequest] { lock.withLock { requests } }

            func stop() {
                let shouldClose: Bool = lock.withLock {
                    if closed { return false }
                    closed = true
                    return true
                }
                if shouldClose { Darwin.close(listenFD) }
            }
        }

        let server = try RawCaptureServer()
        defer { server.stop() }
        server.start { req in
            if req.requestLine.hasPrefix("GET /api/system/status ") {
                return (200, #"{"capabilities":["resumable_import_uploads"]}"#)
            }
            if req.requestLine.hasPrefix("GET /app/import/api/sources ") {
                return (200, #"{"resumable":{"threshold_bytes":16777216,"chunk_bytes":4194304,"max_file_bytes":4294967296}}"#)
            }
            if req.requestLine.hasPrefix("PUT /app/import/api/uploads/u-wire-1?offset=4096 ") {
                return (200, #"{"upload_id":"u-wire-1","next_offset":8192,"total_bytes":16384,"complete":false,"expires_at":"2026-12-02T00:00:00Z"}"#)
            }
            return (404, #"{}"#)
        }

        let base = "http://127.0.0.1:\(server.port)"
        let transport = ImportLiveTransport()

        // 1) Live capability probe over TCP
        let probe = await transport.probeResumableCapabilities(serverURL: base)
        #expect(probe == .supported(ImportResumableCapabilities(
            thresholdBytes: 16_777_216, chunkBytes: 4_194_304, maxFileBytes: 4_294_967_296
        )))

        // 2) Live chunk PUT wire-framing check over TCP
        let chunk = Data((0..<4096).map { UInt8(($0 * 7) & 0xFF) })
        let chunkHash = importDataSHA256(chunk)
        let putOutcome = await transport.putUploadChunk(
            uploadID: "u-wire-1",
            offset: 4096,
            data: chunk,
            chunkSHA256: chunkHash,
            serverURL: base
        )
        #expect(putOutcome == .accepted(nextOffset: 8192, totalBytes: 16384, complete: false, expiresAt: "2026-12-02T00:00:00Z"))

        let putReq = try #require(server.captured().first { $0.requestLine.hasPrefix("PUT ") })
        #expect(putReq.requestLine == "PUT /app/import/api/uploads/u-wire-1?offset=4096 HTTP/1.1")
        #expect(putReq.headers["content-length"] == "4096")
        #expect(putReq.headers["content-type"] == "application/octet-stream")
        #expect(putReq.headers["x-chunk-sha256"] == chunkHash)
        #expect(putReq.headers["transfer-encoding"] == nil)
        #expect(putReq.headers["expect"] == nil)
        #expect(putReq.body == chunk)
    }
}
