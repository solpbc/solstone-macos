// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Darwin
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum BrowserIntakeStoreError: Error, Equatable, Sendable {
    case duplicateAccepted(periodId: String)
    case resourceExhausted
    case staleGeneration
    case localIO
}

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
    private var _isPaused: Bool = false
    public var isPaused: Bool {
        lock.withLock { _isPaused }
    }
    private var isStoreFailed: Bool = false

    private var activeGeneration: String?
    private var activeIdentityToken: String?
    private var currentOpenPeriodId: String?

    private var storedFloorMs: UInt64 = 0
    private var observedFloorMs: UInt64 = 0
    private var earliestHeldMs: UInt64 = 0
    private var heldPayloadBytes: Int = 0
    private var heldDedupBytes: Int = 0
    private var heldStagingBytes: Int = 0
    private var fileRecoveryRequired = false

    public static func receiptDedupBytes(generation: String, inst: String, batchId: String, periodId: String?, reason: String?, receiptClass: String?) -> Int {
        generation.utf8.count + inst.utf8.count + batchId.utf8.count + (periodId?.utf8.count ?? 0) + (reason?.utf8.count ?? 0) + (receiptClass?.utf8.count ?? 0)
    }

    public static func batchSeenDedupBytes(generation: String, inst: String, batchId: String) -> Int {
        generation.utf8.count + inst.utf8.count + batchId.utf8.count
    }

    /// Lowercase hex SHA-256 of the pairing identity token. The token itself is never stored.
    public static func identityDigest(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let data = Data(value.utf8)
        if data.isEmpty {
            sqlite3_bind_text(stmt, index, "", 0, SQLITE_TRANSIENT)
            return
        }
        data.withUnsafeBytes { raw in
            sqlite3_bind_text(
                stmt,
                index,
                raw.bindMemory(to: CChar.self).baseAddress,
                Int32(data.count),
                SQLITE_TRANSIENT
            )
        }
    }

    private static func readText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        _ = sqlite3_column_text(stmt, index)
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        if count == 0 { return "" }
        return String(bytes: UnsafeRawBufferPointer(start: ptr, count: count), encoding: .utf8)
    }

    public func setPaused(_ paused: Bool) {
        lock.withLock { _isPaused = paused }
    }

    public func setStoreFailed(_ failed: Bool) {
        lock.withLock { isStoreFailed = failed }
    }

    public func storeIsFailed() -> Bool {
        lock.withLock { isStoreFailed }
    }

    public func setHeldStagingBytes(_ bytes: Int) {
        lock.withLock { heldStagingBytes = max(0, bytes) }
    }

    public func getActiveIdentityToken() -> String? {
        lock.withLock { activeIdentityToken }
    }

    public init(rootURL: URL, projection: BrowserContractProjection) throws {
        self.rootURL = rootURL
        self.projection = projection

        try Self.rejectSymlink(rootURL)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Self.chmodPath(rootURL, 0o700)
        let periodsDir = rootURL.appendingPathComponent("periods")
        try Self.rejectSymlink(periodsDir)
        try FileManager.default.createDirectory(at: periodsDir, withIntermediateDirectories: true)
        try Self.chmodPath(periodsDir, 0o700)
        try Self.fsyncParent(of: periodsDir)

        let dbURL = rootURL.appendingPathComponent("intake.sqlite")
        try Self.rejectSymlink(dbURL)
        if FileManager.default.fileExists(atPath: dbURL.path) {
            try Self.assertRegularFile(dbURL)
        }
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        try Self.chmodPath(dbURL, 0o600)
        try Self.fsyncParent(of: dbURL)

        try initSchema()
        try recoverAndLoadState()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func fsyncParent(of fileURL: URL) throws {
        let parentURL = fileURL.deletingLastPathComponent()
        let fd = open(parentURL.path, O_RDONLY)
        guard fd >= 0 else { throw BrowserIntakeStoreError.localIO }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw BrowserIntakeStoreError.localIO }
    }

    private static func rejectSymlink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw BrowserIntakeStoreError.localIO
        }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            throw BrowserIntakeStoreError.localIO
        }
    }

    private static func assertRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw BrowserIntakeStoreError.localIO }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK || kind != S_IFREG {
            throw BrowserIntakeStoreError.localIO
        }
    }

    private static func chmodPath(_ url: URL, _ mode: mode_t) throws {
        if chmod(url.path, mode) != 0 {
            throw BrowserIntakeStoreError.localIO
        }
    }

    private static func fileByteCount(_ url: URL) throws -> Int? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw BrowserIntakeStoreError.localIO
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK || kind != S_IFREG {
            throw BrowserIntakeStoreError.localIO
        }
        return Int(info.st_size)
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
                self.activeGeneration = Self.readText(stmt, 0)
                self.activeIdentityToken = Self.readText(stmt, 1)
            }
        }
        sqlite3_finalize(stmt)

        if self.activeGeneration == nil {
            var eStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT identity_token FROM epoch ORDER BY id DESC LIMIT 1", -1, &eStmt, nil) == SQLITE_OK {
                if sqlite3_step(eStmt) == SQLITE_ROW {
                    self.activeIdentityToken = Self.readText(eStmt, 0)
                }
            }
            sqlite3_finalize(eStmt)
        }

        try recoverPeriodFiles()

        if let gen = activeGeneration {
            if sqlite3_prepare_v2(db, "SELECT period_id FROM periods WHERE generation = ? AND state = 'open' ORDER BY created_at_ms DESC LIMIT 1", -1, &stmt, nil) == SQLITE_OK {
                Self.bindText(stmt, 1, gen)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    self.currentOpenPeriodId = Self.readText(stmt, 0)
                }
            }
            sqlite3_finalize(stmt)
        }

        // Recalculate and load counters
        recalculateCounters()
    }

    private func recoverPeriodFiles() throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT period_id, committed_length, state FROM periods WHERE state IN ('open', 'finalized')", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pid = Self.readText(stmt, 0), let state = Self.readText(stmt, 2) else {
                isStoreFailed = true
                continue
            }
            let committed = Int(sqlite3_column_int64(stmt, 1))
            let fileURL = periodFileURL(for: pid)
            let size: Int?
            do {
                size = try Self.fileByteCount(fileURL)
            } catch {
                isStoreFailed = true
                continue
            }
            if size == nil {
                if committed > 0 || state == "finalized" {
                    isStoreFailed = true
                }
                continue
            }
            let bytes = size ?? 0
            if bytes < committed {
                isStoreFailed = true
                continue
            }
            if state == "finalized" && bytes != committed {
                isStoreFailed = true
                continue
            }
            if state == "open" && bytes > committed {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.truncate(atOffset: UInt64(committed))
                try handle.synchronize()
                try handle.close()
            }
        }
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
                let g = Int(sqlite3_column_bytes(stmt, 0))
                let i = Int(sqlite3_column_bytes(stmt, 1))
                let b = Int(sqlite3_column_bytes(stmt, 2))
                let p = Int(sqlite3_column_bytes(stmt, 3))
                let r = Int(sqlite3_column_bytes(stmt, 4))
                let c = Int(sqlite3_column_bytes(stmt, 5))
                dedupBytes += (g + i + b + p + r + c)
            }
        }
        sqlite3_finalize(stmt)
        if sqlite3_prepare_v2(db, "SELECT generation, inst, batch_id FROM batch_seen", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let g = Int(sqlite3_column_bytes(stmt, 0))
                let i = Int(sqlite3_column_bytes(stmt, 1))
                let b = Int(sqlite3_column_bytes(stmt, 2))
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

    public func periodFileByteCount(periodId: String) throws -> Int {
        try Self.fileByteCount(periodFileURL(for: periodId)) ?? 0
    }

    public func periodFileURL(for periodId: String) -> URL {
        rootURL.appendingPathComponent("periods").appendingPathComponent(periodId).appendingPathComponent("browser_pages.jsonl")
    }

    public func getFloorMs() -> UInt64 {
        lock.withLock { storedFloorMs }
    }

    private func updateFloorMsLocked(wallNowMs: UInt64) throws -> UInt64 {
        observedFloorMs = max(observedFloorMs, wallNowMs)
        let target = max(storedFloorMs, observedFloorMs)
        if target > storedFloorMs {
            try execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('floor_ms', \(target));")
            storedFloorMs = target
        }
        return max(storedFloorMs, observedFloorMs)
    }

    public func updateFloorMs(wallNowMs: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return try updateFloorMsLocked(wallNowMs: wallNowMs)
    }

    public func currentStatus(nowMs: UInt64, monotonicFreshnessMs: UInt64) -> [String: Any] {
        _ = monotonicFreshnessMs
        lock.lock()
        defer { lock.unlock() }

        observedFloorMs = max(observedFloorMs, nowMs)
        if observedFloorMs > storedFloorMs {
            if (try? execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('floor_ms', \(observedFloorMs));")) != nil {
                storedFloorMs = observedFloorMs
            }
        }
        let freshness = projection.policy.freshnessMaxMs
        let floor = max(storedFloorMs, observedFloorMs)

        var isStale = false
        if earliestHeldMs > 0 && floor >= earliestHeldMs && (floor - earliestHeldMs) >= projection.policy.spoolAgeMs {
            isStale = true
        }

        let isFull = (try? isQuotaFullLocked()) ?? true

        if isStoreFailed {
            let res: [String: Any] = [
                "type": "state",
                "capture": "unavailable",
                "delivery": "failed",
                "failure": "local_io",
                "freshness_ms": freshness,
                "destination_generation": activeGeneration != nil ? (activeGeneration! as Any) : NSNull(),
                "period_id": currentOpenPeriodId != nil ? (currentOpenPeriodId! as Any) : NSNull(),
                "custody": ["full": isFull, "stale": isStale]
            ]
            return res
        }

        let held = heldPayloadBytes > 0
        let custody: [String: Bool] = ["full": held && isFull, "stale": held && isStale]
        let heldDelivery = held ? "kept_locally" : "unknown"

        guard let identity = activeIdentityToken, !identity.isEmpty else {
            return [
                "type": "state",
                "capture": "not_paired",
                "delivery": held ? "kept_locally" : "unknown",
                "freshness_ms": freshness,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
                "custody": custody
            ]
        }

        guard let gen = activeGeneration, !gen.isEmpty else {
            return [
                "type": "state",
                "capture": "unavailable",
                "delivery": heldDelivery,
                "freshness_ms": freshness,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
                "custody": custody
            ]
        }

        let periodId = currentOpenPeriodId
        var delivery = heldPayloadBytes > 0 ? "kept_locally" : "idle"
        var capture = isFull ? "intake_off" : "permitted"
        if _isPaused {
            capture = "paused"
        }
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

        let digest = Self.identityDigest(of: identityToken)
        if let currentGen = activeGeneration, activeIdentityToken == digest {
            return currentGen
        }

        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        let newGen = UUID().uuidString
        let newPeriodId = UUID().uuidString

        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO epoch (identity_token, destination_generation, status, created_at_ms) VALUES (?, ?, 'active', ?)", -1, &stmt, nil) == SQLITE_OK else {
                throw BrowserIntakeStoreError.localIO
            }
            Self.bindText(stmt, 1, digest)
            Self.bindText(stmt, 2, newGen)
            sqlite3_bind_int64(stmt, 3, Int64(durableNowMs))
            let epochRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard epochRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }

            guard sqlite3_prepare_v2(db, "INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)", -1, &stmt, nil) == SQLITE_OK else {
                throw BrowserIntakeStoreError.localIO
            }
            Self.bindText(stmt, 1, newPeriodId)
            Self.bindText(stmt, 2, newGen)
            sqlite3_bind_int64(stmt, 3, Int64(durableNowMs))
            let periodRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard periodRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        self.activeGeneration = newGen
        self.activeIdentityToken = digest
        self.currentOpenPeriodId = newPeriodId
        return newGen
    }

    public func retireIfTokenChanged(newToken: String?, nowMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }

        let digest = newToken.map { Self.identityDigest(of: $0) }
        if activeIdentityToken == digest && activeGeneration != nil && digest != nil {
            return
        }
        if activeGeneration == nil && activeIdentityToken == digest {
            return
        }

        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))

        if let openPid = currentOpenPeriodId {
            let fileURL = periodFileURL(for: openPid)
            if let bytes = try Self.fileByteCount(fileURL), bytes > 0 {
                try finalizePeriodInternal(
                    periodId: openPid,
                    reason: "identity_retirement",
                    civilDate: Date(timeIntervalSince1970: Double(durableNowMs) / 1000.0),
                    timeZone: TimeZone.current
                )
            }
        }

        try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")
        self.activeGeneration = nil
        self.activeIdentityToken = digest
        self.currentOpenPeriodId = nil
    }

    public func lookupReceipt(generation: String, inst: String, batchId: String) -> BrowserStoredReceipt? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT result, period_id, reason, class, queued_at_ms, accepted_at_ms, size_bytes FROM receipts WHERE generation = ? AND inst = ? AND batch_id = ?", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, 1, generation)
            Self.bindText(stmt, 2, inst)
            Self.bindText(stmt, 3, batchId)

            if sqlite3_step(stmt) == SQLITE_ROW {
                let result = Self.readText(stmt, 0) ?? ""
                let periodId = Self.readText(stmt, 1)
                let reason = Self.readText(stmt, 2)
                let rClass = Self.readText(stmt, 3)
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
            Self.bindText(stmt, 1, periodId)
            Self.bindText(stmt, 2, inst)
            Self.bindText(stmt, 3, ctx)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
        return false
    }

    public func recordBatchSeen(generation: String, inst: String, batchId: String, queuedAtMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }

        let rowBytes = Self.batchSeenDedupBytes(generation: generation, inst: inst, batchId: batchId)
        if try isQuotaFullLocked(additionalBytes: 0, additionalDedupBytes: rowBytes) {
            throw BrowserIntakeStoreError.resourceExhausted
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO batch_seen (generation, inst, batch_id, queued_at_ms) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, generation)
        Self.bindText(stmt, 2, inst)
        Self.bindText(stmt, 3, batchId)
        sqlite3_bind_int64(stmt, 4, Int64(queuedAtMs))
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        if sqlite3_changes(db) == 1 {
            heldDedupBytes += rowBytes
        }
    }

    public func getFirstSeenQueuedAt(generation: String, inst: String, batchId: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT queued_at_ms FROM batch_seen WHERE generation = ? AND inst = ? AND batch_id = ?", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, 1, generation)
            Self.bindText(stmt, 2, inst)
            Self.bindText(stmt, 3, batchId)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return UInt64(sqlite3_column_int64(stmt, 0))
            }
        }
        return nil
    }

    public func getEarliestHeldMs() -> UInt64 {
        lock.withLock { earliestHeldMs }
    }

    private func sqliteFootprintBytes() throws -> Int {
        var total = 0
        var sawDatabase = false
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm"] {
            let url = rootURL.appendingPathComponent(name)
            if let bytes = try Self.fileByteCount(url) {
                total += bytes
                if name == "intake.sqlite" { sawDatabase = true }
            }
        }
        if !sawDatabase { throw BrowserIntakeStoreError.localIO }
        return total
    }

    public func projectedSpoolBytes(additionalPayloadBytes: Int = 0, additionalDedupBytes: Int = 0) -> Int {
        let sqliteSize: Int
        do {
            sqliteSize = try sqliteFootprintBytes()
        } catch {
            return Int.max
        }
        let deliveryReserve = heldPayloadBytes + additionalPayloadBytes
        return heldPayloadBytes + additionalPayloadBytes + heldDedupBytes + additionalDedupBytes + heldStagingBytes + sqliteSize + deliveryReserve
    }

    private func isQuotaFullLocked(additionalBytes: Int = 0, additionalDedupBytes: Int = 0) throws -> Bool {
        let sqliteSize = try sqliteFootprintBytes()
        let payload = additionalBytes == 0 && additionalDedupBytes == 0 ? 1 : additionalBytes
        let deliveryReserve = heldPayloadBytes + payload
        let projected = heldPayloadBytes + payload + heldDedupBytes + additionalDedupBytes + heldStagingBytes + sqliteSize + deliveryReserve
        return projected > projection.policy.spoolBytes
    }

    public func isQuotaFull(additionalBytes: Int = 0, additionalDedupBytes: Int = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (try? isQuotaFullLocked(additionalBytes: additionalBytes, additionalDedupBytes: additionalDedupBytes)) ?? true
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
        let rowBytes = Self.receiptDedupBytes(generation: generation, inst: inst, batchId: batchId, periodId: nil, reason: reason, receiptClass: receiptClass)
        if try isQuotaFullLocked(additionalBytes: 0, additionalDedupBytes: rowBytes) {
            throw BrowserIntakeStoreError.resourceExhausted
        }
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO receipts (generation, inst, batch_id, result, reason, class, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'rejected', ?, ?, ?, ?, 0)", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, generation)
        Self.bindText(stmt, 2, inst)
        Self.bindText(stmt, 3, batchId)
        Self.bindText(stmt, 4, reason)
        Self.bindText(stmt, 5, receiptClass)
        sqlite3_bind_int64(stmt, 6, Int64(queuedAtMs))
        sqlite3_bind_int64(stmt, 7, Int64(durableNowMs))
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        if sqlite3_changes(db) == 1 {
            heldDedupBytes += rowBytes
        }
    }

    private func ensureFileRecoveryLocked() throws {
        guard fileRecoveryRequired else { return }
        try recoverPeriodFiles()
        if isStoreFailed { throw BrowserIntakeStoreError.localIO }
        fileRecoveryRequired = false
    }

    private func ensureOpenPeriodLocked(nowMs: UInt64) throws -> String {
        if let pid = currentOpenPeriodId { return pid }
        guard let gen = activeGeneration else { throw BrowserIntakeStoreError.staleGeneration }
        let pid = UUID().uuidString
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, pid)
        Self.bindText(stmt, 2, gen)
        sqlite3_bind_int64(stmt, 3, Int64(nowMs))
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        currentOpenPeriodId = pid
        return pid
    }

    private func committedLengthLocked(_ periodId: String) throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT committed_length FROM periods WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, periodId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func existingAcceptedPeriodLocked(generation: String, inst: String, batchId: String) throws -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT result, period_id FROM receipts WHERE generation = ? AND inst = ? AND batch_id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, generation)
        Self.bindText(stmt, 2, inst)
        Self.bindText(stmt, 3, batchId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard Self.readText(stmt, 0) == "accepted" else { return nil }
        return Self.readText(stmt, 1)
    }

    private func rollbackFile(_ handle: FileHandle, to length: Int) throws {
        do {
            try handle.truncate(atOffset: UInt64(length))
            try handle.synchronize()
            try handle.close()
        } catch {
            fileRecoveryRequired = true
            try? handle.close()
            throw BrowserIntakeStoreError.localIO
        }
    }

    public func selectPeriodForBatch(byteCount: Int, civilDate: Date, timeZone: TimeZone, nowMs: UInt64) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if isStoreFailed { throw BrowserIntakeStoreError.localIO }
        try ensureFileRecoveryLocked()
        _ = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        let pid = try ensureOpenPeriodLocked(nowMs: max(storedFloorMs, nowMs))
        let committed = try committedLengthLocked(pid)
        if committed + byteCount > projection.policy.file && committed > 0 {
            try finalizePeriodInternal(periodId: pid, reason: "size_pressure", civilDate: civilDate, timeZone: timeZone)
        }
        guard let selected = currentOpenPeriodId else { throw BrowserIntakeStoreError.localIO }
        let selectedCommitted = try committedLengthLocked(selected)
        if selectedCommitted + byteCount > projection.policy.file {
            throw BrowserIntakeStoreError.resourceExhausted
        }
        return selected
    }

    public func commitBatch(
        batch: BrowserDecodedBatch,
        nowMs: UInt64,
        civilDate: Date,
        timeZone: TimeZone
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if isStoreFailed { throw BrowserIntakeStoreError.localIO }
        try ensureFileRecoveryLocked()
        guard let gen = activeGeneration, gen == batch.destinationGeneration else {
            throw BrowserIntakeStoreError.staleGeneration
        }

        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        let pid = try ensureOpenPeriodLocked(nowMs: durableNowMs)

        // Calculate record bytes
        var batchBytesData = Data()
        for rec in batch.records {
            batchBytesData.append(rec.rawSlice)
            batchBytesData.append(0x0A) // '\n'
        }

        var currentCommittedLen = 0
        var pStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT committed_length FROM periods WHERE period_id = ?", -1, &pStmt, nil) == SQLITE_OK {
            Self.bindText(pStmt, 1, pid)
            if sqlite3_step(pStmt) == SQLITE_ROW {
                currentCommittedLen = Int(sqlite3_column_int64(pStmt, 0))
            }
        }
        sqlite3_finalize(pStmt)

        if currentCommittedLen + batchBytesData.count > projection.policy.file {
            throw BrowserIntakeStoreError.resourceExhausted
        }

        let newDedupBytes = Self.receiptDedupBytes(generation: gen, inst: batch.inst, batchId: batch.batchId, periodId: pid, reason: nil, receiptClass: nil)
        if try isQuotaFullLocked(additionalBytes: batchBytesData.count, additionalDedupBytes: newDedupBytes) {
            throw BrowserIntakeStoreError.resourceExhausted
        }

        let finalFileURL = periodFileURL(for: pid)
        let finalPeriodDir = finalFileURL.deletingLastPathComponent()
        try Self.rejectSymlink(finalPeriodDir)
        if !FileManager.default.fileExists(atPath: finalPeriodDir.path) {
            try FileManager.default.createDirectory(at: finalPeriodDir, withIntermediateDirectories: true)
            try Self.chmodPath(finalPeriodDir, 0o700)
            try Self.fsyncParent(of: finalPeriodDir)
        }
        try Self.rejectSymlink(finalFileURL)
        if !FileManager.default.fileExists(atPath: finalFileURL.path) {
            FileManager.default.createFile(atPath: finalFileURL.path, contents: nil)
            try Self.chmodPath(finalFileURL, 0o600)
            try Self.fsyncParent(of: finalFileURL)
        } else {
            try Self.assertRegularFile(finalFileURL)
        }

        let fileHandle = try FileHandle(forWritingTo: finalFileURL)
        do {
            try fileHandle.truncate(atOffset: UInt64(currentCommittedLen))
            try fileHandle.seek(toOffset: UInt64(currentCommittedLen))
            try fileHandle.write(contentsOf: batchBytesData)
            try fileHandle.synchronize()
        } catch {
            try? fileHandle.close()
            fileRecoveryRequired = true
            throw BrowserIntakeStoreError.localIO
        }

        if crashPoint == .afterFileSync {
            try fileHandle.close()
            fileRecoveryRequired = true
            throw BrowserIntakeStoreError.localIO
        }

        if crashPoint == .failCommit {
            try rollbackFile(fileHandle, to: currentCommittedLen)
            throw BrowserIntakeStoreError.resourceExhausted
        }

        try execute("BEGIN IMMEDIATE;")
        let newCommittedLen = currentCommittedLen + batchBytesData.count
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO receipts (generation, inst, batch_id, result, period_id, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'accepted', ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
                throw BrowserIntakeStoreError.localIO
            }
            Self.bindText(stmt, 1, gen)
            Self.bindText(stmt, 2, batch.inst)
            Self.bindText(stmt, 3, batch.batchId)
            Self.bindText(stmt, 4, pid)
            sqlite3_bind_int64(stmt, 5, Int64(batch.queuedAtMs))
            sqlite3_bind_int64(stmt, 6, Int64(durableNowMs))
            sqlite3_bind_int64(stmt, 7, Int64(batchBytesData.count))
            let receiptRC = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            if receiptRC == SQLITE_CONSTRAINT {
                if let existing = try existingAcceptedPeriodLocked(generation: gen, inst: batch.inst, batchId: batch.batchId) {
                    throw BrowserIntakeStoreError.duplicateAccepted(periodId: existing)
                }
                throw BrowserIntakeStoreError.localIO
            }
            guard receiptRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }

            for rec in batch.records where rec.t == "segment_start" {
                var cStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO period_contexts (period_id, inst, ctx, initialized_at_ms) VALUES (?, ?, ?, ?)", -1, &cStmt, nil) == SQLITE_OK else {
                    throw BrowserIntakeStoreError.localIO
                }
                Self.bindText(cStmt, 1, pid)
                Self.bindText(cStmt, 2, batch.inst)
                Self.bindText(cStmt, 3, rec.ctx)
                sqlite3_bind_int64(cStmt, 4, Int64(durableNowMs))
                let contextRC = sqlite3_step(cStmt)
                sqlite3_finalize(cStmt)
                guard contextRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }

            var uStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE periods SET committed_length = ? WHERE period_id = ?", -1, &uStmt, nil) == SQLITE_OK else {
                throw BrowserIntakeStoreError.localIO
            }
            sqlite3_bind_int64(uStmt, 1, Int64(newCommittedLen))
            Self.bindText(uStmt, 2, pid)
            let updateRC = sqlite3_step(uStmt)
            sqlite3_finalize(uStmt)
            guard updateRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            guard sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            try rollbackFile(fileHandle, to: currentCommittedLen)
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
        if let existing = getPeriodLocked(periodId: periodId), existing.state != "open" {
            return
        }
        let fileURL = periodFileURL(for: periodId)
        if let bytes = try Self.fileByteCount(fileURL), bytes > 0 {
            let fh = try FileHandle(forWritingTo: fileURL)
            try fh.synchronize()
            try fh.close()
            try Self.fsyncParent(of: fileURL)
        }

        if crashPoint == .afterFinalizeSync {
            throw BrowserIntakeStoreError.localIO
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
        let fileData: Data
        do {
            if (try Self.fileByteCount(fileURL)) == nil {
                fileData = Data()
            } else {
                fileData = try Data(contentsOf: fileURL)
            }
        } catch {
            throw BrowserIntakeStoreError.localIO
        }
        let fileSize = fileData.count
        let sha256Hex = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

        let nowMs = UInt64(civilDate.timeIntervalSince1970 * 1000.0)
        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))

        var createdAtMs: UInt64 = durableNowMs
        var cStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT created_at_ms, state FROM periods WHERE period_id = ?", -1, &cStmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(cStmt, 1, periodId)
        guard sqlite3_step(cStmt) == SQLITE_ROW else {
            sqlite3_finalize(cStmt)
            throw BrowserIntakeStoreError.localIO
        }
        createdAtMs = UInt64(sqlite3_column_int64(cStmt, 0))
        let state = Self.readText(cStmt, 1)
        sqlite3_finalize(cStmt)
        if state != "open" { return }

        let len = max(1, (durableNowMs >= createdAtMs ? (durableNowMs - createdAtMs) : 0) / 1000)
        let requestedSegment = "\(timePrefix)_\(len)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE periods SET state = 'finalized', requested_day = ?, requested_segment = ?, file_sha256 = ?, size = ?, finalized_at_ms = ? WHERE period_id = ? AND state = 'open'", -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
        Self.bindText(stmt, 1, dayStr)
        Self.bindText(stmt, 2, requestedSegment)
        Self.bindText(stmt, 3, sha256Hex)
        sqlite3_bind_int64(stmt, 4, Int64(fileSize))
        sqlite3_bind_int64(stmt, 5, Int64(durableNowMs))
        Self.bindText(stmt, 6, periodId)
        let updateRC = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard updateRC == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw BrowserIntakeStoreError.localIO
        }

        if currentOpenPeriodId == periodId {
            currentOpenPeriodId = nil
            if activeGeneration != nil {
                do {
                    _ = try ensureOpenPeriodLocked(nowMs: durableNowMs)
                } catch {
                    isStoreFailed = true
                    throw error
                }
            }
        }
    }

    public func releaseProven(periodId: String) {
        lock.lock()
        defer { lock.unlock() }

        if getPeriodLocked(periodId: periodId)?.state != "delivered" {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "UPDATE periods SET state = 'delivered' WHERE period_id = ? AND state != 'delivered'",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else {
                isStoreFailed = true
                return
            }
            Self.bindText(stmt, 1, periodId)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                isStoreFailed = true
                return
            }
        }

        let fileURL = periodFileURL(for: periodId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            recalculateCounters()
            return
        }
        do {
            try Self.assertRegularFile(fileURL)
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            isStoreFailed = true
            return
        }
        recalculateCounters()
    }

    public func recordDelivered(periodId: String, canonicalKey: String?) {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE periods SET canonical_key = ? WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK else {
            isStoreFailed = true
            return
        }
        if let canonicalKey {
            Self.bindText(stmt, 1, canonicalKey)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        Self.bindText(stmt, 2, periodId)
        guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            isStoreFailed = true
            return
        }
    }

    public func removeSegmentPeriod(generation: String, periodId: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let period = getPeriodLocked(periodId: periodId), period.generation == generation else {
            return
        }
        if period.state != "removed" {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "UPDATE periods SET state = 'removed' WHERE period_id = ? AND generation = ? AND state != 'removed'",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else {
                isStoreFailed = true
                return
            }
            Self.bindText(stmt, 1, periodId)
            Self.bindText(stmt, 2, generation)
            guard sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                isStoreFailed = true
                return
            }
        }

        let fileURL = periodFileURL(for: periodId)
        if (try? Self.fileByteCount(fileURL)) == nil && FileManager.default.fileExists(atPath: fileURL.path) {
            isStoreFailed = true
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try Self.assertRegularFile(fileURL)
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                isStoreFailed = true
                return
            }
        }
        recalculateCounters()
    }

    public func garbageCollectExpiredTombstones(nowMs: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let floor: UInt64
        do {
            floor = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        } catch {
            return
        }
        guard floor >= projection.policy.acceptedRetentionMs else { return }
        let cutoff = floor - projection.policy.acceptedRetentionMs
        do {
            try execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('gc_cutoff_ms', \(cutoff));")
        } catch {
            return
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM receipts WHERE result = 'rejected' AND reason = 'expired_unaccepted' AND accepted_at_ms IS NOT NULL AND accepted_at_ms <= ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(cutoff))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        if sqlite3_prepare_v2(db, """
            DELETE FROM batch_seen WHERE queued_at_ms <= ?
            AND NOT EXISTS (
                SELECT 1 FROM receipts r
                WHERE r.generation = batch_seen.generation
                  AND r.inst = batch_seen.inst
                  AND r.batch_id = batch_seen.batch_id
                  AND r.result = 'accepted'
            )
            """, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(cutoff))
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        recalculateCounters()
    }

    public func getOpenPeriodId() -> String? {
        lock.withLock { currentOpenPeriodId }
    }

    public func openPeriodCreatedAtMs() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let pid = currentOpenPeriodId else { return nil }
        return getPeriodLocked(periodId: pid)?.createdAtMs
    }

    public func getActiveGeneration() -> String? {
        lock.withLock { activeGeneration }
    }

    private func getPeriodLocked(periodId: String) -> BrowserStoredPeriod? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT generation, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key FROM periods WHERE period_id = ?", -1, &stmt, nil) == SQLITE_OK {
            Self.bindText(stmt, 1, periodId)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let gen = Self.readText(stmt, 0) ?? ""
                let state = Self.readText(stmt, 1) ?? ""
                let rDay = Self.readText(stmt, 2)
                let rSeg = Self.readText(stmt, 3)
                let sha = Self.readText(stmt, 4)
                let size = Int(sqlite3_column_int64(stmt, 5))
                let cLen = Int(sqlite3_column_int64(stmt, 6))
                let cAt = UInt64(sqlite3_column_int64(stmt, 7))
                let fAt = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 8)) : nil
                let cKey = Self.readText(stmt, 9)
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

    public func getPeriod(periodId: String) -> BrowserStoredPeriod? {
        lock.lock()
        defer { lock.unlock() }
        return getPeriodLocked(periodId: periodId)
    }

    public func getAllFinalizedPeriods() -> [BrowserStoredPeriod] {
        lock.lock()
        defer { lock.unlock() }

        var results: [BrowserStoredPeriod] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        if sqlite3_prepare_v2(db, "SELECT period_id, generation, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key FROM periods WHERE state = 'finalized' ORDER BY created_at_ms ASC", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pid = Self.readText(stmt, 0) ?? ""
                let gen = Self.readText(stmt, 1) ?? ""
                let state = Self.readText(stmt, 2) ?? ""
                let rDay = Self.readText(stmt, 3)
                let rSeg = Self.readText(stmt, 4)
                let sha = Self.readText(stmt, 5)
                let size = Int(sqlite3_column_int64(stmt, 6))
                let cLen = Int(sqlite3_column_int64(stmt, 7))
                let cAt = UInt64(sqlite3_column_int64(stmt, 8))
                let fAt = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 9)) : nil
                let cKey = Self.readText(stmt, 10)
                results.append(BrowserStoredPeriod(
                    periodId: pid,
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
                ))
            }
        }
        return results
    }
}

#endif
