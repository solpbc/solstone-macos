// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import SQLite3
import Testing
@testable import solstone

private final class BrowserTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _date: Date

    init(_ date: Date) {
        self._date = date
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _date
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _date = newValue
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        _date = _date.addingTimeInterval(seconds)
    }
}

private final class BrowserTestInjectedSize: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = max(0, newValue) } }
    }
}

private final class BrowserTestResolvedHome: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ResolvedHomeBase = .held

    var value: ResolvedHomeBase { lock.withLock { current } }
    func set(_ value: ResolvedHomeBase) { lock.withLock { current = value } }
}

private final class ManualMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration

    init(_ current: Duration = .zero) {
        self.current = current
    }

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(for duration: Duration) async {}

    func advance(milliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        current += .milliseconds(milliseconds)
    }
}

extension BrowserIntakeAuthority {
    func testConnectionGeneration(identityToken: String) throws -> String {
        try reconcileIdentity(identityToken, mode: .replace)
        reopenAdmission()
        guard let generation = store.getDestinationGeneration() else { throw BrowserIntakeStoreError.localIO }
        return generation
    }
}

extension BrowserIntakeStore {
    func testConnectionGeneration(identityToken: String, nowMs: UInt64 = 1_700_000_000_000) throws -> String {
        guard let generation = try reconcileIdentity(identityToken, mode: .replace, nowMs: nowMs) else {
            throw BrowserIntakeStoreError.localIO
        }
        return generation
    }
}

func browserTestDeliveryRoute() -> BrowserIntakeRouteCapability {
    BrowserIntakeRouteCapability(
        serverURL: "http://127.0.0.1",
        identityDigest: BrowserIntakeStore.identityDigest(of: "browser-test-route"),
        pairingGeneration: 1,
        transportIncarnation: 1,
        credentialIsCurrent: { true }
    )
}

func browserTestDeliveryBinding(_ ack: BrowserIngestAck) -> BrowserDeliveryBinding {
    BrowserDeliveryBinding(ack: ack, route: browserTestDeliveryRoute())
}

extension BrowserIntakeStore {
    func registerStagingDirectory(_ url: URL, reservedBytes: Int) throws {
        let periodID = getOpenPeriodId() ?? getAllFinalizedPeriods().first?.periodId ?? "test-staging-period"
        try registerStagingDirectory(url, reservedBytes: reservedBytes, periodId: periodID)
    }

    func persistDeliveryBinding(_ ack: BrowserIngestAck) throws {
        try publishDeliveryAck(browserTestDeliveryBinding(ack))
    }

    func publishDeliveryAck(_ ack: BrowserIngestAck) throws {
        try publishDeliveryAck(browserTestDeliveryBinding(ack))
    }

    func releaseProven(periodId: String, binding ack: BrowserIngestAck, nowMs: UInt64) throws {
        try releaseProven(periodId: periodId, binding: browserTestDeliveryBinding(ack), nowMs: nowMs)
    }

    func removeProvenSegment(periodId: String, binding ack: BrowserIngestAck, nowMs: UInt64) throws {
        try removeProvenSegment(periodId: periodId, binding: browserTestDeliveryBinding(ack), nowMs: nowMs)
    }
}

@Suite("BrowserIntakeAdmission")
struct BrowserIntakeAdmissionTests {
    private var vendorURL: URL {
        let currentFile = URL(fileURLWithPath: #filePath)
        let repoRoot = currentFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("vendor")
    }

    private func createTempRoot() throws -> URL {
        let tempDir = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true).appendingPathComponent("solstone-intake-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test func test1_sameBatchIdRetryAndLexemesAndMultiInstContext() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )

        let gen = try authority.testConnectionGeneration(identityToken: "test-token-1")
        let sharedBatchId = "abcdef0123456789abcdef0123456789"

        let openPidBefore = store.getOpenPeriodId()!
        let openFileURL = store.periodFileURL(for: openPidBefore)
        let fileLenBefore = (try? Data(contentsOf: openFileURL).count) ?? 0

        // 1. Uninitialized delta -> rejected with snapshot_required (retryable)
        let uninitDeltaString = """
        {"type":"batch","destination_generation":"\(gen)","inst":"inst-A","batch_id":"\(sharedBatchId)","queued_at_ms":1700000000000,"records":[{"t":"delta","ts":1700000000000,"ctx":"ctx-shared","op":"add","block":{"id":"b1","text":"Delta block"}}]}
        """
        let uninitDeltaData = Data(uninitDeltaString.utf8)
        let reply1 = try authority.accept(bytes: uninitDeltaData, direction: "extension_to_host")
        #expect(reply1["result"] as? String == "rejected")
        #expect(reply1["reason"] as? String == "snapshot_required")
        #expect(reply1["class"] as? String == "retryable")

        // Assert snapshot_required leaves no receipt row and does not change open file length
        #expect(try store.lookupReceipt(generation: gen, inst: "inst-A", batchId: sharedBatchId) == nil)
        let fileLenAfterRefusal = (try? Data(contentsOf: openFileURL).count) ?? 0
        #expect(fileLenAfterRefusal == fileLenBefore)

        // 2. Resend same batch_id as snapshot with raw lexemes literal (ts: 1000.0, rel: 1.0, snapshot_reason: delivery_recovery)
        let rawSnapshotString = """
        {"type":"batch","destination_generation":"\(gen)","inst":"inst-A","batch_id":"\(sharedBatchId)","queued_at_ms":1700000000000,"records":[{"t":"segment_start","ts":1000.0,"rel":1.0,"site":"example.com","url":"https://example.com","title":"Title","adapter":"web","ctx":"ctx-shared","blocks":[{"id":"b1","text":"Snapshot"}],"snapshot_reason":"delivery_recovery"}]}
        """
        let rawSnapshotData = Data(rawSnapshotString.utf8)
        let reply2 = try authority.accept(bytes: rawSnapshotData, direction: "extension_to_host")
        #expect(reply2["result"] as? String == "accepted")
        let pid1 = reply2["period_id"] as? String
        #expect(pid1 != nil)

        // Verify period file contains exact raw characters
        let writtenData = try Data(contentsOf: openFileURL)
        let writtenString = String(data: writtenData, encoding: .utf8) ?? ""
        #expect(writtenString.contains("\"ts\":1000.0"))
        #expect(writtenString.contains("\"rel\":1.0"))
        #expect(writtenString.contains("\"snapshot_reason\":\"delivery_recovery\""))

        // 3. Advance clock across boundary (+300s) and poll -> rotates period
        clock.advance(by: 300)
        authority.poll(now: clock.now)

        let openPidAfterPoll = store.getOpenPeriodId()
        #expect(openPidAfterPoll != pid1)

        // 4. Replay same batch_id -> duplicate referencing original period_id (pid1), not written to new period
        let reply3 = try authority.accept(bytes: rawSnapshotData, direction: "extension_to_host")
        #expect(reply3["result"] as? String == "duplicate")
        #expect(reply3["period_id"] as? String == pid1)

        // 5. Multi-inst: inst-B with same ctx ("ctx-shared") without its own snapshot -> rejected snapshot_required
        let instBDeltaString = """
        {"type":"batch","destination_generation":"\(gen)","inst":"inst-B","batch_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","queued_at_ms":1700000300000,"records":[{"t":"delta","ts":1700000300000,"ctx":"ctx-shared","op":"add","block":{"id":"b2","text":"Delta B"}}]}
        """
        let replyB = try authority.accept(bytes: Data(instBDeltaString.utf8), direction: "extension_to_host")
        #expect(replyB["result"] as? String == "rejected")
        #expect(replyB["reason"] as? String == "snapshot_required")
        #expect(replyB["class"] as? String == "retryable")
    }

    @Test func test2_fileCapRotationWithRealPolicyFile() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        #expect(projection.policy.file == 50331648)

        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )

        let gen = try authority.testConnectionGeneration(identityToken: "test-token-1")
        let pad = String(repeating: "p", count: 26 * 1024 * 1024)

        let batch1: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "11111111111111111111111111111111",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [[
                "t": "segment_start",
                "ts": 1700000000000 as UInt64,
                "ctx": "ctx-1",
                "blocks": [["id": "b1", "text": "snapshot"]],
                "pad": pad
            ]]
        ]
        let reply1 = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: batch1), direction: "extension_to_host")
        #expect(reply1["result"] as? String == "accepted")
        let pid1 = try #require(reply1["period_id"] as? String)
        let file1Before = try Data(contentsOf: store.periodFileURL(for: pid1))

        let deltaId = "22222222222222222222222222222222"
        let batch2: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": deltaId,
            "queued_at_ms": 1700000001000 as UInt64,
            "records": [[
                "t": "delta",
                "ts": 1700000001000 as UInt64,
                "ctx": "ctx-1",
                "op": "add",
                "block": ["id": "batch2_marker", "text": "short"],
                "pad": pad
            ]]
        ]
        let reply2 = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: batch2), direction: "extension_to_host")
        #expect(reply2["result"] as? String == "rejected")
        #expect(reply2["reason"] as? String == "snapshot_required")
        #expect(reply2["class"] as? String == "retryable")
        #expect(try store.lookupReceipt(generation: gen, inst: "inst-1", batchId: deltaId) == nil)
        #expect(store.getPeriod(periodId: pid1)?.state == "finalized")
        let file1After = try Data(contentsOf: store.periodFileURL(for: pid1))
        #expect(file1After == file1Before)
        #expect(!String(decoding: file1After, as: UTF8.self).contains("batch2_marker"))

        let openAfterRotation = try #require(store.getOpenPeriodId())
        #expect(openAfterRotation != pid1)
        let rotatedURL = store.periodFileURL(for: openAfterRotation)
        let rotatedBytes = (try? Data(contentsOf: rotatedURL)) ?? Data()
        #expect(!String(decoding: rotatedBytes, as: UTF8.self).contains("batch2_marker"))

        let substituted: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": deltaId,
            "queued_at_ms": 1700000001000 as UInt64,
            "records": [[
                "t": "segment_start",
                "ts": 1700000001000 as UInt64,
                "ctx": "ctx-1",
                "blocks": [["id": "b2", "text": "substituted-snapshot"]],
                "snapshot_reason": "delivery_recovery"
            ]]
        ]
        let substitutedBytes = try JSONSerialization.data(withJSONObject: substituted)
        let reply3 = try authority.accept(bytes: substitutedBytes, direction: "extension_to_host")
        #expect(reply3["result"] as? String == "accepted")
        let pid2 = try #require(reply3["period_id"] as? String)
        #expect(pid2 == openAfterRotation)
        let file2 = try String(contentsOf: store.periodFileURL(for: pid2), encoding: .utf8)
        #expect(file2.contains("substituted-snapshot"))
        #expect(!file2.contains("batch2_marker"))

        let replay = try authority.accept(bytes: substitutedBytes, direction: "extension_to_host")
        #expect(replay["result"] as? String == "duplicate")
        #expect(replay["period_id"] as? String == pid2)
        #expect(store.getOpenPeriodId() == pid2)
    }

    @Test func test3_afterFinalizeSyncRecoveryAndReopenAndFailCommit() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))

        var gen: String = ""
        var pid1: String = ""

        do {
            let store1 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
            let authority1 = BrowserIntakeAuthority(
                store: store1,
                projection: projection,
                wallClock: { clock.now },
                timeZone: TimeZone(identifier: "UTC")!
            )
            gen = try authority1.testConnectionGeneration(identityToken: "test-token-1")

            let snap: [String: Any] = [
                "type": "batch",
                "destination_generation": gen,
                "inst": "inst-1",
                "batch_id": "33333333333333333333333333333333",
                "queued_at_ms": 1700000000000 as UInt64,
                "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "initial"]]]]
            ]
            let reply = try authority1.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
            pid1 = reply["period_id"] as! String

            // Simulate crash during finalize at .afterFinalizeSync point
            store1.crashPoint = .afterFinalizeSync
            #expect(throws: Error.self) {
                try store1.finalizePeriod(periodId: pid1, reason: "manual_test", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
            }
        }

        // Reopen store from disk -> period remains open, same path, same bytes
        let store2 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let p1URL = store2.periodFileURL(for: pid1)
        let bytesAfterFirstReopen = try Data(contentsOf: p1URL).count

        // Second reopen does not write again
        let store3 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let bytesAfterSecondReopen = try Data(contentsOf: p1URL).count
        #expect(bytesAfterFirstReopen == bytesAfterSecondReopen)

        // Clean finalize
        store3.crashPoint = .none
        try store3.finalizePeriod(periodId: pid1, reason: "clean_finalize", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let finalizedP1 = store3.getPeriod(periodId: pid1)
        #expect(finalizedP1?.state == "finalized")
        let finalizedLen = try Data(contentsOf: p1URL).count

        // A later accept does not change the finalized file's length
        let authority3 = BrowserIntakeAuthority(
            store: store3,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let snap2: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "44444444444444444444444444444444",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b2", "text": "next"]]]]
        ]
        let reply2 = try authority3.accept(bytes: try JSONSerialization.data(withJSONObject: snap2), direction: "extension_to_host")
        let pid2 = reply2["period_id"] as! String
        #expect(pid1 != pid2)
        let finalizedLenAfterNext = try Data(contentsOf: p1URL).count
        #expect(finalizedLenAfterNext == finalizedLen)

        // Test failCommit crashPoint: does not return accepted, does not leave receipt, does not change file length
        let p2URL = store3.periodFileURL(for: pid2)
        let p2LenBefore = try Data(contentsOf: p2URL).count
        store3.crashPoint = .failCommit

        let deltaFail: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "55555555555555555555555555555555",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "delta", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "op": "add", "block": ["id": "d1", "text": "failed commit"]]]
        ]
        let replyFail = try authority3.accept(bytes: try JSONSerialization.data(withJSONObject: deltaFail), direction: "extension_to_host")
        #expect(replyFail["result"] as? String == "rejected")
        #expect(replyFail["reason"] as? String == "resource_exhausted")
        #expect(try store3.lookupReceipt(generation: gen, inst: "inst-1", batchId: "55555555555555555555555555555555") == nil)
        let p2LenAfter = try Data(contentsOf: p2URL).count
        #expect(p2LenAfter == p2LenBefore)
    }

    @Test func test4_spoolQuotaCustodyAndGcAndWallClockRollback() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        #expect(projection.policy.spoolBytes == 536870912)

        let ioInjector = BrowserIntakeIOInjector()
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection, ioInjector: ioInjector)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )

        let gen = try authority.testConnectionGeneration(identityToken: "test-token-1")

        // 1. Initial status: permitted, custody full=false, stale=false
        let stat0 = authority.status()
        #expect(stat0["capture"] as? String == "permitted")
        let custody0 = stat0["custody"] as? [String: Bool]
        #expect(custody0?["full"] == false)
        #expect(custody0?["stale"] == false)

        // 2. Commit small older anchor (to test staleness and anchor retention later)
        let anchorBatchId = "10000000000000000000000000000001"
        let anchorBatch: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": anchorBatchId,
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "anchor"]]]]
        ]
        let anchorReply = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: anchorBatch), direction: "extension_to_host")
        let anchorPid = anchorReply["period_id"] as! String

        // Rotate anchor period so it can be isolated
        try store.finalizePeriod(periodId: anchorPid, reason: "anchor_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        let before = store.projectedSpoolBytes()
        let extra = 1000
        #expect(store.projectedSpoolBytes(additionalPayloadBytes: extra) - before == extra * 2)

        let gap = projection.policy.spoolBytes - before
        let exactPayload = 32
        let stagingDirectory = store.stagingRootURL().appendingPathComponent("footprint-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingFile = stagingDirectory.appendingPathComponent("multipart.body")
        try Data().write(to: stagingFile)
        let injectedStageSize = BrowserTestInjectedSize()
        ioInjector.setSizeOverride { url, actual in
            url == stagingFile ? injectedStageSize.value : actual
        }
        try store.registerStagingDirectory(stagingDirectory, reservedBytes: 0)
        let deliveryReserve = try Data(contentsOf: store.periodFileURL(for: anchorPid)).count + 64 * 1024
        injectedStageSize.value = gap + deliveryReserve - exactPayload
        #expect(store.isQuotaFull(additionalBytes: exactPayload, additionalDedupBytes: 0) == false)
        injectedStageSize.value += 1
        #expect(store.isQuotaFull(additionalBytes: exactPayload, additionalDedupBytes: 0) == true)

        let anchorFile = store.periodFileURL(for: anchorPid)
        injectedStageSize.value = projection.policy.spoolBytes
        #expect(store.isQuotaFull())

        let openBeforeOver = try #require(store.getOpenPeriodId())
        let openFile = store.periodFileURL(for: openBeforeOver)
        let lenBeforeOver = (try? Data(contentsOf: openFile).count) ?? 0
        let overPayload: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "77777777777777777777777777777777",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-over", "blocks": [["id": "bo", "text": "extra"]]]]
        ]
        let repOver = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: overPayload), direction: "extension_to_host")
        #expect(repOver["result"] as? String == "rejected")
        #expect(repOver["reason"] as? String == "resource_exhausted")
        #expect(repOver["class"] as? String == "retryable")
        #expect(((try? Data(contentsOf: openFile).count) ?? 0) == lenBeforeOver)
        #expect(try store.lookupReceipt(generation: gen, inst: "inst-1", batchId: "77777777777777777777777777777777") == nil)

        let repReplay = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: anchorBatch), direction: "extension_to_host")
        #expect(repReplay["result"] as? String == "duplicate")
        #expect(repReplay["period_id"] as? String == anchorPid)

        injectedStageSize.value = 0
        try store.releaseStagingDirectory(stagingDirectory)
        #expect(store.isQuotaFull() == false)
        clock.advance(by: 604801)
        let staleOnly = authority.status()
        let staleCustody = staleOnly["custody"] as? [String: Bool]
        #expect(staleCustody?["stale"] == true)
        #expect(staleCustody?["full"] == false)
        #expect(staleOnly["capture"] as? String == "permitted")
        #expect(staleOnly["delivery"] as? String == "kept_locally")

        clock.advance(by: -100000)
        let afterRollback = authority.status()
        let rollbackCustody = afterRollback["custody"] as? [String: Bool]
        #expect(rollbackCustody?["stale"] == true)
        #expect(afterRollback["delivery"] as? String == "kept_locally")

        let failed = authority.status()
        #expect(failed["delivery"] as? String == "kept_locally")
        // releaseStagingDirectory removed the earlier file. Recreate an actual
        // measured staging file before injecting simultaneous full/stale custody.
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try Data().write(to: stagingFile)
        try store.registerStagingDirectory(stagingDirectory, reservedBytes: 0)
        injectedStageSize.value = projection.policy.spoolBytes
        let combined = authority.status()
        let combinedCustody = combined["custody"] as? [String: Bool]
        #expect(combined["capture"] as? String == "intake_off")
        #expect(combined["delivery"] as? String == "kept_locally")
        #expect(combinedCustody?["full"] == true)
        #expect(combinedCustody?["stale"] == true)
        injectedStageSize.value = 0
        try store.releaseStagingDirectory(stagingDirectory)

        let anchorPeriod = try #require(store.getPeriod(periodId: anchorPid))
        let anchorProof = BrowserIngestAck(
            generation: gen, periodId: anchorPid, sha256: anchorPeriod.fileSha256 ?? "",
            size: UInt64(anchorPeriod.committedLength), metadata: nil,
            requestedDay: anchorPeriod.requestedDay ?? "", requestedSegment: anchorPeriod.requestedSegment ?? "",
            canonicalKey: anchorPeriod.requestedSegment, status: .collision
        )
        try store.persistDeliveryBinding(anchorProof)
        let anchorAck = BrowserIngestAckStore.ackURL(periodDirectory: anchorFile.deletingLastPathComponent())
        try BrowserIngestAckStore.write(anchorProof, to: anchorAck)
        try store.markAckDurable(periodId: anchorPid)
        try store.releaseProven(periodId: anchorPid, binding: anchorProof, nowMs: 1700000000000)
        #expect(!FileManager.default.fileExists(atPath: anchorFile.path))
        #expect(store.getPeriod(periodId: anchorPid)?.state == "delivered")

        // Wall time is still behind the durable floor. A batch timestamped at
        // that rolled-back instant remains admissible without an outbox-age cutoff.
        let youngNowMs = store.getFloorMs()
        let youngSnap: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "88888888888888888888888888888888",
            "queued_at_ms": youngNowMs,
            "records": [["t": "segment_start", "ts": youngNowMs, "ctx": "ctx-young", "blocks": [["id": "by", "text": "young"]]]]
        ]
        let youngRep = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: youngSnap), direction: "extension_to_host")
        #expect(youngRep["result"] as? String == "accepted")
        try store.finalizePeriod(periodId: try #require(youngRep["period_id"] as? String), reason: "young_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        let floorBeforeReopen = store.getFloorMs()
        let earliestBeforeReopen = store.getEarliestHeldMs()
        let storeReopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(storeReopened.getFloorMs() == floorBeforeReopen)
        #expect(storeReopened.getEarliestHeldMs() == earliestBeforeReopen)

        let oldBatchID = "11110000111100001111000011110000"
        let oldQueuedAt = storeReopened.getFloorMs() - 600_001
        let oldBatch: [String: Any] = [
            "type": "batch", "destination_generation": gen, "inst": "inst-1",
            "batch_id": oldBatchID, "queued_at_ms": oldQueuedAt,
            "records": [["t": "segment_start", "ts": storeReopened.getFloorMs(), "ctx": "ctx-old",
                         "blocks": [["id": "bo", "text": "old"]]]]
        ]
        let authorityReopened = BrowserIntakeAuthority(
            store: storeReopened, projection: projection, wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let oldBytes = try JSONSerialization.data(withJSONObject: oldBatch)
        let admitted = try authorityReopened.accept(bytes: oldBytes, direction: "extension_to_host")
        #expect(admitted["result"] as? String == "accepted")
        let oldPeriodID = try #require(admitted["period_id"] as? String)
        let oldPayload = try Data(contentsOf: storeReopened.periodFileURL(for: oldPeriodID))
        clock.advance(by: TimeInterval(projection.policy.acceptedRetentionMs + 1000) / 1000)
        authorityReopened.poll(now: clock.now)
        #expect(try storeReopened.lookupReceipt(generation: gen, inst: "inst-1", batchId: oldBatchID)?.result == "accepted")
        let replay = try authorityReopened.accept(bytes: oldBytes, direction: "extension_to_host")
        #expect(replay["result"] as? String == "duplicate")
        #expect(try Data(contentsOf: storeReopened.periodFileURL(for: oldPeriodID)) == oldPayload)
    }

    @Test func test5_reopenPairingReplacementAndUnpairKeepPendingBytes() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let firstStore = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let firstAuthority = BrowserIntakeAuthority(store: firstStore, projection: projection, wallClock: { clock.now })
        let firstGeneration = try firstAuthority.testConnectionGeneration(identityToken: "token-1")
        func batchBytes(_ generation: String, _ id: String, _ queuedAt: UInt64) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "batch", "destination_generation": generation, "inst": "instance-one",
                "batch_id": id, "queued_at_ms": queuedAt,
                "records": [["t": "segment_start", "ts": queuedAt, "ctx": "context-one",
                             "blocks": [["id": "block-one", "text": "held page"]]]]
            ] as [String: Any])
        }
        let oldQueuedAt = firstStore.getFloorMs() - 600_001
        let firstBytes = try batchBytes(firstGeneration, String(format: "%032x", 1), oldQueuedAt)
        let firstReply = try firstAuthority.accept(bytes: firstBytes, direction: "extension_to_host")
        #expect(firstReply["result"] as? String == "accepted")
        let periodID = try #require(firstReply["period_id"] as? String)
        let payloadURL = firstStore.periodFileURL(for: periodID)
        let original = try Data(contentsOf: payloadURL)

        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(store: reopened, projection: projection, wallClock: { clock.now })
        try authority.reconcileIdentity("token-1", mode: .reload)
        #expect(reopened.getDestinationGeneration() == firstGeneration)
        #expect(reopened.getOpenPeriodId() == periodID)
        #expect(try Data(contentsOf: payloadURL) == original)

        try authority.reconcileIdentity("token-2", mode: .replace)
        authority.reopenAdmission()
        let replacement = try #require(reopened.getDestinationGeneration())
        #expect(replacement != firstGeneration)
        #expect(reopened.getOpenPeriodId() == periodID)
        #expect(try Data(contentsOf: payloadURL) == original)

        let foreignGenerationBytes = try batchBytes("another-connection", String(format: "%032x", 2), reopened.getFloorMs())
        let foreignReply = try authority.accept(bytes: foreignGenerationBytes, direction: "extension_to_host")
        #expect(foreignReply["result"] as? String == "accepted")
        #expect(foreignReply["period_id"] as? String == periodID)
        #expect(try reopened.lookupReceipt(generation: "another-connection", inst: "instance-one", batchId: String(format: "%032x", 2))?.result == "accepted")
        let bytesAfterAdmission = try Data(contentsOf: payloadURL)
        #expect(bytesAfterAdmission.starts(with: original))

        try authority.reconcileIdentity(nil, mode: .replace)
        #expect(authority.status()["capture"] as? String == "not_paired")
        #expect(authority.status()["destination_generation"] is NSNull)
        #expect(reopened.getOpenPeriodId() == periodID)
        #expect(try Data(contentsOf: payloadURL) == bytesAfterAdmission)

        let afterUnpair = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(afterUnpair.getDestinationGeneration() == nil)
        #expect(afterUnpair.getPeriod(periodId: periodID)?.periodId == periodID)
        #expect(try Data(contentsOf: afterUnpair.periodFileURL(for: periodID)) == bytesAfterAdmission)
    }


    @Test func acceptedReceiptSurvivesDiscardRePairRetentionAndRestart() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let generationA = try authority.testConnectionGeneration(identityToken: "discard-pairing-a")
        let batchID = "91919191919191919191919191919191"
        let batchBytes = try JSONSerialization.data(withJSONObject: [
            "type": "batch", "destination_generation": generationA, "inst": "discard-instance",
            "batch_id": batchID, "queued_at_ms": store.getFloorMs(),
            "records": [["t": "segment_start", "ts": store.getFloorMs(), "ctx": "discard-context",
                         "blocks": [["id": "block", "text": "discarded bytes"]]]]
        ] as [String: Any])
        let accepted = try authority.accept(bytes: batchBytes, direction: "extension_to_host")
        let periodID = try #require(accepted["period_id"] as? String)
        let payloadURL = store.periodFileURL(for: periodID)
        try store.finalizePeriod(periodId: periodID, reason: "test", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!, openReplacement: false)
        #expect(!(try Data(contentsOf: payloadURL)).isEmpty)
        let token: BrowserPendingDiscardToken
        if case .present(let captured) = store.pendingDiscardInventory() { token = captured }
        else { Issue.record("Finalized pending bytes should produce a discard token"); return }
        #expect(store.discardPendingPages(token).durablyCompleted)
        #expect(!FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(store.getPeriod(periodId: periodID)?.state == "discarded")
        #expect(try store.lookupReceipt(generation: generationA, inst: "discard-instance", batchId: batchID)?.result == "accepted")

        clock.advance(by: TimeInterval(projection.policy.acceptedRetentionMs + 2_000) / 1000)
        authority.poll(now: clock.now)
        let generationB = try #require(try store.reconcileIdentity("discard-pairing-b", mode: .replace, nowMs: store.getFloorMs()))
        authority.reopenAdmission()
        #expect(generationB != generationA)
        let duplicateAfterPairing = try authority.accept(bytes: batchBytes, direction: "extension_to_host")
        #expect(duplicateAfterPairing["result"] as? String == "duplicate")

        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let reopenedAuthority = BrowserIntakeAuthority(store: reopened, projection: projection, wallClock: { clock.now })
        try reopenedAuthority.reconcileIdentity("discard-pairing-b", mode: .reload)
        let duplicateAfterRestart = try reopenedAuthority.accept(bytes: batchBytes, direction: "extension_to_host")
        #expect(duplicateAfterRestart["result"] as? String == "duplicate")
        #expect(try reopened.lookupReceipt(generation: generationA, inst: "discard-instance", batchId: batchID)?.result == "accepted")
        #expect(!FileManager.default.fileExists(atPath: reopened.periodFileURL(for: periodID).path))
        #expect(!reopened.storeIsFailed())
    }

    @Test func test6_malformedAndOversizeAdmission() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let owner = try BrowserIntakeOwner.start(
            spoolRoot: tempRoot,
            projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "token-1"),
            routeResolver: HomeBaseURLResolver { .held }
        )
        await owner.start()
        let store = owner.store
        let openFileURL = store.periodFileURL(for: try #require(store.getOpenPeriodId()))
        let lenBefore = (try? Data(contentsOf: openFileURL).count) ?? 0

        let reply1 = await owner.accept(bytes: Data("{invalid json".utf8), direction: "extension_to_host")
        guard case .refusal(let localRefusal1) = reply1 else { Issue.record("malformed input was not a local refusal"); return }
        #expect(localRefusal1.code == "bad_json")
        #expect(throws: BrowserIntakeLocalRefusal.self) {
            try BrowserPayloadDecoder.validatedHostMessage(["type": "refused", "code": localRefusal1.code], projection: projection)
        }
        #expect(((try? Data(contentsOf: openFileURL).count) ?? 0) == lenBefore)

        let oversizeData = Data(String(repeating: "o", count: projection.caps.extensionToHost + 10).utf8)
        let reply2 = await owner.accept(bytes: oversizeData, direction: "extension_to_host")
        guard case .refusal(let localRefusal2) = reply2 else { Issue.record("oversize input was not a local refusal"); return }
        #expect(localRefusal2.code == "oversize")
        #expect(((try? Data(contentsOf: openFileURL).count) ?? 0) == lenBefore)
        owner.stop()
    }

    @Test func credentialReplacementKeepsPagesHeldUntilRouteConfirmation() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let transport = ScriptedBrowserTransport()
        transport.succeed = true
        let resolution = BrowserTestResolvedHome()
        let routeState = BrowserIntakeRouteState()
        let routeURLA = "http://127.0.0.1:49321"
        let identityA = BrowserIntakeStore.identityDigest(of: "mark-held-pairing-a")
        routeState.update(BrowserIntakeRouteCapability(serverURL: routeURLA, identityDigest: identityA,
            pairingGeneration: 1, transportIncarnation: 1, credentialIsCurrent: { true }))
        let owner = try BrowserIntakeOwner.start(
            spoolRoot: tempRoot,
            projection: projection,
            credentialSnapshot: BrowserCredentialSnapshot(identityToken: "mark-held-pairing-a"),
            transport: transport,
            routeResolver: HomeBaseURLResolver { resolution.value },
            routeState: routeState
        )
        defer { owner.stop() }
        await owner.start()

        let generationA = try #require(owner.store.getDestinationGeneration())
        let queuedAt = owner.store.getFloorMs()
        let batch = Data("""
        {"type":"batch","destination_generation":"\(generationA)","inst":"mark-held-instance","batch_id":"93939393939393939393939393939393","queued_at_ms":\(queuedAt),"records":[{"t":"segment_start","ts":\(queuedAt),"ctx":"mark-held-context","blocks":[{"id":"block","text":"wait for mark"}]}]}
        """.utf8)
        guard case .message(let replyBytes) = await owner.accept(bytes: batch, direction: "extension_to_host") else {
            Issue.record("batch should remain admitted while delivery is held")
            return
        }
        let reply = try #require(JSONSerialization.jsonObject(with: replyBytes) as? [String: Any])
        let periodID = try #require(reply["period_id"] as? String)
        let payloadURL = owner.store.periodFileURL(for: periodID)
        let payload = try Data(contentsOf: payloadURL)
        try owner.store.finalizePeriod(periodId: periodID, reason: "mark_held", civilDate: Date(), timeZone: .current, openReplacement: false)
        await owner.scheduleDelivery()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.prepareCount == 0)

        try owner.credentialWillChange()
        try owner.credentialDidChange(identityToken: "mark-held-pairing-b")
        let generationB = try #require(owner.store.getDestinationGeneration())
        let routeURLB = "http://127.0.0.1:49322"
        routeState.update(BrowserIntakeRouteCapability(serverURL: routeURLB,
            identityDigest: BrowserIntakeStore.identityDigest(of: "mark-held-pairing-b"),
            pairingGeneration: 2, transportIncarnation: 2, credentialIsCurrent: { true }))
        #expect(generationB != generationA)
        #expect(try Data(contentsOf: payloadURL) == payload)
        await owner.scheduleDelivery()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.prepareCount == 0)
        #expect(try Data(contentsOf: payloadURL) == payload)

        resolution.set(.url(routeURLB))
        await owner.scheduleDelivery()
        for _ in 0..<100 {
            if owner.store.getPeriod(periodId: periodID)?.ackDurable == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.prepareCount == 1)
        let binding = try #require(try owner.store.storedDeliveryBinding(periodId: periodID))
        #expect(binding.identityDigest == BrowserIntakeStore.identityDigest(of: "mark-held-pairing-b"))
        #expect(binding.serverURL == routeURLB)
        #expect(binding.pairingGeneration == 2)
        #expect(binding.transportIncarnation == 2)
    }

    @Test func test1_pairingReplacementInvalidatesPermitAndRetainsPeriodFile() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let gate = BrowserUploadGate(store: store)
        let firstGeneration = try authority.testConnectionGeneration(identityToken: "token-1")
        let snap = try snapshot(generation: firstGeneration, id: 1, now: store.getFloorMs())
        let reply = try authority.accept(bytes: snap, direction: "extension_to_host")
        let periodID = try #require(reply["period_id"] as? String)
        try store.finalizePeriod(periodId: periodID, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let permit = try #require(gate.currentPermit())
        let payloadURL = store.periodFileURL(for: periodID)
        let originalBytes = try Data(contentsOf: payloadURL)
        #expect(!originalBytes.isEmpty)

        gate.invalidateCurrentLease()
        try authority.reconcileIdentity("token-2", mode: .replace)
        authority.reopenAdmission()
        gate.resumeReaders()
        #expect(!gate.isPermitActive(permit))
        #expect(gate.readBodyData(fileURL: payloadURL, permit: permit).isEmpty)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(try Data(contentsOf: payloadURL) == originalBytes)
        #expect(authority.status()["capture"] as? String == "permitted")
        #expect(store.getPeriod(periodId: periodID)?.state == "finalized")
    }

    @Test func test2_sourceAwareMultipartAndDayReadAndSegmentRemoved() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. Multipart MIME builder
        let audioFile = tempRoot.appendingPathComponent("120000_300_audio.m4a")
        let videoFile = tempRoot.appendingPathComponent("120000_300_screen.mp4")
        let notesFile = tempRoot.appendingPathComponent("notes.jsonl")
        let browserFile = tempRoot.appendingPathComponent("browser_pages.jsonl")
        try Data("audio-data".utf8).write(to: audioFile)
        try Data("video-data".utf8).write(to: videoFile)
        try Data("notes-data".utf8).write(to: notesFile)
        try Data("browser-data".utf8).write(to: browserFile)

        let mediaBodyURL = tempRoot.appendingPathComponent("media_body.tmp")
        _ = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://journal.example",
            day: "20260703",
            segment: "120000_300",
            selectedFiles: [videoFile, audioFile, notesFile],
            meta: nil,
            source: nil,
            boundary: "media-boundary-123",
            bodyURL: mediaBodyURL
        )
        let mediaBody = try String(contentsOf: mediaBodyURL, encoding: .utf8)
        #expect(mediaBody.contains("Content-Type: video/mp4"))
        #expect(mediaBody.contains("Content-Type: audio/mp4"))
        #expect(!mediaBody.contains("application/jsonl"))
        #expect(!mediaBody.contains("\"source\""))

        let browserBodyURL = tempRoot.appendingPathComponent("browser_body.tmp")
        _ = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://journal.example",
            day: "20260703",
            segment: "120000_300",
            selectedFiles: [browserFile],
            meta: nil,
            source: "browser",
            boundary: "browser-boundary-123",
            bodyURL: browserBodyURL
        )
        let browserBody = try String(contentsOf: browserBodyURL, encoding: .utf8)
        #expect(browserBody.contains("Content-Type: application/jsonl"))
        #expect(browserBody.contains("\"source\":\"browser\""))

        // 2. Day query path
        #expect(IngestProtocolV3.segmentsDayPath("20260703") == "/app/devices/ingest/segments/20260703")
        #expect(IngestProtocolV3.segmentsDayPath("20260703", source: nil) == "/app/devices/ingest/segments/20260703")
        #expect(IngestProtocolV3.segmentsDayPath("20260703", source: "") == "/app/devices/ingest/segments/20260703")
        #expect(IngestProtocolV3.segmentsDayPath("20260703", source: "browser") == "/app/devices/ingest/segments/20260703?source=browser")

        // 3. Segment removed handling
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot.appendingPathComponent("spool"), projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let gen = try authority.testConnectionGeneration(identityToken: "tok")
        let snap: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "22222222222222222222222222222222",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "to be removed"]]]]
        ]
        let rep = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
        let pid = try #require(rep["period_id"] as? String)
        try store.finalizePeriod(periodId: pid, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        let pFileURL = store.periodFileURL(for: pid)
        #expect(FileManager.default.fileExists(atPath: pFileURL.path))

        let gate = BrowserUploadGate(store: store)
        let routeState = BrowserIntakeRouteState()
        _ = routeState.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let transport = ScriptedBrowserTransport()
        transport.uploadFailure = UploadError.serverError(IngestServerError(statusCode: 409, reasonCode: "segment_removed", bodyStatus: nil))
        let planner = BrowserUploadPlanner(store: store, gate: gate, client: transport, routeState: routeState)

        let stored = try #require(store.getPeriod(periodId: pid))
        let wrongBinding = BrowserIngestAck(
            generation: "wrong-gen", periodId: pid, filename: "browser_pages.jsonl",
            sha256: stored.fileSha256 ?? "", size: UInt64(stored.committedLength), metadata: nil,
            requestedDay: stored.requestedDay ?? "", requestedSegment: stored.requestedSegment ?? "",
            canonicalKey: nil, status: .duplicate
        )
        #expect(throws: BrowserIntakeStoreError.self) {
            try store.persistDeliveryBinding(wrongBinding)
        }
        #expect(store.getPeriod(periodId: pid)?.state == "finalized")
        #expect(FileManager.default.fileExists(atPath: pFileURL.path))

        await planner.planAndUpload()
        #expect(store.getPeriod(periodId: pid)?.state == "removed")
        #expect(!FileManager.default.fileExists(atPath: pFileURL.path))
    }

    @Test func test3_collisionAndLostResponseProof() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )

        let gen = try authority.testConnectionGeneration(identityToken: "tok-3")

        // Create and finalize period 1
        let snap1: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "33333333333333333333333333333333",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "collision test"]]]]
        ]
        let rep1 = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap1), direction: "extension_to_host")
        let pid1 = rep1["period_id"] as! String
        try store.finalizePeriod(periodId: pid1, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        let p1FileURL = store.periodFileURL(for: pid1)
        let p1Data = try Data(contentsOf: p1FileURL)
        let p1Sha256 = SHA256.hash(data: p1Data).map { String(format: "%02x", $0) }.joined()
        let period1 = try #require(store.getPeriod(periodId: pid1))

        // 1. Collision response handling
        let collisionAck = BrowserIngestAck(
            generation: gen,
            source: "browser",
            periodId: pid1,
            filename: "browser_pages.jsonl",
            sha256: p1Sha256,
            size: UInt64(p1Data.count),
            metadata: nil,
            requestedDay: try #require(period1.requestedDay),
            requestedSegment: try #require(period1.requestedSegment),
            canonicalKey: "120001_300",
            status: .collision
        )
        let ackURL1 = BrowserIngestAckStore.ackURL(periodDirectory: p1FileURL.deletingLastPathComponent())
        try store.persistDeliveryBinding(collisionAck)
        try BrowserIngestAckStore.write(collisionAck, to: ackURL1)
        try store.markAckDurable(periodId: pid1)

        let storedAck1 = try #require(try BrowserIngestAckStore.read(from: ackURL1))
        #expect(storedAck1.status == .collision)
        #expect(storedAck1.canonicalKey == "120001_300")
        #expect(store.getPeriod(periodId: pid1)?.canonicalKey == "120001_300")

        // 2. Lost response recovery: custody .present releases period bytes
        #expect(FileManager.default.fileExists(atPath: p1FileURL.path))
        try store.releaseProven(periodId: pid1, binding: collisionAck, nowMs: 1700000000000)
        #expect(!FileManager.default.fileExists(atPath: p1FileURL.path))
        #expect(store.getPeriod(periodId: pid1)?.state == "delivered")
    }

    @Test @MainActor func test4_lifecyclePauseResumeAndStartupComposition() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let pauseManager = PauseManager()
        pauseManager.onPauseIntake = { [weak authority, weak store] in
            authority?.setPaused(true)
            store?.setPaused(true)
        }
        pauseManager.onResumeIntake = { [weak authority, weak store] in
            authority?.setPaused(false)
            store?.setPaused(false)
        }

        let gen = try authority.testConnectionGeneration(identityToken: "tok-4")
        #expect(authority.status()["capture"] as? String == "permitted")

        // 1. Pause intake
        pauseManager.pause(for: .seconds(300))
        #expect(authority.isPaused)
        #expect(store.isPaused)
        #expect(authority.status()["capture"] as? String == "paused")

        // A batch already created by the extension can still be admitted while capture is paused.
        let snap: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "44444444444444444444444444444444",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "paused test"]]]]
        ]
        let repPaused = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
        #expect(repPaused["result"] as? String == "accepted")
        #expect(authority.status()["capture"] as? String == "paused")

        // 2. Resume intake
        pauseManager.resume()
        #expect(!authority.isPaused)
        #expect(!store.isPaused)
        #expect(authority.status()["capture"] as? String == "permitted")

        // A retry after resume is an idempotent duplicate.
        let repResumed = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
        #expect(repResumed["result"] as? String == "duplicate")
    }

    @Test func test7_nulIdentifiersAndDigestRestart() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1700000000) },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let token = "instance-A\u{0}private-key"
        let gen = try authority.testConnectionGeneration(identityToken: token)
        let instA = "i\u{0}a"
        let instB = "i\u{0}b"
        let ctxA = "c\u{0}a"
        let ctxB = "c\u{0}b"
        func batch(inst: String, ctx: String, id: String, snapshot: Bool) -> Data {
            let record: [String: Any] = snapshot
                ? ["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": ctx, "blocks": [["id": "b", "text": "t"]]]
                : ["t": "delta", "ts": 1700000000000 as UInt64, "ctx": ctx, "op": "add", "block": ["id": "b", "text": "t"]]
            let object: [String: Any] = [
                "type": "batch",
                "destination_generation": gen,
                "inst": inst,
                "batch_id": id,
                "queued_at_ms": 1700000000000 as UInt64,
                "records": [record]
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }
        let first = try authority.accept(bytes: batch(inst: instA, ctx: ctxA, id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", snapshot: true), direction: "extension_to_host")
        let second = try authority.accept(bytes: batch(inst: instB, ctx: ctxA, id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", snapshot: true), direction: "extension_to_host")
        #expect(first["result"] as? String == "accepted")
        #expect(second["result"] as? String == "accepted")
        let borrowed = try authority.accept(bytes: batch(inst: instB, ctx: ctxB, id: "cccccccccccccccccccccccccccccccc", snapshot: false), direction: "extension_to_host")
        #expect(borrowed["reason"] as? String == "snapshot_required")
        #expect(try store.lookupReceipt(generation: gen, inst: instA, batchId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") == nil)

        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let again = BrowserIntakeAuthority(store: reopened, projection: projection, wallClock: { Date(timeIntervalSince1970: 1700000000) })
        #expect(try again.testConnectionGeneration(identityToken: token) == gen)
        try again.reconcileIdentity(nil, mode: .replace)
        #expect(reopened.getDestinationGeneration() == nil)
    }

    @Test func test8_fileSyncContinuationRefinalizeAndMissingPayload() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let gen = try authority.testConnectionGeneration(identityToken: "token-1")
        func payload(_ id: String, _ marker: String) -> Data {
            let object: [String: Any] = [
                "type": "batch", "destination_generation": gen, "inst": "inst-1", "batch_id": id,
                "queued_at_ms": 1700000000000 as UInt64,
                "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-\(marker)", "blocks": [["id": "b", "text": marker]]]]
            ]
            return try! JSONSerialization.data(withJSONObject: object)
        }
        let anchor = try authority.accept(bytes: payload("00000000000000000000000000000000", "ACKNOWLEDGED_PREFIX"), direction: "extension_to_host")
        #expect(anchor["result"] as? String == "accepted")
        store.crashPoint = .afterFileSync
        let rejected = try authority.accept(bytes: payload("11111111111111111111111111111111", "REJECTED_SUFFIX"), direction: "extension_to_host")
        #expect(rejected["reason"] as? String == "resource_exhausted")
        #expect(try store.lookupReceipt(generation: gen, inst: "inst-1", batchId: "11111111111111111111111111111111") == nil)
        let openId = try #require(store.getOpenPeriodId())
        let openURL = store.periodFileURL(for: openId)
        let recoveredPrefix = String(decoding: try Data(contentsOf: openURL), as: UTF8.self)
        #expect(recoveredPrefix.contains("ACKNOWLEDGED_PREFIX"))
        // The simulated crash leaves a suffix on disk. The next mutation must
        // recover the committed prefix before it can accept or finalize again.
        #expect(recoveredPrefix.contains("REJECTED_SUFFIX"))

        store.crashPoint = .none
        let accepted = try authority.accept(bytes: payload("22222222222222222222222222222222", "ACCEPTED_BODY"), direction: "extension_to_host")
        #expect(accepted["result"] as? String == "accepted")
        let kept = String(decoding: try Data(contentsOf: openURL), as: UTF8.self)
        #expect(kept.contains("ACCEPTED_BODY"))
        #expect(kept.contains("ACKNOWLEDGED_PREFIX"))
        #expect(!kept.contains("REJECTED_SUFFIX"))

        try store.finalizePeriod(periodId: openId, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let sealed = store.getPeriod(periodId: openId)
        try store.finalizePeriod(periodId: openId, reason: "again", civilDate: clock.now.addingTimeInterval(10), timeZone: TimeZone(identifier: "UTC")!)
        let resealed = store.getPeriod(periodId: openId)
        #expect(resealed?.requestedSegment == sealed?.requestedSegment)
        #expect(resealed?.requestedDay == sealed?.requestedDay)
        #expect(resealed?.finalizedAtMs == sealed?.finalizedAtMs)

        try FileManager.default.removeItem(at: openURL)
        let recovered = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(recovered.storeIsFailed())
        let failed = BrowserIntakeAuthority(store: recovered, projection: projection, wallClock: { clock.now })
        let stat = failed.status()
        #expect(stat["capture"] as? String == "unavailable")
        #expect(stat["delivery"] as? String == "failed")
        #expect(stat["failure"] as? String == "local_io")
        let replay = try failed.accept(bytes: payload("22222222222222222222222222222222", "ACCEPTED_BODY"), direction: "extension_to_host")
        #expect(replay["result"] as? String == "rejected")
        #expect(replay["reason"] as? String == "resource_exhausted")
    }

    @Test func test9_monotonicExpiryWallRollbackAndRootRecords() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let mono = ManualMonotonicClock()
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(
            store: store,
            projection: projection,
            monotonicClock: mono,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let gen = try authority.testConnectionGeneration(identityToken: "token-1")
        let delta: [String: Any] = [
            "type": "batch", "destination_generation": gen, "inst": "inst-1",
            "batch_id": "dddddddddddddddddddddddddddddddd",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "delta", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "op": "add", "block": ["id": "b", "text": "t"]]]
        ]
        let deltaBytes = try JSONSerialization.data(withJSONObject: delta)
        let first = try authority.accept(bytes: deltaBytes, direction: "extension_to_host")
        #expect(first["reason"] as? String == "snapshot_required")
        mono.advance(milliseconds: 600_001)
        let oldOutbox = try authority.accept(bytes: deltaBytes, direction: "extension_to_host")
        #expect(oldOutbox["reason"] as? String == "snapshot_required")

        let decoy = """
        {"extra":{"records":[{"unvalidated":true}]},"type":"batch","destination_generation":"\(gen)","inst":"inst-1","batch_id":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","queued_at_ms":\(store.getFloorMs()),"records":[{"t":"segment_start","ts":1000.0,"ctx":"ctx-real","blocks":[{"id":"b","text":"real-record"}]}]}
        """
        let decoyReply = try authority.accept(bytes: Data(decoy.utf8), direction: "extension_to_host")
        #expect(decoyReply["result"] as? String == "accepted")
        let decoyFile = try String(contentsOf: store.periodFileURL(for: try #require(decoyReply["period_id"] as? String)), encoding: .utf8)
        #expect(decoyFile.contains("\"ts\":1000.0"))
        #expect(decoyFile.contains("real-record"))
        #expect(!decoyFile.contains("unvalidated"))

        let pretty = """
        {
          "type": "batch",
          "destination_generation": "\(gen)",
          "inst": "inst-1",
          "batch_id": "ffffffffffffffffffffffffffffffff",
          "queued_at_ms": \(store.getFloorMs()),
          "records": [
            {
              "t": "segment_start",
              "ts": 1000.0,
              "ctx": "ctx-pretty",
              "blocks": [{"id": "b", "text": "pretty"}]
            }
          ]
        }
        """
        let prettyReply = try authority.accept(bytes: Data(pretty.utf8), direction: "extension_to_host")
        #expect(prettyReply["result"] as? String == "accepted")
        let prettyText = try String(contentsOf: store.periodFileURL(for: try #require(prettyReply["period_id"] as? String)), encoding: .utf8)
        let lines = prettyText.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.contains { $0.contains("\"ts\":1000.0") && $0.contains("pretty") && !$0.contains("\n") })
    }

    @Test(arguments: [false, true])
    func emptyDiscardedPeriodWithoutReceiptsReclaimsImmediately(directoryMissing: Bool) throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let nowMs: UInt64 = 1700000000000
        _ = try store.testConnectionGeneration(identityToken: "empty-pairing", nowMs: nowMs)
        let old = try #require(store.getOpenPeriodId())
        let directory = store.periodFileURL(for: old).deletingLastPathComponent()
        try store.finalizePeriod(periodId: old, reason: "idle", civilDate: Date(timeIntervalSince1970: Double(nowMs) / 1000), timeZone: TimeZone(secondsFromGMT: 0)!)
        let current = try #require(store.getOpenPeriodId())
        if directoryMissing { try FileManager.default.removeItem(at: directory) }
        store.garbageCollectSettledPeriods()
        #expect(store.getPeriod(periodId: old) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.getPeriod(periodId: current)?.state == "open")
        #expect(!store.storeIsFailed())
        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(!reopened.storeIsFailed())
        #expect(reopened.getDestinationGeneration() == store.getDestinationGeneration())
    }

    @Test(arguments: [false, true])
    func stagingRecoveryPreservesUnexpectedContents(link: Bool) throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let staging = store.stagingRootURL().appendingPathComponent("browser-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let unrelated = tempRoot.deletingLastPathComponent().appendingPathComponent("unrelated-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unrelated) }
        let marker = Data("must-remain".utf8)
        try marker.write(to: unrelated)
        let child = staging.appendingPathComponent(link ? "multipart.body" : "unknown-file")
        if link {
            try FileManager.default.createSymbolicLink(at: child, withDestinationURL: unrelated)
        } else {
            try marker.write(to: child)
        }
        if link {
            // Migration capacity inventory refuses symlinks before SQLite opens.
            #expect(throws: BrowserIntakeStoreError.localIO) {
                try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
            }
        } else {
            let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
            #expect(reopened.storeIsFailed())
        }
        #expect(try Data(contentsOf: unrelated) == marker)
        #expect(try Data(contentsOf: child) == marker)
    }

    @Test func stagingConsumesReservedSpaceAndRecoveryReclaimsOnlyItsCopy() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let now = Date(timeIntervalSince1970: 1700000000)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { now })
        let generation = try authority.testConnectionGeneration(identityToken: "staging-pairing")
        let bytes = Data("""
        {"type":"batch","destination_generation":"\(generation)","inst":"staging-inst","batch_id":"97979797979797979797979797979797","queued_at_ms":1700000000000,"records":[{"t":"segment_start","ts":1700000000000,"ctx":"ctx","blocks":[{"id":"b","text":"retained-original"}]}]}
        """.utf8)
        let accepted = try authority.accept(bytes: bytes, direction: "extension_to_host")
        let periodID = try #require(accepted["period_id"] as? String)
        try store.finalizePeriod(periodId: periodID, reason: "seal", civilDate: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let source = store.periodFileURL(for: periodID)
        let original = try Data(contentsOf: source)
        let before = store.projectedSpoolBytes()
        let staging = store.stagingRootURL().appendingPathComponent("browser-upload-\(UUID().uuidString)")
        try store.registerStagingDirectory(staging, reservedBytes: original.count + 64 * 1024)
        #expect(store.projectedSpoolBytes() == before)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("abandoned-copy".utf8).write(to: staging.appendingPathComponent("multipart.body"))
        // Recreate after abandoned staging, without claiming process/power-loss coverage.
        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try Data(contentsOf: source) == original)
        #expect(reopened.getPeriod(periodId: periodID)?.state == "finalized")
        #expect(try reopened.lookupReceipt(generation: generation, inst: "staging-inst", batchId: "97979797979797979797979797979797")?.result == "accepted")
        #expect(!reopened.storeIsFailed())
    }

    @Test(arguments: [false, true])
    func browserURLSessionUsesCapturedLeaseAndInjectedTransport(oversizedResponse: Bool) async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let spool = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        _ = try spool.testConnectionGeneration(identityToken: "session-pairing", nowMs: 1700000000000)
        let gate = BrowserUploadGate(store: spool)
        let permit = try #require(gate.currentPermit())
        let routes = BrowserIntakeRouteState()
        let route = BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1:49323",
            identityDigest: permit.identityToken, pairingGeneration: 1, transportIncarnation: 1,
            credentialIsCurrent: { true })
        routes.update(route)
        let candidateLease = gate.makeLease(permit: permit, periodId: "session-period",
            routeCheck: { routes.matches(route) })
        let lease = try #require(candidateLease)
        let file = tempRoot.appendingPathComponent("browser_pages.jsonl")
        try Data("synthetic-browser-session-marker\n".utf8).write(to: file)
        let prepared = try IngestV3UploadRequestBuilder.build(baseURL: route.serverURL,
            day: "20260929", segment: "120000_1", selectedFiles: [file], meta: nil,
            source: "browser", boundary: "session-boundary",
            bodyURL: tempRoot.appendingPathComponent("multipart.body"))
        let effects = ObserverURLProtocolStore()
        effects.enqueue(statusCode: 503, body: oversizedResponse ? String(repeating: "x", count: 1024 * 1024 + 1) : "{}")
        let config = observerURLProtocolConfiguration(store: effects)
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        let client = UploadClient(sessionConfiguration: config)
        let result = await client.uploadStaged(prepared: prepared, lease: lease)
        if oversizedResponse {
            guard case .failure(let error) = result else {
                Issue.record("Oversized response must not acknowledge custody")
                return
            }
            #expect(error as? UploadError == .invalidResponse)
        }
        #expect(effects.snapshotRequests().count == 1)
        let body = try #require(effects.snapshotRequestBodyData().first ?? nil)
        #expect(String(decoding: body, as: UTF8.self).contains("synthetic-browser-session-marker"))
        // A connection replacement at the same URL must not reuse this lease.
        routes.update(nil)
        routes.update(BrowserIntakeRouteCapability(serverURL: route.serverURL,
            identityDigest: permit.identityToken, pairingGeneration: 1, transportIncarnation: 2,
            credentialIsCurrent: { true }))
        _ = await client.uploadStaged(prepared: prepared, lease: lease)
        #expect(effects.snapshotRequests().count == 1)
    }

    @Test(arguments: [false, true])
    func finalizedCorruptionCannotReachTransport(restart: Bool) async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let now = Date(timeIntervalSince1970: 1700000000)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { now })
        let gen = try authority.testConnectionGeneration(identityToken: "token-1")
        let bytes = Data("""
        {"type":"batch","destination_generation":"\(gen)","inst":"inst-1","batch_id":"98989898989898989898989898989898","queued_at_ms":1700000000000,"records":[{"t":"segment_start","ts":1700000000000,"ctx":"ctx-1","blocks":[{"id":"b","text":"before"}]}]}
        """.utf8)
        let accepted = try authority.accept(bytes: bytes, direction: "extension_to_host")
        let pid = try #require(accepted["period_id"] as? String)
        try store.finalizePeriod(periodId: pid, reason: "seal", civilDate: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let url = store.periodFileURL(for: pid)
        let original = try String(contentsOf: url, encoding: .utf8)
        let damaged = original.replacingOccurrences(of: "before", with: "after!")
        #expect(damaged != original)
        #expect(damaged.utf8.count == original.utf8.count)
        try Data(damaged.utf8).write(to: url)
        let candidate = restart ? try BrowserIntakeStore(rootURL: tempRoot, projection: projection) : store
        if !candidate.storeIsFailed() {
            _ = try candidate.testConnectionGeneration(identityToken: "token-1", nowMs: 1700000000000)
        }
        let transport = ScriptedBrowserTransport()
        let route = BrowserIntakeRouteState()
        _ = route.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let planner = BrowserUploadPlanner(store: candidate, gate: BrowserUploadGate(store: candidate), client: transport, routeState: route)
        await planner.planAndUpload()
        #expect(transport.prepareCount == 0)
        #expect(candidate.storeIsFailed())
        #expect(candidate.getPeriod(periodId: pid)?.state == "finalized")
        #expect(try String(contentsOf: url, encoding: .utf8) == damaged)
    }

    @Test func finalizedEnvelopeMatchesVendoredIngestAddressContract() throws {
        let root = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let contract = vendorURL.appendingPathComponent("contracts/client-ingest")
        let rawSchema = try Data(contentsOf: contract.appendingPathComponent("protocol.schema.json"))
        let adoption = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            contract.appendingPathComponent("adoption.json"))) as? [String: Any])
        #expect(SHA256.hash(data: rawSchema).map { String(format: "%02x", $0) }.joined()
            == adoption["schema_sha256"] as? String)
        let schema = try #require(JSONSerialization.jsonObject(with: rawSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])

        // The observing device's civil day crosses midnight in UTC+14.
        let instant = Date(timeIntervalSince1970: 1700000000)
        let zone = try #require(TimeZone(secondsFromGMT: 14 * 3600))
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: root.appendingPathComponent("spool"), projection: projection)
        let authority = BrowserIntakeAuthority(store: store, projection: projection,
            wallClock: { instant }, timeZone: zone)
        let generation = try authority.testConnectionGeneration(identityToken: "contract-address")
        let batch: [String: Any] = ["type": "batch", "destination_generation": generation,
            "inst": "address-inst", "batch_id": "abababababababababababababababab",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64,
                "ctx": "address-ctx", "blocks": [["id": "b", "text": "address-vector"]]]]]
        let accepted = try authority.accept(bytes: JSONSerialization.data(withJSONObject: batch), direction: "extension_to_host")
        let id = try #require(accepted["period_id"] as? String)
        try store.finalizePeriod(periodId: id, reason: "contract-vector", civilDate: instant, timeZone: zone)
        let period = try #require(store.getPeriod(periodId: id))
        let prepared = try IngestV3UploadRequestBuilder.build(baseURL: "http://127.0.0.1",
            day: #require(period.requestedDay), segment: #require(period.requestedSegment),
            selectedFiles: [store.periodFileURL(for: id)], meta: nil, source: "browser",
            boundary: "ingest-address-vector", bodyURL: root.appendingPathComponent("multipart.body"))
        let parts = try String(contentsOf: prepared.bodyURL, encoding: .utf8).components(separatedBy: "\r\n\r\n")
        #expect(parts.count >= 2)
        let envelopeText = try #require(parts.dropFirst().first).components(separatedBy: "\r\n--")[0]
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any])
        for field in ["day", "segment"] {
            let value = try #require(envelope[field] as? String)
            let pattern = try #require(properties[field]?["pattern"] as? String)
            #expect(value.range(of: pattern, options: .regularExpression) != nil)
        }
        #expect(envelope["day"] as? String == "20231115")
        #expect(envelope["segment"] as? String == "121320_1")
        #expect(envelope["source"] as? String == "browser")
        #expect(envelope["meta"] == nil)
    }

    @Test func test10_inFlightAckKeepsItsCapturedRouteAfterReplacement() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let gate = BrowserUploadGate(store: store)
        let generation = try authority.testConnectionGeneration(identityToken: "token-1")
        let batch: [String: Any] = [
            "type": "batch", "destination_generation": generation, "inst": "inst-1",
            "batch_id": "12121212121212121212121212121212", "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b", "text": "planner"]]]]
        ]
        let reply = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: batch), direction: "extension_to_host")
        let periodID = try #require(reply["period_id"] as? String)
        try store.finalizePeriod(periodId: periodID, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let payloadURL = store.periodFileURL(for: periodID)
        let original = try Data(contentsOf: payloadURL)
        let routeState = BrowserIntakeRouteState()
        let routeA = BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1", identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 1, transportIncarnation: 1, credentialIsCurrent: { true })
        routeState.update(routeA)
        let transport = ScriptedBrowserTransport()
        transport.succeed = true
        let planner = BrowserUploadPlanner(store: store, gate: gate, client: transport, serverURLProvider: { "http://127.0.0.1" }, routeState: routeState)
        await planner.planAndUpload()
        #expect(transport.prepareCount == 1)
        let captured = try #require(store.storedDeliveryBinding(periodId: periodID))
        #expect(captured.serverURL == routeA.serverURL)
        #expect(captured.identityDigest == routeA.identityDigest)
        #expect(captured.pairingGeneration == routeA.pairingGeneration)
        #expect(captured.transportIncarnation == routeA.transportIncarnation)
        #expect(try Data(contentsOf: payloadURL) == original)

        // A same-journal replacement is still a different connection. The old
        // binding must not use the new route's listing as proof of delivery.
        let routeB = BrowserIntakeRouteCapability(serverURL: routeA.serverURL, identityDigest: routeA.identityDigest, pairingGeneration: 2, transportIncarnation: 2, credentialIsCurrent: { true })
        routeState.setOnChange { [weak gate] _, _ in
            gate?.invalidateCurrentLease()
            gate?.resumeReaders()
        }
        routeState.update(routeB)
        gate.resumeReaders()
        transport.succeed = false
        transport.onUpload = { routeState.update(nil) }
        await planner.planAndUpload()
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(try Data(contentsOf: payloadURL) == original)
        #expect(store.getPeriod(periodId: periodID)?.state == "finalized")
        #expect(store.currentStatus(nowMs: store.getFloorMs(), monotonicFreshnessMs: 0)["delivery"] as? String != "failed")
        #expect(!store.storeIsFailed())
    }

    @Test func unclearedAckFromReplacedConnectionUploadsOnCurrentRoute() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection, ioInjector: injector)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let generation = try authority.testConnectionGeneration(identityToken: "same-journal")
        let accepted = try authority.accept(bytes: JSONSerialization.data(withJSONObject: [
            "type": "batch", "destination_generation": generation, "inst": "route-instance",
            "batch_id": "92929292929292929292929292929292", "queued_at_ms": store.getFloorMs(),
            "records": [["t": "segment_start", "ts": store.getFloorMs(), "ctx": "route-context",
                         "blocks": [["id": "block", "text": "uncleared copy"]]]]
        ] as [String: Any]), direction: "extension_to_host")
        let periodID = try #require(accepted["period_id"] as? String)
        try store.finalizePeriod(periodId: periodID, reason: "test", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let period = try #require(store.getPeriod(periodId: periodID))
        let payloadURL = store.periodFileURL(for: periodID)
        let routeA = BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1", identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 7, transportIncarnation: 11, credentialIsCurrent: { true })
        let ack = BrowserIngestAck(generation: generation, periodId: periodID,
            sha256: try #require(period.fileSha256), size: UInt64(period.committedLength), metadata: nil,
            requestedDay: try #require(period.requestedDay), requestedSegment: try #require(period.requestedSegment),
            canonicalKey: period.requestedSegment, status: .ok)
        let bindingA = BrowserDeliveryBinding(ack: ack, route: routeA)
        let syncCalls = BrowserTestInjectedSize()
        injector.setFailure { point in
            guard point == .sync else { return }
            syncCalls.value += 1
            if syncCalls.value == 2 { throw BrowserIngestAckError.parentSyncFailed }
        }
        do {
            try store.publishDeliveryAck(bindingA)
            Issue.record("parent-directory sync should have failed after publishing the ack")
        } catch BrowserIngestAckError.parentSyncFailed {
            // The ack file is present, but the database correctly leaves it pending.
        } catch {
            Issue.record("unexpected ack publication error: \(error)")
        }
        injector.setFailure(nil)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: payloadURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: ackURL.path))
        #expect(store.getPeriod(periodId: periodID)?.ackDurable == false)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(!store.storeIsFailed())

        let routeState = BrowserIntakeRouteState()
        let routeB = BrowserIntakeRouteCapability(serverURL: routeA.serverURL, identityDigest: routeA.identityDigest, pairingGeneration: 8, transportIncarnation: 12, credentialIsCurrent: { true })
        routeState.update(routeB)
        let currentTransport = ScriptedBrowserTransport()
        currentTransport.succeed = true
        let listingReads = BrowserTestInjectedSize()
        currentTransport.onDayRead = { listingReads.value += 1 }
        let planner = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: currentTransport,
            serverURLProvider: { routeB.serverURL }, routeState: routeState)
        await planner.planAndUpload()
        #expect(currentTransport.prepareCount == 1)
        #expect(currentTransport.uploadedByteCount > 0)
        #expect(listingReads.value == 0)
        #expect(store.getPeriod(periodId: periodID)?.ackDurable == true)
        #expect(try store.storedDeliveryBinding(periodId: periodID)?.transportIncarnation == routeB.transportIncarnation)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path))
        #expect(!store.storeIsFailed())
    }

    @Test func wholeSnapshotAtProjectedCeilingCommitsAndNextByteRefuses() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let store = try BrowserIntakeStore(rootURL: url, projection: projection, ioInjector: injector)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.testConnectionGeneration(identityToken: "exact-capacity-pairing")
        let bytes = try snapshot(generation: generation, id: 1, now: store.getFloorMs())
        guard case .accept(.batch(let decoded)) = BrowserPayloadDecoder.decode(bytes: bytes, direction: "extension_to_host", projection: projection) else {
            Issue.record("Boundary witness must use the production decoder"); return
        }
        let recordBytes = decoded.records.reduce(0) { $0 + $1.rawSlice.count + 1 }
        let before = store.projectedSpoolBytes()
        let stage = store.stagingRootURL().appendingPathComponent("capacity-boundary")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let stageFile = stage.appendingPathComponent("multipart.body")
        try Data().write(to: stageFile)
        let injected = BrowserTestInjectedSize()
        injector.setSizeOverride { file, actual in file == stageFile ? injected.value : actual }
        injected.value = projection.policy.spoolBytes - before - recordBytes
        try store.registerStagingDirectory(stage, reservedBytes: 0)
        let accepted = try authority.accept(bytes: bytes, direction: "extension_to_host")
        #expect(accepted["result"] as? String == "accepted")
        #expect(store.projectedSpoolBytes() == projection.policy.spoolBytes)
        let periodID = try #require(accepted["period_id"] as? String)
        let original = try Data(contentsOf: store.periodFileURL(for: periodID))
        injected.value += 1
        let refused = try authority.accept(bytes: snapshot(generation: generation, id: 2, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(refused["result"] as? String == "rejected")
        #expect(refused["reason"] as? String == "resource_exhausted")
        #expect(try store.lookupReceipt(generation: generation, inst: decoded.inst, batchId: String(format: "%032x", 2)) == nil)
        #expect(try !store.isContextInitialized(periodId: periodID, inst: decoded.inst, ctx: "ctx-2"))
        #expect(try Data(contentsOf: store.periodFileURL(for: periodID)) == original)
        #expect(try authority.accept(bytes: bytes, direction: "extension_to_host")["result"] as? String == "duplicate")
        #expect(!store.storeIsFailed())
        injected.value = 0
        try store.releaseStagingDirectory(stage)
    }

    @Test func recognizedWalMigratesAndOversizedOrUnknownCustodyIsPreserved() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: url, projection: projection)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection,
            wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let generation = try authority!.testConnectionGeneration(identityToken: "wal-migration-pairing")
        let reply = try authority!.accept(bytes: snapshot(generation: generation, id: 1, now: store!.getFloorMs()), direction: "extension_to_host")
        let periodID = try #require(reply["period_id"] as? String)
        let payloadURL = store!.periodFileURL(for: periodID)
        let originalPayload = try Data(contentsOf: payloadURL)
        authority = nil; store = nil
        let dbURL = url.appendingPathComponent("intake.sqlite")
        let walURL = url.appendingPathComponent("intake.sqlite-wal")
        var database: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE periods SET created_at_ms=created_at_ms+1;", nil, nil, nil) == SQLITE_OK)
        let oldDatabase = try Data(contentsOf: dbURL)
        let oldWal = try Data(contentsOf: walURL)
        #expect(oldWal.count > 32)
        #expect(sqlite3_close(database) == SQLITE_OK)
        try oldDatabase.write(to: dbURL)
        try oldWal.write(to: walURL)

        let nearCeiling = BrowserIntakeIOInjector()
        nearCeiling.setSizeOverride { file, actual in file == walURL ? projection.policy.spoolBytes : actual }
        #expect(throws: BrowserIntakeStoreError.resourceExhausted) {
            try BrowserIntakeStore(rootURL: url, projection: projection, ioInjector: nearCeiling)
        }
        #expect(try Data(contentsOf: dbURL) == oldDatabase)
        #expect(try Data(contentsOf: walURL) == oldWal)
        #expect(try Data(contentsOf: payloadURL) == originalPayload)
        var reopened: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: url, projection: projection)
        #expect(reopened!.getPeriod(periodId: periodID)?.createdAtMs == 1_700_000_000_001)
        #expect(try reopened!.lookupReceipt(generation: generation, inst: String(repeating: "i", count: 128), batchId: String(format: "%032x", 1))?.result == "accepted")
        #expect(!reopened!.storeIsFailed())
        #expect(try physicalBytes(url) <= reopened!.projectedSpoolBytes())
        reopened = nil
        let unknown = url.appendingPathComponent("unknown-custody")
        try Data("synthetic-unknown-must-remain".utf8).write(to: unknown)
        let dbBeforeUnknown = try Data(contentsOf: dbURL)
        #expect(throws: BrowserIntakeStoreError.localIO) { try BrowserIntakeStore(rootURL: url, projection: projection) }
        #expect(try Data(contentsOf: dbURL) == dbBeforeUnknown)
        #expect(try Data(contentsOf: payloadURL) == originalPayload)
        #expect(try Data(contentsOf: unknown) == Data("synthetic-unknown-must-remain".utf8))
    }

    @Test func nonVersionOneStoreResetsOldRetiredLayout() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let retired = url.appendingPathComponent("retired", isDirectory: true)
        let retiredPeriod = retired.appendingPathComponent("periods/00000000-0000-0000-0000-000000000001", isDirectory: true)
        try FileManager.default.createDirectory(at: retiredPeriod, withIntermediateDirectories: true)
        try Data("old payload".utf8).write(to: retiredPeriod.appendingPathComponent("browser_pages.jsonl"))
        try Data("catalog".utf8).write(to: retired.appendingPathComponent("catalog.sqlite"))
        try Data("transition".utf8).write(to: retired.appendingPathComponent("transition.json"))
        try Data("intent".utf8).write(to: retired.appendingPathComponent("discard-intent.json"))
        var oldDatabase: OpaquePointer?
        #expect(sqlite3_open(url.appendingPathComponent("intake.sqlite").path, &oldDatabase) == SQLITE_OK)
        #expect(sqlite3_exec(oldDatabase, "PRAGMA user_version = 0", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(oldDatabase)

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection)
        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("periods").path).isEmpty)
        #expect(store.getAllFinalizedPeriods().isEmpty)
        #expect(!store.storeIsFailed())
    }

    @Test func metadataOnlyPressurePersistsWithoutAgeEviction() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let age = BrowserCapacityAgeClock()
        let store = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: age.now, metadataPageLimit: 256)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.testConnectionGeneration(identityToken: "capacity-pairing")
        let now = store.getFloorMs()
        #expect(try fillMetadata(store, generation: generation, now: now) > 1)
        #expect(store.isQuotaFull())
        age.changeBoot()
        _ = try store.updateFloorMs(wallNowMs: now + UInt64(projection.policy.acceptedRetentionMs + 2_000))
        authority.poll(now: clock.now.addingTimeInterval(TimeInterval(projection.policy.acceptedRetentionMs + 2_000) / 1000))
        #expect(store.isQuotaFull())
        let refused = try authority.accept(bytes: snapshot(generation: generation, id: 1, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(refused["reason"] as? String == "resource_exhausted")
        #expect(!store.storeIsFailed())
    }
    @Test func metadataPressureSurvivesPairingReplacement() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), metadataPageLimit: 256)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generationA = try authority.testConnectionGeneration(identityToken: "metadata-full-a")
        #expect(try fillMetadata(store, generation: generationA, now: store.getFloorMs()) > 1)
        #expect(store.isQuotaFull())
        try authority.reconcileIdentity("metadata-full-b", mode: .replace)
        let generationB = try #require(store.getDestinationGeneration())
        authority.reopenAdmission()
        #expect(generationB != generationA)
        #expect(store.isQuotaFull())
        let result = try authority.accept(bytes: snapshot(generation: generationB, id: 1, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(result["reason"] as? String == "resource_exhausted")
        #expect(!store.storeIsFailed())
    }
    @Test func pressureStillFinalizesAndPublishesBoundedProofThenReclaims() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), metadataPageLimit: 512)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let generation = try authority.testConnectionGeneration(identityToken: "capacity-drain-pairing")
        var periods: [String] = []
        for id in 1...3 {
            let reply = try authority.accept(bytes: snapshot(generation: generation, id: id, now: store.getFloorMs()), direction: "extension_to_host")
            periods.append(try #require(reply["period_id"] as? String))
            if id < 3 { clock.advance(by: 301); authority.poll(now: clock.now) }
        }
        try fillMetadata(store, generation: generation, now: store.getFloorMs())
        let original = try Data(contentsOf: store.periodFileURL(for: periods[2]))
        clock.advance(by: 301)
        authority.poll(now: clock.now)
        #expect(store.getOpenPeriodId() == nil)
        #expect(store.getPeriod(periodId: periods[2])?.state == "finalized")
        #expect(try Data(contentsOf: store.periodFileURL(for: periods[2])) == original)
        #expect(!store.storeIsFailed())
        let replay = try authority.accept(bytes: snapshot(generation: generation, id: 3, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(replay["result"] as? String == "duplicate")

        let period = try #require(store.getPeriod(periodId: periods[0]))
        let huge = BrowserIngestAck(generation: generation, periodId: period.periodId,
            sha256: period.fileSha256 ?? "", size: UInt64(period.committedLength), metadata: nil,
            requestedDay: period.requestedDay ?? "", requestedSegment: period.requestedSegment ?? "",
            canonicalKey: String(repeating: "x", count: BrowserIngestAckStore.maximumBytes), status: .collision)
        #expect(throws: BrowserIntakeStoreError.localIO) { try store.publishDeliveryAck(huge) }
        #expect(try store.storedDeliveryBinding(periodId: period.periodId) == nil)
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: period.periodId).path))
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: store.periodFileURL(for: period.periodId).deletingLastPathComponent())
        #expect(!FileManager.default.fileExists(atPath: ackURL.path))
        #expect(throws: BrowserIntakeStoreError.localIO) { try BrowserIngestAckStore.write(huge, to: ackURL) }
        let unrepresentableSize = BrowserIngestAck(generation: generation, periodId: period.periodId,
            sha256: period.fileSha256 ?? "", size: UInt64.max, metadata: nil,
            requestedDay: period.requestedDay ?? "", requestedSegment: period.requestedSegment ?? "",
            canonicalKey: "120001_1", status: .collision)
        #expect(throws: BrowserIntakeStoreError.localIO) { try store.publishDeliveryAck(unrepresentableSize) }

        let proof = BrowserIngestAck(generation: generation, periodId: period.periodId,
            sha256: period.fileSha256 ?? "", size: UInt64(period.committedLength), metadata: nil,
            requestedDay: period.requestedDay ?? "", requestedSegment: period.requestedSegment ?? "",
            canonicalKey: "120001_1", status: .collision)
        store.ioInjector.setFailure { point in
            if point == .sync { throw BrowserIntakeStoreError.localIO }
        }
        #expect(throws: BrowserIntakeStoreError.localIO) { try store.publishDeliveryAck(proof) }
        store.ioInjector.setFailure(nil)
        #expect(try store.storedDeliveryBinding(periodId: period.periodId)?.ack == proof)
        #expect(!FileManager.default.fileExists(atPath: ackURL.path))
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: period.periodId).path))
        try store.publishDeliveryAck(proof)
        let reservedCeiling = store.projectedSpoolBytes()
        store.ioInjector.setFailure { point in
            if point == .sync {
                // This point has both the old receipt and its written temporary
                // replacement on disk. Measure actual lengths without entering
                // the already-held store lock again.
                let measured = try physicalBytes(url)
                #expect(measured <= reservedCeiling)
            }
        }
        try store.publishDeliveryAck(proof)
        store.ioInjector.setFailure(nil)
        #expect(!store.storeIsFailed())

        let transport = ScriptedBrowserTransport()
        transport.succeed = true
        let routeState = BrowserIntakeRouteState()
        routeState.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1:49323",
            identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let planner = BrowserUploadPlanner(store: store, gate: BrowserUploadGate(store: store), client: transport,
            serverURLProvider: { "http://127.0.0.1:49323" }, nowMs: { BrowserAgeStamp.wallMilliseconds(clock.now) }, routeState: routeState)
        await planner.planAndUpload()
        for id in periods {
            let binding = try #require(try store.storedDeliveryBinding(periodId: id))
            let proof = binding.ack
            #expect(store.getPeriod(periodId: id)?.ackDurable == true)
            #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: id).path))
            transport.dayListing = IngestProtocolV3.SegmentsDay(total: 1, items: [
                IngestProtocolV3.SegmentsItem(key: try #require(proof.canonicalKey),
                    files: [IngestProtocolV3.ReadFile(name: "browser_pages.jsonl", size: proof.size, sha256: proof.sha256, status: .present)],
                    originalKey: proof.requestedSegment)
            ])
            await planner.planAndUpload()
            #expect(store.getPeriod(periodId: id)?.state == "delivered")
            #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: id).path))
        }
        #expect(!store.storeIsFailed())
        #expect(try physicalBytes(url) <= store.projectedSpoolBytes())
        clock.advance(by: TimeInterval(projection.policy.acceptedRetentionMs + 2000) / 1000)
        authority.poll(now: clock.now)
        #expect(!store.isQuotaFull())
        #expect(store.getDestinationGeneration() == generation)
        let next = try authority.accept(bytes: snapshot(generation: generation, id: 4, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(next["result"] as? String == "accepted")
    }

    @Test func pendingDiscardHonorsExecutionReservationsRotationAndRetry() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let store = try BrowserIntakeStore(rootURL: url, projection: projection, ioInjector: injector)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.testConnectionGeneration(identityToken: "discard-reservations")
        func addFinalized(_ number: Int) throws -> String {
            let accepted = try authority.accept(bytes: snapshot(generation: generation, id: number, now: store.getFloorMs()), direction: "extension_to_host")
            let periodID = try #require(accepted["period_id"] as? String)
            try store.finalizePeriod(periodId: periodID, reason: "test", civilDate: clock.now, timeZone: TimeZone(secondsFromGMT: 0)!, openReplacement: false)
            return periodID
        }

        let reservedAfterCapture = try addFinalized(101)
        let captured = try #require({
            if case .present(let token) = store.pendingDiscardInventory() { return token }
            return nil
        }())
        let stagingA = store.stagingRootURL().appendingPathComponent("browser-upload-\(UUID().uuidString)")
        try store.registerStagingDirectory(stagingA, reservedBytes: 0, periodId: reservedAfterCapture)
        #expect(store.discardPendingPages(captured).durablyCompleted)
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: reservedAfterCapture).path))
        try store.releaseStagingDirectory(stagingA)
        #expect(store.discardPendingPages(captured).durablyCompleted)
        #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: reservedAfterCapture).path))

        let waiting = try addFinalized(102)
        let reservedAtCapture = try addFinalized(103)
        let stagingB = store.stagingRootURL().appendingPathComponent("browser-upload-\(UUID().uuidString)")
        try store.registerStagingDirectory(stagingB, reservedBytes: 0, periodId: reservedAtCapture)
        let capturedWithoutReserved = try #require({
            if case .present(let token) = store.pendingDiscardInventory() { return token }
            return nil
        }())
        try store.releaseStagingDirectory(stagingB)
        #expect(store.discardPendingPages(capturedWithoutReserved).durablyCompleted)
        #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: waiting).path))
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: reservedAtCapture).path))

        let rotates = try #require(try authority.accept(bytes: snapshot(generation: generation, id: 104, now: store.getFloorMs()), direction: "extension_to_host")["period_id"] as? String)
        let rotateToken = try #require({
            if case .present(let token) = store.pendingDiscardInventory() { return token }
            return nil
        }())
        clock.advance(by: 130)
        authority.poll(now: clock.now)
        let newOpen = try #require(store.getOpenPeriodId())
        #expect(newOpen != rotates)
        let newBytes = try authority.accept(bytes: snapshot(generation: generation, id: 105, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(newBytes["period_id"] as? String == newOpen)
        #expect(store.discardPendingPages(rotateToken).durablyCompleted)
        #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: rotates).path))
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: newOpen).path))

        if case .present(let remaining) = store.pendingDiscardInventory() {
            #expect(store.discardPendingPages(remaining).durablyCompleted)
        }

        let retryID = try addFinalized(106)
        let retryToken = try #require({
            if case .present(let token) = store.pendingDiscardInventory() { return token }
            return nil
        }())
        let writes = BrowserTestInjectedSize()
        injector.setFailure { point in
            guard point == .write else { return }
            writes.value += 1
            if writes.value == 2 { throw BrowserIntakeStoreError.localIO }
        }
        let failed = store.discardPendingPages(retryToken)
        injector.setFailure(nil)
        #expect(!failed.durablyCompleted)
        #expect(store.getPeriod(periodId: retryID)?.state == "finalized")
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: retryID).path))
        #expect(!store.storeIsFailed())
        #expect(store.discardPendingPages(retryToken).durablyCompleted)
        #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: retryID).path))
    }

    @Test func pendingDiscardInteractionKeepsConfirmCancelAndFailureStates() {
        let token = BrowserPendingDiscardToken(storeIncarnation: UUID(), openPeriodId: "open", finalizedPeriodIds: ["finalized"])
        var interaction = BrowserPendingDiscardInteraction<BrowserPendingDiscardToken>()
        interaction.openSettings()
        interaction.observe(.present(token))
        interaction.requestDiscard()
        #expect(interaction.confirmation == token)
        interaction.cancelDiscard()
        #expect(interaction.confirmation == nil)
        interaction.requestDiscard()
        interaction.observe(.present(BrowserPendingDiscardToken(
            storeIncarnation: token.storeIncarnation, openPeriodId: "rotated-open", finalizedPeriodIds: ["later-finalized"]
        )))
        let request = interaction.beginDiscard()
        #expect(request != nil)
        if let request {
            #expect(request.scope == token)
            interaction.finishDiscard(request, durablyCompleted: false, inventory: .present(token))
        }
        #expect(interaction.showsFailure)
        #expect(!interaction.showsDiscarded)
        #expect(!interaction.isDiscarding)
    }

    @Test func versionOneReopenKeepsPeriodIDsAndBytes() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let generation = try authority.testConnectionGeneration(identityToken: "reopen-pairing")
        let accepted = try authority.accept(bytes: snapshot(generation: generation, id: 1, now: store.getFloorMs()), direction: "extension_to_host")
        let periodID = try #require(accepted["period_id"] as? String)
        let payloadURL = store.periodFileURL(for: periodID)
        let bytes = try Data(contentsOf: payloadURL)
        let strayRetired = url.appendingPathComponent("retired", isDirectory: true)
        try FileManager.default.createDirectory(at: strayRetired, withIntermediateDirectories: true)
        let strayMarker = strayRetired.appendingPathComponent("preserve-me")
        try Data("stray".utf8).write(to: strayMarker)
        let unrelated = url.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let unrelatedMarker = unrelated.appendingPathComponent("preserve-me")
        try Data("also-stray".utf8).write(to: unrelatedMarker)
        let reopened = try BrowserIntakeStore(rootURL: url, projection: projection)
        #expect(reopened.getPeriod(periodId: periodID)?.periodId == periodID)
        #expect(try Data(contentsOf: reopened.periodFileURL(for: periodID)) == bytes)
        #expect(try Data(contentsOf: strayMarker) == Data("stray".utf8))
        #expect(try Data(contentsOf: unrelatedMarker) == Data("also-stray".utf8))
        var version: Int32 = -1
        var database: OpaquePointer?
        #expect(sqlite3_open(url.appendingPathComponent("intake.sqlite").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        version = sqlite3_column_int(statement, 0)
        #expect(version == 1)
    }
    @Test func actualSQLiteFullAutomaticallyRollsBackAdmissionAndKeepsStoreHealthy() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.testConnectionGeneration(identityToken: "actual-full-pairing")
        let anchor = try snapshot(generation: generation, id: 1, now: store.getFloorMs())
        let reply = try authority.accept(bytes: anchor, direction: "extension_to_host")
        let periodID = try #require(reply["period_id"] as? String)
        try store.setSQLitePageLimitForValidation(store.sqlitePagesForValidation().allocated)
        var encounteredFull = false
        for id in 2...200 {
            let ctx = String(repeating: "c", count: 240) + "-\(id)"
            let bytes = try snapshot(generation: generation, id: id, now: store.getFloorMs(), context: ctx)
            guard case .accept(.batch(let batch)) = BrowserPayloadDecoder.decode(bytes: bytes, direction: "extension_to_host", projection: projection) else {
                Issue.record("Capacity witness must use a valid decoded snapshot")
                return
            }
            let before = try Data(contentsOf: store.periodFileURL(for: periodID))
            do {
                _ = try store.commitBatch(batch: batch, nowMs: store.getFloorMs(), civilDate: clock.now, timeZone: TimeZone(secondsFromGMT: 0)!)
            } catch BrowserIntakeStoreError.resourceExhausted {
                encounteredFull = true
                #expect(try store.sqlitePagesForValidation().fullRollbacks > 0)
                #expect(try Data(contentsOf: store.periodFileURL(for: periodID)) == before)
                #expect(try store.lookupReceipt(generation: generation, inst: batch.inst, batchId: batch.batchId) == nil)
                #expect(try !store.isContextInitialized(periodId: periodID, inst: batch.inst, ctx: ctx))
                break
            }
        }
        #expect(encounteredFull)
        #expect(!store.storeIsFailed())
        #expect(try authority.accept(bytes: anchor, direction: "extension_to_host")["result"] as? String == "duplicate")
        try store.setSQLitePageLimitForValidation(4096)
        #expect(try authority.accept(bytes: snapshot(generation: generation, id: 999, now: store.getFloorMs()), direction: "extension_to_host")["result"] as? String == "accepted")
    }
    #endif
}

private final class ScriptedBrowserTransport: BrowserUploadTransport, @unchecked Sendable {
    var dayListing = IngestProtocolV3.SegmentsDay(total: 0, items: [])
    var onDayRead: (@Sendable () -> Void)?
    var onUpload: (@Sendable () -> Void)?
    var prepareCount = 0
    var succeed = false
    var uploadFailure: Error?
    private(set) var uploadedByteCount = 0
    private let lock = NSLock()

    func getSegmentsDay(serverURL: String, day: String, source: String?) async throws -> IngestProtocolV3.SegmentsDay {
        onDayRead?()
        return dayListing
    }

    func prepareUpload(
        serverURL: String,
        day: String,
        segment: String,
        mediaFiles: [URL],
        metadata: [String: IngestJSONValue]?,
        source: String?,
        boundary: String,
        bodyURL: URL,
        ioInjector: BrowserIntakeIOInjector
    ) throws -> PreparedIngestV3Upload {
        lock.lock()
        prepareCount += 1
        lock.unlock()
        return try IngestV3UploadRequestBuilder.build(
            baseURL: serverURL,
            day: day,
            segment: segment,
            selectedFiles: mediaFiles,
            meta: metadata,
            source: source,
            boundary: boundary,
            bodyURL: bodyURL,
            ioHooks: .browser(using: ioInjector)
        )
    }

    func uploadStaged(prepared: PreparedIngestV3Upload, lease: BrowserUploadLease) async -> UploadResult {
        guard lease.isValid(), let handle = try? FileHandle(forReadingFrom: prepared.bodyURL) else {
            return .failure(URLError(.cancelled))
        }
        defer { try? handle.close() }
        while true {
            guard lease.isValid() else { return .failure(URLError(.cancelled)) }
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            lock.withLock { uploadedByteCount += chunk.count }
        }
        onUpload?()
        guard succeed, let part = prepared.stagedParts.first else {
            return .failure(uploadFailure ?? UploadError.invalidRequest)
        }
        let response = IngestProtocolV3.UploadResponse(
            status: .collision,
            storedSegmentKey: "120001_1",
            segmentOriginal: prepared.submittedSegment,
            fileDescriptors: [IngestProtocolV3.UploadFileDescriptor(
                submitted: part.submitted,
                written: part.submitted,
                size: part.size,
                sha256: part.sha256,
                disposition: .written
            )],
            meta: prepared.metadata ?? [:]
        )
        return .success(UploadSuccessInfo(response: response))
    }

}

@Suite("BrowserIntakePeriodKey")
struct BrowserIntakePeriodKeyTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2023-11-14 23:55:00 UTC, the start of the day's last five-minute window.
    private let lastWindowStart = Date(timeIntervalSince1970: 1_700_006_100)

    private var vendorURL: URL {
        let currentFile = URL(fileURLWithPath: #filePath)
        let repoRoot = currentFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("vendor")
    }

    private struct Harness {
        let root: URL
        let store: BrowserIntakeStore
        let authority: BrowserIntakeAuthority
        let clock: BrowserTestClock
        let generation: String
    }

    private func makeHarness(openingAt start: Date) throws -> Harness {
        let root = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("solstone-intake-key-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        // A still age clock keeps the durable floor on the test's wall clock.
        let store = try BrowserIntakeStore(rootURL: root, projection: projection, ioInjector: BrowserIntakeIOInjector(),
            ageClock: { BrowserAgeStamp(bootID: "period-key-boot", elapsedMs: 0) })
        let clock = BrowserTestClock(start)
        let authority = BrowserIntakeAuthority(store: store, projection: projection,
            monotonicClock: ManualMonotonicClock(), wallClock: { clock.now }, timeZone: utc)
        let generation = try authority.testConnectionGeneration(identityToken: "period-key-token")
        return Harness(root: root, store: store, authority: authority, clock: clock, generation: generation)
    }

    private func acceptBatch(_ harness: Harness, ctx: String) throws -> String {
        let nowMs = UInt64(harness.clock.now.timeIntervalSince1970 * 1000)
        let batch: [String: Any] = ["type": "batch", "destination_generation": harness.generation,
            "inst": "period-key-inst", "batch_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "queued_at_ms": nowMs,
            "records": [["t": "segment_start", "ts": nowMs, "ctx": ctx, "blocks": [["id": "b", "text": "period key"]]]]]
        let reply = try harness.authority.accept(bytes: JSONSerialization.data(withJSONObject: batch), direction: "extension_to_host")
        return try #require(reply["period_id"] as? String)
    }

    private func sealedKey(_ store: BrowserIntakeStore, _ periodId: String) throws -> (day: String, start: String, len: Int) {
        let period = try #require(store.getPeriod(periodId: periodId))
        #expect(period.state == "finalized")
        let parts = try #require(period.requestedSegment).split(separator: "_")
        #expect(parts.count == 2)
        return (try #require(period.requestedDay), String(parts[0]), try #require(Int(parts[1])))
    }

    @Test(arguments: [(TimeInterval(0), "235500", 300), (TimeInterval(150), "235730", 150)])
    func periodSealedHoursLateKeepsItsStartAndEndsAtItsWindowClose(
        startOffset: TimeInterval, expectedStart: String, expectedLen: Int
    ) throws {
        let harness = try makeHarness(openingAt: lastWindowStart.addingTimeInterval(startOffset))
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.clock.advance(by: 20)
        let pid = try acceptBatch(harness, ctx: "before-sleep")

        // The machine sleeps through the boundary and wakes the next morning.
        harness.clock.now = lastWindowStart.addingTimeInterval(8 * 3600 + 5 * 60)
        harness.authority.poll(now: harness.clock.now)

        let key = try sealedKey(harness.store, pid)
        #expect(key.day == "20231114")
        #expect(key.start == expectedStart)
        #expect(key.len == expectedLen)
        #expect(key.len <= 300)
    }

    @Test func batchArrivingAfterSleepOpensANewPeriodInsteadOfJoiningTheStaleOne() throws {
        let harness = try makeHarness(openingAt: lastWindowStart)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.clock.advance(by: 60)
        let stale = try acceptBatch(harness, ctx: "before-sleep")

        // A batch reaches the host on wake before the boundary timer has run.
        harness.clock.now = lastWindowStart.addingTimeInterval(8 * 3600 + 5 * 60)
        let fresh = try acceptBatch(harness, ctx: "after-wake")
        #expect(fresh != stale)
        let staleKey = try sealedKey(harness.store, stale)
        #expect(staleKey.day == "20231114")
        #expect(staleKey.start == "235500")
        #expect(staleKey.len == 300)

        harness.clock.advance(by: 45)
        try harness.store.finalizePeriod(periodId: fresh, reason: "seal", civilDate: harness.clock.now, timeZone: utc)
        let freshKey = try sealedKey(harness.store, fresh)
        #expect(freshKey.day == "20231115")
        #expect(freshKey.start == "080000")
        #expect(freshKey.len == 45)
    }

    @Test func promptSealsKeyTheStartWithTheRealLength() throws {
        let harness = try makeHarness(openingAt: lastWindowStart)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let first = try acceptBatch(harness, ctx: "mid-window")
        harness.clock.advance(by: 130)
        try harness.store.finalizePeriod(periodId: first, reason: "seal", civilDate: harness.clock.now, timeZone: utc)
        let midKey = try sealedKey(harness.store, first)
        #expect(midKey.day == "20231114")
        #expect(midKey.start == "235500")
        #expect(midKey.len == 130)

        // The replacement runs to the boundary and rotates on time.
        let second = try acceptBatch(harness, ctx: "to-boundary")
        harness.clock.now = lastWindowStart.addingTimeInterval(300.4)
        harness.authority.poll(now: harness.clock.now)
        let boundaryKey = try sealedKey(harness.store, second)
        #expect(boundaryKey.day == "20231114")
        #expect(boundaryKey.start == "235710")
        #expect(boundaryKey.len == 170)
    }

    @Test func subSecondPeriodHasLengthOne() throws {
        let harness = try makeHarness(openingAt: lastWindowStart)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let pid = try acceptBatch(harness, ctx: "brief")
        harness.clock.advance(by: 0.4)
        try harness.store.finalizePeriod(periodId: pid, reason: "seal", civilDate: harness.clock.now, timeZone: utc)
        let key = try sealedKey(harness.store, pid)
        #expect(key.start == "235500")
        #expect(key.len == 1)
    }

    @Test func durationClampBoundsToOneThroughCeiling() {
        #expect(clampedSegmentDurationSeconds(0.4, ceiling: 300) == 1)
        #expect(clampedSegmentDurationSeconds(-5, ceiling: 300) == 1)
        #expect(clampedSegmentDurationSeconds(42.9, ceiling: 300) == 42)
        #expect(clampedSegmentDurationSeconds(29_100, ceiling: 300) == 300)
        #expect(clampedSegmentDurationSeconds(.infinity, ceiling: 300) == 300)
        #expect(clampedSegmentDurationSeconds(.nan, ceiling: 300) == 300)
    }
}

#endif
