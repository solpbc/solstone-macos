// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// What a request to change one item did.
enum ImportChange: Equatable, Sendable {
    case done
    /// The item is in the middle of a journal exchange; nothing was changed.
    case inFlight
    /// The journal already has it; nothing was changed.
    case delivered
    /// The item isn't in a state this change applies to.
    case refused
    /// No such item: it was removed, or finished and deleted after delivery.
    case gone
}

/// Where an item's attention verdict came from, for what the owner is shown.
enum ImportAttentionScope: Equatable, Sendable {
    case none
    /// The journal it would go to now refused it, at its current version.
    case here
    /// Another journal, or an older version of this one, refused it; it is going again.
    case elsewhere
    /// The copy on this Mac is missing.
    case local
}

struct ImportListItem: Equatable, Sendable {
    var id: String
    var displayName: String
    var state: String
    var error: String?
    var reasonCode: String?
    var kind: String?
    var scope: ImportAttentionScope
    var inFlight: Bool
    var hasSavedProgress: Bool
}

struct ImportCandidate: Equatable, Sendable {
    var id: String
    var progress: (path: String, timestamp: String)?

    static func == (a: ImportCandidate, b: ImportCandidate) -> Bool {
        a.id == b.id && a.progress?.path == b.progress?.path && a.progress?.timestamp == b.progress?.timestamp
    }
}

struct ImportItemDescriptor: Equatable, Sendable {
    var id: String
    var payloadURL: URL
    var displayName: String
    var mime: String
    var size: Int64
}

/// One item's record. Field for field the Android app's import row.
struct ImportItemRecord: Codable, Equatable, Sendable {
    var id: String
    var payloadKind: String
    var displayName: String
    var mime: String
    var byteSize: Int64
    /// `pending`, `attention` or `delivered`.
    var state: String
    var createdAt: Date
    var progressPath: String?
    var progressTimestamp: String?
    var progressInstanceID: String?
    var backoffInstanceID: String?
    var attemptCount: Int
    var nextAttemptAt: Date?
    var attentionError: String?
    var attentionReasonCode: String?
    var attentionKind: String?
    var attentionInstanceID: String?
    var attentionJournalVersion: String?

    var isJournalAttention: Bool {
        state == "attention" && attentionInstanceID != nil && attentionJournalVersion != nil
    }
}

private struct ImportCustodyFile: Codable {
    var version = 1
    var items: [ImportItemRecord] = []
    var lastDeliveredAt: Date?
    var lastDeliveredInstance: String?
}

/// Flushes a file or directory to the disk itself, not only to the drive's cache.
func importFullFsync(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    if fcntl(fd, F_FULLFSYNC) != 0 {
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

/// The owner's held imports: one folder per item, holding the copy as `payload`, and one record
/// file for them all. An item becomes real only when its record is written, after its folder is
/// in place and flushed; a folder without a record is an add that never finished, and is reaped.
///
/// Every method takes the store's lock, so a change and the record it writes can't interleave
/// with another. If the record file can't be read, nothing is changed and nothing is reaped.
final class ImportCustodyStore: @unchecked Sendable {
    let root: URL
    private let lock = NSRecursiveLock()
    private let clock: @Sendable () -> Date
    private let fsync: @Sendable (URL) throws -> Void
    private let move: @Sendable (URL, URL) throws -> Void
    private let remover: @Sendable (URL) -> Bool
    private var file = ImportCustodyFile()
    private var inFlight: Set<String> = []
    private var stagedKinds: [String: String] = [:]
    private(set) var unreadable = false

    private var recordURL: URL { root.appendingPathComponent("custody.json") }
    private var stagingRoot: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    init(
        root: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        fsync: @escaping @Sendable (URL) throws -> Void = importFullFsync,
        move: @escaping @Sendable (URL, URL) throws -> Void = { from, to in
            guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        },
        remover: @escaping @Sendable (URL) -> Bool = { url in
            do {
                try FileManager.default.removeItem(at: url)
                return true
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                return true
            } catch {
                return false
            }
        }
    ) {
        self.root = root
        self.clock = clock
        self.fsync = fsync
        self.move = move
        self.remover = remover
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: recordURL.path) {
            if let data = try? Data(contentsOf: recordURL),
               let decoded = try? JSONDecoder().decode(ImportCustodyFile.self, from: data) {
                file = decoded
            } else {
                unreadable = true
            }
        }
    }

    private func isUnsafeID(_ id: String) -> Bool {
        id.isEmpty || id.contains("/") || id.contains("\\") || id.contains(".")
    }

    /// Writes the record file; the in-memory record changes only once it is on disk.
    private func persist(_ next: ImportCustodyFile) -> Bool {
        guard !unreadable, let data = try? JSONEncoder().encode(next) else { return false }
        let temporary = root.appendingPathComponent(".custody-\(UUID().uuidString).json")
        do {
            try data.write(to: temporary)
            try fsync(temporary)
            if rename(temporary.path, recordURL.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try fsync(root)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        file = next
        return true
    }

    private func update(_ id: String, _ change: (inout ImportItemRecord) -> Void) -> Bool {
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { return false }
        var next = file
        change(&next.items[index])
        return persist(next)
    }

    private func record(_ id: String) -> ImportItemRecord? { file.items.first { $0.id == id } }

    private var ordered: [ImportItemRecord] {
        file.items.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    // MARK: - adding

    /// Starts an add: a staging folder whose `payload` the caller writes.
    func begin() -> String? {
        lock.withLock {
            guard !unreadable else { return nil }
            let id = UUID().uuidString.lowercased()
            do {
                try FileManager.default.createDirectory(at: stagingRoot.appendingPathComponent(id, isDirectory: true), withIntermediateDirectories: true)
            } catch {
                return nil
            }
            stagedKinds[id] = "file"
            return id
        }
    }

    func stagingPayloadURL(_ id: String) -> URL {
        stagingRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("payload")
    }

    /// Makes a staged add real: flush its copy and folder, move the folder into place, flush the
    /// path down to the store, then write its record. All under the lock, with nothing between.
    func publish(_ id: String, displayName: String, mime: String, size: Int64) -> Bool {
        lock.withLock {
            guard !unreadable, !isUnsafeID(id), let kind = stagedKinds[id] else { return false }
            let staging = stagingRoot.appendingPathComponent(id, isDirectory: true)
            let payload = staging.appendingPathComponent("payload")
            guard let actual = (try? FileManager.default.attributesOfItem(atPath: payload.path))?[.size] as? NSNumber,
                  actual.int64Value == size else { return false }
            var moved = false
            do {
                try fsync(payload)
                try fsync(staging)
                let target = root.appendingPathComponent(id, isDirectory: true)
                try move(staging, target)
                moved = true
                try fsync(target)
                try fsync(root)
                let row = ImportItemRecord(
                    id: id, payloadKind: kind, displayName: displayName, mime: mime, byteSize: size,
                    state: "pending", createdAt: clock(), progressPath: nil, progressTimestamp: nil,
                    progressInstanceID: nil, backoffInstanceID: nil, attemptCount: 0, nextAttemptAt: nil,
                    attentionError: nil, attentionReasonCode: nil, attentionKind: nil,
                    attentionInstanceID: nil, attentionJournalVersion: nil
                )
                guard record(id) == nil else {
                    stagedKinds[id] = nil
                    return false
                }
                var next = file
                next.items.append(row)
                stagedKinds[id] = nil
                return persist(next)
            } catch {
                if moved { stagedKinds[id] = nil }
                return false
            }
        }
    }

    func abandon(_ id: String) {
        lock.withLock {
            guard !isUnsafeID(id) else { return }
            stagedKinds[id] = nil
            _ = remover(stagingRoot.appendingPathComponent(id, isDirectory: true))
        }
    }

    /// Deletes delivered items: the folder first, then the record, so an interrupted finish leaves
    /// a delivered record whose folder is gone, which recovery deletes.
    func finish() {
        lock.withLock {
            guard !unreadable else { return }
            for row in ordered where row.state == "delivered" && !isUnsafeID(row.id) {
                guard remover(root.appendingPathComponent(row.id, isDirectory: true)) else { continue }
                var next = file
                next.items.removeAll { $0.id == row.id }
                _ = persist(next)
            }
        }
    }

    /// Once per launch, before any add or run: finish deliveries, reap abandoned staging and
    /// folders without a record, and mark items whose copy is gone.
    func recover() {
        lock.withLock {
            guard !unreadable else { return }
            finish()
            let fm = FileManager.default
            for child in (try? fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? [] {
                stagedKinds[child.lastPathComponent] = nil
                _ = remover(child)
            }
            let ids = Set(file.items.map(\.id))
            for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = child.lastPathComponent
                guard name != ".staging", (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if !ids.contains(name) { _ = remover(child) }
            }
            for row in ordered where !isUnsafeID(row.id) {
                let folder = root.appendingPathComponent(row.id, isDirectory: true)
                let payload = folder.appendingPathComponent("payload")
                let size = (try? fm.attributesOfItem(atPath: payload.path))?[.size] as? NSNumber
                guard size?.int64Value != row.byteSize else { continue }
                if row.state == "delivered" {
                    var next = file
                    next.items.removeAll { $0.id == row.id }
                    _ = persist(next)
                } else if !(row.state == "attention" && row.attentionKind == "missing_copy" && row.attentionInstanceID == nil) {
                    _ = update(row.id) {
                        $0.state = "attention"
                        $0.attentionKind = "missing_copy"
                        $0.attentionError = nil
                        $0.attentionReasonCode = nil
                        $0.attentionInstanceID = nil
                        $0.attentionJournalVersion = nil
                        $0.progressPath = nil
                        $0.progressTimestamp = nil
                        $0.progressInstanceID = nil
                        $0.backoffInstanceID = nil
                        $0.attemptCount = 0
                        $0.nextAttemptAt = nil
                    }
                }
            }
        }
    }

    // MARK: - delivery

    func eligible(instance: String, journalVersion: String, now: Date) -> [ImportCandidate] {
        lock.withLock {
            guard !unreadable else { return [] }
            return ordered.compactMap { row in
                guard row.state != "delivered" else { return nil }
                let eligible: Bool
                if row.state == "pending" {
                    if row.backoffInstanceID == instance, let next = row.nextAttemptAt { eligible = now >= next } else { eligible = true }
                } else if row.isJournalAttention {
                    eligible = row.attentionInstanceID != instance || row.attentionJournalVersion != journalVersion
                } else {
                    eligible = false
                }
                guard eligible else { return nil }
                if row.progressInstanceID == instance, let path = row.progressPath, let timestamp = row.progressTimestamp {
                    return ImportCandidate(id: row.id, progress: (path, timestamp))
                }
                return ImportCandidate(id: row.id, progress: nil)
            }
        }
    }

    /// Marks an item as in an exchange with `instance`. One refused elsewhere goes back to
    /// pending, since it is being sent again. Only `.done` lets the exchange go.
    func beginExchange(_ id: String, instance: String, journalVersion: String) -> ImportChange {
        lock.withLock {
            guard !unreadable, let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            if row.state == "pending" {
                // fine
            } else if row.isJournalAttention && (row.attentionInstanceID != instance || row.attentionJournalVersion != journalVersion) {
                guard update(id, {
                    $0.state = "pending"
                    $0.attentionError = nil
                    $0.attentionReasonCode = nil
                    $0.attentionKind = nil
                    $0.attentionInstanceID = nil
                    $0.attentionJournalVersion = nil
                }) else { return .refused }
            } else {
                return .refused
            }
            inFlight.insert(id)
            return .done
        }
    }

    func recordSaved(_ id: String, path: String, timestamp: String, instance: String) -> ImportChange {
        lock.withLock {
            guard let row = record(id) else {
                inFlight.remove(id)
                return .gone
            }
            guard row.state == "pending" || row.isJournalAttention else { return .refused }
            return update(id) {
                $0.progressPath = path
                $0.progressTimestamp = timestamp
                $0.progressInstanceID = instance
            } ? .done : .refused
        }
    }

    func recordDelivered(_ id: String, instance: String) -> ImportChange {
        lock.withLock {
            defer { inFlight.remove(id) }
            guard let row = record(id) else { return .gone }
            if row.state == "delivered" { return .done }
            guard row.state == "pending" || row.isJournalAttention,
                  let index = file.items.firstIndex(where: { $0.id == id }) else { return .refused }
            var next = file
            next.items[index].state = "delivered"
            next.lastDeliveredAt = clock()
            next.lastDeliveredInstance = instance
            return persist(next) ? .done : .refused
        }
    }

    func recordAttention(_ id: String, error: String, reasonCode: String, kind: String?, instance: String, journalVersion: String) -> ImportChange {
        lock.withLock {
            defer { inFlight.remove(id) }
            guard let row = record(id) else { return .gone }
            guard row.state == "pending" || row.isJournalAttention else { return .refused }
            return update(id) {
                $0.state = "attention"
                $0.attentionInstanceID = instance
                $0.attentionJournalVersion = journalVersion
                $0.attentionKind = kind
                $0.attentionError = error
                $0.attentionReasonCode = reasonCode
            } ? .done : .refused
        }
    }

    func markRetry(_ id: String, instance: String, now: Date) {
        lock.withLock {
            guard let row = record(id), row.state == "pending" else { return }
            let count = row.backoffInstanceID == instance ? row.attemptCount + 1 : 1
            _ = update(id) {
                $0.backoffInstanceID = instance
                $0.attemptCount = count
                $0.nextAttemptAt = now.addingTimeInterval(importRetryBackoff(attempt: count))
            }
        }
    }

    func endExchange(_ id: String) {
        lock.withLock { _ = inFlight.remove(id) }
    }

    func isInFlight(_ id: String) -> Bool { lock.withLock { inFlight.contains(id) } }

    // MARK: - the owner's changes

    /// Removes an item: its record first, then its folder, so an interrupted removal leaves only
    /// a folder without a record, which recovery reaps. Refused in an exchange or once delivered.
    func remove(_ id: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard !isUnsafeID(id), let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            var next = file
            next.items.removeAll { $0.id == id }
            guard persist(next) else { return .refused }
            _ = remover(root.appendingPathComponent(id, isDirectory: true))
            return .done
        }
    }

    /// The owner's retry of an item the journal refused.
    func retry(_ id: String) -> ImportChange {
        lock.withLock {
            guard !unreadable else { return .refused }
            guard let row = record(id) else { return .gone }
            if inFlight.contains(id) { return .inFlight }
            if row.state == "delivered" { return .delivered }
            guard row.isJournalAttention else { return .refused }
            return update(id) {
                $0.state = "pending"
                $0.progressPath = nil
                $0.progressTimestamp = nil
                $0.progressInstanceID = nil
                $0.backoffInstanceID = nil
                $0.attemptCount = 0
                $0.nextAttemptAt = nil
                $0.attentionError = nil
                $0.attentionReasonCode = nil
                $0.attentionKind = nil
                $0.attentionInstanceID = nil
                $0.attentionJournalVersion = nil
            } ? .done : .refused
        }
    }

    func hasSavedProgress(_ id: String) -> Bool {
        lock.withLock { record(id).map { $0.progressPath != nil && $0.progressTimestamp != nil } ?? false }
    }

    // MARK: - reading

    func items(instance: String?, journalVersion: String?) -> [ImportListItem] {
        lock.withLock {
            ordered.filter { $0.state != "delivered" }.map { row in
                let scope: ImportAttentionScope
                if row.state != "attention" { scope = .none }
                else if !row.isJournalAttention { scope = .local }
                else if row.attentionInstanceID == instance && row.attentionJournalVersion == journalVersion { scope = .here }
                else { scope = .elsewhere }
                return ImportListItem(
                    id: row.id, displayName: row.displayName, state: row.state, error: row.attentionError,
                    reasonCode: row.attentionReasonCode, kind: row.attentionKind, scope: scope,
                    inFlight: inFlight.contains(row.id),
                    hasSavedProgress: row.progressPath != nil && row.progressTimestamp != nil
                )
            }
        }
    }

    func lastDeliveredInstance() -> String? { lock.withLock { file.lastDeliveredInstance } }
    func lastDeliveredAt() -> Date? { lock.withLock { file.lastDeliveredAt } }

    func item(_ id: String) -> ImportItemDescriptor? {
        lock.withLock {
            guard !isUnsafeID(id), let row = record(id) else { return nil }
            return ImportItemDescriptor(
                id: row.id,
                payloadURL: root.appendingPathComponent(row.id, isDirectory: true).appendingPathComponent("payload"),
                displayName: row.displayName, mime: row.mime, size: row.byteSize
            )
        }
    }
}
