// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import CryptoKit
import Darwin
import Foundation
import os
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum BrowserIntakeStoreError: Error, Equatable, Sendable {
    case duplicateAccepted(periodId: String)
    case resourceExhausted
    case staleGeneration
    case localIO
}

enum BrowserOpaqueString {
    static func equals(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    static func equals(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return equals(lhs, rhs)
    }
}

public enum BrowserIntakeCrashPoint: Sendable, Equatable {
    case none
    case afterFileSync
    case afterCommit
    case afterFinalizeSync
    case failCommit
}

enum BrowserIntakeIOPoint: Sendable, Equatable {
    case read
    case bind
    case step
    case begin
    case write
    case sync
    case commit
    case size
    case proof
    case finalizePublication
}

final class BrowserIntakeIOInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (@Sendable (BrowserIntakeIOPoint) throws -> Void)?
    private var sizeOverride: (@Sendable (URL, Int?) -> Int?)?

    func setFailure(_ failure: (@Sendable (BrowserIntakeIOPoint) throws -> Void)?) {
        lock.withLock { self.failure = failure }
    }

    func setSizeOverride(_ override: (@Sendable (URL, Int?) -> Int?)?) {
        lock.withLock { sizeOverride = override }
    }

    func check(_ point: BrowserIntakeIOPoint) throws {
        let action = lock.withLock { failure }
        try action?(point)
    }

    func size(for url: URL, actual: Int?) -> Int? {
        let override = lock.withLock { sizeOverride }
        return override?(url, actual) ?? actual
    }
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
    public let finalizeTimeZone: String?
    public let fileSha256: String?
    public let size: Int
    public let committedLength: Int
    public let createdAtMs: UInt64
    public let finalizedAtMs: UInt64?
    public let canonicalKey: String?
    public let deliveryBinding: String?
    public let ackDurable: Bool
    public let deliveredAtMs: UInt64?
    public let cleanupDurable: Bool
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
    let ioInjector: BrowserIntakeIOInjector
    private var db: OpaquePointer?
    private let ageClock: @Sendable () -> BrowserAgeStamp?
    private var ageCheckpoint: BrowserAgeStamp?

    public var crashPoint: BrowserIntakeCrashPoint = .none
    private var deliveryFailure: String?
    private var _isPaused: Bool = false
    public var isPaused: Bool {
        lock.withLock { _isPaused }
    }
    private var isStoreFailed: Bool = false

    private var activeGeneration: String?
    private var activeIdentityToken: String?
    private var currentOpenPeriodId: String?
    private var deliveryProofsOpen = false
    private var deliveryStopped = false

    private var storedFloorMs: UInt64 = 0
    private var observedFloorMs: UInt64 = 0
    private var earliestHeldMs: UInt64 = 0
    private var staleAnchorMs: UInt64 = 0
    private var staleElapsedHighWaterMs: UInt64 = 0
    private var heldPayloadBytes: Int = 0
    private var heldDedupBytes: Int = 0
    private var stagingDirectories: [URL] = []
    private var stagingReservations: [URL: Int] = [:]
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

    func currentDeliveryPermit() -> BrowserUploadPermit? {
        lock.withLock {
            guard deliveryProofsOpen, !deliveryStopped, !isStoreFailed,
                  let activeGeneration, let activeIdentityToken else { return nil }
            return BrowserUploadPermit(generation: activeGeneration, identityToken: activeIdentityToken)
        }
    }

    func closeDeliveryProofs() {
        lock.withLock { deliveryProofsOpen = false }
    }

    func stopDeliveryProofs() {
        lock.withLock {
            deliveryStopped = true
            deliveryProofsOpen = false
        }
    }

    func reopenDeliveryProofs() {
        lock.withLock {
            if !deliveryStopped { deliveryProofsOpen = true }
        }
    }

    private func requireCurrentDeliveryLocked(periodGeneration: String) throws {
        guard deliveryProofsOpen, !deliveryStopped, !isStoreFailed,
              let activeGeneration,
              BrowserOpaqueString.equals(activeGeneration, periodGeneration) else {
            throw BrowserIntakeStoreError.staleGeneration
        }
    }

    func registerStagingDirectory(_ url: URL, reservedBytes: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.assertNoSymlinkAncestors(url)
        stagingDirectories.append(url)
        stagingReservations[url] = max(0, reservedBytes)
        do {
            if try isQuotaFullLocked() {
                stagingDirectories.removeAll { $0 == url }
                stagingReservations.removeValue(forKey: url)
                throw BrowserIntakeStoreError.resourceExhausted
            }
        } catch {
            stagingDirectories.removeAll { $0 == url }
            stagingReservations.removeValue(forKey: url)
            throw error
        }
    }

    func releaseStagingDirectory(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.assertNoSymlinkAncestors(url)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw BrowserIntakeStoreError.localIO }
        try Self.assertNoSymlinkAncestors(url.deletingLastPathComponent())
        try fsyncParentChecked(of: url)
        stagingDirectories.removeAll { $0 == url }
        stagingReservations.removeValue(forKey: url)
    }

    func setDeliveryFailure(_ failure: String?) {
        lock.withLock { deliveryFailure = failure }
    }

    func validateMutationPath(_ url: URL) throws {
        try Self.assertNoSymlinkAncestors(url)
    }

    func stagingRootURL() -> URL {
        rootURL.appendingPathComponent("staging", isDirectory: true)
    }

    public func getActiveIdentityToken() -> String? {
        lock.withLock { activeIdentityToken }
    }

    func hasPersistedIdentityHistory() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try query("SELECT 1 FROM epoch LIMIT 1") { stmt in
                let rc = try stepChecked(stmt)
                guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
                return rc == SQLITE_ROW
            }
        } catch {
            isStoreFailed = true
            return true
        }
    }

    public convenience init(rootURL: URL, projection: BrowserContractProjection) throws {
        try self.init(rootURL: rootURL, projection: projection, ioInjector: BrowserIntakeIOInjector())
    }

    init(rootURL: URL, projection: BrowserContractProjection, ioInjector: BrowserIntakeIOInjector,
         ageClock: @escaping @Sendable () -> BrowserAgeStamp? = BrowserAgeStamp.current) throws {
        self.rootURL = rootURL
        self.projection = projection
        self.ioInjector = ioInjector
        self.ageClock = ageClock
        var stage = "root-check"
        do {
            try Self.assertNoSymlinkAncestors(rootURL)
            stage = "root-create"
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            stage = "root-chmod"
            try Self.chmodPath(rootURL, 0o700)
            let periodsDir = rootURL.appendingPathComponent("periods")
            stage = "periods"
            try Self.assertNoSymlinkAncestors(periodsDir)
            try FileManager.default.createDirectory(at: periodsDir, withIntermediateDirectories: true)
            try Self.chmodPath(periodsDir, 0o700)
            try fsyncParentChecked(of: periodsDir)

            let stagingDir = rootURL.appendingPathComponent("staging", isDirectory: true)
            stage = "staging"
            try Self.assertNoSymlinkAncestors(stagingDir)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try Self.chmodPath(stagingDir, 0o700)
            try fsyncParentChecked(of: stagingDir)

            let dbURL = rootURL.appendingPathComponent("intake.sqlite")
            stage = "database"
            try validateDatabasePaths()
            if FileManager.default.fileExists(atPath: dbURL.path) {
                try Self.assertRegularFile(dbURL)
            }
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                throw BrowserIntakeStoreError.localIO
            }
            try Self.chmodPath(dbURL, 0o600)
            try fsyncParentChecked(of: dbURL)

            stage = "schema"
            try initSchema()
            stage = "recovery"
            try recoverAndLoadState()
        } catch {
            Logger.storage.error("Browser spool initialization failed at \(stage, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
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

    private func fsyncParentChecked(of fileURL: URL) throws {
        try ioInjector.check(.sync)
        try Self.fsyncParent(of: fileURL)
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

    private static func assertNoSymlinkAncestors(_ url: URL) throws {
        let path = url.path
        var current = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw BrowserIntakeStoreError.localIO }
            } else if errno != ENOENT {
                throw BrowserIntakeStoreError.localIO
            }
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
        try validateDatabasePaths()
        if sql.hasPrefix("BEGIN IMMEDIATE") { try ioInjector.check(.begin) }
        if sql.hasPrefix("COMMIT") { try ioInjector.check(.commit) }
        if !sql.hasPrefix("BEGIN IMMEDIATE") && !sql.hasPrefix("COMMIT") && !sql.hasPrefix("ROLLBACK") {
            try ioInjector.check(.step)
        }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            sqlite3_free(err)
            throw BrowserIntakeStoreError.localIO
        }
    }

    private func prepareChecked(_ sql: String, _ stmt: inout OpaquePointer?) throws {
        try validateDatabasePaths()
        try ioInjector.check(.read)
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BrowserIntakeStoreError.localIO
        }
    }

    private func query<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try prepareChecked(sql, &stmt)
        defer { sqlite3_finalize(stmt) }
        guard let stmt else { throw BrowserIntakeStoreError.localIO }
        return try body(stmt)
    }

    private func bindTextChecked(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) throws {
        try ioInjector.check(.bind)
        let data = Data(value.utf8)
        let rc: Int32 = data.withUnsafeBytes { raw in
            sqlite3_bind_text(stmt, index, raw.bindMemory(to: CChar.self).baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        guard rc == SQLITE_OK else { throw BrowserIntakeStoreError.localIO }
    }

    private func bindInt64Checked(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
        try ioInjector.check(.bind)
        guard sqlite3_bind_int64(stmt, index, value) == SQLITE_OK else { throw BrowserIntakeStoreError.localIO }
    }

    private func bindNullChecked(_ stmt: OpaquePointer?, _ index: Int32) throws {
        try ioInjector.check(.bind)
        guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw BrowserIntakeStoreError.localIO }
    }

    private func stepChecked(_ stmt: OpaquePointer?) throws -> Int32 {
        try validateDatabasePaths()
        try ioInjector.check(.step)
        return sqlite3_step(stmt)
    }

    private func validateDatabasePaths() throws {
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm"] {
            let url = rootURL.appendingPathComponent(name)
            try Self.assertNoSymlinkAncestors(url)
            if FileManager.default.fileExists(atPath: url.path) {
                try Self.assertRegularFile(url)
            }
        }
    }

private static func fullSync(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else { throw BrowserIntakeStoreError.localIO }
    }

    private func initSchema() throws {
        let sql = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        PRAGMA fullfsync = ON;

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
            canonical_key TEXT,
            finalize_timezone TEXT,
            finalize_reason TEXT,
            delivery_binding TEXT,
            ack_durable INTEGER NOT NULL DEFAULT 0,
            delivered_at_ms INTEGER
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
            initial_age_ms INTEGER NOT NULL DEFAULT 0,
            elapsed_highwater_ms INTEGER NOT NULL DEFAULT 0,
            age_established INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (generation, inst, batch_id)
        );

        CREATE TABLE IF NOT EXISTS age_clock (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            boot_id TEXT NOT NULL,
            elapsed_ms INTEGER NOT NULL,
            floor_ms INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS spool_state (
            key TEXT PRIMARY KEY,
            int_value INTEGER NOT NULL
        );
        """
        try execute(sql)
        let fullSyncEnabled = try query("PRAGMA fullfsync") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return sqlite3_column_int(stmt, 0) == 1
        }
        guard fullSyncEnabled else { throw BrowserIntakeStoreError.localIO }
        try ensureColumn("periods", name: "finalize_timezone", definition: "TEXT")
        try ensureColumn("periods", name: "finalize_reason", definition: "TEXT")
        try ensureColumn("periods", name: "delivery_binding", definition: "TEXT")
        try ensureColumn("periods", name: "ack_durable", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("periods", name: "delivered_at_ms", definition: "INTEGER")
        try ensureColumn("periods", name: "cleanup_durable", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("batch_seen", name: "initial_age_ms", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("batch_seen", name: "elapsed_highwater_ms", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("batch_seen", name: "age_established", definition: "INTEGER NOT NULL DEFAULT 0")
        try ensureColumn("batch_seen", name: "first_seen_ms", definition: "INTEGER")
    }

    private func ensureColumn(_ table: String, name: String, definition: String) throws {
        let exists = try query("PRAGMA table_info(\(table))") { stmt in
            while true {
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return false }
                guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                if Self.readText(stmt, 1) == name { return true }
            }
        }
        if exists { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    private func createEmptyPeriodFileLocked(_ periodId: String) throws {
        let fileURL = periodFileURL(for: periodId)
        let directory = fileURL.deletingLastPathComponent()
        try Self.assertNoSymlinkAncestors(directory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.chmodPath(directory, 0o700)
            try fsyncParentChecked(of: directory)
        }
        try Self.assertNoSymlinkAncestors(fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try ioInjector.check(.write)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw BrowserIntakeStoreError.localIO
            }
            try Self.chmodPath(fileURL, 0o600)
            try fsyncParentChecked(of: fileURL)
        }
    }

    private func recoverAndLoadState() throws {
        storedFloorMs = try optionalStateValue("floor_ms") ?? 0
        try query("SELECT boot_id, elapsed_ms, floor_ms FROM age_clock WHERE id = 1") { stmt in
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW, let bootID = Self.readText(stmt, 0),
                  sqlite3_column_int64(stmt, 1) >= 0, sqlite3_column_int64(stmt, 2) >= 0 else { throw BrowserIntakeStoreError.localIO }
            ageCheckpoint = BrowserAgeStamp(bootID: bootID, elapsedMs: UInt64(sqlite3_column_int64(stmt, 1)))
            storedFloorMs = max(storedFloorMs, UInt64(sqlite3_column_int64(stmt, 2)))
        }
        let active = try query("SELECT destination_generation, identity_token FROM epoch WHERE status = 'active' ORDER BY id DESC LIMIT 1") { stmt -> (String, String)? in
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW,
                  let generation = Self.readText(stmt, 0),
                  let token = Self.readText(stmt, 1) else { throw BrowserIntakeStoreError.localIO }
            return (generation, token)
        }
        activeGeneration = active?.0
        activeIdentityToken = active?.1

        if self.activeGeneration == nil {
            activeIdentityToken = try query("SELECT identity_token FROM epoch ORDER BY id DESC LIMIT 1") { stmt in
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return nil }
                guard rc == SQLITE_ROW, let token = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                return token
            }
        }

        try recoverPeriodFiles()
        do {
            try reclaimAbandonedStaging()
            try reclaimEmptyUnreferencedPeriodDirectories()
        } catch {
            // Keep custody inspectable when unexpected contents or failed
            // cleanup prevent safely recovering the delivery reserve.
            isStoreFailed = true
        }

        if let gen = activeGeneration {
            currentOpenPeriodId = try query("SELECT period_id FROM periods WHERE generation = ? AND state = 'open' ORDER BY created_at_ms DESC LIMIT 1") { stmt in
                try bindTextChecked(stmt, 1, gen)
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return nil }
                guard rc == SQLITE_ROW, let periodId = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                return periodId
            }
        }

        // A readable database with damaged custody must still project the held
        // data and local failure. Mutations and delivery remain fail-closed.
        recalculateCounters()
    }

    private func reclaimAbandonedStaging() throws {
        let stagingRoot = stagingRootURL()
        try Self.assertNoSymlinkAncestors(stagingRoot)
        let directories = try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix("browser-upload-"), UUID(uuidString: String(name.dropFirst("browser-upload-".count))) != nil else {
                throw BrowserIntakeStoreError.localIO
            }
            try Self.assertNoSymlinkAncestors(directory)
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw BrowserIntakeStoreError.localIO
            }
            // Only a reproducible multipart copy belongs here. Never traverse
            // or remove unknown entries or links during recovery.
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for child in children {
                guard child.lastPathComponent == "multipart.body" else { throw BrowserIntakeStoreError.localIO }
                try Self.assertNoSymlinkAncestors(child)
                try Self.assertRegularFile(child)
            }
            for child in children { try FileManager.default.removeItem(at: child) }
            try FileManager.default.removeItem(at: directory)
        }
        if !directories.isEmpty { try fsyncParentChecked(of: stagingRoot.appendingPathComponent("reclaimed")) }
    }

    private func reclaimEmptyUnreferencedPeriodDirectories() throws {
        let periodsRoot = rootURL.appendingPathComponent("periods", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(at: periodsRoot, includingPropertiesForKeys: nil)
        let referencedIDs = try query("SELECT period_id FROM periods") { stmt in
            var ids = Set<String>()
            while true {
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return ids }
                guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                ids.insert(id)
            }
        }
        var changed = false
        for directory in directories {
            let id = directory.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            guard !referencedIDs.contains(id) else { continue }
            try Self.assertNoSymlinkAncestors(directory)
            guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty else {
                throw BrowserIntakeStoreError.localIO
            }
            try FileManager.default.removeItem(at: directory)
            changed = true
        }
        if changed { try fsyncParentChecked(of: periodsRoot.appendingPathComponent("reclaimed")) }
    }

    private func recoverPeriodFiles() throws {
        var stmt: OpaquePointer?
        try prepareChecked("SELECT period_id, committed_length, state, requested_day, requested_segment, file_sha256 FROM periods WHERE state IN ('open', 'finalized', 'finalizing')", &stmt)
        defer { sqlite3_finalize(stmt) }
        var finalizing: [(String, Int, String, String)] = []
        while true {
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw BrowserIntakeStoreError.localIO
            }
            guard let pid = Self.readText(stmt, 0), let state = Self.readText(stmt, 2) else {
                throw BrowserIntakeStoreError.localIO
            }
            let committed = Int(sqlite3_column_int64(stmt, 1))
            let fileURL = periodFileURL(for: pid)
            let size: Int?
            do {
                try Self.assertNoSymlinkAncestors(fileURL)
                try ioInjector.check(.size)
                size = try Self.fileByteCount(fileURL)
            } catch {
                isStoreFailed = true
                continue
            }
            if size == nil {
                if state == "open" && committed == 0 {
                    try execute("UPDATE periods SET state = 'retired' WHERE period_id = '\(pid.replacingOccurrences(of: "'", with: "''"))'")
                    if currentOpenPeriodId == pid { currentOpenPeriodId = nil }
                } else {
                    isStoreFailed = true
                }
                continue
            }
            let bytes = size ?? 0
            if state == "open" && committed == 0 && bytes == 0 {
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: fileURL)
                try fsyncParentChecked(of: fileURL)
                try execute("UPDATE periods SET state = 'retired' WHERE period_id = '\(pid.replacingOccurrences(of: "'", with: "''"))'")
                if currentOpenPeriodId == pid { currentOpenPeriodId = nil }
                continue
            }
            if bytes < committed {
                isStoreFailed = true
                continue
            }
            if state == "finalized" {
                do {
                    guard bytes == committed, let expectedHash = Self.readText(stmt, 5) else {
                        throw BrowserIntakeStoreError.localIO
                    }
                    try validatePayloadLocked(fileURL, length: committed, sha256: expectedHash)
                } catch {
                    isStoreFailed = true
                }
                continue
            }
            if (state == "open" || state == "finalizing") && bytes > committed {
                do {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try ioInjector.check(.write)
                    try handle.truncate(atOffset: UInt64(committed))
                    try ioInjector.check(.sync)
                    try Self.fullSync(handle)
                }
            }
            if state == "open" && committed == 0 {
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: fileURL)
                try fsyncParentChecked(of: fileURL)
                try execute("UPDATE periods SET state = 'retired' WHERE period_id = '\(pid.replacingOccurrences(of: "'", with: "''"))'")
                if currentOpenPeriodId == pid { currentOpenPeriodId = nil }
            }
            if state == "finalizing" {
                guard let day = Self.readText(stmt, 3), let segment = Self.readText(stmt, 4) else {
                    isStoreFailed = true
                    continue
                }
                finalizing.append((pid, committed, day, segment))
            }
        }
        for (pid, committed, day, segment) in finalizing {
            let fileURL = periodFileURL(for: pid)
            let data: Data
            do {
                try Self.assertNoSymlinkAncestors(fileURL)
                try ioInjector.check(.read)
                data = Data(try Data(contentsOf: fileURL).prefix(committed))
            } catch {
                isStoreFailed = true
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try query("UPDATE periods SET state = 'finalized', file_sha256 = ?, size = ? WHERE period_id = ? AND state = 'finalizing'") { update in
                try bindTextChecked(update, 1, digest)
                try bindInt64Checked(update, 2, Int64(committed))
                try bindTextChecked(update, 3, pid)
                guard try stepChecked(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
            if currentOpenPeriodId == pid { currentOpenPeriodId = nil }
            _ = (day, segment)
        }

        var terminalStmt: OpaquePointer?
        try prepareChecked("SELECT period_id FROM periods WHERE state IN ('delivered', 'removed')", &terminalStmt)
        defer { sqlite3_finalize(terminalStmt) }
        var terminalIds: [String] = []
        while true {
            let rc = try stepChecked(terminalStmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW, let pid = Self.readText(terminalStmt, 0) else {
                throw BrowserIntakeStoreError.localIO
            }
            terminalIds.append(pid)
        }
        for pid in terminalIds {
            let fileURL = periodFileURL(for: pid)
            do {
                try Self.assertNoSymlinkAncestors(fileURL)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try Self.assertRegularFile(fileURL)
                    try ioInjector.check(.write)
                    try FileManager.default.removeItem(at: fileURL)
                }
                try fsyncParentChecked(of: fileURL)
                try query("UPDATE periods SET cleanup_durable = 1 WHERE period_id = ? AND state IN ('delivered', 'removed')") { done in
                    try bindTextChecked(done, 1, pid)
                    guard try stepChecked(done) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
                }
            } catch {
                isStoreFailed = true
            }
        }
    }

    private func recalculateCounters() {
        do {
            var payloadBytes = 0
            try query("SELECT period_id, committed_length, state FROM periods WHERE state IN ('open', 'finalized', 'delivered', 'removed')") { stmt in
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW, let pid = Self.readText(stmt, 0), let state = Self.readText(stmt, 2) else {
                        throw BrowserIntakeStoreError.localIO
                    }
                    let committed = Int(sqlite3_column_int64(stmt, 1))
                    if state == "open" || state == "finalized" {
                        payloadBytes += committed
                    } else if !isCleanupDurableLocked(pid) || FileManager.default.fileExists(atPath: periodFileURL(for: pid).path) {
                        payloadBytes += committed
                    }
                }
            }
            heldPayloadBytes = payloadBytes

            var dedupBytes = 0
            try query("SELECT generation, inst, batch_id, period_id, reason, class FROM receipts") { stmt in
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                    dedupBytes += (0..<6).reduce(0) { $0 + Int(sqlite3_column_bytes(stmt, Int32($1))) }
                }
            }
            try query("SELECT generation, inst, batch_id FROM batch_seen") { stmt in
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                    dedupBytes += (0..<3).reduce(0) { $0 + Int(sqlite3_column_bytes(stmt, Int32($1))) }
                }
            }
            heldDedupBytes = dedupBytes

            earliestHeldMs = try query("SELECT MIN(accepted_at_ms) FROM receipts r JOIN periods p ON r.period_id = p.period_id WHERE p.state IN ('open', 'finalized') AND r.accepted_at_ms IS NOT NULL") { stmt in
                guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : UInt64(sqlite3_column_int64(stmt, 0))
            }

            storedFloorMs = max(storedFloorMs, try optionalStateValue("floor_ms") ?? 0)
            staleAnchorMs = try optionalStateValue("stale_anchor_ms") ?? 0
            staleElapsedHighWaterMs = try optionalStateValue("stale_elapsed_ms") ?? 0
        } catch {
            isStoreFailed = true
            heldPayloadBytes = Int.max
            heldDedupBytes = Int.max
        }
    }

    private func optionalStateValue(_ key: String) throws -> UInt64? {
        try query("SELECT int_value FROM spool_state WHERE key = '\(key)'") { stmt in
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return UInt64(sqlite3_column_int64(stmt, 0))
        }
    }

    private func isCleanupDurableLocked(_ periodId: String) -> Bool {
        do {
            return try query("SELECT cleanup_durable FROM periods WHERE period_id = ?") { stmt in
                try bindTextChecked(stmt, 1, periodId)
                let rc = try stepChecked(stmt)
                guard rc == SQLITE_ROW else {
                    if rc != SQLITE_DONE { throw BrowserIntakeStoreError.localIO }
                    return false
                }
                return sqlite3_column_int(stmt, 0) != 0
            }
        } catch {
            isStoreFailed = true
            return false
        }
    }

    private func validatePayloadLocked(_ url: URL, length: Int, sha256: String) throws {
        guard length > 0, length <= projection.policy.file else { throw BrowserIntakeStoreError.localIO }
        try Self.assertNoSymlinkAncestors(url)
        try Self.assertRegularFile(url)
        try ioInjector.check(.size)
        guard try Self.fileByteCount(url) == length else { throw BrowserIntakeStoreError.localIO }
        try ioInjector.check(.read)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: length + 1) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == length, BrowserOpaqueString.equals(digest, sha256) else {
            throw BrowserIntakeStoreError.localIO
        }
    }

    func validateFinalizedPayload(_ period: BrowserStoredPeriod) throws {
        try lock.withLock {
            do {
                guard !isStoreFailed, period.state == "finalized", let digest = period.fileSha256 else {
                    throw BrowserIntakeStoreError.localIO
                }
                try validatePayloadLocked(periodFileURL(for: period.periodId), length: period.committedLength, sha256: digest)
            } catch {
                isStoreFailed = true
                throw error
            }
        }
    }

    public func periodFileByteCount(periodId: String) throws -> Int {
        let url = periodFileURL(for: periodId)
        try Self.assertNoSymlinkAncestors(url)
        try ioInjector.check(.read)
        guard let size = try Self.fileByteCount(url) else { throw BrowserIntakeStoreError.localIO }
        return size
    }

    public func periodFileURL(for periodId: String) -> URL {
        rootURL.appendingPathComponent("periods").appendingPathComponent(periodId).appendingPathComponent("browser_pages.jsonl")
    }

    public func getFloorMs() -> UInt64 {
        lock.withLock { storedFloorMs }
    }

    private func updateFloorMsLocked(wallNowMs: UInt64) throws -> UInt64 {
        guard let stamp = ageClock(), stamp.elapsedMs <= UInt64(Int64.max), !stamp.bootID.isEmpty else {
            isStoreFailed = true
            throw BrowserIntakeStoreError.localIO
        }
        if let previous = ageCheckpoint, BrowserOpaqueString.equals(previous.bootID, stamp.bootID), stamp.elapsedMs < previous.elapsedMs {
            isStoreFailed = true
            throw BrowserIntakeStoreError.localIO
        }
        let sameBoot = ageCheckpoint.map { BrowserOpaqueString.equals($0.bootID, stamp.bootID) && stamp.elapsedMs >= $0.elapsedMs } ?? false
        let elapsed = sameBoot ? stamp.elapsedMs - ageCheckpoint!.elapsedMs : (ageCheckpoint == nil ? 0 : stamp.elapsedMs)
        let (advanced, overflow) = storedFloorMs.addingReportingOverflow(elapsed)
        let target = max(wallNowMs, overflow ? UInt64(Int64.max) : min(advanced, UInt64(Int64.max)))
        guard target <= UInt64(Int64.max) else { throw BrowserIntakeStoreError.localIO }
        if target == storedFloorMs, sameBoot, ageCheckpoint?.elapsedMs == stamp.elapsedMs { return storedFloorMs }
        do {
            try execute("BEGIN IMMEDIATE;")
            // A changed/missing boot coordinate cannot establish a recovered
            // unaccepted batch's remaining time. Earned receipts are unaffected.
            if !sameBoot && storedFloorMs > 0 {
                try execute("UPDATE batch_seen SET age_established = 0;")
            }
            try query("INSERT OR REPLACE INTO age_clock (id, boot_id, elapsed_ms, floor_ms) VALUES (1, ?, ?, ?)") { stmt in
                try bindTextChecked(stmt, 1, stamp.bootID)
                try bindInt64Checked(stmt, 2, Int64(stamp.elapsedMs))
                try bindInt64Checked(stmt, 3, Int64(target))
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            isStoreFailed = true
            throw error
        }
        ageCheckpoint = stamp
        storedFloorMs = target
        observedFloorMs = max(observedFloorMs, storedFloorMs)
        return storedFloorMs
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

        do { _ = try updateFloorMsLocked(wallNowMs: nowMs) }
        catch { isStoreFailed = true }
        let freshness = projection.policy.freshnessMaxMs

        let heldAge = storedFloorMs >= earliestHeldMs ? storedFloorMs - earliestHeldMs : 0
        let savedAge = staleAnchorMs == earliestHeldMs ? staleElapsedHighWaterMs : 0
        let isStale = earliestHeldMs > 0 && max(heldAge, savedAge) >= projection.policy.spoolAgeMs

        let isFull = (try? isQuotaFullLocked()) ?? true

        if isStoreFailed {
            let res: [String: Any] = [
                "type": "state",
                "capture": "unavailable",
                "delivery": "failed",
                "failure": "local_io",
                "freshness_ms": freshness,
                "destination_generation": NSNull(),
                "period_id": NSNull(),
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

        if isFull {
            failure = "resource_exhausted"
        }

        if let failureCode = deliveryFailure {
            delivery = "failed"
            failure = failureCode
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
        guard !isStoreFailed else { throw BrowserIntakeStoreError.localIO }
        guard !deliveryStopped else { throw BrowserIntakeStoreError.staleGeneration }

        let digest = Self.identityDigest(of: identityToken)
        if let currentGen = activeGeneration, BrowserOpaqueString.equals(activeIdentityToken, digest) {
            guard !deliveryStopped else { throw BrowserIntakeStoreError.staleGeneration }
            let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
            _ = try ensureOpenPeriodLocked(nowMs: durableNowMs)
            deliveryProofsOpen = true
            return currentGen
        }

        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        let newGen = UUID().uuidString
        let newPeriodId = UUID().uuidString

        try createEmptyPeriodFileLocked(newPeriodId)
        var transactionBegan = false
        do {
            try execute("BEGIN IMMEDIATE;")
            transactionBegan = true
            try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")
            try query("INSERT INTO epoch (identity_token, destination_generation, status, created_at_ms) VALUES (?, ?, 'active', ?)") { stmt in
                try bindTextChecked(stmt, 1, digest)
                try bindTextChecked(stmt, 2, newGen)
                try bindInt64Checked(stmt, 3, Int64(durableNowMs))
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            try query("INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)") { stmt in
                try bindTextChecked(stmt, 1, newPeriodId)
                try bindTextChecked(stmt, 2, newGen)
                try bindInt64Checked(stmt, 3, Int64(durableNowMs))
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            try execute("COMMIT;")
            transactionBegan = false
        } catch {
            if transactionBegan {
                do { try execute("ROLLBACK;") }
                catch { isStoreFailed = true }
            }
            let fileURL = periodFileURL(for: newPeriodId)
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try Self.assertNoSymlinkAncestors(fileURL)
                    try ioInjector.check(.write)
                    try FileManager.default.removeItem(at: fileURL)
                    try fsyncParentChecked(of: fileURL)
                }
            } catch {
                isStoreFailed = true
            }
            throw error
        }

        self.activeGeneration = newGen
        self.activeIdentityToken = digest
        self.currentOpenPeriodId = newPeriodId
        if !deliveryStopped { deliveryProofsOpen = true }
        return newGen
    }

    public func retireIfTokenChanged(newToken: String?, nowMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }

        let digest = newToken.map { Self.identityDigest(of: $0) }
        if BrowserOpaqueString.equals(activeIdentityToken, digest) && activeGeneration != nil && digest != nil {
            return
        }
        if activeGeneration == nil && BrowserOpaqueString.equals(activeIdentityToken, digest) {
            return
        }

        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))

        if let openPid = currentOpenPeriodId {
            try finalizePeriodInternal(
                periodId: openPid,
                reason: "identity_retirement",
                civilDate: Date(timeIntervalSince1970: Double(durableNowMs) / 1000.0),
                timeZone: TimeZone.current,
                openReplacement: false
            )
        }

        try execute("UPDATE epoch SET status = 'retired', retired_at_ms = \(durableNowMs) WHERE status = 'active';")
        self.activeGeneration = nil
        self.activeIdentityToken = digest
        self.currentOpenPeriodId = nil
    }

    public func lookupReceipt(generation: String, inst: String, batchId: String) throws -> BrowserStoredReceipt? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        try prepareChecked("SELECT result, period_id, reason, class, queued_at_ms, accepted_at_ms, size_bytes FROM receipts WHERE generation = ? AND inst = ? AND batch_id = ?", &stmt)
        try bindTextChecked(stmt, 1, generation)
        try bindTextChecked(stmt, 2, inst)
        try bindTextChecked(stmt, 3, batchId)
        let rc = try stepChecked(stmt)
        if rc == SQLITE_ROW {
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
        } else if rc != SQLITE_DONE {
            throw BrowserIntakeStoreError.localIO
        }
        return nil
    }

    public func isContextInitialized(periodId: String, inst: String, ctx: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        try prepareChecked("SELECT 1 FROM period_contexts WHERE period_id = ? AND inst = ? AND ctx = ?", &stmt)
        try bindTextChecked(stmt, 1, periodId)
        try bindTextChecked(stmt, 2, inst)
        try bindTextChecked(stmt, 3, ctx)
        let rc = try stepChecked(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        return rc == SQLITE_ROW
    }

    public func recordBatchSeen(generation: String, inst: String, batchId: String, queuedAtMs: UInt64, initialAgeMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }

        let rowBytes = Self.batchSeenDedupBytes(generation: generation, inst: inst, batchId: batchId)
        if try isQuotaFullLocked(additionalBytes: 0, additionalDedupBytes: rowBytes) {
            throw BrowserIntakeStoreError.resourceExhausted
        }

        var stmt: OpaquePointer?
        try prepareChecked("INSERT OR IGNORE INTO batch_seen (generation, inst, batch_id, queued_at_ms, initial_age_ms, elapsed_highwater_ms, age_established, first_seen_ms) VALUES (?, ?, ?, ?, ?, 0, 1, ?)", &stmt)
        try bindTextChecked(stmt, 1, generation)
        try bindTextChecked(stmt, 2, inst)
        try bindTextChecked(stmt, 3, batchId)
        try bindInt64Checked(stmt, 4, Int64(queuedAtMs))
        try bindInt64Checked(stmt, 5, Int64(initialAgeMs))
        try bindInt64Checked(stmt, 6, Int64(storedFloorMs))
        let rc = try stepChecked(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        if sqlite3_changes(db) == 1 {
            heldDedupBytes += rowBytes
        }
    }

    public func getBatchAge(generation: String, inst: String, batchId: String) throws -> (initialAgeMs: UInt64, elapsedHighWaterMs: UInt64, established: Bool)? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        try prepareChecked("SELECT initial_age_ms, elapsed_highwater_ms, age_established, first_seen_ms FROM batch_seen WHERE generation = ? AND inst = ? AND batch_id = ?", &stmt)
        try bindTextChecked(stmt, 1, generation)
        try bindTextChecked(stmt, 2, inst)
        try bindTextChecked(stmt, 3, batchId)
        let rc = try stepChecked(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
        let initial = sqlite3_column_int64(stmt, 0)
        let savedElapsed = sqlite3_column_int64(stmt, 1)
        let firstSeen = sqlite3_column_int64(stmt, 3)
        guard initial >= 0, savedElapsed >= 0, firstSeen >= 0 else {
            isStoreFailed = true
            throw BrowserIntakeStoreError.localIO
        }
        let elapsed = storedFloorMs >= UInt64(firstSeen) ? storedFloorMs - UInt64(firstSeen) : 0
        return (UInt64(initial), max(UInt64(savedElapsed), elapsed),
                sqlite3_column_int(stmt, 2) != 0 && sqlite3_column_type(stmt, 3) != SQLITE_NULL)
    }

    func updateBatchAgeHighWater(generation: String, inst: String, batchId: String, elapsedMs: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        try prepareChecked("UPDATE batch_seen SET elapsed_highwater_ms = MAX(elapsed_highwater_ms, ?) WHERE generation = ? AND inst = ? AND batch_id = ?", &stmt)
        try bindInt64Checked(stmt, 1, Int64(elapsedMs))
        try bindTextChecked(stmt, 2, generation)
        try bindTextChecked(stmt, 3, inst)
        try bindTextChecked(stmt, 4, batchId)
        guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
    }

    func updateStaleness(anchorMs: UInt64?, elapsedMs: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let anchorMs {
            let candidate = staleAnchorMs == anchorMs ? max(staleElapsedHighWaterMs, elapsedMs) : elapsedMs
            if staleAnchorMs != anchorMs {
                try execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('stale_anchor_ms', \(anchorMs)), ('stale_elapsed_ms', \(candidate));")
                staleAnchorMs = anchorMs
                staleElapsedHighWaterMs = candidate
            } else if candidate > staleElapsedHighWaterMs {
                try execute("INSERT OR REPLACE INTO spool_state (key, int_value) VALUES ('stale_elapsed_ms', \(candidate));")
                staleElapsedHighWaterMs = candidate
            }
        } else if staleAnchorMs != 0 || staleElapsedHighWaterMs != 0 {
            try execute("DELETE FROM spool_state WHERE key IN ('stale_anchor_ms', 'stale_elapsed_ms');")
            staleAnchorMs = 0
            staleElapsedHighWaterMs = 0
        }
        return staleElapsedHighWaterMs
    }

    func stalenessState() -> (anchorMs: UInt64, elapsedHighWaterMs: UInt64) {
        lock.withLock { (staleAnchorMs, staleElapsedHighWaterMs) }
    }

    func failClosed() {
        lock.withLock { isStoreFailed = true }
    }

    public func getEarliestHeldMs() -> UInt64 {
        lock.withLock { earliestHeldMs }
    }

    private func sqliteFootprintBytes() throws -> Int {
        var total = 0
        var sawDatabase = false
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm"] {
            let url = rootURL.appendingPathComponent(name)
            try ioInjector.check(.size)
            if let bytes = ioInjector.size(for: url, actual: try Self.fileByteCount(url)) {
                total += bytes
                if name == "intake.sqlite" { sawDatabase = true }
            }
        }
        if !sawDatabase { throw BrowserIntakeStoreError.localIO }
        return total
    }

    private func directoryFootprintBytes(_ directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var total = 0
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw BrowserIntakeStoreError.localIO
        }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw BrowserIntakeStoreError.localIO }
            let kind = info.st_mode & S_IFMT
            guard kind != S_IFLNK else { throw BrowserIntakeStoreError.localIO }
            if kind == S_IFREG {
                try ioInjector.check(.size)
                total += ioInjector.size(for: url, actual: Int(info.st_size)) ?? 0
            }
        }
        return total
    }

    private func acknowledgementFootprintBytes() throws -> Int {
        let periodsURL = rootURL.appendingPathComponent("periods", isDirectory: true)
        guard FileManager.default.fileExists(atPath: periodsURL.path) else { return 0 }
        var total = 0
        guard let enumerator = FileManager.default.enumerator(at: periodsURL, includingPropertiesForKeys: nil) else {
            throw BrowserIntakeStoreError.localIO
        }
        for case let url as URL in enumerator where url.lastPathComponent == "browser_ingest_ack.json" ||
            (url.lastPathComponent.hasPrefix(".browser_ingest_ack.json.") && url.lastPathComponent.hasSuffix(".tmp")) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw BrowserIntakeStoreError.localIO
            }
            try ioInjector.check(.size)
            total += ioInjector.size(for: url, actual: Int(info.st_size)) ?? 0
        }
        return total
    }

    private func stagingFootprintBytes() throws -> Int {
        var directories = stagingDirectories
        let stagingRoot = rootURL.appendingPathComponent("staging", isDirectory: true)
        try Self.assertNoSymlinkAncestors(stagingRoot)
        guard let children = try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) else {
            throw BrowserIntakeStoreError.localIO
        }
        directories.append(contentsOf: children)
        var total = 0
        for directory in Set(directories).union(stagingReservations.keys) {
            let actual = try directoryFootprintBytes(directory)
            total = Self.saturatingAdd(total, max(stagingReservations[directory] ?? 0, actual))
        }
        return total
    }

    private func productionFootprintBytesLocked(additionalPayloadBytes: Int = 0, additionalDedupBytes: Int = 0) throws -> Int {
        let payload = Self.saturatingAdd(heldPayloadBytes, max(0, additionalPayloadBytes))
        // One sequential multipart upload consumes the already reserved copy;
        // it must not charge that same copy a second time and block draining.
        let deliveryReserve = payload > 0 ? Self.saturatingAdd(payload, 64 * 1024) : 0
        let staging = try stagingFootprintBytes()
        var total = Self.saturatingAdd(payload, max(deliveryReserve, staging))
        total = Self.saturatingAdd(total, max(0, additionalDedupBytes))
        total = Self.saturatingAdd(total, try sqliteFootprintBytes())
        total = Self.saturatingAdd(total, try acknowledgementFootprintBytes())
        return total
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    public func projectedSpoolBytes(additionalPayloadBytes: Int = 0, additionalDedupBytes: Int = 0) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (try? productionFootprintBytesLocked(additionalPayloadBytes: additionalPayloadBytes, additionalDedupBytes: additionalDedupBytes)) ?? Int.max
    }

    private func isQuotaFullLocked(additionalBytes: Int = 0, additionalDedupBytes: Int = 0) throws -> Bool {
        let payload = additionalBytes == 0 && additionalDedupBytes == 0 ? 1 : additionalBytes
        let projected = try productionFootprintBytesLocked(additionalPayloadBytes: payload, additionalDedupBytes: additionalDedupBytes)
        return projected > projection.policy.spoolBytes
    }

    public func isQuotaFull(additionalBytes: Int = 0, additionalDedupBytes: Int = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try isQuotaFullLocked(additionalBytes: additionalBytes, additionalDedupBytes: additionalDedupBytes)
        } catch {
            isStoreFailed = true
            Logger.storage.error("Browser spool quota footprint failed")
            return true
        }
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

        let rowBytes = Self.receiptDedupBytes(generation: generation, inst: inst, batchId: batchId, periodId: nil, reason: reason, receiptClass: receiptClass)
        if try isQuotaFullLocked(additionalBytes: 0, additionalDedupBytes: rowBytes) {
            throw BrowserIntakeStoreError.resourceExhausted
        }
        let inserted = try query("INSERT OR IGNORE INTO receipts (generation, inst, batch_id, result, reason, class, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'rejected', ?, ?, ?, ?, 0)") { stmt in
            try bindTextChecked(stmt, 1, generation)
            try bindTextChecked(stmt, 2, inst)
            try bindTextChecked(stmt, 3, batchId)
            try bindTextChecked(stmt, 4, reason)
            try bindTextChecked(stmt, 5, receiptClass)
            try bindInt64Checked(stmt, 6, Int64(queuedAtMs))
            try bindInt64Checked(stmt, 7, Int64(durableNowMs))
            guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            return sqlite3_changes(db) == 1
        }
        if inserted {
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
        try createEmptyPeriodFileLocked(pid)
        try query("INSERT INTO periods (period_id, generation, state, committed_length, created_at_ms) VALUES (?, ?, 'open', 0, ?)") { stmt in
            try bindTextChecked(stmt, 1, pid)
            try bindTextChecked(stmt, 2, gen)
            try bindInt64Checked(stmt, 3, Int64(nowMs))
            guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
        }
        currentOpenPeriodId = pid
        return pid
    }

    private func committedLengthLocked(_ periodId: String) throws -> Int {
        try query("SELECT committed_length FROM periods WHERE period_id = ?") { stmt in
            try bindTextChecked(stmt, 1, periodId)
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func checkedPeriodFileSize(_ periodId: String) throws -> Int {
        let url = periodFileURL(for: periodId)
        try Self.assertNoSymlinkAncestors(url)
        try ioInjector.check(.size)
        guard let actual = try Self.fileByteCount(url), let injected = ioInjector.size(for: url, actual: actual) else {
            throw BrowserIntakeStoreError.localIO
        }
        return injected
    }

    private func existingAcceptedPeriodLocked(generation: String, inst: String, batchId: String) throws -> String? {
        try query("SELECT result, period_id FROM receipts WHERE generation = ? AND inst = ? AND batch_id = ?") { stmt in
            try bindTextChecked(stmt, 1, generation)
            try bindTextChecked(stmt, 2, inst)
            try bindTextChecked(stmt, 3, batchId)
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            guard Self.readText(stmt, 0) == "accepted" else { return nil }
            return Self.readText(stmt, 1)
        }
    }

    private func rollbackFile(_ handle: FileHandle, to length: Int) throws {
        do {
            try ioInjector.check(.write)
            try handle.truncate(atOffset: UInt64(length))
            try ioInjector.check(.sync)
            try Self.fullSync(handle)
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
        let committed = try checkedPeriodFileSize(pid)
        if committed + byteCount > projection.policy.file && committed > 0 {
            try finalizePeriodInternal(periodId: pid, reason: "size_pressure", civilDate: civilDate, timeZone: timeZone)
        }
        guard let selected = currentOpenPeriodId else { throw BrowserIntakeStoreError.localIO }
        let selectedCommitted = try checkedPeriodFileSize(selected)
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
        guard let gen = activeGeneration, BrowserOpaqueString.equals(gen, batch.destinationGeneration) else {
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

        let currentCommittedLen = try committedLengthLocked(pid)
        guard try checkedPeriodFileSize(pid) == currentCommittedLen else { throw BrowserIntakeStoreError.localIO }

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
            try ioInjector.check(.write)
            try FileManager.default.createDirectory(at: finalPeriodDir, withIntermediateDirectories: true)
            try Self.chmodPath(finalPeriodDir, 0o700)
            try fsyncParentChecked(of: finalPeriodDir)
        }
        try Self.assertNoSymlinkAncestors(finalFileURL)
        if !FileManager.default.fileExists(atPath: finalFileURL.path) {
            try ioInjector.check(.write)
            guard FileManager.default.createFile(atPath: finalFileURL.path, contents: nil) else {
                throw BrowserIntakeStoreError.localIO
            }
            try Self.chmodPath(finalFileURL, 0o600)
            try fsyncParentChecked(of: finalFileURL)
        } else {
            try Self.assertRegularFile(finalFileURL)
        }

        try Self.assertNoSymlinkAncestors(finalFileURL)
        let fileHandle = try FileHandle(forWritingTo: finalFileURL)
        do {
            try ioInjector.check(.write)
            try fileHandle.truncate(atOffset: UInt64(currentCommittedLen))
            try fileHandle.seek(toOffset: UInt64(currentCommittedLen))
            try fileHandle.write(contentsOf: batchBytesData)
            try ioInjector.check(.sync)
            try Self.fullSync(fileHandle)
        } catch {
            do {
                try rollbackFile(fileHandle, to: currentCommittedLen)
            } catch {
                isStoreFailed = true
                fileRecoveryRequired = true
            }
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

        let newCommittedLen = currentCommittedLen + batchBytesData.count
        var transactionBegan = false
        do {
            try execute("BEGIN IMMEDIATE;")
            transactionBegan = true
            let receiptRC = try query("INSERT INTO receipts (generation, inst, batch_id, result, period_id, queued_at_ms, accepted_at_ms, size_bytes) VALUES (?, ?, ?, 'accepted', ?, ?, ?, ?)") { stmt in
                try bindTextChecked(stmt, 1, gen)
                try bindTextChecked(stmt, 2, batch.inst)
                try bindTextChecked(stmt, 3, batch.batchId)
                try bindTextChecked(stmt, 4, pid)
                try bindInt64Checked(stmt, 5, Int64(batch.queuedAtMs))
                try bindInt64Checked(stmt, 6, Int64(durableNowMs))
                try bindInt64Checked(stmt, 7, Int64(batchBytesData.count))
                return try stepChecked(stmt)
            }
            if receiptRC == SQLITE_CONSTRAINT {
                if let existing = try existingAcceptedPeriodLocked(generation: gen, inst: batch.inst, batchId: batch.batchId) {
                    throw BrowserIntakeStoreError.duplicateAccepted(periodId: existing)
                }
                throw BrowserIntakeStoreError.localIO
            }
            guard receiptRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }

            for rec in batch.records where rec.t == "segment_start" {
                let contextRC = try query("INSERT OR IGNORE INTO period_contexts (period_id, inst, ctx, initialized_at_ms) VALUES (?, ?, ?, ?)") { stmt in
                    try bindTextChecked(stmt, 1, pid)
                    try bindTextChecked(stmt, 2, batch.inst)
                    try bindTextChecked(stmt, 3, rec.ctx)
                    try bindInt64Checked(stmt, 4, Int64(durableNowMs))
                    return try stepChecked(stmt)
                }
                guard contextRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }

            let updateRC = try query("UPDATE periods SET committed_length = ? WHERE period_id = ?") { stmt in
                try bindInt64Checked(stmt, 1, Int64(newCommittedLen))
                try bindTextChecked(stmt, 2, pid)
                return try stepChecked(stmt)
            }
            guard updateRC == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            guard sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }

            try execute("COMMIT;")
        } catch {
            if transactionBegan {
                do {
                    try execute("ROLLBACK;")
                } catch {
                    isStoreFailed = true
                    fileRecoveryRequired = true
                }
            }
            do {
                try rollbackFile(fileHandle, to: currentCommittedLen)
            } catch {
                isStoreFailed = true
                fileRecoveryRequired = true
            }
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
        timeZone: TimeZone,
        openReplacement: Bool = true
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try finalizePeriodInternal(periodId: periodId, reason: reason, civilDate: civilDate, timeZone: timeZone, openReplacement: openReplacement)
    }

    private func finalizePeriodInternal(
        periodId: String,
        reason: String,
        civilDate: Date,
        timeZone: TimeZone,
        openReplacement: Bool = true
    ) throws {
        try ensureFileRecoveryLocked()
        if let existing = getPeriodLocked(periodId: periodId), existing.state != "open" {
            return
        }
        let committedLength = try committedLengthLocked(periodId)
        let fileURL = periodFileURL(for: periodId)
        try Self.assertNoSymlinkAncestors(fileURL)
        if committedLength == 0 {
            if let fileBytes = try Self.fileByteCount(fileURL) {
                guard fileBytes == 0 else { throw BrowserIntakeStoreError.localIO }
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: fileURL)
                try fsyncParentChecked(of: fileURL)
            }
            try execute("UPDATE periods SET state = 'retired' WHERE period_id = '\(periodId.replacingOccurrences(of: "'", with: "''"))' AND state = 'open'")
            if currentOpenPeriodId == periodId {
                currentOpenPeriodId = nil
                if openReplacement, activeGeneration != nil {
                    _ = try ensureOpenPeriodLocked(nowMs: storedFloorMs)
                }
            }
            return
        }

        guard let fileBytes = try Self.fileByteCount(fileURL), fileBytes >= committedLength else {
            throw BrowserIntakeStoreError.localIO
        }
        let fh = try FileHandle(forWritingTo: fileURL)
        if fileBytes > committedLength {
            try ioInjector.check(.write)
            try fh.truncate(atOffset: UInt64(committedLength))
        }
        try ioInjector.check(.sync)
        try Self.fullSync(fh)
        try fh.close()
        try fsyncParentChecked(of: fileURL)

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

        try ioInjector.check(.read)
        let fileData: Data
        do {
            fileData = Data(try Data(contentsOf: fileURL).prefix(committedLength))
        } catch {
            throw BrowserIntakeStoreError.localIO
        }
        guard fileData.count == committedLength else { throw BrowserIntakeStoreError.localIO }
        let sha256Hex = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

        let nowMs = UInt64(civilDate.timeIntervalSince1970 * 1000.0)
        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))

        let (createdAtMs, state) = try query("SELECT created_at_ms, state FROM periods WHERE period_id = ?") { stmt in
            try bindTextChecked(stmt, 1, periodId)
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return (UInt64(sqlite3_column_int64(stmt, 0)), Self.readText(stmt, 1))
        }
        if state != "open" { return }

        let len = max(1, (durableNowMs >= createdAtMs ? (durableNowMs - createdAtMs) : 0) / 1000)
        let requestedSegment = "\(timePrefix)_\(len)"

        try execute("BEGIN IMMEDIATE;")
        var intentTransactionBegan = true
        do {
            let updateRC = try query("UPDATE periods SET state = 'finalizing', requested_day = ?, requested_segment = ?, finalize_timezone = ?, finalize_reason = ?, finalized_at_ms = ? WHERE period_id = ? AND state = 'open'") { stmt in
                try bindTextChecked(stmt, 1, dayStr)
                try bindTextChecked(stmt, 2, requestedSegment)
                try bindTextChecked(stmt, 3, timeZone.identifier)
                try bindTextChecked(stmt, 4, reason)
                try bindInt64Checked(stmt, 5, Int64(durableNowMs))
                try bindTextChecked(stmt, 6, periodId)
                return try stepChecked(stmt)
            }
            guard updateRC == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            try execute("COMMIT;")
            intentTransactionBegan = false
        } catch {
            if intentTransactionBegan {
                do { try execute("ROLLBACK;") }
                catch { isStoreFailed = true }
            }
            fileRecoveryRequired = true
            throw error
        }

        fileRecoveryRequired = true
        try ioInjector.check(.finalizePublication)
        try execute("BEGIN IMMEDIATE;")
        var publicationTransactionBegan = true
        do {
            let updateRC = try query("UPDATE periods SET state = 'finalized', file_sha256 = ?, size = ? WHERE period_id = ? AND state = 'finalizing'") { stmt in
                try bindTextChecked(stmt, 1, sha256Hex)
                try bindInt64Checked(stmt, 2, Int64(committedLength))
                try bindTextChecked(stmt, 3, periodId)
                return try stepChecked(stmt)
            }
            guard updateRC == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            try execute("COMMIT;")
            publicationTransactionBegan = false
            fileRecoveryRequired = false
        } catch {
            if publicationTransactionBegan {
                do { try execute("ROLLBACK;") }
                catch { isStoreFailed = true }
            }
            fileRecoveryRequired = true
            throw error
        }

        if currentOpenPeriodId == periodId {
            currentOpenPeriodId = nil
            if openReplacement, activeGeneration != nil {
                do {
                    _ = try ensureOpenPeriodLocked(nowMs: durableNowMs)
                } catch {
                    isStoreFailed = true
                    throw error
                }
            }
        }
    }

    func persistDeliveryBinding(_ ack: BrowserIngestAck) throws {
        lock.lock()
        defer { lock.unlock() }
        try persistDeliveryBindingLocked(ack)
    }

    private func persistDeliveryBindingLocked(_ ack: BrowserIngestAck) throws {
        try requireCurrentDeliveryLocked(periodGeneration: ack.generation)
        guard let period = getPeriodLocked(periodId: ack.periodId),
              BrowserOpaqueString.equals(period.generation, ack.generation),
              period.state == "finalized",
              BrowserOpaqueString.equals(period.requestedDay, ack.requestedDay),
              BrowserOpaqueString.equals(period.requestedSegment, ack.requestedSegment),
              BrowserOpaqueString.equals(period.fileSha256, ack.sha256),
              period.committedLength == Int(ack.size),
              ack.source == "browser",
              BrowserOpaqueString.equals(ack.filename, "browser_pages.jsonl"),
              ack.metadata == nil else {
            throw BrowserIntakeStoreError.staleGeneration
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(ack)
        let binding = String(decoding: encoded, as: UTF8.self)
        if let existing = period.deliveryBinding, Data(existing.utf8) != Data(binding.utf8) {
            throw BrowserIntakeStoreError.localIO
        }
        guard period.deliveryBinding == nil else { return }
        try query("UPDATE periods SET delivery_binding = ?, canonical_key = ?, ack_durable = 0 WHERE period_id = ? AND state = 'finalized'") { stmt in
            try bindTextChecked(stmt, 1, binding)
            if let key = ack.canonicalKey { try bindTextChecked(stmt, 2, key) } else { try bindNullChecked(stmt, 2) }
            try bindTextChecked(stmt, 3, ack.periodId)
            guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func publishDeliveryAck(_ ack: BrowserIngestAck) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }

        try persistDeliveryBindingLocked(ack)
        try requireCurrentDeliveryLocked(periodGeneration: ack.generation)
        let periodURL = periodFileURL(for: ack.periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: periodURL.deletingLastPathComponent())
        try BrowserIngestAckStore.write(ack, to: ackURL, ioInjector: ioInjector)
        try requireCurrentDeliveryLocked(periodGeneration: ack.generation)
        try markAckDurableLocked(periodId: ack.periodId, periodGeneration: ack.generation)
    }

    func storedDeliveryBinding(periodId: String) throws -> BrowserIngestAck? {
        lock.lock()
        defer { lock.unlock() }
        guard let encoded = getPeriodLocked(periodId: periodId)?.deliveryBinding else { return nil }
        guard let data = encoded.data(using: .utf8) else { throw BrowserIntakeStoreError.localIO }
        return try JSONDecoder().decode(BrowserIngestAck.self, from: data)
    }

    func markAckDurable(periodId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let period = getPeriodLocked(periodId: periodId) else { throw BrowserIntakeStoreError.staleGeneration }
        try requireCurrentDeliveryLocked(periodGeneration: period.generation)
        try markAckDurableLocked(periodId: periodId, periodGeneration: period.generation)
    }

    private func markAckDurableLocked(periodId: String, periodGeneration: String) throws {
        try requireCurrentDeliveryLocked(periodGeneration: periodGeneration)
        try query("UPDATE periods SET ack_durable = 1 WHERE period_id = ? AND delivery_binding IS NOT NULL AND state = 'finalized'") { stmt in
            try bindTextChecked(stmt, 1, periodId)
            guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func releaseProven(periodId: String, binding: BrowserIngestAck, nowMs: UInt64) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }
        try terminalAndUnlinkLocked(periodId: periodId, binding: binding, state: "delivered", nowMs: nowMs, requireAck: true)
    }

    func removeProvenSegment(periodId: String, binding: BrowserIngestAck, nowMs: UInt64) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }
        if getPeriodLocked(periodId: periodId)?.state != "removed" {
            try persistDeliveryBindingLocked(binding)
        }
        try terminalAndUnlinkLocked(periodId: periodId, binding: binding, state: "removed", nowMs: nowMs, requireAck: false)
    }

    private func terminalAndUnlinkLocked(periodId: String, binding: BrowserIngestAck, state: String, nowMs: UInt64, requireAck: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expectedBinding = String(decoding: try encoder.encode(binding), as: UTF8.self)
        guard let period = getPeriodLocked(periodId: periodId),
              period.deliveryBinding != nil,
              period.deliveryBinding.map({ Data($0.utf8) == Data(expectedBinding.utf8) }) == true,
              BrowserOpaqueString.equals(period.generation, binding.generation),
              BrowserOpaqueString.equals(period.requestedDay, binding.requestedDay),
              BrowserOpaqueString.equals(period.requestedSegment, binding.requestedSegment),
              BrowserOpaqueString.equals(period.fileSha256, binding.sha256),
              period.committedLength == Int(binding.size),
              binding.source == "browser",
              BrowserOpaqueString.equals(binding.periodId, periodId),
              BrowserOpaqueString.equals(binding.filename, "browser_pages.jsonl"),
              binding.metadata == nil,
              (!requireAck || period.ackDurable) else {
            throw BrowserIntakeStoreError.staleGeneration
        }
        if period.state != state {
            guard period.state == "finalized" else { throw BrowserIntakeStoreError.staleGeneration }
            try requireCurrentDeliveryLocked(periodGeneration: period.generation)
            try query("UPDATE periods SET state = ?, canonical_key = ?, delivered_at_ms = ?, cleanup_durable = 0 WHERE period_id = ? AND state IN ('finalized', 'delivered', 'removed')") { stmt in
                try bindTextChecked(stmt, 1, state)
                if let key = binding.canonicalKey { try bindTextChecked(stmt, 2, key) } else { try bindNullChecked(stmt, 2) }
                try bindInt64Checked(stmt, 3, Int64(nowMs))
                try bindTextChecked(stmt, 4, periodId)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
        }
        let fileURL = periodFileURL(for: periodId)
        try Self.assertNoSymlinkAncestors(fileURL)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try Self.assertRegularFile(fileURL)
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: fileURL)
            }
            try fsyncParentChecked(of: fileURL)
            try query("UPDATE periods SET cleanup_durable = 1 WHERE period_id = ? AND state = ?") { stmt in
                try bindTextChecked(stmt, 1, periodId)
                try bindTextChecked(stmt, 2, state)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
        } catch {
            isStoreFailed = true
            Logger.storage.error("Browser spool terminal cleanup failed for period \(periodId, privacy: .public)")
            throw BrowserIntakeStoreError.localIO
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
            let expiredPeriods = try query("""
                SELECT period_id FROM periods
                WHERE (state IN ('delivered', 'removed') AND cleanup_durable = 1
                       AND delivered_at_ms IS NOT NULL AND delivered_at_ms < ?)
                   OR (state = 'retired' AND committed_length = 0 AND created_at_ms < ?
                       AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.period_id = periods.period_id))
                """) { stmt in
                try bindInt64Checked(stmt, 1, Int64(cutoff))
                try bindInt64Checked(stmt, 2, Int64(cutoff))
                var ids: [String] = []
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return ids }
                    guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                    ids.append(id)
                }
            }

            for id in expiredPeriods {
                let payloadURL = periodFileURL(for: id)
                try Self.assertNoSymlinkAncestors(payloadURL)
                guard !FileManager.default.fileExists(atPath: payloadURL.path) else { throw BrowserIntakeStoreError.localIO }
                let ackURL = BrowserIngestAckStore.ackURL(
                    periodDirectory: periodFileURL(for: id).deletingLastPathComponent()
                )
                try Self.assertNoSymlinkAncestors(ackURL)
                if FileManager.default.fileExists(atPath: ackURL.path) {
                    try Self.assertRegularFile(ackURL)
                    try FileManager.default.removeItem(at: ackURL)
                }
                let directory = payloadURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: directory.path) {
                    try fsyncParentChecked(of: ackURL)
                } else {
                    try fsyncParentChecked(of: directory)
                }
            }

            try execute("BEGIN IMMEDIATE;")
            for id in expiredPeriods {
                let escaped = id.replacingOccurrences(of: "'", with: "''")
                try execute("DELETE FROM period_contexts WHERE period_id = '\(escaped)';")
                try execute("DELETE FROM receipts WHERE period_id = '\(escaped)' AND result = 'accepted';")
                try execute("DELETE FROM periods WHERE period_id = '\(escaped)' AND (state IN ('delivered', 'removed') OR (state = 'retired' AND committed_length = 0));")
            }
            try execute("DELETE FROM receipts WHERE result = 'rejected' AND reason = 'expired_unaccepted' AND accepted_at_ms IS NOT NULL AND accepted_at_ms <= \(cutoff);")
            try execute("DELETE FROM batch_seen WHERE queued_at_ms <= \(cutoff) AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.generation = batch_seen.generation AND r.inst = batch_seen.inst AND r.batch_id = batch_seen.batch_id);")
            // Keep the most recent identity as a reload fence even if all its
            // old periods have gone; retire older unreferenced history only.
            try execute("""
                DELETE FROM epoch WHERE status != 'active' AND retired_at_ms < \(cutoff)
                AND id != (SELECT MAX(id) FROM epoch)
                AND NOT EXISTS (SELECT 1 FROM periods p WHERE p.generation = epoch.destination_generation)
                AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.generation = epoch.destination_generation)
                AND NOT EXISTS (SELECT 1 FROM batch_seen b WHERE b.generation = epoch.destination_generation);
                """)
            try execute("COMMIT;")
            try reclaimEmptyUnreferencedPeriodDirectories()
            recalculateCounters()
        } catch {
            try? execute("ROLLBACK;")
            isStoreFailed = true
            Logger.storage.error("Browser spool retention cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
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
        do {
            return try query("SELECT generation, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key, delivery_binding, ack_durable, delivered_at_ms, cleanup_durable, finalize_timezone FROM periods WHERE period_id = ?") { stmt in
                try bindTextChecked(stmt, 1, periodId)
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return nil }
                guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                return try storedPeriod(from: stmt, periodId: periodId, includesPeriodId: false)
            }
        } catch {
            isStoreFailed = true
            return nil
        }
    }

    private func storedPeriod(from stmt: OpaquePointer, periodId: String?, includesPeriodId: Bool) throws -> BrowserStoredPeriod {
        let idOffset: Int32 = includesPeriodId ? 1 : 0
        let pid = includesPeriodId ? Self.readText(stmt, 0) : periodId
        guard let pid,
              let generation = Self.readText(stmt, idOffset),
              let state = Self.readText(stmt, idOffset + 1) else {
            throw BrowserIntakeStoreError.localIO
        }
        let rDay = Self.readText(stmt, idOffset + 2)
        let rSeg = Self.readText(stmt, idOffset + 3)
        let sha = Self.readText(stmt, idOffset + 4)
        let size = Int(sqlite3_column_int64(stmt, idOffset + 5))
        let committedLength = Int(sqlite3_column_int64(stmt, idOffset + 6))
        let createdAt = UInt64(sqlite3_column_int64(stmt, idOffset + 7))
        let finalizedAt = sqlite3_column_type(stmt, idOffset + 8) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, idOffset + 8)) : nil
        let canonicalKey = Self.readText(stmt, idOffset + 9)
        let deliveryBinding = Self.readText(stmt, idOffset + 10)
        let ackDurable = sqlite3_column_int(stmt, idOffset + 11) != 0
        let deliveredAt = sqlite3_column_type(stmt, idOffset + 12) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, idOffset + 12)) : nil
        let cleanupDurable = sqlite3_column_int(stmt, idOffset + 13) != 0
        let finalizeTimeZone = Self.readText(stmt, idOffset + 14)
        return BrowserStoredPeriod(
            periodId: pid,
            generation: generation,
            state: state,
            requestedDay: rDay,
            requestedSegment: rSeg,
            finalizeTimeZone: finalizeTimeZone,
            fileSha256: sha,
            size: size,
            committedLength: committedLength,
            createdAtMs: createdAt,
            finalizedAtMs: finalizedAt,
            canonicalKey: canonicalKey,
            deliveryBinding: deliveryBinding,
            ackDurable: ackDurable,
            deliveredAtMs: deliveredAt,
            cleanupDurable: cleanupDurable
        )
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
        do {
            try query("SELECT period_id, generation, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key, delivery_binding, ack_durable, delivered_at_ms, cleanup_durable, finalize_timezone FROM periods WHERE state = 'finalized' ORDER BY created_at_ms ASC") { stmt in
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                    results.append(try storedPeriod(from: stmt, periodId: nil, includesPeriodId: true))
                }
            }
        } catch {
            isStoreFailed = true
            heldPayloadBytes = Int.max
            Logger.storage.error("Browser finalized-period read failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return results
    }
}

#endif
