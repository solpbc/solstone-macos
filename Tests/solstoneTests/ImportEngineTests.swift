// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import solstone

/// A transport whose answers the test sets, and which can hold a save until the test lets it go.
private final class FakeImportTransport: ImportTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var saves: [String: [ImportOutcome]] = [:]
    private var starts: [ImportOutcome] = []
    private(set) var saveCalls: [String] = []
    private(set) var startCalls: [String] = []
    var defaultSave: ImportOutcome = .saved(path: "/journal/imports/x/p", timestamp: "20261111_120000")
    var defaultStart: ImportOutcome = .delivered
    private var hold: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var heldStarted: CheckedContinuation<Void, Never>?

    func answerSave(_ id: String, _ outcomes: ImportOutcome...) { lock.withLock { saves[id, default: []] += outcomes } }
    func answerStart(_ outcomes: ImportOutcome...) { lock.withLock { starts += outcomes } }
    var calls: Int { lock.withLock { saveCalls.count + startCalls.count } }

    func holdNextSave() { lock.withLock { holdNext = true } }
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
        let shouldHold: Bool = lock.withLock {
            saveCalls.append(item.id)
            defer { holdNext = false }
            return holdNext
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

    @Test func typesFollowWhatTheJournalImports() {
        #expect(importIntakeDecision(.pdf) == .accept(mime: "application/pdf"))
        #expect(importIntakeDecision(.plainText) == .accept(mime: "text/plain"))
        #expect(importIntakeDecision(.png) == .accept(mime: "image/png"))
        #expect(importIntakeDecision(.jpeg) == .accept(mime: "image/jpeg"))
        #expect(importIntakeDecision(.webP) == .accept(mime: "image/webp"))
        #expect(importIntakeDecision(.gif) == .accept(mime: "image/gif"))
        #expect(importIntakeDecision(.mp3) != .refuse(.unsupportedType))
        #expect(importIntakeDecision(.heic) == .convertToJPEG)
        for refused: UTType in [.tiff, .bmp, .svg, .mpeg4Movie, .quickTimeMovie, .html] {
            #expect(importIntakeDecision(refused) == .refuse(.unsupportedType), "\(refused.identifier)")
        }
        #expect(importIntakeDecision(UTType(filenameExtension: "md")) == .refuse(.unsupportedType))
    }

    @Test func namesKeepTheirKindAndFitTheJournal() {
        #expect(importIntakeName("scan", mime: "application/pdf") == "scan.pdf")
        #expect(importIntakeName("photo.heic", mime: "image/heic", convertedToJPEG: true) == "photo.jpg")
        #expect(importIntakeName(nil, mime: "text/plain") == "file.txt")
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
            #expect(try answer(name, .start) == .delivered, "\(name)")
        }
        #expect(try answer("save_already_imported_400", .save) == .delivered)
        #expect(try answer("start_already_imported_400", .start) == .delivered)
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

    @Test func theBackoffIsCappedAndNeverTraps() {
        #expect(importRetryBackoff(attempt: 1) == 15 * 60)
        #expect(importRetryBackoff(attempt: 2) == 30 * 60)
        #expect(importRetryBackoff(attempt: 100) == 4 * 3600)
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
        #expect(text.contains("name=\"imported_via\"\r\n\r\ndesktop\r\n"))
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

        // A relaunch over the same folder sends only the start, after the backoff.
        clock.advance(16 * 60)
        let second = makeEngine(root, transport, clock: clock)
        let snapshot = await second.tick(facts)
        #expect(transport.saveCalls.count == 1)
        #expect(transport.startCalls.count == 2)
        #expect(snapshot.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
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

    @Test func addsRefuseWhatTheJournalCantTakeAndLeaveNothingBehind() async throws {
        let dir = try tempDir("add")
        let root = dir.appendingPathComponent("store")
        let transport = FakeImportTransport()
        let engine = ImportEngine(directory: root, transport: transport, freeSpace: { 100 * 1024 * 1024 * 1024 }, maxBytes: 8, storeFsync: { _ in })
        let folder = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await engine.add([
            try file(dir, "ok.txt", "small"),
            try file(dir, "movie.mov"),
            folder,
            try file(dir, "big.pdf", "much more than eight bytes"),
            try file(dir, "notes.md"),
        ])
        #expect(result.outcomes.map(\.name) == ["ok.txt", "movie.mov", "folder", "big.pdf", "notes.md"])
        if case .added = result.outcomes[0].outcome {} else { Issue.record("text added") }
        #expect(result.outcomes[1].outcome == .refused(.unsupportedType))
        #expect(result.outcomes[2].outcome == .refused(.unsupportedType))
        #expect(result.outcomes[3].outcome == .refused(.tooLarge))
        #expect(result.outcomes[4].outcome == .refused(.unsupportedType))
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
}
