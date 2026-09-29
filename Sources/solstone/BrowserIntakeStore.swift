// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum BrowserIntakeCrashPoint: Sendable, Equatable {
    case none
    case afterFileSync
    case afterCommit
    case afterFinalizeSync
    case failCommit
}

public struct BrowserStoredReceipt: Sendable, Equatable {
    public let generation: String
    public let inst: String
    public let batchId: String
    public let result: String
    public let periodId: String?
    public let reason: String?
    public let receiptClass: String?
    public let queuedAtMs: UInt64
    public let acceptedAtMs: UInt64?
    public let sizeBytes: Int
}

public struct BrowserStoredPeriod: Sendable, Equatable {
    public let periodId: String
    public let generation: String
    public let state: String // "open", "finalized", "delivered", "retired"
    public let requestedDay: String?
    public let requestedSegment: String?
    public let fileSha256: String?
    public let size: Int
    public let committedLength: Int
    public let createdAtMs: UInt64
    public let finalizedAtMs: UInt64?
    public let canonicalKey: String?
}

/// The acceptance store for browser intake.
///
/// This type is `@unchecked Sendable` and guarded by a single `NSLock` across all mutable state.
/// It is NOT a Swift actor and NOT `@MainActor`: `PairingCredentialStore.save`, `delete`, and
/// `noteExternalPairingChange` are synchronous and must retire the epoch before the keychain write
/// returns; an actor hop would let an accept interleave.
public final class BrowserIntakeStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private let projection: BrowserContractProjection
    private var db: OpaquePointer?

    public var crashPoint: BrowserIntakeCrashPoint = .none
    public var simulatedDeliveryFailure: String? = nil

    private var activeGeneration: String?
    private var activeIdentityToken: String?
    private var currentOpenPeriodId: String?

    private var storedFloorMs: UInt64 = 0
    private var earliestHeldMs: UInt64 = 0
    private var heldPayloadBytes: Int = 0
    private var heldDedupBytes: Int = 0
    private var heldStagingBytes: Int = 0

    public static func receiptDedupBytes(generation: String, inst: String, batchId: String, periodId: String?, reason: String?, receiptClass: String?) -> Int {
        generation.utf8.count + inst.utf8.count + batchId.utf8.count + (periodId?.utf8.count ?? 0) + (reason?.utf8.count ?? 0) + (receiptClass?.utf8.count ?? 0)
    }

    public static func batchSeenDedupBytes(generation: String, inst: String, batchId: String) -> Int {
        generation.utf8.count + inst.utf8.count + batchId.utf8.count
    }

    public init(rootURL: URL, projection: BrowserContractProjection) throws {
        self.rootURL = rootURL
        self.projection = projection

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let periodsDir = rootURL.appendingPathComponent("periods")
        try FileManager.default.createDirectory(at: periodsDir, withIntermediateDirectories: true)
        Self.fsyncParent(of: periodsDir)

        let dbURL = rootURL.appendingPathComponent("intake.sqlite")
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "BrowserIntakeStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open sqlite db"])
        }
        Self.fsyncParent(of: dbURL)

        try initSchema()
        try recoverAndLoadState()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func fsyncParent(of fileURL: URL) {
        let parentURL = fileURL.deletingLastPathComponent()
        let fd = open(parentURL.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
    }

    private func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "unknown sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "BrowserIntakeStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func initSchema() throws {
        let sql = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;

        CREATE TABLE IF NOT EXISTS epoch (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            identity_token TEXT NOT NULL,
            destination_generation TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            retired_at_ms INTEGER
        );

        CREATE TABLE IF NOT EXISTS periods (
            period_id TEXT PRIMARY KEY,
            generation TEXT NOT NULL,
            state TEXT NOT NULL,
            requested_day TEXT,
            requested_segment TEXT,
            file_sha256 TEXT,
            size INTEGER NOT NULL DEFAULT 0,
            committed_length INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            finalized_at_ms INTEGER,
            canonical_key TEXT
        );

        CREATE TABLE IF NOT EXISTS period_contexts (
            period_id TEXT NOT NULL,
            inst TEXT NOT NULL,
            ctx TEXT NOT NULL,
            initialized_at_ms INTEGER NOT NULL,
            PRIMARY KEY (period_id, inst, ctx)
        );

        CREATE TABLE IF NOT EXISTS receipts (
            generation TEXT NOT NULL,
            inst TEXT NOT NULL,
            batch_id TEXT NOT NULL,
            result TEXT NOT NULL,
            period_id TEXT,
            reason TEXT,
            class TEXT,
            queued_at_ms INTEGER NOT NULL,
            accepted_at_ms INTEGER,
            size_bytes INTEGER NOT NULL,
            PRIMARY KEY (generation, inst, batch_id)
        );

        CREATE TABLE IF NOT EXISTS batch_seen (
            generation TEXT NOT NULL,
            inst TEXT NOT NULL,
            batch_id TEXT NOT NULL,
            queued_at_ms INTEGER NOT NULL,
            PRIMARY KEY (generation, inst, batch_id)
        );

        CREATE TABLE IF NOT EXISTS spool_state (
            key TEXT PRIMARY KEY,
            int_value INTEGER NOT NULL
        );
        """
        try execute(sql)
    }

    private func recoverAndLoadState() throws {
        // Load active epoch if one exists
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT destination_generation, identity_token FROM epoch WHERE status = 'active' ORDER BY id DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                self.activeGeneration = String(cString: sqlite3_column_text(stmt, 0))
                self.activeIdentityToken = String(cString: sqlite3_column_text(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)

        // If no active epoch, check if there's any epoch recorded
        if self.activeGeneration == nil {
            var eStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT identity_token FROM epoch ORDER BY id DESC LIMIT 1", -1, &eStmt, nil) == SQLITE_OK {
                if sqlite3_step(eStmt) == SQLITE_ROW {
                    self.activeIdentityToken = String(cString: sqlite3_column_text(eStmt, 0))
                }
            }
            sqlite3_finalize(eStmt)
        }

        // Load open period
        if let gen = activeGeneration {
            if sqlite3_prepare_v2(db, "SELECT period_id, committed_length FROM periods WHERE generation = ? AND state = 'open' ORDER BY created_at_ms DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gen as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let pid = String(cString: sqlite3_column_text(stmt, 0))
                    let committedLen = Int(sqlite3_column_int64(stmt, 1))
                    self.currentOpenPeriodId = pid

                    // Truncate file if longer than committed_length
                    let fileURL = periodFileURL(for: pid)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                           let fileSize = attrs[.size] as? Int, fileSize > committedLen {
                            let fh = try FileHandle(forWritingTo: fileURL)
                            try fh.truncate(atOffset: UInt64(committedLen))
                            try fh.synchronize()
                            try fh.close()
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }

        // Recalculate and load counters
        recalculateCounters()
    }

    private func recalculateCounters() {
        var stmt: OpaquePointer?
        var payloadBytes = 0
        if sqlite3_prepare_v2(db, "SELECT SUM(committed_length) FROM periods WHERE state IN ('open', 'finalized')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                payloadBytes = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        self.heldPayloadBytes = payloadBytes

        var dedupBytes = 0
        if sqlite3_prepare_v2(db, "SELECT generation, inst, batch_id, period_id, reason, class FROM receipts", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let g = sqlite3_column_text(stmt, 0).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let i = sqlite3_column_text(stmt, 1).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let b = sqlite3_column_text(stmt, 2).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let p = sqlite3_column_text(stmt, 3).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let r = sqlite3_column_text(stmt, 4).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let c = sqlite3_column_text(stmt, 5).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                dedupBytes += (g + i + b + p + r + c)
            }
        }
        sqlite3_finalize(stmt)
        if sqlite3_prepare_v2(db, "SELECT generation, inst, batch_id FROM batch_seen", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let g = sqlite3_column_text(stmt, 0).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let i = sqlite3_column_text(stmt, 1).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                let b = sqlite3_column_text(stmt, 2).map { strlen(UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) } ?? 0
                dedupBytes += (g + i + b)
            }
        }
        sqlite3_finalize(stmt)
        self.heldDedupBytes = dedupBytes

        var minAccepted: UInt64 = 0
        if sqlite3_prepare_v2(db, "SELECT MIN(accepted_at_ms) FROM receipts r JOIN periods p ON r.period_id = p.period_id WHERE p.state IN ('open', 'finalized') AND r.accepted_at_ms IS NOT NULL", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                minAccepted = UInt64(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        self.earliestHeldMs = minAccepted

        // Load floor_ms
        if sqlite3_prepare_v2(db, "SELECT int_value FROM spool_state WHERE key = 'floor_ms'", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                self.storedFloorMs = UInt64(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
    }

    public func periodFileURL(for periodId: String) -> URL {
        rootURL.appendingPathComponent("periods").appendingPathComponent(periodId).appendingPathComponent("browser_pages.jsonl")
    }

    public func getFloorMs() -> UInt64 {
        lock.withLock { storedFloorMs }
    }

    private func updateFloorMsLocked(wallNowMs: UInt64) -> UInt64 {
        if wallNowMs > storedFloorMs {
            storedFloorMs = wallNowMs
            try? execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('floor_ms', \(storedFloorMs));")
        }
        return storedFloorMs
    }

    public func updateFloorMs(wallNowMs: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return updateFloorMsLocked(wallNowMs: wallNowMs)
    }

    public func currentStatus(nowMs: UInt64, monotonicFreshnessMs: UInt64) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let freshness = min(monotonicFreshnessMs, projection.policy.freshnessMaxMs)
        let floor = max(storedFloorMs, nowMs)

        var isStale = false
        if earliestHeldMs > 0 && floor >= earliestHeldMs && (floor - earliestHeldMs) >= projection.policy.spoolAgeMs {
            isStale = true
        }

        let isFull = isQuotaFull()

        guard let identity = activeIdentityToken, !identity.isEmpty else {
            return [
                "type": "state",
                "capture": "not_paired",
                "delivery": "unknown",
                "freshness_ms": freshness,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
                "custody": ["full": false, "stale": false]
            ]
        }

        guard let gen = activeGeneration, !gen.isEmpty else {
            return [
                "type": "state",
                "capture": "unavailable",
                "delivery": "unknown",
                "freshness_ms": freshness,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
                "custody": ["full": false, "stale": false]
            ]
        }

        let periodId = currentOpenPeriodId
        var delivery = heldPayloadBytes > 0 ? "kept_locally" : "idle"
        var capture = isFull ? "intake_off" : "permitted"
        var failure: String? = nil

        if isFull && simulatedDeliveryFailure == nil {
            failure = "resource_exhausted"
        }

        if let simFail = simulatedDeliveryFailure {
            delivery = "failed"
            failure = simFail
            if isFull {
                capture = "intake_off"
            }
        }

        var res: [String: Any] = [
            "type": "state",
            "capture": capture,
            "delivery": delivery,
            "freshness_ms": freshness,
            "destination_generation": gen,
            "period_id": periodId ?? NSNull(),
            "custody": ["full": isFull, "stale": isStale]
        ]
        if let failure {
            res["failure"] = failure
        }
        return res
    }

    public func publishEpoch(identityToken: String, nowMs: UInt64) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let currentGen = activeGeneration, activeIdentityToken == identityToken {
            return currentGen
        }

        let durableNowMs = max(storedFloorMs, nowMs)
        _ = updateFloorMsLocked(wallNowMs: durableNowMs)

        // Retire any existing active epoch
        try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")

        let newGen = UUID().uuidString
        let newPeriodId = UUID().uuidString

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO epoch (identity_token, destination_generation, status, created_at_ms) VALUES (?, ?, 'active', ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (identityToken as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (newGen as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(durableNowMs))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        if sqlite3_prepare_v2(db, "INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (newPeriodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (newGen as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(durableNowMs))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        self.activeGeneration = newGen
        self.activeIdentityToken = identityToken
        self.currentOpenPeriodId = newPeriodId

        return newGen
    }

    public func retireIfTokenChanged(newToken: String?, nowMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }

        if let current = activeIdentityToken, current == newToken {
            return
        }

        let durableNowMs = max(storedFloorMs, nowMs)
        _ = updateFloorMsLocked(wallNowMs: durableNowMs)

        // Finalize non-empty open period before retiring
        if let openPid = currentOpenPeriodId {
            let fileURL = periodFileURL(for: openPid)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? finalizePeriodInternal(periodId: openPid, reason: "identity_retirement", civilDate: Date(timeIntervalSince1970: Double(durableNowMs) / 1000.0), timeZone: TimeZone.current)
            }
        }

        try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")
        self.activeGeneration = nil
        self.activeIdentityToken = newToken
        self.currentOpenPeriodId = nil
    }

    public func lookupReceipt(generation: String, inst: String, batchId: String) -> BrowserStoredReceipt? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT result, period_id, reason, class, queued_at_ms, accepted_at_ms, size_bytes FROM receipts WHERE generation = ? AND inst = ? AND batch_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (generation as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (batchId as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let result = String(cString: sqlite3_column_text(stmt, 0))
                let periodId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let reason = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let rClass = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let queuedAtMs = UInt64(sqlite3_column_int64(stmt, 4))
                let acceptedAtMs = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil
                let sizeBytes = Int(sqlite3_column_int64(stmt, 6))

                return BrowserStoredReceipt(
                    generation: generation,
                    inst: inst,
                    batchId: batchId,
                    result: result,
                    periodId: periodId,
                    reason: reason,
                    receiptClass: rClass,
                    queuedAtMs: queuedAtMs,
                    acceptedAtMs: acceptedAtMs,
                    sizeBytes: sizeBytes
                )
            }
        }
        return nil
    }

    public func isContextInitialized(periodId: String, inst: String, ctx: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT 1 FROM period_contexts WHERE period_id = ? AND inst = ? AND ctx = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (periodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (ctx as NSString).utf8String, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        return false
    }

    public func recordBatchSeen(generation: String, inst: String, batchId: String, queuedAtMs: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO batch_seen (generation, inst, batch_id, queued_at_ms) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (generation as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (batchId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(queuedAtMs))
            if sqlite3_step(stmt) == SQLITE_DONE {
                if sqlite3_changes(db) == 1 {
                    heldDedupBytes += Self.batchSeenDedupBytes(generation: generation, inst: inst, batchId: batchId)
                }
            }
        }
        sqlite3_finalize(stmt)
    }

    public func getFirstSeenQueuedAt(generation: String, inst: String, batchId: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT queued_at_ms FROM batch_seen WHERE generation = ? AND inst = ? AND batch_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (generation as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (batchId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return UInt64(sqlite3_column_int64(stmt, 0))
            }
        }
        return nil
    }

    public func getEarliestHeldMs() -> UInt64 {
        lock.withLock { earliestHeldMs }
    }

    public func projectedSpoolBytes(additionalPayloadBytes: Int = 0, additionalDedupBytes: Int = 0) -> Int {
        let sqliteSize = (try? FileManager.default.attributesOfItem(atPath: rootURL.appendingPathComponent("intake.sqlite").path)[.size] as? Int) ?? 4096
        let deliveryReserve = heldPayloadBytes + additionalPayloadBytes
        return heldPayloadBytes + additionalPayloadBytes + heldDedupBytes + additionalDedupBytes + heldStagingBytes + sqliteSize + deliveryReserve
    }

    public func isQuotaFull(additionalBytes: Int = 0, additionalDedupBytes: Int = 0) -> Bool {
        if additionalBytes == 0 && additionalDedupBytes == 0 {
            return projectedSpoolBytes(additionalPayloadBytes: 1, additionalDedupBytes: 0) > projection.policy.spoolBytes
        }
        return projectedSpoolBytes(additionalPayloadBytes: additionalBytes, additionalDedupBytes: additionalDedupBytes) > projection.policy.spoolBytes
    }

    public func commitTombstone(
        generation: String,
        inst: String,
        batchId: String,
        reason: String,
        receiptClass: String,
        queuedAtMs: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let durableNowMs = storedFloorMs

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO receipts (generation, inst, batch_id, result, reason, class, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'rejected', ?, ?, ?, ?, 0)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (generation as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (batchId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, (reason as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, (receiptClass as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 6, Int64(queuedAtMs))
            sqlite3_bind_int64(stmt, 7, Int64(durableNowMs))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        let rowBytes = Self.receiptDedupBytes(generation: generation, inst: inst, batchId: batchId, periodId: nil, reason: reason, receiptClass: receiptClass)
        heldDedupBytes += rowBytes
    }

    public func commitBatch(
        batch: BrowserDecodedBatch,
        nowMs: UInt64,
        civilDate: Date,
        timeZone: TimeZone
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let gen = activeGeneration, gen == batch.destinationGeneration else {
            throw NSError(domain: "BrowserIntakeStore", code: 10, userInfo: [NSLocalizedDescriptionKey: "stale_generation"])
        }

        let durableNowMs = max(storedFloorMs, nowMs)
        _ = updateFloorMsLocked(wallNowMs: durableNowMs)

        var pid = currentOpenPeriodId ?? UUID().uuidString
        if currentOpenPeriodId == nil {
            currentOpenPeriodId = pid
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (gen as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, Int64(durableNowMs))
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        // Calculate record bytes
        var batchBytesData = Data()
        for rec in batch.records {
            batchBytesData.append(rec.rawSlice)
            batchBytesData.append(0x0A) // '\n'
        }

        var currentCommittedLen = 0
        var pStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT committed_length FROM periods WHERE period_id = ?", -1, &pStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(pStmt, 1, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(pStmt) == SQLITE_ROW {
                currentCommittedLen = Int(sqlite3_column_int64(pStmt, 0))
            }
        }
        sqlite3_finalize(pStmt)

        // Check size pressure
        if currentCommittedLen + batchBytesData.count > projection.policy.file && currentCommittedLen > 0 {
            // Finalize current open period
            try finalizePeriodInternal(periodId: pid, reason: "size_pressure", civilDate: civilDate, timeZone: timeZone)
            guard let nextPid = currentOpenPeriodId else {
                throw NSError(domain: "BrowserIntakeStore", code: 11, userInfo: [NSLocalizedDescriptionKey: "No open period after rotation"])
            }
            pid = nextPid
            currentCommittedLen = 0
        }

        // Re-check quota while lock is held before file append
        let newDedupBytes = Self.receiptDedupBytes(generation: gen, inst: batch.inst, batchId: batch.batchId, periodId: pid, reason: nil, receiptClass: nil)
        if isQuotaFull(additionalBytes: batchBytesData.count, additionalDedupBytes: newDedupBytes) {
            throw NSError(domain: "BrowserIntakeStore", code: 13, userInfo: [NSLocalizedDescriptionKey: "resource_exhausted"])
        }

        let finalFileURL = periodFileURL(for: pid)
        let finalPeriodDir = finalFileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: finalPeriodDir.path) {
            try FileManager.default.createDirectory(at: finalPeriodDir, withIntermediateDirectories: true)
            Self.fsyncParent(of: finalPeriodDir)
        }

        // 1. Append record bytes
        if !FileManager.default.fileExists(atPath: finalFileURL.path) {
            FileManager.default.createFile(atPath: finalFileURL.path, contents: nil)
            Self.fsyncParent(of: finalFileURL)
        }

        let fileHandle = try FileHandle(forWritingTo: finalFileURL)
        fileHandle.seekToEndOfFile()
        fileHandle.write(batchBytesData)

        // 2. Synchronize
        try fileHandle.synchronize()

        if crashPoint == .afterFileSync {
            try fileHandle.close()
            throw NSError(domain: "BrowserIntakeStore", code: 99, userInfo: [NSLocalizedDescriptionKey: "Crash after file sync"])
        }

        if crashPoint == .failCommit {
            try fileHandle.truncate(atOffset: UInt64(currentCommittedLen))
            try fileHandle.synchronize()
            try fileHandle.close()
            throw NSError(domain: "BrowserIntakeStore", code: 98, userInfo: [NSLocalizedDescriptionKey: "Commit failed"])
        }

        // 3. BEGIN IMMEDIATE transaction
        try execute("BEGIN IMMEDIATE;")

        let newCommittedLen = currentCommittedLen + batchBytesData.count
        do {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO receipts (generation, inst, batch_id, result, period_id, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'accepted', ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (gen as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (batch.inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (batch.batchId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 5, Int64(batch.queuedAtMs))
                sqlite3_bind_int64(stmt, 6, Int64(durableNowMs))
                sqlite3_bind_int64(stmt, 7, Int64(batchBytesData.count))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    sqlite3_finalize(stmt)
                    throw NSError(domain: "BrowserIntakeStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to insert receipt"])
                }
                sqlite3_finalize(stmt)
            } else {
                throw NSError(domain: "BrowserIntakeStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare insert receipt"])
            }

            // Insert contexts
            for rec in batch.records {
                var cStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO period_contexts (period_id, inst, ctx, initialized_at_ms) VALUES (?, ?, ?, ?)", -1, &cStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(cStmt, 1, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(cStmt, 2, (batch.inst as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(cStmt, 3, (rec.ctx as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(cStmt, 4, Int64(durableNowMs))
                    _ = sqlite3_step(cStmt)
                }
                sqlite3_finalize(cStmt)
            }

            // Update period committed_length
            var uStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE periods SET committed_length = ? WHERE period_id = ?", -1, &uStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(uStmt, 1, Int64(newCommittedLen))
                sqlite3_bind_text(uStmt, 2, (pid as NSString).utf8String, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(uStmt)
            }
            sqlite3_finalize(uStmt)

            // 4. COMMIT
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            try? fileHandle.truncate(atOffset: UInt64(currentCommittedLen))
            try? fileHandle.synchronize()
            try? fileHandle.close()
            throw error
        }

        try fileHandle.close()

        heldPayloadBytes += batchBytesData.count
        heldDedupBytes += newDedupBytes
        if earliestHeldMs == 0 || durableNowMs < earliestHeldMs {
            earliestHeldMs = durableNowMs
        }

        if crashPoint == .afterCommit {
            throw NSError(domain: "BrowserIntakeStore", code: 97, userInfo: [NSLocalizedDescriptionKey: "Crash after commit"])
        }

        return pid
    }

    public func finalizePeriod(
        periodId: String,
        reason: String,
        civilDate: Date,
        timeZone: TimeZone
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try finalizePeriodInternal(periodId: periodId, reason: reason, civilDate: civilDate, timeZone: timeZone)
    }

    private func finalizePeriodInternal(
        periodId: String,
        reason: String,
        civilDate: Date,
        timeZone: TimeZone
    ) throws {
        let fileURL = periodFileURL(for: periodId)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let fh = try? FileHandle(forWritingTo: fileURL)
            try? fh?.synchronize()
            try? fh?.close()
            Self.fsyncParent(of: fileURL)
        }

        if crashPoint == .afterFinalizeSync {
            throw NSError(domain: "BrowserIntakeStore", code: 96, userInfo: [NSLocalizedDescriptionKey: "Crash after finalize sync"])
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = timeZone
        let dayStr = dayFormatter.string(from: civilDate)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        timeFormatter.timeZone = timeZone
        let timePrefix = timeFormatter.string(from: civilDate)

        // Calculate sha256 and size
        var sha256Hex = ""
        var fileSize = 0
        if let data = try? Data(contentsOf: fileURL) {
            fileSize = data.count
            let digest = SHA256.hash(data: data)
            sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        }

        let nowMs = UInt64(civilDate.timeIntervalSince1970 * 1000.0)
        let durableNowMs = max(storedFloorMs, nowMs)
        _ = updateFloorMsLocked(wallNowMs: durableNowMs)

        var createdAtMs: UInt64 = durableNowMs
        var cStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT created_at_ms FROM periods WHERE period_id = ?", -1, &cStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(cStmt, 1, (periodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(cStmt) == SQLITE_ROW {
                createdAtMs = UInt64(sqlite3_column_int64(cStmt, 0))
            }
        }
        sqlite3_finalize(cStmt)

        let len = max(1, (durableNowMs >= createdAtMs ? (durableNowMs - createdAtMs) : 0) / 1000)
        let requestedSegment = "\(timePrefix)_\(len)"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE periods SET state = 'finalized', requested_day = ?, requested_segment = ?, file_sha256 = ?, size = ?, finalized_at_ms = ? WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (dayStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (requestedSegment as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (sha256Hex as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(fileSize))
            sqlite3_bind_int64(stmt, 5, Int64(durableNowMs))
            sqlite3_bind_text(stmt, 6, (periodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        if currentOpenPeriodId == periodId {
            currentOpenPeriodId = nil
            // Open next empty period for intake to stay permitted
            if let gen = activeGeneration {
                let nextPid = UUID().uuidString
                var nStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)", -1, &nStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(nStmt, 1, (nextPid as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(nStmt, 2, (gen as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(nStmt, 3, Int64(durableNowMs))
                    _ = sqlite3_step(nStmt)
                }
                sqlite3_finalize(nStmt)
                self.currentOpenPeriodId = nextPid
            }
        }
    }

    public func releaseProven(periodId: String) {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE periods SET state = 'delivered' WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (periodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        recalculateCounters()
    }

    public func garbageCollectExpiredTombstones(nowMs: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let floor = max(storedFloorMs, nowMs)
        if floor >= projection.policy.acceptedRetentionMs {
            let cutoff = floor - projection.policy.acceptedRetentionMs
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM receipts WHERE result = 'rejected' AND reason = 'expired_unaccepted' AND accepted_at_ms IS NOT NULL AND accepted_at_ms <= ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(cutoff))
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            recalculateCounters()
        }
    }

    public func getOpenPeriodId() -> String? {
        lock.withLock { currentOpenPeriodId }
    }

    public func getActiveGeneration() -> String? {
        lock.withLock { activeGeneration }
    }

    public func getPeriod(periodId: String) -> BrowserStoredPeriod? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT generation, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key FROM periods WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (periodId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let gen = String(cString: sqlite3_column_text(stmt, 0))
                let state = String(cString: sqlite3_column_text(stmt, 1))
                let rDay = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let rSeg = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let sha = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let size = Int(sqlite3_column_int64(stmt, 5))
                let cLen = Int(sqlite3_column_int64(stmt, 6))
                let cAt = UInt64(sqlite3_column_int64(stmt, 7))
                let fAt = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 8)) : nil
                let cKey = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                return BrowserStoredPeriod(
                    periodId: periodId,
                    generation: gen,
                    state: state,
                    requestedDay: rDay,
                    requestedSegment: rSeg,
                    fileSha256: sha,
                    size: size,
                    committedLength: cLen,
                    createdAtMs: cAt,
                    finalizedAtMs: fAt,
                    canonicalKey: cKey
                )
            }
        }
        return nil
    }
}

#endif
