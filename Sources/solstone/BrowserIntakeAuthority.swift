// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore

public final class BrowserIntakeAuthority: @unchecked Sendable {
    private let lock = NSLock()
    public let store: BrowserIntakeStore
    public let projection: BrowserContractProjection
    private let monotonicClock: any MonotonicClock
    private var wallClock: @Sendable () -> Date
    private var timeZone: TimeZone
    private var lastRotationDate: Date

    public init(
        store: BrowserIntakeStore,
        projection: BrowserContractProjection,
        monotonicClock: any MonotonicClock = SystemMonotonicClock(),
        wallClock: @escaping @Sendable () -> Date = Date.init,
        timeZone: TimeZone = TimeZone.current
    ) {
        self.store = store
        self.projection = projection
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.timeZone = timeZone
        self.lastRotationDate = wallClock()
    }

    public func setWallClock(_ clock: @escaping @Sendable () -> Date) {
        lock.lock()
        defer { lock.unlock() }
        self.wallClock = clock
    }

    public func setTimeZone(_ tz: TimeZone) {
        lock.lock()
        defer { lock.unlock() }
        if tz != self.timeZone {
            let now = wallClock()
            if let pid = store.getOpenPeriodId() {
                let fileURL = store.periodFileURL(for: pid)
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if size > 0 {
                    try? store.finalizePeriod(periodId: pid, reason: "timezone_change", civilDate: now, timeZone: self.timeZone)
                }
            }
            self.timeZone = tz
            self.lastRotationDate = now
        }
    }

    public func publishEpoch(identityToken: String) throws -> String {
        let now = wallClock()
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)
        return try store.publishEpoch(identityToken: identityToken, nowMs: nowMs)
    }

    public func retireIfTokenChanged(newToken: String?) throws {
        let now = wallClock()
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)
        try store.retireIfTokenChanged(newToken: newToken, nowMs: nowMs)
    }

    public func status() -> [String: Any] {
        let now = wallClock()
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)
        let elapsed = monotonicClock.now()
        let freshnessMs = UInt64(Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0)
        return store.currentStatus(nowMs: nowMs, monotonicFreshnessMs: freshnessMs)
    }

    public func poll(now: Date) {
        lock.lock()
        defer { lock.unlock() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let lastMinute = calendar.component(.minute, from: lastRotationDate)
        let currentMinute = calendar.component(.minute, from: now)
        let lastDay = calendar.component(.day, from: lastRotationDate)
        let currentDay = calendar.component(.day, from: now)

        let crossedBoundary = (currentMinute / 5 != lastMinute / 5) || (currentDay != lastDay)

        if crossedBoundary {
            if let pid = store.getOpenPeriodId() {
                try? store.finalizePeriod(periodId: pid, reason: "clock_boundary", civilDate: now, timeZone: timeZone)
            }
            lastRotationDate = now
        }

        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)
        store.garbageCollectExpiredTombstones(nowMs: nowMs)
    }

    public func accept(bytes: Data, direction: String) throws -> [String: Any] {
        let now = wallClock()
        let nowMs = UInt64(now.timeIntervalSince1970 * 1000.0)

        // 1. Decode
        let decodeResult = BrowserPayloadDecoder.decode(bytes: bytes, direction: direction, projection: projection)

        switch decodeResult {
        case .refuse(let refusal):
            var gen = ""
            var inst = ""
            var batchId = ""
            if let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                gen = obj["destination_generation"] as? String ?? ""
                inst = obj["inst"] as? String ?? ""
                batchId = obj["batch_id"] as? String ?? ""
            }
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: gen,
                inst: inst,
                batchId: batchId,
                result: "rejected",
                reason: refusal.receiptReason,
                receiptClass: refusal.receiptClass,
                projection: projection
            )

        case .unsupported(let proto, let behind):
            return [
                "type": "unsupported",
                "protocol": proto,
                "behind": behind
            ]

        case .accept(let message):
            switch message {
            case .hello(_):
                let stat = status()
                var reply: [String: Any] = [
                    "type": "hello_ack",
                    "capture": stat["capture"] ?? "permitted",
                    "delivery": stat["delivery"] ?? "idle",
                    "freshness_ms": stat["freshness_ms"] ?? 0,
                    "destination_generation": stat["destination_generation"] ?? NSNull(),
                    "period_id": stat["period_id"] ?? NSNull(),
                    "custody": stat["custody"] ?? ["full": false, "stale": false]
                ]
                if let fail = stat["failure"] { reply["failure"] = fail }
                return reply

            case .state, .boundary, .accepted, .bye, .unsupported:
                return ["type": "accepted", "result": "accepted", "destination_generation": "", "inst": "", "batch_id": "", "period_id": ""]

            case .batch(let batch):
                return try processBatch(batch: batch, nowMs: nowMs, civilDate: now)
            }
        }
    }

    private func processBatch(batch: BrowserDecodedBatch, nowMs: UInt64, civilDate: Date) throws -> [String: Any] {
        // 2. Lookup existing receipt
        if let stored = store.lookupReceipt(generation: batch.destinationGeneration, inst: batch.inst, batchId: batch.batchId) {
            if stored.result == "accepted" || stored.result == "duplicate" {
                return try BrowserPayloadDecoder.buildReply(
                    destinationGeneration: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    result: "duplicate",
                    periodId: stored.periodId ?? "",
                    projection: projection
                )
            } else {
                return try BrowserPayloadDecoder.buildReply(
                    destinationGeneration: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    result: "rejected",
                    reason: stored.reason,
                    receiptClass: stored.receiptClass,
                    projection: projection
                )
            }
        }

        // 3. Generation check
        guard batch.destinationGeneration.count <= projection.stringBounds.generation else {
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "stale_generation",
                receiptClass: "permanent",
                projection: projection
            )
        }

        guard let activeGen = store.getActiveGeneration(), activeGen == batch.destinationGeneration else {
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "stale_generation",
                receiptClass: "permanent",
                projection: projection
            )
        }

        // 4. Age policy
        let floorMs = store.updateFloorMs(wallNowMs: nowMs)
        let firstSeen = store.getFirstSeenQueuedAt(generation: batch.destinationGeneration, inst: batch.inst, batchId: batch.batchId)
        if firstSeen == nil {
            store.recordBatchSeen(generation: batch.destinationGeneration, inst: batch.inst, batchId: batch.batchId, queuedAtMs: batch.queuedAtMs)
        }
        let effectiveQueued = min(firstSeen ?? batch.queuedAtMs, batch.queuedAtMs)

        if effectiveQueued > floorMs && (effectiveQueued - floorMs) > projection.policy.futureSkewMs {
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "age_policy",
                receiptClass: "retryable",
                projection: projection
            )
        }

        if floorMs >= effectiveQueued && (floorMs - effectiveQueued) >= projection.policy.outboxAgeMs {
            try? store.commitTombstone(
                generation: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                reason: "expired_unaccepted",
                receiptClass: "permanent",
                queuedAtMs: effectiveQueued
            )
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "expired_unaccepted",
                receiptClass: "permanent",
                projection: projection
            )
        }

        // 5. Snapshot / context check
        let firstRec = batch.records[0]
        if firstRec.t == "delta" {
            guard let openPid = store.getOpenPeriodId(),
                  store.isContextInitialized(periodId: openPid, inst: batch.inst, ctx: firstRec.ctx) else {
                return try BrowserPayloadDecoder.buildReply(
                    destinationGeneration: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    result: "rejected",
                    reason: "snapshot_required",
                    receiptClass: "retryable",
                    projection: projection
                )
            }
        }

        // 6. Quota check
        var batchBytes = 0
        for r in batch.records { batchBytes += r.rawSlice.count + 1 }
        let batchDedupBytes = BrowserIntakeStore.receiptDedupBytes(
            generation: batch.destinationGeneration,
            inst: batch.inst,
            batchId: batch.batchId,
            periodId: store.getOpenPeriodId(),
            reason: nil,
            receiptClass: nil
        )

        if store.isQuotaFull(additionalBytes: batchBytes, additionalDedupBytes: batchDedupBytes) {
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "resource_exhausted",
                receiptClass: "retryable",
                projection: projection
            )
        }

        // 7. Commit
        do {
            let pid = try store.commitBatch(
                batch: batch,
                nowMs: nowMs,
                civilDate: civilDate,
                timeZone: timeZone
            )
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "accepted",
                periodId: pid,
                projection: projection
            )
        } catch {
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "rejected",
                reason: "resource_exhausted",
                receiptClass: "retryable",
                projection: projection
            )
        }
    }
}

#endif
