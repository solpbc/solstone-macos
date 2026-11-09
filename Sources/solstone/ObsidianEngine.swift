// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

/// What the source remembers about one note. Survives turning the source off and on.
struct ObsidianTableRow: Codable, Equatable, Sendable {
    var mtimeMs: Int64
    var size: Int64
    var fileID: UInt64
    var contentHash: String?
    /// The `changed_at` of the last line this note produced. Nil if it has never produced one.
    var lastReportedMs: Int64?
    /// The last window sent for this note.
    var sentWindow: String?
    /// When this note was first found missing, while a delete is held for one scan.
    var heldSinceMs: Int64?
    var tooLarge: Bool = false
}

/// One note's waiting change in one window, persisted so nothing is lost across launches.
struct ObsidianPendingEntry: Codable, Sendable {
    var vault: String
    var change: ObsidianChange
    var path: String
    var previousPath: String?
    var changedAt: ObsidianStamp
    var observedAt: ObsidianStamp
    var text: String?
    var contentHash: String?
    /// True while the journal has never been told about this note.
    var firstSeen: Bool

    var line: ObsidianNoteLine {
        ObsidianNoteLine(
            change: change, vault: vault, path: path, previousPath: previousPath,
            changedAt: changedAt, observedAt: observedAt, text: text, contentHash: contentHash
        )
    }
}

/// The source's own persisted settings. Carries no journal identity: what's waiting goes
/// to whichever journal is paired and confirmed when it's delivered.
struct ObsidianSourceState: Codable, Equatable, Sendable {
    var enabled = false
    var vaultPath: String?
    var vaultName: String?
    var firstSendCleared = false
    var firstScanDone = false
    var firstSyncTotal: Int?
    var firstSyncDelivered = 0
    /// When the last completed scan ran. Kept so a scan after the app was off still has it.
    var lastScanMs: Int64?
    /// What each other vault this device has used remembers, by its folder's path.
    var knownVaults: [String: ObsidianVaultMemo]?
}

/// The parts of the source's state that belong to one vault, kept while another is in use.
struct ObsidianVaultMemo: Codable, Equatable, Sendable {
    var firstSendCleared: Bool
    var firstScanDone: Bool
    var firstSyncTotal: Int?
    var firstSyncDelivered: Int
    var lastScanMs: Int64?
}

struct ObsidianEngineSnapshot: Equatable, Sendable {
    var state = ObsidianSourceState()
    var lastCheckedMs: Int64?
    var vaultUnreadable = false
    var partUnreadable = false
    var waiting = 0
    var notOnDevice = 0
    var tooLarge = 0
    var setAside = 0

    static let empty = ObsidianEngineSnapshot()
}

struct ObsidianOutboxFile: Equatable, Sendable {
    let url: URL
    let window: ObsidianWindow
}

/// The table, the pending windows and the outbox. All file work happens on this actor's
/// own queue so a long scan can't starve the cooperative pool.
actor ObsidianEngine {
    private let queue = DispatchSerialQueue(label: "app.solstone.observer.obsidian-engine")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let directory: URL
    private let timeZone: @Sendable () -> TimeZone
    private let walker: @Sendable (URL) -> ObsidianVaultWalkResult
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    private var state = ObsidianSourceState()
    private var table: [String: ObsidianTableRow] = [:]
    private var pendingCount = 0
    private var outboxLines = 0
    private var setAsideCount = 0
    private var lastCheckedMs: Int64?
    private var vaultUnreadable = false
    private var partUnreadable = false
    private var scanReadFailed = false
    private var notOnDevice = 0
    private var tooLarge = 0
    private var readBuffer = [UInt8](repeating: 0, count: 1 << 20)
    private var loaded = false

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var tablesRoot: URL { directory.appendingPathComponent("tables", isDirectory: true) }
    private var pendingRoot: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    private var outboxRoot: URL { directory.appendingPathComponent("outbox", isDirectory: true) }
    private var asideRoot: URL { directory.appendingPathComponent("aside", isDirectory: true) }
    var stagingDirectory: URL { directory.appendingPathComponent("staging", isDirectory: true) }

    private struct StoredTable: Codable {
        var rows: [String: ObsidianTableRow]
    }

    init(
        directory: URL,
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.autoupdatingCurrent },
        walker: @escaping @Sendable (URL) -> ObsidianVaultWalkResult = ObsidianVaultWalker.walk
    ) {
        self.directory = directory
        self.timeZone = timeZone
        self.walker = walker
    }

    /// Reads what earlier launches left. Off the main thread, and only once.
    func load() {
        guard !loaded else { return }
        loaded = true
        for url in [directory, pendingRoot, outboxRoot, asideRoot, stagingDirectory, tablesRoot] {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if let data = try? Data(contentsOf: stateURL), let decoded = try? decoder.decode(ObsidianSourceState.self, from: data) {
            state = decoded
        }
        if let path = state.vaultPath { table = loadTable(forVaultAt: path) }
        for url in (try? fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
        for name in directoryNames(directory) where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        returnSetAsideFiles()
        pendingCount = Self.fileCount(under: pendingRoot)
        outboxLines = Self.outboxLineTotal(outboxRoot)
        setAsideCount = Self.fileCount(under: asideRoot)
    }

    /// A refusal may be about this version of the app. Files set aside get another try,
    /// and go aside again if they're refused again.
    private func returnSetAsideFiles() {
        for window in directoryNames(asideRoot) {
            let source = asideRoot.appendingPathComponent(window, isDirectory: true)
            let destination = outboxRoot.appendingPathComponent(window, isDirectory: true)
            try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in directoryNames(source) where !name.hasPrefix(".") {
                let target = destination.appendingPathComponent(name)
                try? fileManager.removeItem(at: target)
                try? fileManager.moveItem(at: source.appendingPathComponent(name), to: target)
            }
            if directoryNames(source).isEmpty { try? fileManager.removeItem(at: source) }
        }
    }

    // MARK: - Settings

    func currentState() -> ObsidianSourceState { state }

    func snapshot() -> ObsidianEngineSnapshot {
        ObsidianEngineSnapshot(
            state: state, lastCheckedMs: lastCheckedMs, vaultUnreadable: vaultUnreadable, partUnreadable: partUnreadable,
            waiting: pendingCount + outboxLines, notOnDevice: notOnDevice,
            tooLarge: tooLarge, setAside: setAsideCount
        )
    }

    /// Turns the source on for a vault. A different vault than last time starts a fresh table;
    /// what's already waiting stays and still goes.
    func adoptVault(root: URL, name: String) {
        load()
        if setAsideCount > 0 {
            returnSetAsideFiles()
            outboxLines = Self.outboxLineTotal(outboxRoot)
            setAsideCount = Self.fileCount(under: asideRoot)
        }
        if state.vaultPath != root.path {
            // Each vault keeps its own table, so one turned back on still finds what changed.
            var known = state.knownVaults ?? [:]
            if let current = state.vaultPath {
                known[current] = ObsidianVaultMemo(
                    firstSendCleared: state.firstSendCleared, firstScanDone: state.firstScanDone,
                    firstSyncTotal: state.firstSyncTotal, firstSyncDelivered: state.firstSyncDelivered,
                    lastScanMs: state.lastScanMs
                )
            }
            let memo = known.removeValue(forKey: root.path)
            state.knownVaults = known.isEmpty ? nil : known
            state.vaultPath = root.path
            state.firstSendCleared = memo?.firstSendCleared ?? false
            state.firstScanDone = memo?.firstScanDone ?? false
            state.firstSyncTotal = memo?.firstSyncTotal
            state.firstSyncDelivered = memo?.firstSyncDelivered ?? 0
            state.lastScanMs = memo?.lastScanMs
            table = loadTable(forVaultAt: root.path)
            partUnreadable = false
            notOnDevice = 0
            tooLarge = 0
            lastCheckedMs = nil
        }
        state.vaultName = name
        state.enabled = true
        vaultUnreadable = false
        saveState()
    }

    func setEnabled(_ enabled: Bool) {
        state.enabled = enabled
        saveState()
    }

    func setFirstSendCleared() {
        state.firstSendCleared = true
        saveState()
    }

    /// Declining the first-send warning leaves the source off. Only this vault's unsent
    /// changes go: its windows never reached the outbox, and what's there is another's.
    func discardUnsentVault() {
        let vault = state.vaultName
        for window in directoryNames(pendingRoot) {
            let directory = pendingRoot.appendingPathComponent(window, isDirectory: true)
            for name in directoryNames(directory) where name.hasSuffix(".json") {
                let url = directory.appendingPathComponent(name)
                if case .entry(let entry) = readEntry(url), entry.vault == vault { removeEntry(url) }
            }
            if directoryNames(directory).isEmpty { try? fileManager.removeItem(at: directory) }
        }
        table = [:]
        if let path = state.vaultPath { try? fileManager.removeItem(at: tableFile(forVaultAt: path)) }
        lastCheckedMs = nil
        vaultUnreadable = false
        partUnreadable = false
        notOnDevice = 0
        tooLarge = 0
        state = ObsidianSourceState(knownVaults: state.knownVaults)
        saveState()
    }

    // MARK: - Scan

    private enum NoteRead {
        case note(text: String, hash: String)
        case tooLarge
        case unreadable
    }

    /// Reads and hashes a note. Opens the file for reading only.
    private func read(root: String, path: String) -> NoteRead {
        let descriptor = open(root + "/" + path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno != ENOENT { scanReadFailed = true }
            return .unreadable
        }
        defer { close(descriptor) }
        var data = Data()
        let capacity = readBuffer.count
        while true {
            let count = Darwin.read(descriptor, &readBuffer, capacity)
            if count < 0 {
                if errno == EINTR { continue }
                scanReadFailed = true
                return .unreadable
            }
            if count == 0 { break }
            data.append(contentsOf: readBuffer[0..<count])
            if data.count > ObsidianWire.maxNoteBytes { return .tooLarge }
        }
        let text = String(decoding: data, as: UTF8.self)
        let bytes = Data(text.utf8)
        guard bytes.count <= ObsidianWire.maxNoteBytes else { return .tooLarge }
        return .note(text: text, hash: ObsidianWire.sha256Hex(bytes))
    }

    private func lineFits(text: String, path: String) -> Bool {
        // Only a text this big can escape past a file's limit.
        guard text.utf8.count > 1_000_000 else { return true }
        let probe = ObsidianStamp(epochSeconds: 0, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
        return ObsidianNoteLine(
            change: .changed, vault: state.vaultName ?? "", path: path, previousPath: nil,
            changedAt: probe, observedAt: probe, text: text, contentHash: String(repeating: "0", count: 64)
        ).fitsInFile
    }

    /// The `changed` rule from the times table.
    private func changeStamp(
        mtimeMs: Int64, row: ObsidianTableRow?, contentChanged: Bool,
        observed: ObsidianStamp, nowMs: Int64, zone: TimeZone
    ) -> ObsidianStamp {
        let stamp = ObsidianStamp(milliseconds: mtimeMs, timeZone: zone)
        var notLater = false
        if contentChanged, let last = row?.lastReportedMs {
            notLater = stamp.epochSeconds <= ObsidianStamp(milliseconds: last, timeZone: zone).epochSeconds
        }
        if mtimeMs > nowMs || notLater || !stamp.isRepresentable { return observed }
        return stamp
    }

    /// One line per note per window: a window already sent for this note moves to the scan's
    /// time. If the scan is still inside that window, nil: a later scan picks the change up.
    /// A sent window later than now means the clock went back, so this is a different window
    /// and waiting for it could take any length of time.
    private func placeInWindow(
        _ stamp: ObsidianStamp, observedAt: ObsidianStamp, scan: ObsidianStamp, sentWindow: String?
    ) -> (changedAt: ObsidianStamp, observedAt: ObsidianStamp)? {
        guard let sentWindow, stamp.window.key <= sentWindow else { return (stamp, observedAt) }
        return scan.window.key == sentWindow ? nil : (scan, scan)
    }

    /// A rename with no edit of its own goes at the earliest change in its scan, so it reaches
    /// the journal at or before the edits Obsidian makes to the notes that link to it.
    private func renameStamp(anchorMs: Int64?, row: ObsidianTableRow, observed: ObsidianStamp, zone: TimeZone) -> ObsidianStamp {
        let candidate = anchorMs.map { ObsidianStamp(milliseconds: $0, timeZone: zone) } ?? observed
        // The journal drops anything earlier than the note's latest as stale.
        if let last = row.lastReportedMs, last > candidate.epochSeconds * 1000 {
            return ObsidianStamp(milliseconds: last, timeZone: zone)
        }
        return candidate
    }

    /// Walks the vault and turns what it finds into waiting changes.
    @discardableResult
    func scan(now: Date) -> ObsidianEngineSnapshot {
        guard state.enabled, let rootPath = state.vaultPath else { return snapshot() }
        guard case .scanned(let walk) = walker(URL(fileURLWithPath: rootPath, isDirectory: true)) else {
            vaultUnreadable = true
            return snapshot()
        }
        vaultUnreadable = false
        scanReadFailed = false
        let zone = timeZone()
        let nowMs = Self.milliseconds(now)
        let observed = ObsidianStamp(milliseconds: nowMs, timeZone: zone)
        lastCheckedMs = nowMs
        let previousScanMs = state.lastScanMs

        var dirty = false
        var changedMtimes: [Int64] = []
        var emitted = 0
        var placeholders = walk.placeholderOnly.count
        var largeCount = 0
        var newPaths: [String] = []

        for (path, entry) in walk.notes {
            if entry.isPlaceholder {
                placeholders += 1
                if table[path]?.heldSinceMs != nil {
                    table[path]?.heldSinceMs = nil
                    dirty = true
                }
                continue
            }
            guard var row = table[path] else {
                newPaths.append(path)
                continue
            }
            if row.heldSinceMs != nil {
                row.heldSinceMs = nil
                dirty = true
            }
            if row.mtimeMs == entry.mtimeMs, row.size == entry.size {
                if row.fileID != entry.fileID {
                    row.fileID = entry.fileID
                    dirty = true
                }
                if row.tooLarge { largeCount += 1 }
                table[path] = row
                continue
            }
            func markTooLarge() {
                row.mtimeMs = entry.mtimeMs
                row.size = entry.size
                row.fileID = entry.fileID
                row.tooLarge = true
                table[path] = row
                largeCount += 1
                dirty = true
            }
            if entry.size > ObsidianWire.maxNoteBytes {
                markTooLarge()
                continue
            }
            switch read(root: rootPath, path: path) {
            case .unreadable:
                continue
            case .tooLarge:
                markTooLarge()
            case .note(let text, let hash):
                guard lineFits(text: text, path: path) else {
                    markTooLarge()
                    continue
                }
                let wasReported = row.lastReportedMs != nil
                let contentChanged = hash != row.contentHash || !wasReported
                let stamp = changeStamp(
                    mtimeMs: entry.mtimeMs, row: row, contentChanged: true,
                    observed: observed, nowMs: nowMs, zone: zone
                )
                let placed = contentChanged
                    ? placeInWindow(stamp, observedAt: observed, scan: observed, sentWindow: row.sentWindow)
                    : (stamp, observed)
                guard let placed else { continue }
                row.mtimeMs = entry.mtimeMs
                row.size = entry.size
                row.fileID = entry.fileID
                row.contentHash = hash
                row.tooLarge = false
                dirty = true
                guard contentChanged else {
                    table[path] = row
                    continue
                }
                guard record(.changed, path: path, previousPath: nil, text: text, hash: hash,
                             changedAt: placed.changedAt, observedAt: placed.observedAt, firstSeen: !wasReported) else { continue }
                row.lastReportedMs = placed.changedAt.epochSeconds * 1000
                table[path] = row
                changedMtimes.append(entry.mtimeMs)
                emitted += 1
            }
        }

        // A note can grow past the limit and move in one step. It isn't gone: its file id is here.
        var tooLargeIDs = Set<UInt64>()
        for (path, entry) in walk.notes where entry.fileID != 0 {
            if entry.size > ObsidianWire.maxNoteBytes || table[path]?.tooLarge == true { tooLargeIDs.insert(entry.fileID) }
        }
        var missing: [String] = []
        for path in table.keys where walk.notes[path] == nil && !walk.placeholderOnly.contains(path) && !walk.isUnderUnreachableDirectory(path) {
            if let row = table[path], row.fileID != 0, tooLargeIDs.contains(row.fileID) {
                if row.heldSinceMs != nil {
                    table[path]?.heldSinceMs = nil
                    dirty = true
                }
                continue
            }
            missing.append(path)
        }
        missing.sort(by: Self.bytewise)
        placeholders += table.keys.filter { walk.notes[$0] == nil && walk.isUnderUnreachableDirectory($0) }.count

        // Pair by file id, then by content. A note that was never reported, or is too large, pairs with nothing.
        var byFileID: [UInt64: String] = [:]
        var unpairedMissing = Set(missing)
        for path in missing {
            guard let row = table[path], row.lastReportedMs != nil, !row.tooLarge, row.fileID != 0 else { continue }
            if byFileID[row.fileID] == nil { byFileID[row.fileID] = path }
        }
        var renames: [(old: String, new: String)] = []
        var unpairedNew: [String] = []
        for path in newPaths.sorted(by: Self.bytewise) {
            guard let entry = walk.notes[path] else { continue }
            if entry.size <= ObsidianWire.maxNoteBytes, entry.fileID != 0,
               let old = byFileID[entry.fileID], unpairedMissing.contains(old) {
                byFileID[entry.fileID] = nil
                unpairedMissing.remove(old)
                renames.append((old, path))
            } else {
                unpairedNew.append(path)
            }
        }
        var byHash: [String: [String]] = [:]
        for path in unpairedMissing.sorted(by: Self.bytewise) {
            guard let row = table[path], row.lastReportedMs != nil, !row.tooLarge, let hash = row.contentHash else { continue }
            byHash[hash, default: []].append(path)
        }
        var remainingNew: [String] = []
        var unreadableSizes = Set<Int64>()
        if byHash.isEmpty {
            remainingNew = unpairedNew
        } else {
            for path in unpairedNew {
                guard let entry = walk.notes[path], entry.size <= ObsidianWire.maxNoteBytes else {
                    remainingNew.append(path)
                    continue
                }
                let hash: String
                switch read(root: rootPath, path: path) {
                case .note(_, let readHash):
                    hash = readHash
                case .tooLarge:
                    remainingNew.append(path)
                    continue
                case .unreadable:
                    // It could be the new name of any missing note of its size.
                    unreadableSizes.insert(entry.size)
                    continue
                }
                guard var candidates = byHash[hash], let old = candidates.first else {
                    remainingNew.append(path)
                    continue
                }
                candidates.removeFirst()
                byHash[hash] = candidates.isEmpty ? nil : candidates
                unpairedMissing.remove(old)
                renames.append((old, path))
            }
        }

        // Every note changed in this scan counts toward a rename's time, so settle them first.
        // Metadata that didn't move means no edit; only the others need reading here.
        for (old, new) in renames {
            guard let entry = walk.notes[new], let row = table[old],
                  entry.mtimeMs != row.mtimeMs || entry.size != row.size,
                  case .note(_, let hash) = read(root: rootPath, path: new), hash != row.contentHash else { continue }
            changedMtimes.append(entry.mtimeMs)
        }
        changedMtimes += remainingNew.compactMap { path in
            walk.notes[path].flatMap { $0.size <= ObsidianWire.maxNoteBytes ? $0.mtimeMs : nil }
        }
        let renameAnchorMs = previousScanMs.flatMap { previous in
            changedMtimes.filter { $0 > previous && $0 <= nowMs }.min()
        }

        for (old, new) in renames {
            guard let entry = walk.notes[new], var row = table[old],
                  case .note(let text, let hash) = read(root: rootPath, path: new) else {
                // Paired but unread: the old row stays as it is until the new path can be read.
                continue
            }
            let contentChanged = hash != row.contentHash
            let stamp = contentChanged
                ? changeStamp(mtimeMs: entry.mtimeMs, row: row, contentChanged: true, observed: observed, nowMs: nowMs, zone: zone)
                : renameStamp(anchorMs: renameAnchorMs, row: row, observed: observed, zone: zone)
            guard let placed = placeInWindow(stamp, observedAt: observed, scan: observed, sentWindow: row.sentWindow) else { continue }
            guard record(.renamed, path: new, previousPath: old, text: text, hash: hash,
                         changedAt: placed.changedAt, observedAt: placed.observedAt, firstSeen: false) else { continue }
            row.mtimeMs = entry.mtimeMs
            row.size = entry.size
            row.fileID = entry.fileID
            row.contentHash = hash
            row.lastReportedMs = placed.changedAt.epochSeconds * 1000
            row.heldSinceMs = nil
            table[old] = nil
            table[new] = row
            dirty = true
            emitted += 1
        }

        for path in remainingNew {
            guard let entry = walk.notes[path] else { continue }
            func addTooLarge() {
                table[path] = ObsidianTableRow(
                    mtimeMs: entry.mtimeMs, size: entry.size, fileID: entry.fileID,
                    contentHash: nil, lastReportedMs: nil, sentWindow: nil, heldSinceMs: nil, tooLarge: true
                )
                largeCount += 1
                dirty = true
            }
            if entry.size > ObsidianWire.maxNoteBytes {
                addTooLarge()
                continue
            }
            switch read(root: rootPath, path: path) {
            case .unreadable:
                unreadableSizes.insert(entry.size)
                continue
            case .tooLarge:
                addTooLarge()
            case .note(let text, let hash):
                guard lineFits(text: text, path: path) else {
                    addTooLarge()
                    continue
                }
                let changedAt = changeStamp(mtimeMs: entry.mtimeMs, row: nil, contentChanged: false,
                                            observed: observed, nowMs: nowMs, zone: zone)
                guard record(.changed, path: path, previousPath: nil, text: text, hash: hash,
                             changedAt: changedAt, observedAt: observed, firstSeen: true) else { continue }
                table[path] = ObsidianTableRow(
                    mtimeMs: entry.mtimeMs, size: entry.size, fileID: entry.fileID, contentHash: hash,
                    lastReportedMs: changedAt.epochSeconds * 1000, sentWindow: nil, heldSinceMs: nil, tooLarge: false
                )
                dirty = true
                emitted += 1
            }
        }

        // A placeholder or folder this scan can't see into, with no row, may be a missing note's new name.
        var directoriesWithRows = Set<String>()
        if !walk.unreachableDirectories.isEmpty {
            for path in table.keys {
                var ancestor = path[...]
                while let slash = ancestor.lastIndex(of: "/") {
                    ancestor = ancestor[..<slash]
                    directoriesWithRows.insert(String(ancestor))
                }
            }
        }
        // A stub or folder says nothing about size, so it could be any missing note. A dataless
        // file keeps its size, so it can only be one of the same size.
        let anyNoteCouldBeThere = walk.placeholderOnly.contains { table[$0] == nil }
            || walk.unreachableDirectories.contains { !directoriesWithRows.contains($0) }
        var placeholderSizes = Set<Int64>()
        for (path, entry) in walk.notes where entry.isPlaceholder && table[path] == nil { placeholderSizes.insert(entry.size) }
        var deletesHeld = false

        for path in unpairedMissing.sorted(by: Self.bytewise) {
            guard var row = table[path] else { continue }
            if unreadableSizes.contains(row.size) {
                deletesHeld = true
                continue
            }
            guard let heldSince = row.heldSinceMs else {
                row.heldSinceMs = nowMs
                table[path] = row
                dirty = true
                continue
            }
            if anyNoteCouldBeThere || placeholderSizes.contains(row.size) {
                deletesHeld = true
                continue
            }
            // Held for a scan with no partner: a real delete, at the moment it was first missed.
            let firstMissed = ObsidianStamp(milliseconds: heldSince, timeZone: zone)
            guard let placed = placeInWindow(firstMissed, observedAt: firstMissed, scan: observed, sentWindow: row.sentWindow) else { continue }
            if row.lastReportedMs != nil {
                guard record(.removed, path: path, previousPath: nil, text: nil, hash: nil,
                             changedAt: placed.changedAt, observedAt: placed.observedAt, firstSeen: false) else { continue }
                emitted += 1
            }
            table[path] = nil
            dirty = true
        }

        if walk.unsendableNames > 0 {
            Logger.upload.info("Obsidian scan skipped \(walk.unsendableNames, privacy: .public) notes whose names the journal can't take")
        }
        notOnDevice = placeholders
        tooLarge = largeCount
        partUnreadable = scanReadFailed || !walk.failedDirectories.isEmpty || deletesHeld
        if dirty { saveTable() }
        if !state.firstScanDone {
            state.firstScanDone = true
            state.firstSyncTotal = emitted > 0 ? emitted : nil
            state.firstSyncDelivered = 0
        }
        state.lastScanMs = nowMs
        saveState()
        return snapshot()
    }

    private static func bytewise(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    // MARK: - Pending windows

    private func windowDirectory(_ root: URL, _ window: ObsidianWindow) -> URL {
        root.appendingPathComponent(window.key, isDirectory: true)
    }

    private func pendingEntryURL(window: ObsidianWindow, vault: String, path: String) -> URL {
        windowDirectory(pendingRoot, window).appendingPathComponent(ObsidianWire.sha256Hex(Data("\(vault)\u{0}\(path)".utf8)) + ".json")
    }

    private enum EntryRead {
        case entry(ObsidianPendingEntry)
        case corrupt
        case unreadable
    }

    private func readEntry(_ url: URL) -> EntryRead {
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard let entry = try? decoder.decode(ObsidianPendingEntry.self, from: data) else { return .corrupt }
        return .entry(entry)
    }

    private func loadEntry(_ url: URL) -> ObsidianPendingEntry? {
        if case .entry(let entry) = readEntry(url) { return entry }
        return nil
    }

    private func removeEntry(_ url: URL) {
        if (try? fileManager.removeItem(at: url)) != nil { pendingCount -= 1 }
    }

    /// Coalesces a change into its window's entry for the note, so a window holds its net.
    private func record(
        _ change: ObsidianChange, path: String, previousPath: String?, text: String?, hash: String?,
        changedAt: ObsidianStamp, observedAt: ObsidianStamp, firstSeen: Bool
    ) -> Bool {
        guard let vault = state.vaultName else { return false }
        let window = changedAt.window
        var entry = ObsidianPendingEntry(
            vault: vault, change: change, path: path, previousPath: previousPath,
            changedAt: changedAt, observedAt: observedAt, text: text, contentHash: hash, firstSeen: firstSeen
        )
        var target = pendingEntryURL(window: window, vault: vault, path: path)
        switch change {
        case .changed:
            if let existing = loadEntry(target) {
                switch existing.change {
                case .changed:
                    entry.firstSeen = existing.firstSeen
                case .renamed:
                    entry.change = .renamed
                    entry.previousPath = existing.previousPath
                    entry.firstSeen = false
                case .removed:
                    entry.firstSeen = false
                }
            }
        case .renamed:
            if let previousPath {
                let source = pendingEntryURL(window: window, vault: vault, path: previousPath)
                if let existing = loadEntry(source) {
                    switch existing.change {
                    case .changed where existing.firstSeen:
                        entry.change = .changed
                        entry.previousPath = nil
                        entry.firstSeen = true
                    case .renamed:
                        if existing.previousPath?.utf8.elementsEqual(path.utf8) == true {
                            entry.change = .changed
                            entry.previousPath = nil
                            entry.firstSeen = false
                        } else {
                            entry.previousPath = existing.previousPath
                        }
                    default:
                        break
                    }
                    removeEntry(source)
                }
            }
        case .removed:
            if let existing = loadEntry(target) {
                switch existing.change {
                case .changed where existing.firstSeen:
                    removeEntry(target)
                    return true
                case .renamed:
                    if let previous = existing.previousPath, table[previous] != nil {
                        // A new note lives at the old path: the rename nets to nothing, and no delete.
                        removeEntry(target)
                        return true
                    }
                    entry.path = existing.previousPath ?? path
                    removeEntry(target)
                    target = pendingEntryURL(window: window, vault: vault, path: entry.path)
                case .removed:
                    return true
                case .changed:
                    break
                }
            }
        }
        do {
            let isNew = !fileManager.fileExists(atPath: target.path)
            try ensureDirectory(target.deletingLastPathComponent())
            try writeDurably(encoder.encode(entry), to: target)
            if isNew { pendingCount += 1 }
            return true
        } catch {
            Logger.upload.error("Obsidian pending entry not saved: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Closing windows

    private func pendingWindows() -> [ObsidianWindow] {
        directoryNames(pendingRoot).compactMap(ObsidianWindow.init(key:)).sorted()
    }

    /// Windows that have closed become outbox files; their pending entries go. A vault's
    /// windows wait here until its first send is cleared, so cancelling can take them back.
    @discardableResult
    func closeDueWindows(now: Date) -> ObsidianEngineSnapshot {
        guard state.firstSendCleared else { return snapshot() }
        let zone = timeZone()
        var closed: [URL] = []
        for window in pendingWindows() {
            guard let close = window.closeDate(timeZone: zone), close <= now else { continue }
            if let directory = closeWindow(window) { closed.append(directory) }
        }
        if !closed.isEmpty {
            // Once per pass: a vault's first close can be thousands of windows. Saving the table
            // flushes the drive, so the outbox files are safe before their pending entries go.
            saveTable()
            for directory in closed { try? fileManager.removeItem(at: directory) }
        }
        return snapshot()
    }

    /// Builds a window's outbox files. Returns its pending directory once it's safe to remove.
    private func closeWindow(_ window: ObsidianWindow) -> URL? {
        let directory = windowDirectory(pendingRoot, window)
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        // Decode for the sort, then read each entry once more while writing, so a window's
        // text is never all in memory at once.
        var ordered: [(key: ObsidianLineSortKey, url: URL, path: String)] = []
        for url in urls where url.pathExtension == "json" {
            switch readEntry(url) {
            case .entry(let entry):
                ordered.append((entry.line.sortKey, url, entry.path))
            case .corrupt:
                Logger.upload.error("Obsidian pending entry can't be decoded; dropped")
                removeEntry(url)
            case .unreadable:
                Logger.upload.error("Obsidian pending entry unreadable; window stays pending")
                return nil
            }
        }
        if ordered.isEmpty {
            try? fileManager.removeItem(at: directory)
            return nil
        }
        ordered.sort { $0.key < $1.key }

        var accumulator = ObsidianFileAccumulator()
        var writtenFiles: [URL] = []
        func abandon() -> URL? {
            // Nothing is lost: the pending entries stay and the same bytes are built next time.
            Logger.upload.error("Obsidian window not closed; it stays pending")
            for url in writtenFiles { try? fileManager.removeItem(at: url) }
            return nil
        }
        for item in ordered {
            guard case .entry(let entry) = readEntry(item.url) else { return abandon() }
            if let finished = accumulator.add(entry.line.encoded()) {
                guard let url = writeOutboxFile(finished, window: window) else { return abandon() }
                writtenFiles.append(url)
            }
        }
        if let finished = accumulator.finish() {
            guard let url = writeOutboxFile(finished, window: window) else { return abandon() }
            writtenFiles.append(url)
        }
        for item in ordered { table[item.path]?.sentWindow = window.key }
        pendingCount -= ordered.count
        outboxLines += ordered.count
        return directory
    }

    private func writeOutboxFile(_ bytes: Data, window: ObsidianWindow) -> URL? {
        let directory = windowDirectory(outboxRoot, window)
        let destination = directory.appendingPathComponent(ObsidianWire.fileName(for: bytes))
        do {
            try ensureDirectory(directory)
            try writeDurably(bytes, to: destination)
            return destination
        } catch {
            Logger.upload.error("Obsidian outbox write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Outbox

    /// Every file waiting to go, oldest window first.
    func outboxFiles() -> [ObsidianOutboxFile] {
        var files: [ObsidianOutboxFile] = []
        for window in directoryNames(outboxRoot).compactMap(ObsidianWindow.init(key:)).sorted() {
            let directory = windowDirectory(outboxRoot, window)
            for name in directoryNames(directory).sorted() where !name.hasPrefix(".") {
                files.append(ObsidianOutboxFile(url: directory.appendingPathComponent(name), window: window))
            }
        }
        return files
    }

    func markDelivered(_ file: ObsidianOutboxFile) {
        let lines = Self.lineCount(file.url)
        try? fileManager.removeItem(at: file.url)
        removeWindowDirectoryIfEmpty(file)
        outboxLines = max(0, outboxLines - lines)
        if state.firstSyncTotal != nil {
            state.firstSyncDelivered += lines
            if pendingCount + outboxLines == 0 {
                state.firstSyncTotal = nil
                state.firstSyncDelivered = 0
            }
            saveState()
        }
    }

    /// A file the journal called invalid can't be retried. It's kept aside, off the outbox.
    func setAside(_ file: ObsidianOutboxFile) {
        let lines = Self.lineCount(file.url)
        let directory = windowDirectory(asideRoot, file.window)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        if (try? fileManager.moveItem(at: file.url, to: destination)) != nil {
            setAsideCount += 1
            outboxLines = max(0, outboxLines - lines)
            removeWindowDirectoryIfEmpty(file)
        }
    }

    private func removeWindowDirectoryIfEmpty(_ file: ObsidianOutboxFile) {
        let directory = file.url.deletingLastPathComponent()
        if directoryNames(directory).isEmpty { try? fileManager.removeItem(at: directory) }
    }

    // MARK: - Persistence

    private enum DurableWriteError: Error {
        case failed(Int32)
    }

    /// Replaces a file so a crash leaves the old bytes or the new, never a mix. `flushDrive`
    /// also empties the drive's cache, which covers everything already synced before it.
    private func writeDurably(_ data: Data, to url: URL, flushDrive: Bool = false) throws {
        let directory = url.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DurableWriteError.failed(errno) }
        var published = false
        defer { if !published { unlink(staging.path) } }
        do {
            defer { close(descriptor) }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw DurableWriteError.failed(errno)
                    }
                    offset += count
                }
            }
            let flushed = flushDrive && fcntl(descriptor, F_FULLFSYNC) == 0
            guard flushed || fsync(descriptor) == 0 else { throw DurableWriteError.failed(errno) }
        }
        guard rename(staging.path, url.path) == 0 else { throw DurableWriteError.failed(errno) }
        published = true
        syncDirectory(directory)
    }

    private func syncDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }

    /// Creates a window's directory and makes its name durable in the parent.
    private func ensureDirectory(_ directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        syncDirectory(directory.deletingLastPathComponent())
    }

    private func saveState() {
        guard let data = try? encoder.encode(state) else { return }
        do {
            try writeDurably(data, to: stateURL)
        } catch {
            Logger.upload.error("Obsidian state not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func tableFile(forVaultAt path: String) -> URL {
        tablesRoot.appendingPathComponent(String(ObsidianWire.sha256Hex(Data(path.utf8)).prefix(16)) + ".json")
    }

    private func loadTable(forVaultAt path: String) -> [String: ObsidianTableRow] {
        guard let data = try? Data(contentsOf: tableFile(forVaultAt: path)),
              let decoded = try? decoder.decode(StoredTable.self, from: data) else { return [:] }
        return decoded.rows
    }

    private func saveTable() {
        guard let path = state.vaultPath else { return }
        do {
            try writeDurably(encoder.encode(StoredTable(rows: table)), to: tableFile(forVaultAt: path), flushDrive: true)
        } catch {
            Logger.upload.error("Obsidian table not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func fileCount(under root: URL) -> Int {
        var count = 0
        for window in names(root) {
            count += names(root.appendingPathComponent(window)).filter { !$0.hasPrefix(".") }.count
        }
        return count
    }

    private static func outboxLineTotal(_ root: URL) -> Int {
        var total = 0
        for window in names(root) {
            let directory = root.appendingPathComponent(window)
            for name in names(directory) where !name.hasPrefix(".") {
                total += lineCount(directory.appendingPathComponent(name))
            }
        }
        return total
    }

    private static func names(_ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    private func directoryNames(_ root: URL) -> [String] { Self.names(root) }

    private static func lineCount(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var lines = 0
        while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            lines += chunk.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        }
        return lines
    }
}
