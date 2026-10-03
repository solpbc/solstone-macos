// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Foundation
import SolstoneCore
import os

public enum BrowserIdentityChangeMode: Sendable {
    case replace
    case reload
}

struct BrowserIntakeOperationError: Error {
    let underlying: any Error
    let generation: String?
}

public final class BrowserIntakeAuthority: @unchecked Sendable {
    private let lock = NSLock()
    public let store: BrowserIntakeStore
    public let projection: BrowserContractProjection
    private let monotonicClock: any MonotonicClock
    private var wallClock: @Sendable () -> Date
    private var timeZone: TimeZone
    private var lastRotationDate: Date
    private var _isPaused: Bool = false
    private var admissionClosed = false
    private var stopped = false
    private var staleAnchorMs: UInt64 = 0
    private var staleMonotonicAnchor: Duration = .zero
    private var staleElapsedBaseMs: UInt64 = 0
    private let floorAnchorMs: UInt64
    private let floorMonotonicAnchor: Duration
    public var isPaused: Bool {
        lock.withLock { _isPaused }
    }

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
        self.floorAnchorMs = max(store.getFloorMs(), BrowserAgeStamp.wallMilliseconds(wallClock()))
        self.floorMonotonicAnchor = monotonicClock.now()
        let staleState = store.stalenessState()
        self.staleAnchorMs = staleState.anchorMs
        self.staleElapsedBaseMs = staleState.elapsedHighWaterMs
        self.staleMonotonicAnchor = monotonicClock.now()
        let initialHeldAnchor = store.getEarliestHeldMs()
        if initialHeldAnchor > 0 {
            let wallNowMs = max(BrowserAgeStamp.wallMilliseconds(wallClock()), store.getFloorMs())
            let wallElapsed = wallNowMs > initialHeldAnchor ? wallNowMs - initialHeldAnchor : 0
            self.staleAnchorMs = initialHeldAnchor
            self.staleElapsedBaseMs = max(staleState.anchorMs == initialHeldAnchor ? staleState.elapsedHighWaterMs : 0, wallElapsed)
        }
        if let created = store.openPeriodCreatedAtMs() {
            self.lastRotationDate = Date(timeIntervalSince1970: Double(created) / 1000.0)
        }
        let now = self.wallClock()
        rotateIfBoundary(now: now)
    }

    public func closeAdmission() {
        lock.lock()
        admissionClosed = true
        lock.unlock()
    }

    public func reopenAdmission() {
        lock.lock()
        if !stopped { admissionClosed = false }
        lock.unlock()
    }

    func resumeAfterDrain() {
        lock.withLock { stopped = false }
    }

    public func isAdmissionOpen() -> Bool {
        lock.withLock { !admissionClosed && !store.storeIsFailed() }
    }

    public func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self._isPaused = paused
        store.setPaused(paused)
    }

    public func setWallClock(_ clock: @escaping @Sendable () -> Date) {
        lock.lock()
        defer { lock.unlock() }
        self.wallClock = clock
    }

    public func setTimeZone(_ tz: TimeZone, attachFailureGeneration: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            if tz != self.timeZone {
                let now = wallClock()
                if let pid = store.getOpenPeriodId(), try store.periodFileByteCount(periodId: pid) > 0 {
                    try store.finalizePeriod(periodId: pid, reason: "timezone_change", civilDate: now, timeZone: self.timeZone)
                }
                self.timeZone = tz
                self.lastRotationDate = now
            }
        } catch {
            if attachFailureGeneration {
                throw BrowserIntakeOperationError(underlying: error, generation: store.getActiveGeneration())
            }
            throw error
        }
    }

    public func publishEpoch(identityToken: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let now = wallClock()
        let nowMs = BrowserAgeStamp.wallMilliseconds(now)
        return try store.publishEpoch(identityToken: identityToken, nowMs: nowMs)
    }

    public func retireIfTokenChanged(newToken: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = wallClock()
        let nowMs = BrowserAgeStamp.wallMilliseconds(now)
        try store.retireIfTokenChanged(newToken: newToken, nowMs: nowMs, timeZone: timeZone)
    }

    public func stopAndFinalize() throws {
        lock.lock()
        defer { lock.unlock() }
        admissionClosed = true
        stopped = true
        if let periodId = store.getOpenPeriodId() {
            try store.finalizePeriod(periodId: periodId, reason: "owner_stop", civilDate: wallClock(), timeZone: timeZone, openReplacement: false)
        }
    }

    public func reconcileIdentity(_ token: String?, mode: BrowserIdentityChangeMode) throws {
        closeAdmission()
        store.closeDeliveryProofs()
        guard !store.storeIsFailed() else { throw BrowserIntakeStoreError.localIO }
        switch mode {
        case .replace:
            // Same-journal replacement keeps its admitted generation. The
            // credential fence is published only after the save has succeeded.
            try retireIfTokenChanged(newToken: token)
        case .reload:
            guard let token else { return }
            if store.getActiveGeneration() != nil {
                guard store.matchesActiveJournal(identityToken: token) else { return }
            } else if store.hasPersistedIdentityHistory() {
                // A reload cannot undo retirement or assign the loaded pairing
                // to old custody. Only a completed credential save publishes a
                // new generation after retirement.
                return
            }
            _ = try publishEpoch(identityToken: token)
            reopenAdmission()
        }
    }

    private func advanceFloor(wallNowMs: UInt64) throws -> UInt64 {
        let elapsed = durationMs(monotonicClock.now() - floorMonotonicAnchor)
        let (advanced, overflow) = floorAnchorMs.addingReportingOverflow(elapsed)
        let candidate = overflow ? UInt64(Int64.max) : min(advanced, UInt64(Int64.max))
        return try store.updateFloorMs(wallNowMs: max(wallNowMs, candidate))
    }

    public func status() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let now = wallClock()
        let nowMs = BrowserAgeStamp.wallMilliseconds(now)
        let floorMs: UInt64
        do { floorMs = try advanceFloor(wallNowMs: nowMs) }
        catch { store.failClosed(); floorMs = store.getFloorMs() }
        let monoNow = monotonicClock.now()
        let heldAnchor = store.getEarliestHeldMs()
        do {
            if heldAnchor == 0 {
                _ = try store.updateStaleness(anchorMs: nil, elapsedMs: 0)
                staleAnchorMs = 0
                staleElapsedBaseMs = 0
                staleMonotonicAnchor = monoNow
            } else {
                if staleAnchorMs != heldAnchor {
                    let stored = store.stalenessState()
                    let wallElapsed = floorMs > heldAnchor ? floorMs - heldAnchor : 0
                    staleElapsedBaseMs = max(stored.anchorMs == heldAnchor ? stored.elapsedHighWaterMs : 0, wallElapsed)
                    staleAnchorMs = heldAnchor
                    staleMonotonicAnchor = monoNow
                }
                let elapsed = durationMs(monoNow - staleMonotonicAnchor)
                _ = try store.updateStaleness(anchorMs: heldAnchor, elapsedMs: staleElapsedBaseMs + elapsed)
            }
        } catch {
            store.failClosed()
            Logger.storage.error("Browser intake stale-age persistence failed: \(error.localizedDescription, privacy: .public)")
        }
        if admissionClosed {
            let held = store.currentStatus(nowMs: nowMs, monotonicFreshnessMs: projection.policy.freshnessMaxMs)
            var result: [String: Any] = [
                "type": "state",
                "capture": "unavailable",
                "delivery": held["delivery"] ?? "unknown",
                "freshness_ms": held["freshness_ms"] ?? projection.policy.freshnessMaxMs,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
                "custody": held["custody"] ?? ["full": false, "stale": false]
            ]
            if let failure = held["failure"] as? String { result["failure"] = failure }
            return result
        }
        return store.currentStatus(nowMs: nowMs, monotonicFreshnessMs: projection.policy.freshnessMaxMs)
    }

    public func poll(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        let nowMs = BrowserAgeStamp.wallMilliseconds(now)
        do { _ = try advanceFloor(wallNowMs: nowMs) }
        catch { store.failClosed(); return }
        rotateIfBoundary(now: now)
        store.garbageCollectExpiredTombstones(nowMs: nowMs)
    }

    private func boundaryKey(_ date: Date) -> (Int, Int, Int, Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return (
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date),
            (hour * 60 + minute) / 5
        )
    }

    private func rotateIfBoundary(now: Date) {
        let previous = boundaryKey(lastRotationDate)
        let current = boundaryKey(now)
        guard previous != current else { return }
        if let pid = store.getOpenPeriodId() {
            do {
                try store.finalizePeriod(periodId: pid, reason: "clock_boundary", civilDate: now, timeZone: timeZone)
                lastRotationDate = now
            } catch {
                store.setStoreFailed(true)
                Logger.storage.error("Browser intake boundary finalization failed")
                return
            }
        } else {
            lastRotationDate = now
        }
    }

    private func durationMs(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        if parts.seconds < 0 { return 0 }
        return UInt64(parts.seconds) * 1000 + UInt64(parts.attoseconds / 1_000_000_000_000_000)
    }

    private func refusalReply(_ refusal: BrowserRefusal) -> [String: Any] {
        [
            "type": "refused",
            "code": refusal.code,
            "reason": refusal.receiptReason,
            "class": refusal.receiptClass
        ]
    }

    public func accept(bytes: Data, direction: String, admitNewBatches: Bool = true) throws -> [String: Any] {
        let decodeResult = BrowserPayloadDecoder.decode(bytes: bytes, direction: direction, projection: projection)
        return try accept(decoded: decodeResult, admitNewBatches: admitNewBatches)
    }

    public func accept(decoded decodeResult: BrowserDecodeResult, admitNewBatches: Bool = true,
                       sessionIsCurrent: @Sendable () -> Bool = { true },
                       attachFailureGeneration: Bool = false) throws -> [String: Any] {
        switch decodeResult {
        case .refuse(let refusal):
            return refusalReply(refusal)

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
                    "freshness_ms": stat["freshness_ms"] ?? projection.policy.freshnessMaxMs,
                    "destination_generation": stat["destination_generation"] ?? NSNull(),
                    "period_id": stat["period_id"] ?? NSNull(),
                    "custody": stat["custody"] ?? ["full": false, "stale": false]
                ]
                if let fail = stat["failure"] { reply["failure"] = fail }
                return reply

            case .state, .boundary, .accepted, .bye, .unsupported:
                return refusalReply(BrowserRefusal(code: "bad_direction"))

            case .batch(let batch):
                lock.lock()
                defer { lock.unlock() }
                guard sessionIsCurrent() else { return refusalReply(BrowserRefusal(code: "shutdown")) }
                let now = wallClock()
                let nowMs = BrowserAgeStamp.wallMilliseconds(now)
                do {
                    return try processBatch(batch: batch, nowMs: nowMs, civilDate: now, admitNewBatches: admitNewBatches)
                } catch {
                    if attachFailureGeneration {
                        throw BrowserIntakeOperationError(underlying: error, generation: store.getActiveGeneration())
                    }
                    throw error
                }
            }
        }
    }

    private func rejected(
        batch: BrowserDecodedBatch,
        reason: String,
        receiptClass: String
    ) throws -> [String: Any] {
        try BrowserPayloadDecoder.buildReply(
            destinationGeneration: batch.destinationGeneration,
            inst: batch.inst,
            batchId: batch.batchId,
            result: "rejected",
            reason: reason,
            receiptClass: receiptClass,
            projection: projection
        )
    }

    private func processBatch(batch: BrowserDecodedBatch, nowMs: UInt64, civilDate: Date, admitNewBatches: Bool = true) throws -> [String: Any] {
        // A receipt from damaged custody cannot promise that the bytes remain
        // kept. Closed admission alone still permits healthy duplicate answers.
        if store.storeIsFailed() {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }
        if let stored = try store.lookupReceipt(generation: batch.destinationGeneration, inst: batch.inst, batchId: batch.batchId) {
            if stored.result == "accepted" || stored.result == "duplicate" {
                return try BrowserPayloadDecoder.buildReply(
                    destinationGeneration: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    result: "duplicate",
                    periodId: stored.periodId ?? "",
                    projection: projection
                )
            }
            return try rejected(batch: batch, reason: stored.reason ?? "malformed", receiptClass: stored.receiptClass ?? "permanent")
        }

        guard let activeGen = store.getActiveGeneration(), BrowserOpaqueString.equals(activeGen, batch.destinationGeneration) else {
            return try rejected(batch: batch, reason: "stale_generation", receiptClass: "permanent")
        }

        if !admitNewBatches || admissionClosed || store.storeIsFailed() {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }

        let floorMs: UInt64
        do {
            floorMs = try advanceFloor(wallNowMs: nowMs)
        } catch {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }

        if batch.queuedAtMs > floorMs && (batch.queuedAtMs - floorMs) > projection.policy.futureSkewMs {
            return try rejected(batch: batch, reason: "age_policy", receiptClass: "retryable")
        }

        var seenAge: (initialAgeMs: UInt64, elapsedHighWaterMs: UInt64, established: Bool)?
        do {
            seenAge = try store.getBatchAge(generation: batch.destinationGeneration, inst: batch.inst, batchId: batch.batchId)
            if seenAge == nil {
                let initialAge = floorMs > batch.queuedAtMs ? floorMs - batch.queuedAtMs : 0
                try store.recordBatchSeen(
                    generation: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    queuedAtMs: batch.queuedAtMs,
                    initialAgeMs: initialAge
                )
                seenAge = (initialAgeMs: initialAge, elapsedHighWaterMs: 0, established: true)
            }
        } catch {
            if error as? BrowserIntakeStoreError != .resourceExhausted {
                store.failClosed()
            }
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }
        guard let seenAge else { throw BrowserIntakeStoreError.localIO }
        if !seenAge.established {
            do {
                try store.commitTombstone(
                    generation: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    reason: "expired_unaccepted",
                    receiptClass: "permanent",
                    queuedAtMs: batch.queuedAtMs
                )
            } catch {
                return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
            }
            return try rejected(batch: batch, reason: "expired_unaccepted", receiptClass: "permanent")
        }
        let elapsedHighWater = seenAge.elapsedHighWaterMs
        do {
            try store.updateBatchAgeHighWater(
                generation: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                elapsedMs: elapsedHighWater
            )
        } catch {
            store.failClosed()
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }
        let totalAge = seenAge.initialAgeMs + elapsedHighWater
        if totalAge >= projection.policy.outboxAgeMs {
            do {
                try store.commitTombstone(
                    generation: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    reason: "expired_unaccepted",
                    receiptClass: "permanent",
                    queuedAtMs: batch.queuedAtMs
                )
            } catch {
                return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
            }
            return try rejected(batch: batch, reason: "expired_unaccepted", receiptClass: "permanent")
        }

        var batchBytes = 0
        for record in batch.records { batchBytes += record.rawSlice.count + 1 }
        // A batch that arrives after the window closed (on wake, before the
        // boundary timer runs) belongs to a new period, not the stale one.
        rotateIfBoundary(now: civilDate)
        let selectedPeriod: String
        do {
            selectedPeriod = try store.selectPeriodForBatch(
                byteCount: batchBytes,
                civilDate: civilDate,
                timeZone: timeZone,
                nowMs: nowMs
            )
        } catch let error as BrowserIntakeStoreError {
            switch error {
            case .resourceExhausted:
                return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
            case .staleGeneration:
                return try rejected(batch: batch, reason: "stale_generation", receiptClass: "permanent")
            case .duplicateAccepted, .localIO:
                return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
            }
        } catch {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }

        let firstRec = batch.records[0]
        if firstRec.t == "delta" {
            let initialized = try store.isContextInitialized(periodId: selectedPeriod, inst: batch.inst, ctx: firstRec.ctx)
            if !initialized {
                return try rejected(batch: batch, reason: "snapshot_required", receiptClass: "retryable")
            }
        }

        if store.isQuotaFull(
            additionalBytes: batchBytes,
            additionalDedupBytes: BrowserIntakeStore.receiptDedupBytes(
                generation: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                periodId: selectedPeriod,
                reason: nil,
                receiptClass: nil
            )
        ) {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }

        do {
            let pid = try store.commitBatch(batch: batch, nowMs: nowMs, civilDate: civilDate, timeZone: timeZone)
            return try BrowserPayloadDecoder.buildReply(
                destinationGeneration: batch.destinationGeneration,
                inst: batch.inst,
                batchId: batch.batchId,
                result: "accepted",
                periodId: pid,
                projection: projection
            )
        } catch let error as BrowserIntakeStoreError {
            if case .duplicateAccepted(let periodId) = error {
                return try BrowserPayloadDecoder.buildReply(
                    destinationGeneration: batch.destinationGeneration,
                    inst: batch.inst,
                    batchId: batch.batchId,
                    result: "duplicate",
                    periodId: periodId,
                    projection: projection
                )
            }
            if case .staleGeneration = error {
                return try rejected(batch: batch, reason: "stale_generation", receiptClass: "permanent")
            }
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        } catch {
            return try rejected(batch: batch, reason: "resource_exhausted", receiptClass: "retryable")
        }
    }
}

#endif
