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

        let gen = try authority.publishEpoch(identityToken: "test-token-1")
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

        let gen = try authority.publishEpoch(identityToken: "test-token-1")
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
            gen = try authority1.publishEpoch(identityToken: "test-token-1")

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

        let gen = try authority.publishEpoch(identityToken: "test-token-1")

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
        // that rolled-back instant is older than the outbox window.
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

        let oldTombstoneBatchId = "11110000111100001111000011110000"
        let oldQueuedAt: UInt64 = 1690000000000
        let oldBatch: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": oldTombstoneBatchId,
            "queued_at_ms": oldQueuedAt,
            "records": [["t": "segment_start", "ts": oldQueuedAt, "ctx": "ctx-old", "blocks": [["id": "bo", "text": "old"]]]]
        ]
        let authorityReopened = BrowserIntakeAuthority(
            store: storeReopened,
            projection: projection,
            wallClock: { clock.now },
            timeZone: TimeZone(identifier: "UTC")!
        )
        let repOld1 = try authorityReopened.accept(bytes: try JSONSerialization.data(withJSONObject: oldBatch), direction: "extension_to_host")
        #expect(repOld1["result"] as? String == "rejected")
        #expect(repOld1["reason"] as? String == "expired_unaccepted")
        authorityReopened.poll(now: clock.now)
        #expect(try storeReopened.lookupReceipt(generation: gen, inst: "inst-1", batchId: oldTombstoneBatchId) != nil)
        // The durable floor is still ahead of the rolled-back wall clock.
        // Retention is measured from accepted_at_ms against that floor.
        let retentionTarget = storeReopened.getFloorMs() + projection.policy.acceptedRetentionMs + 1000
        let wallMs = UInt64(clock.now.timeIntervalSince1970 * 1000.0)
        if retentionTarget > wallMs {
            clock.advance(by: TimeInterval(retentionTarget - wallMs) / 1000.0)
        }
        authorityReopened.poll(now: clock.now)
        #expect(try storeReopened.lookupReceipt(generation: gen, inst: "inst-1", batchId: oldTombstoneBatchId) == nil)
        clock.advance(by: -100000)
        let repOld2 = try authorityReopened.accept(bytes: try JSONSerialization.data(withJSONObject: oldBatch), direction: "extension_to_host")
        #expect(repOld2["result"] as? String == "rejected")
        #expect(repOld2["reason"] as? String == "expired_unaccepted")
    }

    @Test func test5_generationReopenAndRetireIfTokenChangedNil() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))

        var gen: String = ""
        var pid1: String = ""
        do {
            let store1 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
            let authority1 = BrowserIntakeAuthority(store: store1, projection: projection, wallClock: { clock.now })
            gen = try authority1.publishEpoch(identityToken: "token-1")
            let snap: [String: Any] = [
                "type": "batch",
                "destination_generation": gen,
                "inst": "inst-1",
                "batch_id": "77777777777777777777777777777777",
                "queued_at_ms": 1700000000000 as UInt64,
                "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "t"]]]]
            ]
            let reply = try authority1.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
            #expect(reply["result"] as? String == "accepted")
            pid1 = try #require(reply["period_id"] as? String)
        }

        let store2 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority2 = BrowserIntakeAuthority(store: store2, projection: projection, wallClock: { clock.now })
        let sameGen = try authority2.publishEpoch(identityToken: "token-1")
        #expect(sameGen == gen)
        try authority2.retireIfTokenChanged(newToken: "token-1")
        #expect(store2.getActiveGeneration() == gen)

        let activeFileURL = store2.periodFileURL(for: pid1)
        let originalBytes = try Data(contentsOf: activeFileURL)
        try authority2.retireIfTokenChanged(newToken: "token-2")
        let statDiff = authority2.status()
        #expect(statDiff["capture"] as? String == "unavailable")
        #expect(statDiff["destination_generation"] is NSNull)
        #expect(statDiff["period_id"] is NSNull)
        #expect(statDiff["delivery"] as? String == "unknown")

        let retiredFileURL = tempRoot.appendingPathComponent("retired/periods/\(pid1)/browser_pages.jsonl")
        #expect(!FileManager.default.fileExists(atPath: activeFileURL.path))
        #expect(try Data(contentsOf: retiredFileURL) == originalBytes)
        try authority2.retireIfTokenChanged(newToken: nil)
        let statNil = authority2.status()
        #expect(statNil["capture"] as? String == "not_paired")
        #expect(statNil["destination_generation"] is NSNull)
        #expect(statNil["period_id"] is NSNull)
        #expect(try Data(contentsOf: retiredFileURL) == originalBytes)

        let store3 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority3 = BrowserIntakeAuthority(store: store3, projection: projection, wallClock: { clock.now })
        #expect(store3.getActiveGeneration() == nil)
        let reopened = authority3.status()
        #expect(reopened["capture"] as? String == "unavailable")
        #expect(reopened["delivery"] as? String == "unknown")
        #expect(reopened["destination_generation"] is NSNull)
        #expect(reopened["period_id"] is NSNull)
        #expect(try Data(contentsOf: retiredFileURL) == originalBytes)

        let staleBatch: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "88888888888888888888888888888888",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "t"]]]]
        ]
        let replyStale = try authority3.accept(bytes: try JSONSerialization.data(withJSONObject: staleBatch), direction: "extension_to_host")
        #expect(replyStale["result"] as? String == "rejected")
        #expect(replyStale["reason"] as? String == "stale_generation")
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

    @Test func test1_generationRaceZeroBytesAndFileRetained() throws {
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
        let gate = BrowserUploadGate(store: store)
        let gen1 = try authority.publishEpoch(identityToken: "token-1")

        // Accept a batch
        let snap: [String: Any] = [
            "type": "batch",
            "destination_generation": gen1,
            "inst": "inst-1",
            "batch_id": "11111111111111111111111111111111",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b1", "text": "race test payload"]]]]
        ]
        let reply = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
        let pid1 = reply["period_id"] as! String

        // Finalize period 1
        try store.finalizePeriod(periodId: pid1, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        // Acquire current permit under gen1
        let permit = try #require(gate.currentPermit())
        #expect(gate.isPermitActive(permit))

        let p1FileURL = store.periodFileURL(for: pid1)
        let originalBytes = try Data(contentsOf: p1FileURL)
        #expect(!originalBytes.isEmpty)

        // Race: pairing replaced / retired via retireIfTokenChanged
        gate.invalidateCurrentLease()
        try authority.retireIfTokenChanged(newToken: "token-2")

        #expect(!gate.isPermitActive(permit))

        // Attempt reading body through gate returns empty Data (zero bytes)
        let readData = gate.readBodyData(fileURL: p1FileURL, permit: permit)
        #expect(readData.isEmpty)

        // Retired custody remains byte-exact outside active period lookup.
        let retiredFileURL = tempRoot.appendingPathComponent("retired/periods/\(pid1)/browser_pages.jsonl")
        #expect(!FileManager.default.fileExists(atPath: p1FileURL.path))
        let remainingBytes = try Data(contentsOf: retiredFileURL)
        #expect(remainingBytes == originalBytes)

        // Status is unavailable
        let stat = authority.status()
        #expect(stat["capture"] as? String == "unavailable")
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
        let gen = try authority.publishEpoch(identityToken: "tok")
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

        let gen = try authority.publishEpoch(identityToken: "tok-3")

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

        let gen = try authority.publishEpoch(identityToken: "tok-4")
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
        let gen = try authority.publishEpoch(identityToken: token)
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
        #expect(try again.publishEpoch(identityToken: token) == gen)
        try again.retireIfTokenChanged(newToken: "instance-A\u{0}other-key")
        #expect(reopened.getActiveGeneration() == nil)
    }

    @Test func test8_fileSyncContinuationRefinalizeAndMissingPayload() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let gen = try authority.publishEpoch(identityToken: "token-1")
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
        let gen = try authority.publishEpoch(identityToken: "token-1")
        let delta: [String: Any] = [
            "type": "batch", "destination_generation": gen, "inst": "inst-1",
            "batch_id": "dddddddddddddddddddddddddddddddd",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "delta", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "op": "add", "block": ["id": "b", "text": "t"]]]
        ]
        let deltaBytes = try JSONSerialization.data(withJSONObject: delta)
        let first = try authority.accept(bytes: deltaBytes, direction: "extension_to_host")
        #expect(first["reason"] as? String == "snapshot_required")
        mono.advance(milliseconds: Int(projection.policy.outboxAgeMs))
        let expired = try authority.accept(bytes: deltaBytes, direction: "extension_to_host")
        #expect(expired["reason"] as? String == "expired_unaccepted")

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
    func emptyPeriodHistoryReclaimsAfterRetention(directoryMissing: Bool) throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let nowMs: UInt64 = 1700000000000
        _ = try store.publishEpoch(identityToken: "empty-pairing", nowMs: nowMs)
        let old = try #require(store.getOpenPeriodId())
        let directory = store.periodFileURL(for: old).deletingLastPathComponent()
        try store.finalizePeriod(periodId: old, reason: "idle", civilDate: Date(timeIntervalSince1970: Double(nowMs) / 1000), timeZone: TimeZone(secondsFromGMT: 0)!)
        let current = try #require(store.getOpenPeriodId())
        if directoryMissing { try FileManager.default.removeItem(at: directory) }
        store.garbageCollectExpiredTombstones(nowMs: nowMs + projection.policy.acceptedRetentionMs + 1)
        #expect(store.getPeriod(periodId: old) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.getPeriod(periodId: current)?.state == "open")
        #expect(!store.storeIsFailed())
        let reopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(!reopened.storeIsFailed())
        #expect(reopened.getActiveGeneration() == store.getActiveGeneration())
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
        let generation = try authority.publishEpoch(identityToken: "staging-pairing")
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
        _ = try spool.publishEpoch(identityToken: "session-pairing", nowMs: 1700000000000)
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
        let gen = try authority.publishEpoch(identityToken: "token-1")
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
            _ = try candidate.publishEpoch(identityToken: "token-1", nowMs: 1700000000000)
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
        let generation = try authority.publishEpoch(identityToken: "contract-address")
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

    @Test func test10_plannerRaceProofAndSegmentKey() async throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
        let gate = BrowserUploadGate(store: store)
        let gen = try authority.publishEpoch(identityToken: "token-1")
        let snap: [String: Any] = [
            "type": "batch", "destination_generation": gen, "inst": "inst-1",
            "batch_id": "12121212121212121212121212121212",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-1", "blocks": [["id": "b", "text": "planner"]]]]
        ]
        let reply = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: snap), direction: "extension_to_host")
        let pid = try #require(reply["period_id"] as? String)
        try store.finalizePeriod(periodId: pid, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let period = try #require(store.getPeriod(periodId: pid))
        let segment = try #require(period.requestedSegment)
        let day = try #require(period.requestedDay)
        let fileURL = store.periodFileURL(for: pid)
        let original = try Data(contentsOf: fileURL)

        let transport = ScriptedBrowserTransport()
        let routeState = BrowserIntakeRouteState()
        _ = routeState.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: try #require(store.getActiveIdentityToken()), pairingGeneration: 1,
            transportIncarnation: 1, credentialIsCurrent: { true }))
        let planner = BrowserUploadPlanner(store: store, gate: gate, client: transport, serverURLProvider: { "http://127.0.0.1" }, routeState: routeState)
        // Reconciliation reads the day listing only after a validated upload
        // binding exists. Retire during that read, before any cleanup can occur.
        transport.succeed = true
        await planner.planAndUpload()
        #expect(transport.prepareCount == 1)
        #expect(try store.storedDeliveryBinding(periodId: pid) != nil)
        transport.onDayRead = {
            try? authority.retireIfTokenChanged(newToken: "token-2")
        }
        await planner.planAndUpload()
        #expect(transport.prepareCount == 1)
        let retiredFileURL = tempRoot.appendingPathComponent("retired/periods/\(pid)/browser_pages.jsonl")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: retiredFileURL) == original)
        #expect(authority.status()["capture"] as? String == "unavailable")

        _ = try authority.publishEpoch(identityToken: "token-2")
        gate.resumeReaders()
        authority.reopenAdmission()
        transport.onDayRead = nil
        transport.succeed = true
        let fresh = try authority.publishEpoch(identityToken: "token-fresh")
        routeState.update(BrowserIntakeRouteCapability(serverURL: "http://127.0.0.1",
            identityDigest: BrowserIntakeStore.identityDigest(of: "token-fresh"), pairingGeneration: 2,
            transportIncarnation: 2, credentialIsCurrent: { true }))
        let freshSnap: [String: Any] = [
            "type": "batch", "destination_generation": fresh, "inst": "inst-1",
            "batch_id": "34343434343434343434343434343434",
            "queued_at_ms": UInt64(clock.now.timeIntervalSince1970 * 1000),
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-2", "blocks": [["id": "b", "text": "fresh"]]]]
        ]
        let freshReply = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: freshSnap), direction: "extension_to_host")
        let freshPid = try #require(freshReply["period_id"] as? String)
        try store.finalizePeriod(periodId: freshPid, reason: "seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
        let freshPeriod = try #require(store.getPeriod(periodId: freshPid))
        await planner.planAndUpload()
        #expect(store.getPeriod(periodId: freshPid)?.state == "finalized")
        #expect(store.getPeriod(periodId: freshPid)?.canonicalKey == "120001_1")
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: freshPid).path))
        let ack = try #require(try BrowserIngestAckStore.read(from: BrowserIngestAckStore.ackURL(periodDirectory: store.periodFileURL(for: freshPid).deletingLastPathComponent())))
        transport.dayListing = IngestProtocolV3.SegmentsDay(total: 1, items: [
            IngestProtocolV3.SegmentsItem(
                key: "other-key",
                files: [IngestProtocolV3.ReadFile(name: "browser_pages.jsonl", size: ack.size, sha256: ack.sha256, status: .present)],
                originalKey: freshPeriod.requestedSegment
            )
        ])
        await planner.planAndUpload()
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: freshPid).path))
        transport.dayListing = IngestProtocolV3.SegmentsDay(total: 1, items: [
            IngestProtocolV3.SegmentsItem(
                key: try #require(freshPeriod.requestedSegment),
                files: [IngestProtocolV3.ReadFile(name: "browser_pages.jsonl", size: ack.size, sha256: ack.sha256, status: .processed)]
            )
        ])
        await planner.planAndUpload()
        #expect(FileManager.default.fileExists(atPath: store.periodFileURL(for: freshPid).path))
        // Only the returned canonical collision key can prove delivery.
        transport.dayListing = IngestProtocolV3.SegmentsDay(total: 1, items: [
            IngestProtocolV3.SegmentsItem(
                key: try #require(ack.canonicalKey),
                files: [IngestProtocolV3.ReadFile(name: "browser_pages.jsonl", size: ack.size, sha256: ack.sha256, status: .present)],
                originalKey: freshPeriod.requestedSegment
            )
        ])
        await planner.planAndUpload()
        #expect(!FileManager.default.fileExists(atPath: store.periodFileURL(for: freshPid).path))
        #expect(store.getPeriod(periodId: freshPid)?.state == "delivered")
        _ = (segment, day)
    }
}

private final class BrowserCapacityAgeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stamp = BrowserAgeStamp(bootID: "capacity-boot-1", elapsedMs: 0)
    func now() -> BrowserAgeStamp? { lock.withLock { stamp } }
    func changeBoot() { lock.withLock { stamp = BrowserAgeStamp(bootID: "capacity-boot-2", elapsedMs: 100) } }
}

@Suite("BrowserMetadataCapacity", .serialized)
struct BrowserMetadataCapacityTests {
    private var vendorURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("vendor")
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/var/tmp/solstone-capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func snapshot(generation: String, id: Int, now: UInt64, context: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "batch", "destination_generation": generation,
            "inst": String(repeating: "i", count: 128), "batch_id": String(format: "%032x", id),
            "queued_at_ms": now,
            "records": [["t": "segment_start", "ts": now, "ctx": context ?? "ctx-\(id)",
                         "blocks": [["id": "b", "text": "synthetic-capacity-marker-\(id)"]]]]
        ])
    }

    @discardableResult
    private func fillMetadata(_ store: BrowserIntakeStore, generation: String, now: UInt64) throws -> Int {
        for index in 1...10_000 {
            let id = String(format: "%032x", index + 100_000)
            do {
                try store.recordBatchSeen(generation: generation, inst: String(repeating: "m", count: 128),
                                          batchId: id, queuedAtMs: now, initialAgeMs: 0)
                try store.commitTombstone(generation: generation, inst: String(repeating: "m", count: 128),
                                          batchId: id, reason: "expired_unaccepted", receiptClass: "terminal", queuedAtMs: now)
            } catch BrowserIntakeStoreError.resourceExhausted {
                #expect(store.isQuotaFull())
                #expect(!store.storeIsFailed())
                return index
            }
        }
        Issue.record("Metadata traffic did not encounter the configured production page budget")
        return 10_000
    }

    private func physicalBytes(_ root: URL) throws -> Int {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
        }
        return bytes
    }

    @Test func wholeSnapshotAtProjectedCeilingCommitsAndNextByteRefuses() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let injector = BrowserIntakeIOInjector()
        let store = try BrowserIntakeStore(rootURL: url, projection: projection, ioInjector: injector)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.publishEpoch(identityToken: "exact-capacity-pairing")
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
        let generation = try authority!.publishEpoch(identityToken: "wal-migration-pairing")
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

    @Test func metadataOnlyPressurePersistsClockAndReclaimsWithoutPairing() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let age = BrowserCapacityAgeClock()
        let store = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: age.now, metadataPageLimit: 256)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.publishEpoch(identityToken: "capacity-pairing")
        let now = store.getFloorMs()
        #expect(try fillMetadata(store, generation: generation, now: now) > 1)
        #expect(store.getEarliestHeldMs() == 0)
        let state = authority.status()
        #expect((state["custody"] as? [String: Bool])?["full"] == true)
        #expect(state["capture"] as? String == "intake_off")
        #expect(try physicalBytes(url) < 256 * 4096 * 3 + 64 * 1024)
        #expect(store.projectedSpoolBytes() < projection.policy.spoolBytes)
        #expect(store.getActiveGeneration() == generation)
        age.changeBoot()
        #expect(try store.updateFloorMs(wallNowMs: now + 1000) >= now + 1000)
        let firstID = String(format: "%032x", 100_001)
        #expect(try store.getBatchAge(generation: generation, inst: String(repeating: "m", count: 128), batchId: firstID)?.established == false)
        clock.advance(by: TimeInterval(projection.policy.acceptedRetentionMs + 2000) / 1000)
        authority.poll(now: clock.now)
        #expect(!store.isQuotaFull())
        #expect(store.getActiveGeneration() == generation)
        let accepted = try authority.accept(bytes: snapshot(generation: generation, id: 1, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(accepted["result"] as? String == "accepted")
        #expect(!store.storeIsFailed())
    }

    @Test func metadataOnlyRetirementReleasesSuccessorAdmission() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), metadataPageLimit: 256)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generationA = try authority.publishEpoch(identityToken: "metadata-full-a")
        #expect(try fillMetadata(store, generation: generationA, now: store.getFloorMs()) > 1)
        #expect(store.isQuotaFull())
        #expect(store.getEarliestHeldMs() == 0)
        try authority.reconcileIdentity("metadata-full-b", mode: .replace)
        let generationB = try authority.publishEpoch(identityToken: "metadata-full-b")
        authority.reopenAdmission()
        #expect(generationB != generationA)
        #expect(!store.isQuotaFull())
        #expect(store.retiredCustodyInventory() == .empty)
        let result = try authority.accept(bytes: snapshot(generation: generationB, id: 1, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(result["result"] as? String == "accepted")
        let period = try #require(result["period_id"] as? String)
        try store.finalizePeriod(periodId: period, reason: "metadata-successor", civilDate: clock.now,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(store.getPeriod(periodId: period)?.state == "finalized")
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
        let generation = try authority.publishEpoch(identityToken: "capacity-drain-pairing")
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
        #expect(throws: BrowserIntakeStoreError.staleGeneration) { try store.publishDeliveryAck(unrepresentableSize) }

        let proof = BrowserIngestAck(generation: generation, periodId: period.periodId,
            sha256: period.fileSha256 ?? "", size: UInt64(period.committedLength), metadata: nil,
            requestedDay: period.requestedDay ?? "", requestedSegment: period.requestedSegment ?? "",
            canonicalKey: "120001_1", status: .collision)
        store.ioInjector.setFailure { point in
            if point == .sync { throw BrowserIntakeStoreError.localIO }
        }
        #expect(throws: BrowserIntakeStoreError.localIO) { try store.publishDeliveryAck(proof) }
        store.ioInjector.setFailure(nil)
        #expect(try store.storedDeliveryBinding(periodId: period.periodId) == proof)
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
            let proof = try #require(try store.storedDeliveryBinding(periodId: id))
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
        #expect(store.getActiveGeneration() == generation)
        let next = try authority.accept(bytes: snapshot(generation: generation, id: 4, now: store.getFloorMs()), direction: "extension_to_host")
        #expect(next["result"] as? String == "accepted")
    }

    @Test func pressureRetirementSurvivesReconstructionAndPreservesOldBytes() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let age = BrowserCapacityAgeClock()
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        var store: BrowserIntakeStore? = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: age.now, metadataPageLimit: 256)
        var authority: BrowserIntakeAuthority? = BrowserIntakeAuthority(store: store!, projection: projection, wallClock: { clock.now })
        let generation = try authority!.publishEpoch(identityToken: "old-capacity-identity")
        let bytes = try snapshot(generation: generation, id: 1, now: store!.getFloorMs())
        let reply = try authority!.accept(bytes: bytes, direction: "extension_to_host")
        let periodID = try #require(reply["period_id"] as? String)
        let payloadURL = store!.periodFileURL(for: periodID)
        let original = try Data(contentsOf: payloadURL)
        try fillMetadata(store!, generation: generation, now: store!.getFloorMs())
        age.changeBoot()
        try authority!.reconcileIdentity(nil, mode: .replace)
        let floor = store!.getFloorMs()
        #expect(store!.getActiveGeneration() == nil)
        authority = nil; store = nil
        let reopened = try BrowserIntakeStore(rootURL: url, projection: projection,
            ioInjector: BrowserIntakeIOInjector(), ageClock: age.now, metadataPageLimit: 256)
        #expect(reopened.getFloorMs() == floor)
        #expect(reopened.getActiveGeneration() == nil)
        #expect(reopened.getPeriod(periodId: periodID) == nil)
        let retiredURL = url.appendingPathComponent("retired/periods/\(periodID)/browser_pages.jsonl")
        #expect(!reopened.getAllFinalizedPeriods().contains { $0.periodId == periodID })
        #expect(try Data(contentsOf: retiredURL) == original)
        #expect(try reopened.lookupReceipt(generation: generation, inst: String(repeating: "i", count: 128), batchId: String(format: "%032x", 1))?.result == "accepted")
        let newAuthority = BrowserIntakeAuthority(store: reopened, projection: projection, wallClock: { clock.now })
        try newAuthority.reconcileIdentity("replacement-capacity-identity", mode: .reload)
        #expect(reopened.getActiveGeneration() == nil)
        #expect(BrowserUploadGate(store: reopened).currentPermit() == nil)
        #expect(!reopened.storeIsFailed())
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    @Test func actualSQLiteFullAutomaticallyRollsBackAdmissionAndKeepsStoreHealthy() throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: url, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        let generation = try authority.publishEpoch(identityToken: "actual-full-pairing")
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

#endif
