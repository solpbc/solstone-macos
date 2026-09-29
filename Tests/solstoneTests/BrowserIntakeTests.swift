// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Foundation
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

@Suite("BrowserIntakeAdmission")
struct BrowserIntakeAdmissionTests {
    private var vendorURL: URL {
        let currentFile = URL(fileURLWithPath: #filePath)
        let repoRoot = currentFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("vendor")
    }

    private func createTempRoot() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("solstone-intake-test-\(UUID().uuidString)")
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
        #expect(store.lookupReceipt(generation: gen, inst: "inst-A", batchId: sharedBatchId) == nil)
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

        // Batch 1: 26 MB snapshot payload (<= 33554432 extensionToHost cap)
        let pad26MB = String(repeating: "1", count: 26 * 1024 * 1024)
        let batch1: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "11111111111111111111111111111111",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [
                [
                    "t": "segment_start",
                    "ts": 1700000000000 as UInt64,
                    "ctx": "ctx-1",
                    "blocks": [["id": "b1", "text": pad26MB]]
                ]
            ]
        ]
        let reply1 = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: batch1), direction: "extension_to_host")
        #expect(reply1["result"] as? String == "accepted")
        let pid1 = reply1["period_id"] as! String

        // Batch 2: 26 MB delta batch with marker "batch2_marker". Total (26 + 26 = 52 MB) > 50331648
        let pad26MB_2 = String(repeating: "2", count: 26 * 1024 * 1024)
        let batch2: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "22222222222222222222222222222222",
            "queued_at_ms": 1700000001000 as UInt64,
            "records": [
                [
                    "t": "delta",
                    "ts": 1700000001000 as UInt64,
                    "ctx": "ctx-1",
                    "op": "add",
                    "block": ["id": "batch2_marker", "text": pad26MB_2]
                ]
            ]
        ]
        let reply2 = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: batch2), direction: "extension_to_host")
        #expect(reply2["result"] as? String == "accepted")
        let pid2 = reply2["period_id"] as! String

        #expect(pid1 != pid2)

        // Verify period 1 file does NOT contain batch2_marker
        let file1URL = store.periodFileURL(for: pid1)
        let file1Data = try Data(contentsOf: file1URL)
        let file1String = String(data: file1Data, encoding: .utf8) ?? ""
        #expect(!file1String.contains("batch2_marker"))

        // Verify period 2 file contains entire record line with batch2_marker
        let file2URL = store.periodFileURL(for: pid2)
        let file2Data = try Data(contentsOf: file2URL)
        let file2String = String(data: file2Data, encoding: .utf8) ?? ""
        #expect(file2String.contains("batch2_marker"))

        // Verify no extra empty open periods exist (only pid2 is open)
        #expect(store.getOpenPeriodId() == pid2)
        let storedP1 = store.getPeriod(periodId: pid1)
        #expect(storedP1?.state == "finalized")
        let storedP2 = store.getPeriod(periodId: pid2)
        #expect(storedP2?.state == "open")
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
        #expect(store3.lookupReceipt(generation: gen, inst: "inst-1", batchId: "55555555555555555555555555555555") == nil)
        let p2LenAfter = try Data(contentsOf: p2URL).count
        #expect(p2LenAfter == p2LenBefore)
    }

    @Test func test4_spoolQuotaCustodyAndGcAndWallClockRollback() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        #expect(projection.policy.spoolBytes == 536870912)

        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
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

        // 3. Fill with large filler records to approach spoolBytes (536870912)
        // Delivery reserve doubles payload: 2 * payload + dedup + sqliteSize ~ 536870912 -> ~256 MB payload fills it
        var fillerPids: [String] = []
        var fillerIndex = 2
        while true {
            // Check remaining space before admitting another ~25 MB batch
            let nextBatchPayloadBytes = 25 * 1024 * 1024
            let nextDedup = 128
            if store.projectedSpoolBytes(additionalPayloadBytes: nextBatchPayloadBytes, additionalDedupBytes: nextDedup) > projection.policy.spoolBytes {
                break
            }
            let pad25M = String(repeating: "f", count: nextBatchPayloadBytes - 500)
            let bId = String(format: "%032d", fillerIndex)
            let bPayload: [String: Any] = [
                "type": "batch",
                "destination_generation": gen,
                "inst": "inst-1",
                "batch_id": bId,
                "queued_at_ms": 1700000000000 as UInt64,
                "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-filler-\(fillerIndex)", "blocks": [["id": "bf", "text": pad25M]]]]
            ]
            let rep = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: bPayload), direction: "extension_to_host")
            #expect(rep["result"] as? String == "accepted")
            let fPid = rep["period_id"] as! String
            if !fillerPids.contains(fPid) { fillerPids.append(fPid) }
            try store.finalizePeriod(periodId: fPid, reason: "filler_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
            fillerIndex += 1
        }

        // Fill remaining space until store.isQuotaFull() is true
        while !store.isQuotaFull() {
            _ = store.updateFloorMs(wallNowMs: 1700000000000)
            let curProj = store.projectedSpoolBytes(additionalPayloadBytes: 0, additionalDedupBytes: 0)
            let fitBatchId = String(format: "e%031x", fillerIndex)
            let fitDedup = BrowserIntakeStore.receiptDedupBytes(generation: gen, inst: "inst-1", batchId: fitBatchId, periodId: store.getOpenPeriodId(), reason: nil, receiptClass: nil)
            let fitSeenDedup = BrowserIntakeStore.batchSeenDedupBytes(generation: gen, inst: "inst-1", batchId: fitBatchId)
            let headroom = projection.policy.spoolBytes - curProj - fitDedup - fitSeenDedup
            let newRecBytes = max(1, headroom / 2)

            let basePrefix = "{\"t\":\"segment_start\",\"ts\":1700000000000,\"ctx\":\"ctx-fit-\(fillerIndex)\",\"blocks\":[{\"id\":\"be\",\"text\":\""
            let baseSuffix = "\"}]}"
            let padLen = max(0, newRecBytes - basePrefix.utf8.count - baseSuffix.utf8.count - 1)
            let pad = String(repeating: "z", count: padLen)
            let recJson = basePrefix + pad + baseSuffix
            let batchJson = "{\"type\":\"batch\",\"destination_generation\":\"\(gen)\",\"inst\":\"inst-1\",\"batch_id\":\"\(fitBatchId)\",\"queued_at_ms\":1700000000000,\"records\":[\(recJson)]}"
            let rep = try authority.accept(bytes: Data(batchJson.utf8), direction: "extension_to_host")
            #expect(rep["result"] as? String == "accepted")
            let pId = rep["period_id"] as! String
            if !fillerPids.contains(pId) { fillerPids.append(pId) }
            try store.finalizePeriod(periodId: pId, reason: "fit_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
            fillerIndex += 1
        }
        #expect(store.isQuotaFull())

        // One extra byte returns resource_exhausted
        let openPidBeforeOver = store.getOpenPeriodId()!
        let openFileBeforeOver = store.periodFileURL(for: openPidBeforeOver)
        let lenBeforeOver = (try? Data(contentsOf: openFileBeforeOver).count) ?? 0

        let overPayload: [String: Any] = [
            "type": "batch",
            "destination_generation": gen,
            "inst": "inst-1",
            "batch_id": "77777777777777777777777777777777",
            "queued_at_ms": 1700000000000 as UInt64,
            "records": [["t": "segment_start", "ts": 1700000000000 as UInt64, "ctx": "ctx-over", "blocks": [["id": "bo", "text": "extra byte over cap"]]]]
        ]
        let repOver = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: overPayload), direction: "extension_to_host")
        #expect(repOver["result"] as? String == "rejected")
        #expect(repOver["reason"] as? String == "resource_exhausted")
        #expect(repOver["class"] as? String == "retryable")
        let lenAfterOver = (try? Data(contentsOf: openFileBeforeOver).count) ?? 0
        #expect(lenAfterOver == lenBeforeOver)
        #expect(store.lookupReceipt(generation: gen, inst: "inst-1", batchId: "77777777777777777777777777777777") == nil)

        // Replay of an accepted id is duplicate while full
        let repReplay = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: anchorBatch), direction: "extension_to_host")
        #expect(repReplay["result"] as? String == "duplicate")
        #expect(repReplay["period_id"] as? String == anchorPid)

        // Advance spoolAgeMs (7 days = 604,800 s): custody.full, custody.stale, and delivery == failed (seam) true together
        clock.advance(by: 604801)
        store.simulatedDeliveryFailure = "journal_rejected"
        let statFullStaleFail = authority.status()
        let cFSF = statFullStaleFail["custody"] as? [String: Bool]
        #expect(cFSF?["full"] == true)
        #expect(cFSF?["stale"] == true)
        #expect(statFullStaleFail["delivery"] as? String == "failed")
        #expect(statFullStaleFail["failure"] as? String == "journal_rejected")

        // Clear only the seam -> full and stale stay
        store.simulatedDeliveryFailure = nil
        let statFS = authority.status()
        let cFS = statFS["custody"] as? [String: Bool]
        #expect(cFS?["full"] == true)
        #expect(cFS?["stale"] == true)
        #expect(statFS["delivery"] as? String == "kept_locally")

        // Release the filler periods and assert explicitly if that clears full
        for fPid in fillerPids {
            store.releaseProven(periodId: fPid)
        }
        let statAfterFillerRelease = authority.status()
        let cAFR = statAfterFillerRelease["custody"] as? [String: Bool]
        #expect(cAFR?["full"] == false)
        #expect(cAFR?["stale"] == true) // Anchor is still held and old, so stale stays
        #expect(statAfterFillerRelease["capture"] as? String == "permitted")

        // New snapshot accepts
        let youngNowMs = UInt64(clock.now.timeIntervalSince1970 * 1000.0)
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
        let youngPid = youngRep["period_id"] as! String
        try store.finalizePeriod(periodId: youngPid, reason: "young_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)

        // Release only the anchor: stale clears
        store.releaseProven(periodId: anchorPid)
        let statAfterAnchorRelease = authority.status()
        let cAAR = statAfterAnchorRelease["custody"] as? [String: Bool]
        #expect(cAAR?["stale"] == false)
        #expect(cAAR?["full"] == false)

        // Refill with young bytes to the cap
        var youngFillerPids: [String] = []
        var youngFillerIndex = 1
        while true {
            let nextBatchPayloadBytes = 25 * 1024 * 1024
            let nextDedup = 128
            if store.projectedSpoolBytes(additionalPayloadBytes: nextBatchPayloadBytes, additionalDedupBytes: nextDedup) > projection.policy.spoolBytes {
                break
            }
            let pad25M = String(repeating: "y", count: nextBatchPayloadBytes - 500)
            let bId = String(format: "a%031x", youngFillerIndex)
            let bPayload: [String: Any] = [
                "type": "batch",
                "destination_generation": gen,
                "inst": "inst-1",
                "batch_id": bId,
                "queued_at_ms": youngNowMs,
                "records": [["t": "segment_start", "ts": youngNowMs, "ctx": "ctx-yfill-\(youngFillerIndex)", "blocks": [["id": "byf", "text": pad25M]]]]
            ]
            let rep = try authority.accept(bytes: try JSONSerialization.data(withJSONObject: bPayload), direction: "extension_to_host")
            #expect(rep["result"] as? String == "accepted")
            let yfPid = rep["period_id"] as! String
            if !youngFillerPids.contains(yfPid) { youngFillerPids.append(yfPid) }
            try store.finalizePeriod(periodId: yfPid, reason: "yfiller_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
            youngFillerIndex += 1
        }

        while !store.isQuotaFull() {
            _ = store.updateFloorMs(wallNowMs: youngNowMs)
            let curProj = store.projectedSpoolBytes(additionalPayloadBytes: 0, additionalDedupBytes: 0)
            let yFitBatchId = String(format: "b%031x", youngFillerIndex)
            let yFitDedup = BrowserIntakeStore.receiptDedupBytes(generation: gen, inst: "inst-1", batchId: yFitBatchId, periodId: store.getOpenPeriodId(), reason: nil, receiptClass: nil)
            let yFitSeenDedup = BrowserIntakeStore.batchSeenDedupBytes(generation: gen, inst: "inst-1", batchId: yFitBatchId)
            let headroom = projection.policy.spoolBytes - curProj - yFitDedup - yFitSeenDedup
            let newRecBytes = max(1, headroom / 2)

            let basePrefix = "{\"t\":\"segment_start\",\"ts\":\(youngNowMs),\"ctx\":\"ctx-yfit-\(youngFillerIndex)\",\"blocks\":[{\"id\":\"bye\",\"text\":\""
            let baseSuffix = "\"}]}"
            let padLen = max(0, newRecBytes - basePrefix.utf8.count - baseSuffix.utf8.count - 1)
            let pad = String(repeating: "w", count: padLen)
            let recJson = basePrefix + pad + baseSuffix
            let batchJson = "{\"type\":\"batch\",\"destination_generation\":\"\(gen)\",\"inst\":\"inst-1\",\"batch_id\":\"\(yFitBatchId)\",\"queued_at_ms\":\(youngNowMs),\"records\":[\(recJson)]}"
            let rep = try authority.accept(bytes: Data(batchJson.utf8), direction: "extension_to_host")
            #expect(rep["result"] as? String == "accepted")
            let pId = rep["period_id"] as! String
            if !youngFillerPids.contains(pId) { youngFillerPids.append(pId) }
            try store.finalizePeriod(periodId: pId, reason: "yfit_seal", civilDate: clock.now, timeZone: TimeZone(identifier: "UTC")!)
            youngFillerIndex += 1
        }
        #expect(store.isQuotaFull())

        let statAfterYoungFull = authority.status()
        let cAYF = statAfterYoungFull["custody"] as? [String: Bool]
        #expect(cAYF?["stale"] == false)
        #expect(cAYF?["full"] == true)

        // Reopen store: floor_ms and earliest_held_ms are unchanged
        let floorBeforeReopen = store.getFloorMs()
        let earliestBeforeReopen = store.getEarliestHeldMs()
        let storeReopened = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        #expect(storeReopened.getFloorMs() == floorBeforeReopen)
        #expect(storeReopened.getEarliestHeldMs() == earliestBeforeReopen)

        // GC tombstone, roll injected clock backwards, submit same queued_at_ms again -> expired_unaccepted
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

        // Poll immediately after insert leaves the tombstone
        authorityReopened.poll(now: clock.now)
        #expect(storeReopened.lookupReceipt(generation: gen, inst: "inst-1", batchId: oldTombstoneBatchId) != nil)

        // Advance 2000s (> 1200000ms acceptedRetentionMs) and poll -> deletes tombstone
        clock.advance(by: 2000)
        authorityReopened.poll(now: clock.now)
        #expect(storeReopened.lookupReceipt(generation: gen, inst: "inst-1", batchId: oldTombstoneBatchId) == nil)

        // Roll injected clock backwards and submit again -> still expired_unaccepted (because floor_ms never rolls back)
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
            pid1 = reply["period_id"] as! String
        }

        // Reopen and call publishEpoch with the same token: generation id is unchanged
        let store2 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority2 = BrowserIntakeAuthority(store: store2, projection: projection, wallClock: { clock.now })
        let sameGen = try authority2.publishEpoch(identityToken: "token-1")
        #expect(sameGen == gen)

        // retireIfTokenChanged with that same token is a no-op
        try authority2.retireIfTokenChanged(newToken: "token-1")
        #expect(store2.getActiveGeneration() == gen)

        // Call with a different token without calling publishEpoch: status is unavailable
        try authority2.retireIfTokenChanged(newToken: "token-2")
        let statDiff = authority2.status()
        #expect(statDiff["capture"] as? String == "unavailable")
        #expect(statDiff["destination_generation"] is NSNull)
        #expect(statDiff["period_id"] is NSNull)

        // retireIfTokenChanged(nil) -> capture not_paired, old file still on disk
        let openFileURL = store2.periodFileURL(for: pid1)
        #expect(FileManager.default.fileExists(atPath: openFileURL.path))

        try authority2.retireIfTokenChanged(newToken: nil)

        let statNil = authority2.status()
        #expect(statNil["capture"] as? String == "not_paired")
        #expect(statNil["destination_generation"] is NSNull)
        #expect(statNil["period_id"] is NSNull)
        #expect(FileManager.default.fileExists(atPath: openFileURL.path))

        // Reopen after retire(nil): retired epoch with no publishEpoch stays closed
        let store3 = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let authority3 = BrowserIntakeAuthority(store: store3, projection: projection, wallClock: { clock.now })
        #expect(store3.getActiveGeneration() == nil)
        #expect(store3.getOpenPeriodId() == nil)

        // Batch to old generation is rejected with stale_generation
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

    @Test func test6_malformedAndOversizeAdmission() throws {
        let tempRoot = try createTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let projection = try BrowserContractProjection(rootURL: vendorURL)
        let store = try BrowserIntakeStore(rootURL: tempRoot, projection: projection)
        let clock = BrowserTestClock(Date(timeIntervalSince1970: 1700000000))
        let authority = BrowserIntakeAuthority(store: store, projection: projection, wallClock: { clock.now })
        _ = try authority.publishEpoch(identityToken: "token-1")

        let openPid = store.getOpenPeriodId()!
        let openFileURL = store.periodFileURL(for: openPid)
        let lenBefore = (try? Data(contentsOf: openFileURL).count) ?? 0

        // 1. Malformed JSON
        let badJsonData = Data("{invalid json".utf8)
        let reply1 = try authority.accept(bytes: badJsonData, direction: "extension_to_host")
        #expect(reply1["result"] as? String == "rejected")
        #expect(reply1["reason"] as? String == "malformed")
        #expect(reply1["class"] as? String == "permanent")
        let lenAfterBadJson = (try? Data(contentsOf: openFileURL).count) ?? 0
        #expect(lenAfterBadJson == lenBefore)

        // 2. Oversize batch (> 33,554,432 bytes)
        let oversizePad = String(repeating: "o", count: projection.caps.extensionToHost + 10)
        let oversizeData = Data(oversizePad.utf8)
        let reply2 = try authority.accept(bytes: oversizeData, direction: "extension_to_host")
        #expect(reply2["result"] as? String == "rejected")
        #expect(reply2["reason"] as? String == "oversize")
        #expect(reply2["class"] as? String == "permanent")
        let lenAfterOversize = (try? Data(contentsOf: openFileURL).count) ?? 0
        #expect(lenAfterOversize == lenBefore)
    }
}

#endif
