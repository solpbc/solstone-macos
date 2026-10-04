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
    case ownerFailurePublication
}

public struct BrowserPendingDiscardToken: Sendable, Equatable {
    let storeIncarnation: UUID
    let openPeriodId: String?
    let finalizedPeriodIds: [String]
}

public enum BrowserPendingDiscardInventory: Sendable, Equatable {
    case empty
    case unavailable
    case present(BrowserPendingDiscardToken)
}

struct BrowserPendingDiscardObservation: Sendable {
    let durablyCompleted: Bool
    let inventory: BrowserPendingDiscardInventory
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
    public let state: String // "open", "finalized", "delivered", "removed", "discarded"
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
public final class BrowserIntakeStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private let projection: BrowserContractProjection
    let ioInjector: BrowserIntakeIOInjector
    private let metadataPageLimit: Int
    private let metadataPageBytes = 4096
    // Reserve 256 KiB for each active period's finalization, bounded binding,
    // receipt and terminal updates, plus 512 KiB for clocks and cleanup.
    // An empty replacement counts as a prospective active period.
    private let drainPagesPerActivePeriod = 64
    private let fixedDrainPages = 128
    #if DEBUG || SOLSTONE_TEST_SUPPORT
    private var automaticFullRollbackCount = 0
    #endif
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

    private let storeIncarnation = UUID()
    private var destinationGeneration: String?
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
    private var stagingPeriodIDs: [URL: String] = [:]
    private var fileRecoveryRequired = false

    public static func receiptDedupBytes(generation: String, inst: String, batchId: String, periodId: String?) -> Int {
        generation.utf8.count + inst.utf8.count + batchId.utf8.count + (periodId?.utf8.count ?? 0)
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

    @discardableResult
    func setStoreFailed(_ failed: Bool, forDestinationGeneration generation: String?) -> Bool {
        lock.withLock {
            guard destinationGeneration == generation else { return false }
            isStoreFailed = failed
            return true
        }
    }

    public func storeIsFailed() -> Bool {
        lock.withLock { isStoreFailed }
    }

    func currentDeliveryPermit() -> BrowserUploadPermit? {
        lock.withLock {
            guard deliveryProofsOpen, !deliveryStopped, !isStoreFailed,
                  let activeIdentityToken else { return nil }
            return BrowserUploadPermit(identityToken: activeIdentityToken)
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

    func resumeDeliveryAfterDrain() {
        lock.withLock { deliveryStopped = false }
    }

    func reopenDeliveryProofs() {
        lock.withLock {
            if !deliveryStopped { deliveryProofsOpen = true }
        }
    }

    func registerStagingDirectory(_ url: URL, reservedBytes: Int, periodId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !deliveryStopped, !isStoreFailed else { throw BrowserIntakeStoreError.localIO }
        try Self.assertNoSymlinkAncestors(url)
        stagingDirectories.append(url)
        stagingReservations[url] = max(0, reservedBytes)
        stagingPeriodIDs[url] = periodId
        do {
            // Delivery consumes its already-reserved copy and drain metadata.
            // Admission headroom may be exhausted without blocking that work.
            if try productionFootprintBytesLocked() > projection.policy.spoolBytes {
                stagingDirectories.removeAll { $0 == url }
                stagingReservations.removeValue(forKey: url)
                throw BrowserIntakeStoreError.resourceExhausted
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Self.chmodPath(url, 0o700)
        } catch {
            stagingDirectories.removeAll { $0 == url }
            stagingReservations.removeValue(forKey: url)
            stagingPeriodIDs.removeValue(forKey: url)
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
        // The reservation protects bytes that are still present in this process. Once
        // unlink is confirmed, release it even if syncing the parent directory fails.
        stagingDirectories.removeAll { $0 == url }
        stagingReservations.removeValue(forKey: url)
        stagingPeriodIDs.removeValue(forKey: url)
        try Self.assertNoSymlinkAncestors(url.deletingLastPathComponent())
        try fsyncParentChecked(of: url)
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

    public convenience init(rootURL: URL, projection: BrowserContractProjection) throws {
        try self.init(rootURL: rootURL, projection: projection, ioInjector: BrowserIntakeIOInjector())
    }

    init(rootURL: URL, projection: BrowserContractProjection, ioInjector: BrowserIntakeIOInjector,
         ageClock: @escaping @Sendable () -> BrowserAgeStamp? = BrowserAgeStamp.current,
         metadataPageLimit: Int = 4096) throws {
        self.rootURL = rootURL
        self.projection = projection
        self.ioInjector = ioInjector
        self.ageClock = ageClock
        guard metadataPageLimit >= 256, metadataPageLimit <= 4096 else { throw BrowserIntakeStoreError.localIO }
        self.metadataPageLimit = metadataPageLimit
        var stage = "root-check"
        do {
            try Self.assertNoSymlinkAncestors(rootURL)
            stage = "root-create"
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            stage = "root-chmod"
            try Self.chmodPath(rootURL, 0o700)
            let dbURL = rootURL.appendingPathComponent("intake.sqlite")
            stage = "schema-version"
            if try Self.userVersion(at: dbURL) != 1 {
                try resetSpoolContents()
            }
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

            stage = "database"
            try validateDatabasePaths()
            let databaseFiles: Set<String> = ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm", "intake.sqlite-journal"]
            for item in try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
                var info = stat()
                guard lstat(item.path, &info) == 0 else { throw BrowserIntakeStoreError.localIO }
                let kind = info.st_mode & S_IFMT
                if databaseFiles.contains(item.lastPathComponent) {
                    guard kind == S_IFREG else { throw BrowserIntakeStoreError.localIO }
                } else {
                    // A version-1 spool keeps unrelated directories in place;
                    // they are not part of the store and are never traversed.
                    guard kind == S_IFDIR else { throw BrowserIntakeStoreError.localIO }
                }
            }
            for directory in try FileManager.default.contentsOfDirectory(at: periodsDir, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: directory.lastPathComponent) != nil else { throw BrowserIntakeStoreError.localIO }
                try Self.assertNoSymlinkAncestors(directory)
                for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    let name = child.lastPathComponent
                    let temporaryAck = name.hasPrefix(".browser_ingest_ack.json.") && name.hasSuffix(".tmp")
                        && UUID(uuidString: String(name.dropFirst(".browser_ingest_ack.json.".count).dropLast(4))) != nil
                    let discardTemp = Self.isDiscardTempName(name)
                    guard name == "browser_pages.jsonl" || name == "browser_ingest_ack.json"
                            || name == ".browser_pages.jsonl.discard-backup" || temporaryAck || discardTemp else {
                        throw BrowserIntakeStoreError.localIO
                    }
                    try Self.assertRegularFile(child)
                }
            }
            if let databaseBytes = try Self.fileByteCount(dbURL), databaseBytes > metadataPageLimit * metadataPageBytes {
                throw BrowserIntakeStoreError.resourceExhausted
            }
            // Bound an old WAL before opening can checkpoint it. Every possible
            // committed page number must fit the new DB cap; repeated frames
            // may be large, but are refused rather than erased to make room.
            let walURL = rootURL.appendingPathComponent("intake.sqlite-wal")
            if let walBytes = try Self.fileByteCount(walURL), walBytes > 0 {
                guard walBytes <= metadataReservationBytes else { throw BrowserIntakeStoreError.resourceExhausted }
                let wal = try Data(contentsOf: walURL)
                func word(_ offset: Int) -> UInt32 {
                    wal[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
                guard wal.count >= 32, [UInt32(0x377f0682), UInt32(0x377f0683)].contains(word(0)),
                      word(8) == UInt32(metadataPageBytes), (wal.count - 32) % (metadataPageBytes + 24) == 0 else {
                    throw BrowserIntakeStoreError.localIO
                }
                for offset in stride(from: 32, to: wal.count, by: metadataPageBytes + 24) {
                    guard word(offset) > 0, word(offset) <= UInt32(metadataPageLimit),
                          word(offset + 4) <= UInt32(metadataPageLimit) else { throw BrowserIntakeStoreError.resourceExhausted }
                }
            }
            // Opening an old WAL can recover/checkpoint it. Reserve that work
            // before SQLite can write, preserving an oversized store as-is.
            guard try activePreopenFootprintBytes() <= projection.policy.spoolBytes else {
                throw BrowserIntakeStoreError.resourceExhausted
            }
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
            guard try activePreopenFootprintBytes() <= projection.policy.spoolBytes else {
                throw BrowserIntakeStoreError.resourceExhausted
            }
        } catch {
            if let db { sqlite3_close_v2(db); self.db = nil }
            Logger.storage.error("Browser spool initialization failed at \(stage, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func userVersion(at databaseURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        try assertNoSymlinkAncestors(databaseURL)
        try assertRegularFile(databaseURL)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else { throw BrowserIntakeStoreError.localIO }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw BrowserIntakeStoreError.localIO }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func resetSpoolContents() throws {
        for item in try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            try ioInjector.check(.write)
            try FileManager.default.removeItem(at: item)
        }
        try ioInjector.check(.sync)
        try syncDirectory(rootURL)
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
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            sqlite3_free(err)
            if rc & 0xff == SQLITE_FULL {
                noteFullRollbackLocked()
                throw BrowserIntakeStoreError.resourceExhausted
            }
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
        let rc = sqlite3_step(stmt)
        if rc & 0xff == SQLITE_FULL {
            noteFullRollbackLocked()
            throw BrowserIntakeStoreError.resourceExhausted
        }
        return rc
    }

    private func noteFullRollbackLocked() {
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        if sqlite3_get_autocommit(db) != 0 { automaticFullRollbackCount += 1 }
        #endif
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    func setSQLitePageLimitForValidation(_ pages: Int) throws {
        try lock.withLock {
            guard pages > 0, pages <= metadataPageLimit,
                  try integerPragmaLocked("max_page_count = \(pages)") == pages else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func sqlitePagesForValidation() throws -> (allocated: Int, free: Int, fullRollbacks: Int) {
        try lock.withLock {
            (try integerPragmaLocked("page_count"), try integerPragmaLocked("freelist_count"), automaticFullRollbackCount)
        }
    }
    #endif

    private func rollbackIfActiveLocked() throws {
        // FULL can already have rolled back the transaction.
        if sqlite3_get_autocommit(db) == 0 { try execute("ROLLBACK;") }
    }

    private func integerPragmaLocked(_ name: String) throws -> Int {
        try query("PRAGMA \(name)") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // Reserve the entire hard DB bound, its rollback journal and conservative
    // journal framing, rather than charge lexical row sizes as physical growth.
    private var metadataReservationBytes: Int { metadataPageLimit * metadataPageBytes * 3 + 64 * 1024 }

    private func metadataAdmissionFitsLocked(additionalBytes: Int = 0) throws -> Bool {
        let allocated = try integerPragmaLocked("page_count")
        let free = try integerPragmaLocked("freelist_count")
        let periods = try query("SELECT COUNT(*), MAX(CASE WHEN state = 'open' THEN 1 ELSE 0 END) FROM periods WHERE state IN ('open', 'finalizing', 'finalized')") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return (count: Int(sqlite3_column_int64(stmt, 0)), hasOpen: sqlite3_column_int(stmt, 1) == 1)
        }
        let prospectivePages = Self.saturatingAdd(max(0, additionalBytes), metadataPageBytes - 1) / metadataPageBytes
        let reserve = fixedDrainPages + (periods.count + (periods.hasOpen ? 0 : 1)) * drainPagesPerActivePeriod
        return allocated - free + reserve + prospectivePages + 4 <= metadataPageLimit
    }

    private func requireMetadataHeadroomLocked() throws {
        guard try metadataAdmissionFitsLocked() else { throw BrowserIntakeStoreError.resourceExhausted }
    }

    private func admissionMetadataTransactionLocked<T>(_ operation: () throws -> T) throws -> T {
        try requireMetadataHeadroomLocked()
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try operation()
            try requireMetadataHeadroomLocked()
            guard try productionFootprintBytesLocked() <= projection.policy.spoolBytes else {
                throw BrowserIntakeStoreError.resourceExhausted
            }
            try execute("COMMIT;")
            return result
        } catch {
            do { try rollbackIfActiveLocked() }
            catch { isStoreFailed = true }
            throw error
        }
    }

    private func validateDatabasePaths() throws {
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm", "intake.sqlite-journal"] {
            let url = rootURL.appendingPathComponent(name)
            try Self.assertNoSymlinkAncestors(url)
            if FileManager.default.fileExists(atPath: url.path) {
                try Self.assertRegularFile(url)
            }
        }
    }

    private func activePreopenFootprintBytes() throws -> Int {
        let periods = try directoryFootprintBytes(rootURL.appendingPathComponent("periods", isDirectory: true))
        let staging = try directoryFootprintBytes(rootURL.appendingPathComponent("staging", isDirectory: true))
        var sqliteBytes = 0
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm", "intake.sqlite-journal"] {
            let url = rootURL.appendingPathComponent(name)
            try ioInjector.check(.size)
            let actual = try Self.fileByteCount(url)
            if let bytes = ioInjector.size(for: url, actual: actual) {
                sqliteBytes = Self.saturatingAdd(sqliteBytes, bytes)
            }
        }
        return Self.saturatingAdd(Self.saturatingAdd(Self.saturatingAdd(periods, staging), sqliteBytes), metadataReservationBytes)
    }

    private func syncActivePeriodDirectory() throws {
        let directory = rootURL.appendingPathComponent("periods", isDirectory: true)
        try Self.assertNoSymlinkAncestors(directory)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw BrowserIntakeStoreError.localIO
        }
        try syncDirectory(directory)
    }

    private func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw BrowserIntakeStoreError.localIO }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw BrowserIntakeStoreError.localIO }
    }

    private func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fullSync(_ handle: FileHandle) throws {
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else { throw BrowserIntakeStoreError.localIO }
    }

    private func initSchema() throws {
        try execute("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA cache_spill = OFF; PRAGMA temp_store = MEMORY;")
        if try integerPragmaLocked("user_version") != 1 {
            try execute("BEGIN IMMEDIATE;")
            do {
            try execute("""
            CREATE TABLE periods (
                period_id TEXT PRIMARY KEY,
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
                delivered_at_ms INTEGER,
                cleanup_durable INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE period_contexts (
                period_id TEXT NOT NULL,
                inst TEXT NOT NULL,
                ctx TEXT NOT NULL,
                initialized_at_ms INTEGER NOT NULL,
                PRIMARY KEY (period_id, inst, ctx)
            );

            CREATE TABLE receipts (
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
                PRIMARY KEY (inst, batch_id)
            );

            CREATE TABLE age_clock (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                boot_id TEXT NOT NULL,
                elapsed_ms INTEGER NOT NULL,
                floor_ms INTEGER NOT NULL
            );

            CREATE TABLE connection (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                destination_generation TEXT
            );

            CREATE TABLE spool_state (
                key TEXT PRIMARY KEY,
                int_value INTEGER NOT NULL
            );

            INSERT INTO connection (id, destination_generation) VALUES (1, NULL);
            """)
            try execute("PRAGMA user_version = 1;")
            try execute("COMMIT;")
            } catch {
                try? rollbackIfActiveLocked()
                throw error
            }
        }
        let pageSize = try integerPragmaLocked("page_size")
        let limit = try integerPragmaLocked("max_page_count = \(metadataPageLimit)")
        let deleteJournal = try query("PRAGMA journal_mode") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return Self.readText(stmt, 0) == "delete"
        }
        guard pageSize == metadataPageBytes, limit == metadataPageLimit, deleteJournal,
              try integerPragmaLocked("cache_spill") == 0,
              try integerPragmaLocked("temp_store") == 2 else { throw BrowserIntakeStoreError.localIO }
        let fullSyncEnabled = try query("PRAGMA fullfsync") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return sqlite3_column_int(stmt, 0) == 1
        }
        guard fullSyncEnabled else { throw BrowserIntakeStoreError.localIO }
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
        destinationGeneration = try query("SELECT destination_generation FROM connection WHERE id = 1") { stmt -> String? in
            let rc = try stepChecked(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return Self.readText(stmt, 0)
        }

        try recoverDiscardArtifacts()
        try recoverPeriodFiles()
        if !isStoreFailed { try recoverTerminalCleanup() }
        do {
            try reclaimAbandonedStaging()
            stagingReservations.removeAll()
            stagingPeriodIDs.removeAll()
            stagingDirectories.removeAll()
            try reclaimEmptyUnreferencedPeriodDirectories()
        } catch {
            // Keep custody inspectable when unexpected contents or failed
            // cleanup prevent safely recovering the delivery reserve.
            isStoreFailed = true
        }

        currentOpenPeriodId = try query("SELECT period_id FROM periods WHERE state = 'open' ORDER BY created_at_ms DESC LIMIT 1") { stmt in
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return nil }
                guard rc == SQLITE_ROW, let periodId = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                return periodId
        }

        // A readable database with damaged custody must still project the held
        // data and local failure. Mutations and delivery remain fail-closed.
        recalculateCounters(clearStalenessWhenEmpty: true)
    }

    private static func isDiscardTempName(_ name: String) -> Bool {
        let prefix = ".browser_pages.jsonl."
        let suffix = ".discard.tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuid = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: uuid) != nil
    }

    private func recoverDiscardArtifacts() throws {
        let periodsRoot = rootURL.appendingPathComponent("periods", isDirectory: true)
        for directory in try FileManager.default.contentsOfDirectory(at: periodsRoot, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { throw BrowserIntakeStoreError.localIO }
            let periodId = directory.lastPathComponent
            let payload = periodFileURL(for: periodId)
            let backup = discardBackupURL(for: payload)
            var changed = false
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where Self.isDiscardTempName(item.lastPathComponent) {
                try FileManager.default.removeItem(at: item)
                changed = true
            }
            if FileManager.default.fileExists(atPath: backup.path) {
                let state = try query("SELECT state, committed_length, cleanup_durable FROM periods WHERE period_id = ?") { stmt -> (String?, Int, Bool)? in
                    try bindTextChecked(stmt, 1, periodId)
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return nil }
                    guard rc == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                    return (Self.readText(stmt, 0), Int(sqlite3_column_int64(stmt, 1)), sqlite3_column_int(stmt, 2) != 0)
                }
                if let (state, committed, cleanupDurable) = state,
                   state == "discarded" || cleanupDurable || (state == "open" && committed == 0) {
                    if state == "discarded" || cleanupDurable {
                        if FileManager.default.fileExists(atPath: payload.path) {
                            try FileManager.default.removeItem(at: payload)
                        }
                    } else if !FileManager.default.fileExists(atPath: payload.path) {
                        try createEmptyPeriodFileLocked(periodId)
                    }
                    try FileManager.default.removeItem(at: backup)
                    changed = true
                } else {
                    try restoreDiscardBackupLocked(backup, to: payload)
                    changed = true
                }
            }
            if changed { try fsyncParentChecked(of: payload) }
        }
    }

    private func recoverTerminalCleanup() throws {
        let pending = try query("SELECT period_id, state, delivery_binding FROM periods WHERE state IN ('delivered', 'removed') AND cleanup_durable = 0") { stmt in
            var rows: [(String, String, String)] = []
            while true {
                let rc = try stepChecked(stmt)
                if rc == SQLITE_DONE { return rows }
                guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0),
                      let state = Self.readText(stmt, 1), let binding = Self.readText(stmt, 2) else {
                    throw BrowserIntakeStoreError.localIO
                }
                rows.append((id, state, binding))
            }
        }
        for (id, state, encoded) in pending {
            let binding = try JSONDecoder().decode(BrowserDeliveryBinding.self, from: Data(encoded.utf8))
            try terminalAndUnlinkLocked(periodId: id, binding: binding, state: state,
                nowMs: storedFloorMs, requireAck: state == "delivered")
        }
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
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw BrowserIntakeStoreError.localIO
            }
            let removedPath = directory.standardizedFileURL.path
            stagingDirectories.removeAll { $0.standardizedFileURL.path == removedPath }
            let reservedURLs = stagingReservations.keys.filter {
                $0.standardizedFileURL.path == removedPath
            }
            for reservedURL in reservedURLs { stagingReservations.removeValue(forKey: reservedURL) }
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
            guard UUID(uuidString: id) != nil else { throw BrowserIntakeStoreError.localIO }
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
        try prepareChecked("SELECT period_id, committed_length, state, requested_day, requested_segment, file_sha256, cleanup_durable FROM periods WHERE state IN ('open', 'finalized', 'finalizing', 'delivered', 'removed')", &stmt)
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
                if state == "delivered" || state == "removed" {
                    // The terminal proof is validated before cleanup resumes.
                    continue
                }
                if state == "open" && committed == 0 {
                    try createEmptyPeriodFileLocked(pid)
                } else {
                    isStoreFailed = true
                }
                continue
            }
            let bytes = size ?? 0
            if bytes < committed {
                isStoreFailed = true
                continue
            }
            if state == "finalized" || state == "delivered" || state == "removed" {
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

    }

    private func recalculateCounters(clearStalenessWhenEmpty: Bool = false) {
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
            heldDedupBytes = dedupBytes

            earliestHeldMs = try query("SELECT MIN(accepted_at_ms) FROM receipts r JOIN periods p ON r.period_id = p.period_id WHERE p.state IN ('open', 'finalized', 'delivered', 'removed') AND p.cleanup_durable = 0 AND r.accepted_at_ms IS NOT NULL") { stmt in
                guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
                return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : UInt64(sqlite3_column_int64(stmt, 0))
            }

            storedFloorMs = max(storedFloorMs, try optionalStateValue("floor_ms") ?? 0)
            if heldPayloadBytes == 0 && clearStalenessWhenEmpty {
                try execute("DELETE FROM spool_state WHERE key IN ('stale_anchor_ms', 'stale_elapsed_ms');")
                staleAnchorMs = 0
                staleElapsedHighWaterMs = 0
            } else {
                staleAnchorMs = try optionalStateValue("stale_anchor_ms") ?? 0
                staleElapsedHighWaterMs = try optionalStateValue("stale_elapsed_ms") ?? 0
            }
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
                guard !isStoreFailed,
                      period.state == "finalized" || ((period.state == "delivered" || period.state == "removed") && !period.cleanupDurable),
                      let digest = period.fileSha256 else {
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
        guard let stamp = ageClock(), stamp.elapsedMs <= UInt64(Int64.max),
              !stamp.bootID.isEmpty, stamp.bootID.utf8.count <= 128 else {
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
        if !isStoreFailed, !deliveryStopped, currentOpenPeriodId == nil,
           activeIdentityToken != nil, destinationGeneration != nil {
            do { _ = try ensureOpenPeriodLocked(nowMs: storedFloorMs) }
            catch BrowserIntakeStoreError.resourceExhausted { }
            catch { isStoreFailed = true }
        }
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
        let custody: [String: Bool] = ["full": isFull, "stale": held && isStale]
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

        guard let gen = destinationGeneration, !gen.isEmpty else {
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

    func reconcileIdentity(_ token: String?, mode: BrowserIdentityChangeMode, nowMs: UInt64) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !isStoreFailed, !deliveryStopped else { throw BrowserIntakeStoreError.localIO }

        guard let token, !token.isEmpty else {
            try execute("INSERT OR REPLACE INTO connection (id, destination_generation) VALUES (1, NULL);")
            destinationGeneration = nil
            activeIdentityToken = nil
            deliveryFailure = nil
            deliveryProofsOpen = false
            return nil
        }

        let digest = Self.identityDigest(of: token)
        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))
        let shouldMint: Bool
        switch mode {
        case .replace:
            shouldMint = true
        case .reload:
            shouldMint = destinationGeneration == nil
        }
        if shouldMint {
            let next = UUID().uuidString
            try query("INSERT OR REPLACE INTO connection (id, destination_generation) VALUES (1, ?)") { stmt in
                try bindTextChecked(stmt, 1, next)
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            destinationGeneration = next
        }
        if !BrowserOpaqueString.equals(activeIdentityToken, digest) || shouldMint {
            deliveryFailure = nil
        }
        activeIdentityToken = digest
        deliveryProofsOpen = true
        if currentOpenPeriodId == nil {
            do { _ = try ensureOpenPeriodLocked(nowMs: durableNowMs) }
            catch BrowserIntakeStoreError.resourceExhausted { }
        }
        return destinationGeneration
    }

    public func getDestinationGeneration() -> String? {
        lock.withLock { destinationGeneration }
    }

    public func pendingDiscardInventory() -> BrowserPendingDiscardInventory {
        lock.lock()
        defer { lock.unlock() }
        guard !isStoreFailed else { return .unavailable }
        do {
            let open = try query("SELECT period_id, committed_length FROM periods WHERE state = 'open' ORDER BY created_at_ms DESC LIMIT 1") { stmt -> (String, Int)? in
                guard try stepChecked(stmt) == SQLITE_ROW,
                      let id = Self.readText(stmt, 0) else { return nil }
                return (id, Int(sqlite3_column_int64(stmt, 1)))
            }
            let reserved = Set(stagingPeriodIDs.values)
            let finalized = try query("SELECT period_id FROM periods WHERE state IN ('finalized', 'delivered', 'removed') AND cleanup_durable = 0 AND committed_length > 0 ORDER BY created_at_ms") { stmt in
                var ids: [String] = []
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return ids }
                    guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                    if !reserved.contains(id) { ids.append(id) }
                }
            }
            let hasOpenBytes = (open?.1 ?? 0) > 0
            guard hasOpenBytes || !finalized.isEmpty else { return .empty }
            return .present(BrowserPendingDiscardToken(
                storeIncarnation: storeIncarnation,
                openPeriodId: open?.0,
                finalizedPeriodIds: finalized
            ))
        } catch {
            return .unavailable
        }
    }

    func discardPendingPages(_ token: BrowserPendingDiscardToken) -> BrowserPendingDiscardObservation {
        lock.lock()
        defer { lock.unlock() }
        guard token.storeIncarnation == storeIncarnation, !isStoreFailed else {
            return BrowserPendingDiscardObservation(durablyCompleted: false, inventory: .unavailable)
        }

        let ids = Array(Set(token.finalizedPeriodIds + (token.openPeriodId.map { [$0] } ?? []))).sorted()
        var failed = false
        for id in ids {
            if stagingPeriodIDs.values.contains(id) { continue }
            do {
                guard let period = getPeriodLocked(periodId: id) else { continue }
                if period.state == "discarded" || (period.cleanupDurable && !FileManager.default.fileExists(atPath: periodFileURL(for: id).path)) {
                    continue
                }
                if id == token.openPeriodId && period.state == "open" {
                    try emptyOpenPeriodForDiscardLocked(period)
                } else if period.state == "finalized" || period.state == "delivered" || period.state == "removed" {
                    try removeFinalizedPeriodForDiscardLocked(period)
                }
            } catch {
                failed = true
                Logger.storage.error("Browser waiting-page discard failed for period \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        recalculateCounters()
        return BrowserPendingDiscardObservation(durablyCompleted: !failed, inventory: pendingDiscardInventoryLocked())
    }

    private func pendingDiscardInventoryLocked() -> BrowserPendingDiscardInventory {
        guard !isStoreFailed else { return .unavailable }
        do {
            let open = try query("SELECT period_id, committed_length FROM periods WHERE state = 'open' ORDER BY created_at_ms DESC LIMIT 1") { stmt -> (String, Int)? in
                guard try stepChecked(stmt) == SQLITE_ROW,
                      let id = Self.readText(stmt, 0) else { return nil }
                return (id, Int(sqlite3_column_int64(stmt, 1)))
            }
            let reserved = Set(stagingPeriodIDs.values)
            let finalized = try query("SELECT period_id FROM periods WHERE state IN ('finalized', 'delivered', 'removed') AND cleanup_durable = 0 AND committed_length > 0 ORDER BY created_at_ms") { stmt in
                var ids: [String] = []
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return ids }
                    guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                    if !reserved.contains(id) { ids.append(id) }
                }
            }
            guard (open?.1 ?? 0) > 0 || !finalized.isEmpty else { return .empty }
            return .present(BrowserPendingDiscardToken(
                storeIncarnation: storeIncarnation,
                openPeriodId: open?.0,
                finalizedPeriodIds: finalized
            ))
        } catch {
            return .unavailable
        }
    }

    private func discardBackupURL(for payloadURL: URL) -> URL {
        payloadURL.deletingLastPathComponent().appendingPathComponent(".browser_pages.jsonl.discard-backup")
    }

    private func makeDiscardBackupLocked(for payloadURL: URL) throws -> URL {
        let backup = discardBackupURL(for: payloadURL)
        guard FileManager.default.fileExists(atPath: payloadURL.path),
              !FileManager.default.fileExists(atPath: backup.path) else { throw BrowserIntakeStoreError.localIO }
        try Self.assertRegularFile(payloadURL)
        try ioInjector.check(.write)
        guard Darwin.link(payloadURL.path, backup.path) == 0 else { throw BrowserIntakeStoreError.localIO }
        do {
            try fsyncParentChecked(of: backup)
            return backup
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
    }

    private func restoreDiscardBackupLocked(_ backup: URL, to payloadURL: URL) throws {
        guard FileManager.default.fileExists(atPath: backup.path) else { throw BrowserIntakeStoreError.localIO }
        if FileManager.default.fileExists(atPath: payloadURL.path) {
            try FileManager.default.removeItem(at: payloadURL)
        }
        try ioInjector.check(.write)
        guard Darwin.rename(backup.path, payloadURL.path) == 0 else { throw BrowserIntakeStoreError.localIO }
        try fsyncParentChecked(of: payloadURL)
    }

    private func removeDiscardBackupBestEffort(_ backup: URL) {
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: backup)
                try fsyncParentChecked(of: backup)
            }
        } catch {
            Logger.storage.error("Browser discard backup cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func emptyOpenPeriodForDiscardLocked(_ period: BrowserStoredPeriod) throws {
        let payload = periodFileURL(for: period.periodId)
        let backup = try makeDiscardBackupLocked(for: payload)
        let temp = payload.deletingLastPathComponent().appendingPathComponent(".browser_pages.jsonl.\(UUID().uuidString).discard.tmp")
        do {
            try ioInjector.check(.write)
            guard FileManager.default.createFile(atPath: temp.path, contents: Data()) else { throw BrowserIntakeStoreError.localIO }
            try Self.chmodPath(temp, 0o600)
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try ioInjector.check(.sync)
            try Self.fullSync(handle)
            try ioInjector.check(.write)
            guard Darwin.rename(temp.path, payload.path) == 0 else { throw BrowserIntakeStoreError.localIO }
            try fsyncParentChecked(of: payload)
            try execute("BEGIN IMMEDIATE;")
            try query("UPDATE periods SET committed_length = 0, size = 0, file_sha256 = NULL WHERE period_id = ? AND state = 'open'") { stmt in
                try bindTextChecked(stmt, 1, period.periodId)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
            try query("DELETE FROM period_contexts WHERE period_id = ?") { stmt in
                try bindTextChecked(stmt, 1, period.periodId)
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            try execute("COMMIT;")
        } catch {
            try? rollbackIfActiveLocked()
            try? FileManager.default.removeItem(at: temp)
            do { try restoreDiscardBackupLocked(backup, to: payload) }
            catch { isStoreFailed = true }
            throw error
        }
        removeDiscardBackupBestEffort(backup)
    }

    private func removeFinalizedPeriodForDiscardLocked(_ period: BrowserStoredPeriod) throws {
        let payload = periodFileURL(for: period.periodId)
        guard let digest = period.fileSha256 else { throw BrowserIntakeStoreError.localIO }
        try validatePayloadLocked(payload, length: period.committedLength, sha256: digest)
        let backup = try makeDiscardBackupLocked(for: payload)
        do {
            try ioInjector.check(.write)
            try FileManager.default.removeItem(at: payload)
            try fsyncParentChecked(of: payload)
            try execute("BEGIN IMMEDIATE;")
            try query("UPDATE periods SET state = 'discarded', cleanup_durable = 1 WHERE period_id = ? AND state IN ('finalized', 'delivered', 'removed')") { stmt in
                try bindTextChecked(stmt, 1, period.periodId)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
            try query("DELETE FROM period_contexts WHERE period_id = ?") { stmt in
                try bindTextChecked(stmt, 1, period.periodId)
                guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
            }
            try execute("COMMIT;")
        } catch {
            try? rollbackIfActiveLocked()
            do { try restoreDiscardBackupLocked(backup, to: payload) }
            catch { isStoreFailed = true }
            throw error
        }
        removeDiscardBackupBestEffort(backup)
    }

    public func lookupReceipt(generation: String, inst: String, batchId: String) throws -> BrowserStoredReceipt? {
        lock.lock()
        defer { lock.unlock() }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        try prepareChecked("SELECT result, period_id, reason, class, queued_at_ms, accepted_at_ms, size_bytes FROM receipts WHERE inst = ? AND batch_id = ?", &stmt)
        try bindTextChecked(stmt, 1, inst)
        try bindTextChecked(stmt, 2, batchId)
        let rc = try stepChecked(stmt)
        if rc == SQLITE_ROW {
            return Self.storedReceipt(from: stmt, generation: generation, inst: inst, batchId: batchId)
        }
        guard rc == SQLITE_DONE else {
            throw BrowserIntakeStoreError.localIO
        }
        return nil
    }

    private static func storedReceipt(from stmt: OpaquePointer?, generation: String, inst: String, batchId: String) -> BrowserStoredReceipt {
        BrowserStoredReceipt(
            generation: generation,
            inst: inst,
            batchId: batchId,
            result: readText(stmt, 0) ?? "",
            periodId: readText(stmt, 1),
            reason: readText(stmt, 2),
            receiptClass: readText(stmt, 3),
            queuedAtMs: UInt64(sqlite3_column_int64(stmt, 4)),
            acceptedAtMs: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, 5)) : nil,
            sizeBytes: Int(sqlite3_column_int64(stmt, 6))
        )
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
        for name in ["intake.sqlite", "intake.sqlite-wal", "intake.sqlite-shm", "intake.sqlite-journal"] {
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
            guard kind == S_IFREG || kind == S_IFDIR else { throw BrowserIntakeStoreError.localIO }
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
        let uniqueDirectories = Set((directories + Array(stagingReservations.keys)).map {
            URL(fileURLWithPath: $0.path, isDirectory: true)
        })
        for directory in uniqueDirectories {
            let actual = try directoryFootprintBytes(directory)
            let reserved = stagingReservations.filter { $0.key.path == directory.path }.values.max() ?? 0
            total = Self.saturatingAdd(total, max(reserved, actual))
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
        total = Self.saturatingAdd(total, max(metadataReservationBytes, try sqliteFootprintBytes()))
        let periods = try query("SELECT COUNT(*) FROM periods") { stmt in
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        // Account for small payload/directory overhead and both the previous
        // receipt and its bounded temporary replacement for every period.
        total = Self.saturatingAdd(total, periods * 8 * 1024)
        total = Self.saturatingAdd(total, max(periods * BrowserIngestAckStore.maximumBytes * 2,
                                            try acknowledgementFootprintBytes()))
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
        if try !metadataAdmissionFitsLocked(additionalBytes: max(1, additionalDedupBytes)) { return true }
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

    private func ensureFileRecoveryLocked() throws {
        guard fileRecoveryRequired else { return }
        try recoverPeriodFiles()
        if isStoreFailed { throw BrowserIntakeStoreError.localIO }
        fileRecoveryRequired = false
    }

    private func ensureOpenPeriodLocked(nowMs: UInt64) throws -> String {
        if let pid = currentOpenPeriodId { return pid }
        guard try !isQuotaFullLocked(additionalDedupBytes: 1) else { throw BrowserIntakeStoreError.resourceExhausted }
        let pid = UUID().uuidString
        try admissionMetadataTransactionLocked {
          try query("INSERT INTO periods (period_id, state, committed_length, created_at_ms) VALUES (?, 'open', 0, ?)") { stmt in
            try bindTextChecked(stmt, 1, pid)
            try bindInt64Checked(stmt, 2, Int64(nowMs))
            guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
          }
        }
        try createEmptyPeriodFileLocked(pid)
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
        try query("SELECT result, period_id FROM receipts WHERE inst = ? AND batch_id = ?") { stmt in
            try bindTextChecked(stmt, 1, inst)
            try bindTextChecked(stmt, 2, batchId)
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
        guard let selected = currentOpenPeriodId else { throw BrowserIntakeStoreError.resourceExhausted }
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
        let receiptGeneration = batch.destinationGeneration

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

        let newDedupBytes = Self.receiptDedupBytes(generation: receiptGeneration, inst: batch.inst, batchId: batch.batchId, periodId: pid)
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
                try bindTextChecked(stmt, 1, receiptGeneration)
                try bindTextChecked(stmt, 2, batch.inst)
                try bindTextChecked(stmt, 3, batch.batchId)
                try bindTextChecked(stmt, 4, pid)
                try bindInt64Checked(stmt, 5, Int64(batch.queuedAtMs))
                try bindInt64Checked(stmt, 6, Int64(durableNowMs))
                try bindInt64Checked(stmt, 7, Int64(batchBytesData.count))
                return try stepChecked(stmt)
            }
            if receiptRC == SQLITE_CONSTRAINT {
                if let existing = try existingAcceptedPeriodLocked(generation: receiptGeneration, inst: batch.inst, batchId: batch.batchId) {
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

            try requireMetadataHeadroomLocked()
            try execute("COMMIT;")
        } catch {
            if transactionBegan {
                do {
                    try rollbackIfActiveLocked()
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

    /// Length of one intake window. Periods rotate on this clock grid.
    static let periodWindowSeconds: TimeInterval = 300

    /// The close of the clock-aligned window that contains `date`.
    static func periodWindowEnd(containing date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let windowMinutes = Int(periodWindowSeconds) / 60
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let minute = calendar.component(.minute, from: date)
        return minuteStart.addingTimeInterval(TimeInterval((windowMinutes - minute % windowMinutes) * 60))
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
            try execute("UPDATE periods SET state = 'discarded' WHERE period_id = '\(periodId.replacingOccurrences(of: "'", with: "''"))' AND state = 'open'")
            if currentOpenPeriodId == periodId {
                currentOpenPeriodId = nil
                if openReplacement, destinationGeneration != nil {
                    do { _ = try ensureOpenPeriodLocked(nowMs: storedFloorMs) }
                    catch BrowserIntakeStoreError.resourceExhausted { }
                }
            }
            return
        }

        guard let fileBytes = try Self.fileByteCount(fileURL), fileBytes >= committedLength else {
            throw BrowserIntakeStoreError.localIO
        }
        try ioInjector.check(.read)
        let fileData: Data
        do {
            fileData = Data(try Data(contentsOf: fileURL).prefix(committedLength))
        } catch {
            throw BrowserIntakeStoreError.localIO
        }
        guard fileData.count == committedLength else { throw BrowserIntakeStoreError.localIO }
        let sha256Hex = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

        let nowMs = BrowserAgeStamp.wallMilliseconds(civilDate)
        let durableNowMs = try updateFloorMsLocked(wallNowMs: max(storedFloorMs, nowMs))

        let (createdAtMs, state) = try query("SELECT created_at_ms, state FROM periods WHERE period_id = ?") { stmt in
            try bindTextChecked(stmt, 1, periodId)
            guard try stepChecked(stmt) == SQLITE_ROW else { throw BrowserIntakeStoreError.localIO }
            return (UInt64(sqlite3_column_int64(stmt, 0)), Self.readText(stmt, 1))
        }
        if state != "open" { return }

        // The key names the period's own window: its start, and how long it
        // ran before the window closed. A period sealed late (after sleep, at
        // stop, at recovery) still ends at its window's close, not at seal.
        let periodStart = Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyyMMdd"
        dayFormatter.timeZone = timeZone
        let dayStr = dayFormatter.string(from: periodStart)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.dateFormat = "HHmmss"
        timeFormatter.timeZone = timeZone
        let timePrefix = timeFormatter.string(from: periodStart)

        let windowEndMs = BrowserAgeStamp.wallMilliseconds(Self.periodWindowEnd(containing: periodStart, timeZone: timeZone))
        let endMs = min(durableNowMs, windowEndMs)
        let len = clampedSegmentDurationSeconds(
            Double(endMs >= createdAtMs ? endMs - createdAtMs : 0) / 1000.0,
            ceiling: Self.periodWindowSeconds
        )
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
        // Commit the civil identity before changing the file. Recovery must
        // retain this destination even if the clock or time zone changes.
        let fh = try FileHandle(forWritingTo: fileURL)
        defer { try? fh.close() }
        if fileBytes > committedLength {
            try ioInjector.check(.write)
            try fh.truncate(atOffset: UInt64(committedLength))
        }
        try ioInjector.check(.sync)
        try Self.fullSync(fh)
        try fsyncParentChecked(of: fileURL)
        if crashPoint == .afterFinalizeSync {
            throw BrowserIntakeStoreError.localIO
        }
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
            if openReplacement, destinationGeneration != nil {
                do {
                    _ = try ensureOpenPeriodLocked(nowMs: durableNowMs)
                } catch BrowserIntakeStoreError.resourceExhausted {
                    // Finalized custody remains deliverable at admission pressure.
                } catch {
                    isStoreFailed = true
                    throw error
                }
            }
        }
    }

    private func encodeDeliveryBinding(_ binding: BrowserDeliveryBinding) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(binding), as: UTF8.self)
    }

    private func persistDeliveryBindingLocked(_ binding: BrowserDeliveryBinding) throws {
        let ack = binding.ack
        _ = try BrowserIngestAckStore.boundedData(ack)
        guard let period = getPeriodLocked(periodId: ack.periodId),
              period.state == "finalized" || period.state == "delivered" || period.state == "removed",
              BrowserOpaqueString.equals(period.requestedDay, ack.requestedDay),
              BrowserOpaqueString.equals(period.requestedSegment, ack.requestedSegment),
              BrowserOpaqueString.equals(period.fileSha256, ack.sha256),
              Int(exactly: ack.size) == period.committedLength,
              ack.source == "browser",
              BrowserOpaqueString.equals(ack.filename, "browser_pages.jsonl"),
              ack.metadata == nil else {
            throw BrowserIntakeStoreError.localIO
        }
        let encoded = try encodeDeliveryBinding(binding)
        if let existing = period.deliveryBinding, Data(existing.utf8) != Data(encoded.utf8) {
            let payloadURL = periodFileURL(for: ack.periodId)
            guard !period.cleanupDurable, FileManager.default.fileExists(atPath: payloadURL.path) else {
                throw BrowserIntakeStoreError.localIO
            }
        } else if period.deliveryBinding != nil {
            return
        }
        try query("UPDATE periods SET delivery_binding = ?, canonical_key = ?, ack_durable = 0 WHERE period_id = ? AND state IN ('finalized', 'delivered', 'removed')") { stmt in
            try bindTextChecked(stmt, 1, encoded)
            if let key = ack.canonicalKey { try bindTextChecked(stmt, 2, key) } else { try bindNullChecked(stmt, 2) }
            try bindTextChecked(stmt, 3, ack.periodId)
            guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func publishDeliveryAck(_ binding: BrowserDeliveryBinding) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }

        try persistDeliveryBindingLocked(binding)
        let periodURL = periodFileURL(for: binding.ack.periodId)
        let ackURL = BrowserIngestAckStore.ackURL(periodDirectory: periodURL.deletingLastPathComponent())
        try BrowserIngestAckStore.write(binding.ack, to: ackURL, ioInjector: ioInjector)
        try query("UPDATE periods SET ack_durable = 1 WHERE period_id = ? AND delivery_binding IS NOT NULL AND state IN ('finalized', 'delivered', 'removed')") { stmt in
            try bindTextChecked(stmt, 1, binding.ack.periodId)
            guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func storedDeliveryBinding(periodId: String) throws -> BrowserDeliveryBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard let encoded = getPeriodLocked(periodId: periodId)?.deliveryBinding else { return nil }
        guard let data = encoded.data(using: .utf8) else { throw BrowserIntakeStoreError.localIO }
        return try JSONDecoder().decode(BrowserDeliveryBinding.self, from: data)
    }

    func markAckDurable(periodId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try query("UPDATE periods SET ack_durable = 1 WHERE period_id = ? AND delivery_binding IS NOT NULL AND state IN ('finalized', 'delivered', 'removed')") { stmt in
            try bindTextChecked(stmt, 1, periodId)
            guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
        }
    }

    func releaseProven(periodId: String, binding: BrowserDeliveryBinding, nowMs: UInt64) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }
        try terminalAndUnlinkLocked(periodId: periodId, binding: binding, state: "delivered", nowMs: nowMs, requireAck: true)
    }

    func removeProvenSegment(periodId: String, binding: BrowserDeliveryBinding, nowMs: UInt64) throws {
        try ioInjector.check(.proof)
        lock.lock()
        defer { lock.unlock() }
        try persistDeliveryBindingLocked(binding)
        try terminalAndUnlinkLocked(periodId: periodId, binding: binding, state: "removed", nowMs: nowMs, requireAck: false)
    }

    private func terminalAndUnlinkLocked(periodId: String, binding: BrowserDeliveryBinding, state: String, nowMs: UInt64, requireAck: Bool) throws {
        let expectedBinding = try encodeDeliveryBinding(binding)
        guard let period = getPeriodLocked(periodId: periodId),
              period.deliveryBinding.map({ Data($0.utf8) == Data(expectedBinding.utf8) }) == true,
              BrowserOpaqueString.equals(period.requestedDay, binding.ack.requestedDay),
              BrowserOpaqueString.equals(period.requestedSegment, binding.ack.requestedSegment),
              BrowserOpaqueString.equals(period.fileSha256, binding.ack.sha256),
              Int(exactly: binding.ack.size) == period.committedLength,
              BrowserOpaqueString.equals(binding.ack.periodId, periodId),
              (!requireAck || period.ackDurable) else {
            throw BrowserIntakeStoreError.localIO
        }
        if period.state != state {
            guard period.state == "finalized" || period.state == "delivered" || period.state == "removed" else {
                throw BrowserIntakeStoreError.localIO
            }
            try query("UPDATE periods SET state = ?, canonical_key = ?, delivered_at_ms = ?, cleanup_durable = 0 WHERE period_id = ? AND state IN ('finalized', 'delivered', 'removed')") { stmt in
                try bindTextChecked(stmt, 1, state)
                if let key = binding.ack.canonicalKey { try bindTextChecked(stmt, 2, key) } else { try bindNullChecked(stmt, 2) }
                try bindInt64Checked(stmt, 3, Int64(nowMs))
                try bindTextChecked(stmt, 4, periodId)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
        }
        let fileURL = periodFileURL(for: periodId)
        try Self.assertNoSymlinkAncestors(fileURL)
        var backup: URL?
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try Self.assertRegularFile(fileURL)
                backup = try makeDiscardBackupLocked(for: fileURL)
                try ioInjector.check(.write)
                try FileManager.default.removeItem(at: fileURL)
            }
            try fsyncParentChecked(of: fileURL)
            try query("UPDATE periods SET cleanup_durable = 1 WHERE period_id = ? AND state = ?") { stmt in
                try bindTextChecked(stmt, 1, periodId)
                try bindTextChecked(stmt, 2, state)
                guard try stepChecked(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw BrowserIntakeStoreError.localIO }
            }
            if let backup { removeDiscardBackupBestEffort(backup) }
        } catch {
            if let backup {
                do { try restoreDiscardBackupLocked(backup, to: fileURL) }
                catch { Logger.storage.error("Browser payload restore after cleanup failure failed for period \(periodId, privacy: .public)") }
            }
            Logger.storage.error("Browser spool terminal cleanup failed for period \(periodId, privacy: .public)")
            throw BrowserIntakeStoreError.localIO
        }
        recalculateCounters()
    }

    public func garbageCollectSettledPeriods() {
        lock.lock()
        defer { lock.unlock() }
        do {
            let completed = try query("SELECT period_id FROM periods WHERE state IN ('delivered', 'removed') AND cleanup_durable = 1") { stmt in
                var ids: [String] = []
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return ids }
                    guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                    ids.append(id)
                }
            }
            let emptyDiscarded = try query("""
                SELECT p.period_id FROM periods p
                WHERE p.state = 'discarded' AND p.committed_length = 0
                  AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.period_id = p.period_id)
                  AND NOT EXISTS (SELECT 1 FROM period_contexts c WHERE c.period_id = p.period_id)
                """) { stmt in
                var ids: [String] = []
                while true {
                    let rc = try stepChecked(stmt)
                    if rc == SQLITE_DONE { return ids }
                    guard rc == SQLITE_ROW, let id = Self.readText(stmt, 0) else { throw BrowserIntakeStoreError.localIO }
                    ids.append(id)
                }
            }
            var deletable: [String] = []
            for id in completed {
                let payload = periodFileURL(for: id)
                try Self.assertNoSymlinkAncestors(payload)
                guard !FileManager.default.fileExists(atPath: payload.path) else { continue }
                let backup = discardBackupURL(for: payload)
                if FileManager.default.fileExists(atPath: backup.path) {
                    try Self.assertRegularFile(backup)
                    try ioInjector.check(.write)
                    try FileManager.default.removeItem(at: backup)
                    try fsyncParentChecked(of: backup)
                }
                guard !FileManager.default.fileExists(atPath: backup.path) else { continue }
                let ack = BrowserIngestAckStore.ackURL(periodDirectory: payload.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: ack.path) {
                    try Self.assertRegularFile(ack)
                    try ioInjector.check(.write)
                    try FileManager.default.removeItem(at: ack)
                    try fsyncParentChecked(of: ack)
                }
                deletable.append(id)
            }
            var emptyDiscardedDeletable: [String] = []
            for id in emptyDiscarded {
                let payload = periodFileURL(for: id)
                let backup = discardBackupURL(for: payload)
                let ack = BrowserIngestAckStore.ackURL(periodDirectory: payload.deletingLastPathComponent())
                try Self.assertNoSymlinkAncestors(payload)
                guard !FileManager.default.fileExists(atPath: payload.path),
                      !FileManager.default.fileExists(atPath: backup.path),
                      !FileManager.default.fileExists(atPath: ack.path) else { continue }
                emptyDiscardedDeletable.append(id)
            }
            try execute("BEGIN IMMEDIATE;")
            for id in deletable {
                let escaped = id.replacingOccurrences(of: "'", with: "''")
                try execute("""
                    DELETE FROM period_contexts WHERE period_id = '\(escaped)';
                    DELETE FROM periods WHERE period_id = '\(escaped)'
                      AND state IN ('delivered', 'removed') AND cleanup_durable = 1;
                    """)
            }
            for id in emptyDiscardedDeletable {
                try query("""
                    DELETE FROM periods WHERE period_id = ? AND state = 'discarded' AND committed_length = 0
                      AND NOT EXISTS (SELECT 1 FROM receipts r WHERE r.period_id = periods.period_id)
                      AND NOT EXISTS (SELECT 1 FROM period_contexts c WHERE c.period_id = periods.period_id)
                    """) { stmt in
                    try bindTextChecked(stmt, 1, id)
                    guard try stepChecked(stmt) == SQLITE_DONE else { throw BrowserIntakeStoreError.localIO }
                }
            }
            try execute("COMMIT;")
            try reclaimEmptyUnreferencedPeriodDirectories()
            recalculateCounters()
        } catch {
            try? rollbackIfActiveLocked()
            Logger.storage.error("Browser spool completed-period cleanup failed: \(error.localizedDescription, privacy: .public)")
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

    private func getPeriodLocked(periodId: String) -> BrowserStoredPeriod? {
        do {
            return try query("SELECT state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key, delivery_binding, ack_durable, delivered_at_ms, cleanup_durable, finalize_timezone FROM periods WHERE period_id = ?") { stmt in
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
              let state = Self.readText(stmt, idOffset) else {
            throw BrowserIntakeStoreError.localIO
        }
        let rDay = Self.readText(stmt, idOffset + 1)
        let rSeg = Self.readText(stmt, idOffset + 2)
        let sha = Self.readText(stmt, idOffset + 3)
        let size = Int(sqlite3_column_int64(stmt, idOffset + 4))
        let committedLength = Int(sqlite3_column_int64(stmt, idOffset + 5))
        let createdAt = UInt64(sqlite3_column_int64(stmt, idOffset + 6))
        let finalizedAt = sqlite3_column_type(stmt, idOffset + 7) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, idOffset + 7)) : nil
        let canonicalKey = Self.readText(stmt, idOffset + 8)
        let deliveryBinding = Self.readText(stmt, idOffset + 9)
        let ackDurable = sqlite3_column_int(stmt, idOffset + 10) != 0
        let deliveredAt = sqlite3_column_type(stmt, idOffset + 11) != SQLITE_NULL ? UInt64(sqlite3_column_int64(stmt, idOffset + 11)) : nil
        let cleanupDurable = sqlite3_column_int(stmt, idOffset + 12) != 0
        let finalizeTimeZone = Self.readText(stmt, idOffset + 13)
        return BrowserStoredPeriod(
            periodId: pid,
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
            try query("SELECT period_id, state, requested_day, requested_segment, file_sha256, size, committed_length, created_at_ms, finalized_at_ms, canonical_key, delivery_binding, ack_durable, delivered_at_ms, cleanup_durable, finalize_timezone FROM periods WHERE state = 'finalized' OR (state IN ('delivered', 'removed') AND cleanup_durable = 0) ORDER BY created_at_ms ASC") { stmt in
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
