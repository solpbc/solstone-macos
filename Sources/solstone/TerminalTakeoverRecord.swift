// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

/// Which journal a pairing belongs to.
struct TerminalJournalIdentity: Codable, Equatable, Sendable {
    let journalID: String?
    let instanceID: String
    let caFingerprint: String

    /// Compared on the CA's journal id where both can read one, because a stored
    /// instance id may have been rewritten to it.
    func isSameJournal(as other: TerminalJournalIdentity) -> Bool {
        if let journalID, let otherID = other.journalID { return journalID == otherID }
        // The old app keeps only a prefix of the CA's fingerprint.
        return instanceID == other.instanceID && !caFingerprint.isEmpty && !other.caFingerprint.isEmpty
            && (caFingerprint.hasPrefix(other.caFingerprint) || other.caFingerprint.hasPrefix(caFingerprint))
    }
}

/// A migration request as first sent. Every retry sends exactly these bytes.
struct TerminalMigrationRecord: Codable, Equatable, Sendable {
    let operationID: String
    let body: String
    let callerID: String
}

/// How the terminal history's continuity settled.
enum TerminalContinuity: Codable, Equatable, Sendable {
    case continued
    case newStream(reason: String, needsAttention: Bool)
}

/// The durable record of moving solstone for tmux into this app.
struct TerminalTakeoverRecord: Codable, Equatable, Sendable {
    enum Phase: Int, Codable, Comparable, Sendable {
        case consented = 0
        case stopped = 1
        case listed = 2
        case done = 3

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var phase: Phase = .consented
    var tmuxTmpdir: String?
    var tmuxPath: String?
    var carriedSettings: Data?
    var settingsApplied = false
    var terminalSettled = false
    var ownerTurnedOff = false
    /// The old spool has not given a complete listing yet.
    var needsListing = true
    var legacyDeviceID: String?
    var legacyJournal: TerminalJournalIdentity?
    var migration: TerminalMigrationRecord?
    var continuity: TerminalContinuity?
    var lastAnswer: String?
    var problems: [String] = []
    var heldCount = 0

    /// `source = "tmux"` uploads wait until continuity is settled.
    var uploadsGated: Bool { continuity == nil }

    mutating func finishIfComplete() {
        if phase == .listed, settingsApplied, terminalSettled, continuity != nil {
            phase = .done
        }
    }
}

/// The durable-write stages a test can fail.
enum TerminalDurableStage: CaseIterable, Sendable {
    case write, sync, rename, directorySync
}

/// One record file, written atomically and durably, so a reader sees the old
/// record or the new one. A record that can't be read is a hard stop.
final class TerminalTakeoverStore: @unchecked Sendable {
    enum Stored: Equatable, Sendable {
        case absent
        case present(TerminalTakeoverRecord)
        case unusable(URL)

        var record: TerminalTakeoverRecord? {
            if case .present(let record) = self { return record }
            return nil
        }

        /// Whether `source = "tmux"` uploads must wait.
        var uploadsGated: Bool {
            switch self {
            case .absent: return false
            case .present(let record): return record.uploadsGated
            case .unusable: return true
            }
        }
    }

    enum StoreError: Error { case failed }

    let fileURL: URL
    private let lock = NSLock()
    var fault: (@Sendable (TerminalDurableStage) -> Bool)?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("terminal-takeover.json")
    }

    func load() -> Stored {
        lock.withLock { read() }
    }

    private func read() -> Stored {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return .absent
        } catch {
            return .unusable(fileURL)
        }
        guard let record = try? JSONDecoder().decode(TerminalTakeoverRecord.self, from: data) else {
            return .unusable(fileURL)
        }
        return .present(record)
    }

    func save(_ record: TerminalTakeoverRecord) throws {
        try lock.withLock { try write(record) }
    }

    /// Records `record` unless one exists. `false` when one already did.
    func saveIfAbsent(_ record: TerminalTakeoverRecord) throws -> Bool {
        try lock.withLock {
            guard read() == .absent else { return false }
            try write(record)
            return true
        }
    }

    /// Applies `change` to the stored record and saves it. `nil` with no usable record.
    @discardableResult
    func update<T>(_ change: (inout TerminalTakeoverRecord) -> T) -> T? {
        lock.withLock {
            guard case .present(var record) = read() else { return nil }
            let original = record
            let result = change(&record)
            guard record != original else { return result }
            do {
                try write(record)
            } catch {
                return nil
            }
            return result
        }
    }

    private func check(_ stage: TerminalDurableStage) throws {
        if fault?(stage) == true { throw StoreError.failed }
    }

    private func write(_ record: TerminalTakeoverRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".terminal-takeover-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try check(.write)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.failed
        }
        try check(.sync)
        let handle = try FileHandle(forUpdating: temporary)
        defer { try? handle.close() }
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 else { throw StoreError.failed }
        try check(.rename)
        guard rename(temporary.path, fileURL.path) == 0 else { throw StoreError.failed }
        try check(.directorySync)
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw StoreError.failed }
        defer { close(directoryFD) }
        guard fcntl(directoryFD, F_FULLFSYNC) == 0 else { throw StoreError.failed }
    }
}
