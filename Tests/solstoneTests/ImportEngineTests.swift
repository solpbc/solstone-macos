// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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
    private let lock = NSLock()
    private var saves: [String: [ImportOutcome]] = [:]
    private var starts: [ImportOutcome] = []
    private var inspects: [String: [ImportInspectOutcome]] = [:]
    private(set) var saveCalls: [String] = []
    private(set) var startCalls: [String] = []
    private(set) var inspectCalls: [String] = []
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
        #expect(StallingImportURLProtocol.stopped)
        if case .failed(let cause) = answer {
            #expect(cause == "io-cancelled")
        } else {
            Issue.record("expected .failed(cause: \"io-cancelled\"), got \(answer)")
        }
    }
}
