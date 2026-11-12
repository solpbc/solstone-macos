// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let screenshotLog = Logger(subsystem: "app.solstone.observer", category: "screenshots")

enum ScreenshotOutcome: String, Codable, Equatable, Sendable {
    case pending, delivered, refused, unreadable, deleted, held
}

struct ScreenshotStoredItem: Codable, Equatable, Sendable {
    var id: String
    var path: String
    var outcome: ScreenshotOutcome
    var capturedAt: Date?
    var takenFrom: String?
    var byteCount: Int
    var fileName: String?
    var inFrozen: Bool
    var fileExtension: String
}

struct ScreenshotLedger: Codable, Equatable, Sendable {
    var version = 1
    var consented = false
    var enabled = false
    var confirmed = false
    var wasOn = false
    var path: String?
    var folderName = "Desktop"
    var isDesktop = true
    var ownerChose = false
    var systemPathAtConsent: String?
    var access: ScreenshotAccess = .ok
    /// Whether this folder has ever been read. A refusal before that is the owner's answer to
    /// the system's prompt, not access that was taken away. Optional so a ledger saved before
    /// it existed still decodes; nil reads as held.
    var accessHeld: Bool?
    var movedName = "Desktop"
    var span: ScreenshotSpan = .last30Days
    /// Where the chosen span began when the owner confirmed it. A screenshot from before it
    /// stays out, so the folder's older screenshots don't come in after the count.
    var liveFrom: Date?
    var items: [ScreenshotStoredItem] = []
    var pauseWindows: [ScreenshotPauseWindow] = []
    var lastChecked: Date?
    var seenCandidates: [ScreenshotCandidateRecord] = []
}

/// A scan row kept so confirm can freeze the count without listing again.
struct ScreenshotCandidateRecord: Codable, Equatable, Sendable {
    var path: String
    var marked: Bool
    var platformDate: Date?
    var fileDate: Date?
    var byteCount: Int
    var stable: Bool
    var header: Data
    var sha256: String?
    var pixelCount: Int64?
    var unreadable: Bool
    var fileExtension: String

    init(_ file: ScreenshotCandidate) {
        path = file.path
        marked = file.marked
        platformDate = file.platformDate
        fileDate = file.fileDate
        byteCount = file.byteCount
        stable = file.stable
        header = file.header
        sha256 = file.sha256
        pixelCount = file.pixelCount
        unreadable = file.unreadable
        fileExtension = file.fileExtension
    }

    var candidate: ScreenshotCandidate {
        ScreenshotCandidate(
            path: path, marked: marked, platformDate: platformDate, fileDate: fileDate,
            byteCount: byteCount, stable: stable, header: header, sha256: sha256,
            pixelCount: pixelCount, unreadable: unreadable, fileExtension: fileExtension
        )
    }
}

actor ScreenshotEngine {
    private let directory: URL
    private let reader: any ScreenshotReading
    private let transport: any ScreenshotTransport
    private let totals: SourceTotals?
    private let timeZone: @Sendable () -> TimeZone
    private let onDelivered: @Sendable () async -> Void
    private let fileURL: URL
    private var ledger = ScreenshotLedger()
    private var capability: Bool?
    private var capabilityAskedAt: Date?
    /// Moves when a new pairing starts the setup again, so a send that was already on its way
    /// leaves no outcome behind it.
    private var setupGeneration = 0
    /// How long a journal that doesn't list `screenshots` waits before it is asked again, so an
    /// updated journal is noticed without a relaunch.
    static let capabilityRecheck: TimeInterval = 60
    private var countFailed = false

    init(
        directory: URL,
        reader: any ScreenshotReading,
        transport: any ScreenshotTransport,
        totals: SourceTotals? = nil,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        onDelivered: @escaping @Sendable () async -> Void = {}
    ) {
        self.directory = directory
        self.reader = reader
        self.transport = transport
        self.totals = totals
        self.timeZone = timeZone
        self.onDelivered = onDelivered
        fileURL = directory.appendingPathComponent("ledger.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(ScreenshotLedger.self, from: data) {
            ledger = decoded
        }
    }

    func snapshot(now: Date, pause: ScreenshotPauseFact, paired: Bool) -> ScreenshotSnapshot {
        presentScreenshots(facts(now: now, pause: pause, paired: paired))
    }

    func allow(now: Date, pause: ScreenshotPauseFact, paired: Bool) async -> ScreenshotSnapshot {
        let system = reader.systemFolder()
        ledger.consented = true
        ledger.enabled = true
        ledger.confirmed = false
        ledger.ownerChose = false
        ledger.path = system.path
        ledger.folderName = system.name
        ledger.isDesktop = system.isDesktop
        ledger.systemPathAtConsent = system.path
        ledger.access = .ok
        ledger.accessHeld = false
        scan(now: now)
        save()
        return await tick(now: now, pause: pause, serverURL: nil, paired: paired, syncPaused: true)
    }

    func choose(_ folder: ScreenshotFolder, now: Date, pause: ScreenshotPauseFact, paired: Bool) async -> ScreenshotSnapshot {
        let system = reader.systemFolder()
        ledger.consented = true
        ledger.enabled = true
        ledger.confirmed = false
        ledger.ownerChose = true
        ledger.path = folder.path
        ledger.folderName = folder.name
        ledger.isDesktop = folder.isDesktop
        ledger.systemPathAtConsent = system.path
        ledger.access = .ok
        ledger.accessHeld = false
        scan(now: now)
        save()
        return await tick(now: now, pause: pause, serverURL: nil, paired: paired, syncPaused: true)
    }

    func turnOff() {
        ledger.enabled = false
        ledger.confirmed = false
        ledger.items.removeAll { $0.inFrozen && ($0.outcome == .pending || $0.outcome == .held) }
        ledger.pauseWindows.removeAll()
        ledger.seenCandidates.removeAll()
        save()
    }

    /// The switch turned on. Before the folder was ever read, that asks for it, as `allow` does.
    func turnOn(now: Date, pause: ScreenshotPauseFact, paired: Bool) async -> ScreenshotSnapshot {
        if !ledger.consented || (ledger.access == .denied && ledger.accessHeld == false) {
            return await allow(now: now, pause: pause, paired: paired)
        }
        turnBackOn(now: now)
        return snapshot(now: now, pause: pause, paired: paired)
    }

    func turnBackOn(now: Date) {
        guard ledger.consented else { return }
        ledger.enabled = true
        ledger.confirmed = false
        ledger.access = ledger.access == .moved ? .moved : .ok
        scan(now: now)
        save()
    }

    /// A new pairing: the journal paired now gets this source's first setup. The chooser comes
    /// back with a fresh count and nothing goes until the owner confirms it. The folder, its
    /// access, the switch and the owner's pauses stay. A screenshot that came in live and hasn't
    /// gone yet stays waiting, and goes after the confirm.
    func restartFirstSetup(now: Date) {
        setupGeneration += 1
        capability = nil
        capabilityAskedAt = nil
        ledger.confirmed = false
        ledger.wasOn = false
        ledger.liveFrom = nil
        ledger.items.removeAll { $0.outcome == .delivered || ($0.inFrozen && ($0.outcome == .pending || $0.outcome == .held)) }
        for index in ledger.items.indices { ledger.items[index].inFrozen = false }
        ledger.seenCandidates.removeAll()
        scan(now: now)
        save()
    }

    func select(span: ScreenshotSpan, now: Date) {
        ledger.span = span
        if ledger.consented, !ledger.confirmed { scan(now: now) }
        save()
    }

    func confirm(now: Date) {
        guard ledger.consented, ledger.enabled, ledger.access == .ok, !countFailed else { return }
        let start = ledger.span.start(now: now, timeZone: timeZone())
        let delivered = deliveredHashes
        ledger.items.removeAll { $0.inFrozen && ($0.outcome == .pending || $0.outcome == .held) }
        // This backfill is the count the owner just saw, so an earlier one stops counting toward
        // `{d} of {N}`, and a screenshot the ledger already knows joins this one.
        for index in ledger.items.indices { ledger.items[index].inFrozen = false }
        var seen = Set<String>()
        for file in ledger.seenCandidates.map(\.candidate) {
            guard let item = makeItem(file, spanStart: start, delivered: delivered, frozen: true) else { continue }
            guard seen.insert(item.id).inserted else { continue }
            guard let index = ledger.items.firstIndex(where: { $0.id == item.id }) else {
                ledger.items.append(item)
                continue
            }
            ledger.items[index].inFrozen = true
            // Seen gone and back: the journal hasn't got it.
            if ledger.items[index].outcome == .deleted {
                ledger.items[index].outcome = item.outcome
                ledger.items[index].path = item.path
            }
        }
        ledger.liveFrom = start
        ledger.confirmed = true
        ledger.wasOn = true
        save()
    }

    func retryUnreadable() {
        for index in ledger.items.indices where ledger.items[index].outcome == .unreadable {
            ledger.items[index].outcome = .pending
        }
        save()
    }

    func tick(
        now: Date,
        pause: ScreenshotPauseFact,
        serverURL: String?,
        paired: Bool,
        syncPaused: Bool
    ) async -> ScreenshotSnapshot {
        if ledger.confirmed { reconcilePause(now: now, fact: pause) }
        if ledger.consented { scan(now: now) }
        if let serverURL, !syncPaused {
            await sendReady(serverURL: serverURL, now: now)
        }
        save()
        return snapshot(now: now, pause: pause, paired: paired)
    }

    // MARK: - scan

    private func noteMove() {
        let system = reader.systemFolder()
        guard ledger.consented, let seen = ledger.systemPathAtConsent else { return }
        guard system.path != seen else {
            // Moved back to the folder the app already reads: nothing to ask for.
            if ledger.access == .moved { ledger.access = .ok }
            return
        }
        ledger.access = .moved
        ledger.movedName = system.name
    }

    private func scan(now: Date) {
        noteMove()
        guard ledger.consented, ledger.access != .moved, let path = ledger.path else { return }
        let folder = ScreenshotFolder(path: path, name: ledger.folderName, isDesktop: ledger.isDesktop)
        switch reader.list(folder, now: now) {
        case .denied:
            ledger.access = .denied
            countFailed = false
        case .missing, .failed:
            ledger.access = .ok
            countFailed = true
        case .files(let files):
            ledger.access = .ok
            ledger.accessHeld = true
            countFailed = false
            ledger.lastChecked = now
            absorb(files, now: now)
        }
    }

    private func absorb(_ files: [ScreenshotCandidate], now: Date) {
        let marked = files.filter(\.marked)
        ledger.seenCandidates = marked.map(ScreenshotCandidateRecord.init)
        guard ledger.confirmed else { return }
        // Read before the items are mutated: reading the ledger inside its own mutation is an
        // exclusivity violation, which traps at run time.
        let windows = ledger.pauseWindows
        ledger.items.removeAll { item in
            guard !item.inFrozen, item.outcome == .pending || item.outcome == .held else { return false }
            guard let when = item.capturedAt else { return false }
            return ScreenshotPause.excludes(when, windows: windows)
        }
        var byHash: [String: ScreenshotCandidate] = [:]
        for file in marked {
            if let hash = file.sha256 { byHash[hash] = file }
        }
        for index in ledger.items.indices {
            let item = ledger.items[index]
            guard item.outcome == .pending || item.outcome == .held else { continue }
            if item.id.hasPrefix("path:") {
                if let file = marked.first(where: { $0.path == item.path }) {
                    if let replacement = makeItem(file, spanStart: .distantPast, delivered: [], frozen: item.inFrozen),
                       replacement.id != item.id {
                        ledger.items[index].outcome = .deleted
                        if !ledger.items.contains(where: { $0.id == replacement.id }) {
                            ledger.items.append(replacement)
                        }
                    }
                } else if !marked.contains(where: { $0.path == item.path && !$0.stable }) {
                    ledger.items[index].outcome = .deleted
                }
                continue
            }
            if let file = byHash[item.id] {
                if file.stable { ledger.items[index].path = file.path }
                continue
            }
            let samePathUnstable = marked.contains { $0.path == item.path && !$0.stable }
            if !samePathUnstable { ledger.items[index].outcome = .deleted }
        }
        let known = Set(ledger.items.map(\.id))
        for file in marked where file.stable {
            guard let item = makeItem(file, spanStart: .distantPast, delivered: known, frozen: false) else { continue }
            guard !known.contains(item.id) else { continue }
            if let when = file.when, let from = ledger.liveFrom, when < from { continue }
            if let when = file.when, ScreenshotPause.excludes(when, windows: windows) { continue }
            if item.outcome == .refused || item.outcome == .unreadable || item.outcome == .pending {
                ledger.items.append(item)
            }
        }
    }

    private func makeItem(
        _ file: ScreenshotCandidate,
        spanStart: Date,
        delivered: Set<String>,
        frozen: Bool
    ) -> ScreenshotStoredItem? {
        guard file.marked, file.stable else { return nil }
        if let when = file.when, when < spanStart { return nil }
        if let hash = file.sha256, delivered.contains(hash) { return nil }
        guard let hash = file.sha256, let when = file.when, !file.unreadable else {
            return ScreenshotStoredItem(
                id: "path:\(file.path)", path: file.path, outcome: .unreadable,
                capturedAt: file.when, takenFrom: nil, byteCount: file.byteCount,
                fileName: nil, inFrozen: frozen, fileExtension: file.fileExtension
            )
        }
        let kind = ScreenshotBytes.kind(header: file.header)
        let refused = ScreenshotBytes.refused(byteCount: file.byteCount, pixelCount: file.pixelCount, kind: kind)
        let name = ScreenshotBytes.uploadName(kind: kind, fileExtension: file.fileExtension)
        return ScreenshotStoredItem(
            id: hash, path: file.path,
            outcome: refused ? .refused : .pending,
            capturedAt: when, takenFrom: file.takenFrom, byteCount: file.byteCount,
            fileName: name, inFrozen: frozen, fileExtension: file.fileExtension
        )
    }

    // MARK: - send

    private func sendReady(serverURL: String, now: Date) async {
        guard ledger.confirmed, ledger.enabled, ledger.access == .ok else { return }
        let generation = setupGeneration
        if capability != true {
            let due = capabilityAskedAt.map { now.timeIntervalSince($0) >= Self.capabilityRecheck } ?? true
            if capability == nil || due {
                if let listed = try? await transport.capabilities(serverURL: serverURL) {
                    guard generation == setupGeneration else { return }
                    capability = listed.contains("screenshots")
                    capabilityAskedAt = now
                }
            }
            guard capability == true else { return }
        }
        var sent = 0
        var delivered = false
        defer { if delivered { Task { await onDelivered() } } }
        while sent < 8 {
            guard ledger.confirmed, let index = nextSendable() else { return }
            let item = ledger.items[index]
            guard let capturedAt = item.capturedAt, let takenFrom = item.takenFrom, let fileName = item.fileName else {
                ledger.items[index].outcome = .unreadable
                continue
            }
            let stamp = ScreenshotStamp(date: capturedAt, timeZone: timeZone())
            let upload = ScreenshotUpload(
                sourcePath: item.path, fileName: fileName, day: stamp.day, segment: stamp.segment,
                capturedAt: stamp.rfc3339, takenFrom: takenFrom, hash: item.id
            )
            let answer = await transport.send(upload, serverURL: serverURL)
            // The send let other work run on this actor. A new pairing's restart drops what this
            // send was for, and turning off or a rescan can move the item, so look it up again.
            guard generation == setupGeneration,
                  let current = ledger.items.firstIndex(where: { $0.id == item.id }) else { return }
            switch answer {
            case .delivered:
                ledger.items[current].outcome = .delivered
                delivered = true
                _ = totals?.applyScreenshot(hash: item.id)
            case .invalid:
                ledger.items[current].outcome = .refused
            case .ahead, .retry:
                ledger.items[current].outcome = .held
                return
            }
            sent += 1
        }
    }

    private func nextSendable() -> Int? {
        ledger.items.indices.first { index in
            let item = ledger.items[index]
            guard item.outcome == .pending || item.outcome == .held else { return false }
            guard item.fileName != nil, item.capturedAt != nil, !item.id.hasPrefix("path:") else { return false }
            if let when = item.capturedAt, !item.inFrozen, ScreenshotPause.excludes(when, windows: ledger.pauseWindows) {
                return false
            }
            return true
        }
    }

    // MARK: - pause

    private func reconcilePause(now: Date, fact: ScreenshotPauseFact) {
        if fact.paused {
            if let index = ledger.pauseWindows.lastIndex(where: { $0.end == nil }) {
                ledger.pauseWindows[index].expiration = fact.expiration
            } else {
                ledger.pauseWindows.append(ScreenshotPauseWindow(start: now, end: nil, expiration: fact.expiration))
            }
        } else if let index = ledger.pauseWindows.lastIndex(where: { $0.end == nil }) {
            let expiration = ledger.pauseWindows[index].expiration
            if let expiration, expiration <= now {
                ledger.pauseWindows[index].end = expiration
            } else {
                ledger.pauseWindows[index].end = now
            }
        }
    }

    /// What has gone to the journal. A new pairing's restart clears it.
    private var deliveredHashes: Set<String> {
        Set(ledger.items.lazy.filter { $0.outcome == .delivered }.map(\.id))
    }

    // MARK: - facts

    private func facts(now: Date, pause: ScreenshotPauseFact, paired: Bool) -> ScreenshotFacts {
        let system = reader.systemFolder()
        let frozen = ledger.items.filter(\.inFrozen)
        let doneOutcomes: Set<ScreenshotOutcome> = [.delivered, .refused, .unreadable, .deleted]
        let done = frozen.filter { doneOutcomes.contains($0.outcome) }.count
        let open = frozen.contains { $0.outcome == .pending || $0.outcome == .held }
        let waiting = ledger.items.filter { $0.outcome == .pending || $0.outcome == .held }.count
        let name = ledger.consented ? ledger.folderName : system.name
        let line = ScreenshotPaths.folderLine(path: ledger.path ?? system.path, home: reader.homePath())
        var count: ScreenshotCount = .idle
        if ledger.consented && !ledger.confirmed && ledger.access == .ok {
            if countFailed {
                count = .failed
            } else {
                let start = ledger.span.start(now: now, timeZone: timeZone())
                let delivered = deliveredHashes
                let included = ledger.seenCandidates.map(\.candidate).filter { file in
                    guard file.marked, file.stable else { return false }
                    if let hash = file.sha256, delivered.contains(hash) { return false }
                    if let when = file.when, when < start { return false }
                    return true
                }
                var identities = Set<String>()
                var total = 0
                for file in included {
                    let id = file.sha256 ?? "path:\(file.path)"
                    if identities.insert(id).inserted { total += 1 }
                }
                count = .ready(total)
            }
        }
        return ScreenshotFacts(
            consented: ledger.consented,
            enabled: ledger.enabled,
            confirmed: ledger.confirmed,
            access: ledger.access,
            accessHeld: ledger.accessHeld ?? true,
            ownerPaused: pause.paused && ledger.confirmed,
            paired: paired,
            waitingForJournal: ledger.confirmed && paired && capability == false,
            folderName: name,
            folderIsDesktop: ledger.consented ? ledger.isDesktop : system.isDesktop,
            folderFromOwner: ledger.ownerChose,
            folderLine: line,
            folderPath: ledger.path ?? system.path,
            span: ledger.span,
            count: count,
            done: done,
            total: frozen.count,
            backlogOpen: ledger.confirmed && open,
            refused: ledger.items.filter { $0.outcome == .refused }.count,
            unreadable: ledger.items.filter { $0.outcome == .unreadable }.count,
            waiting: waiting,
            lastChecked: ledger.lastChecked,
            showReturnNote: ledger.wasOn && ledger.enabled && !ledger.confirmed,
            movedName: ledger.movedName
        )
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            screenshotLog.error("screenshots ledger not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
