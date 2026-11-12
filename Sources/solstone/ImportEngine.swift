// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What adding one file did.
enum ImportAddOutcome: Equatable, Sendable {
    case added(id: String)
    case refused(ImportIntakeRefusal)
}

struct ImportAddResult: Equatable, Sendable {
    /// One per URL given, in order.
    var outcomes: [(name: String, outcome: ImportAddOutcome)]

    static func == (a: ImportAddResult, b: ImportAddResult) -> Bool {
        a.outcomes.map(\.name) == b.outcomes.map(\.name) && a.outcomes.map(\.outcome) == b.outcomes.map(\.outcome)
    }
}

/// Converts a HEIC/HEIF photo to JPEG, keeping its image properties (capture date, orientation),
/// so the journal dates it by when it was taken.
func importConvertHEICToJPEG(_ source: URL, _ target: URL) throws {
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
          CGImageSourceGetCount(image) > 0,
          let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let primary = CGImageSourceGetPrimaryImageIndex(image)
    let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, image, primary, options)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Free space on the volume holding `url`, read fresh every time.
func importAvailableCapacity(_ url: URL) -> Int64 {
    var fresh = URL(fileURLWithPath: url.path)
    fresh.removeAllCachedResourceValues()
    let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
}

/// Holds the owner's imports and carries them to the paired journal. Recovery runs once, before
/// any add or run. Adds run one at a time, with their copy off this actor, so a long copy never
/// holds up a run or a read.
actor ImportEngine {
    private let store: ImportCustodyStore
    private let transport: any ImportTransport
    private let clock: @Sendable () -> Date
    private let freeSpace: @Sendable () -> Int64
    private let convertHEIC: @Sendable (URL, URL) throws -> Void
    private let onDelivered: @Sendable (String) async -> Void
    private let maxBytes: Int64
    private var started = false
    private var running = false
    private var latest = ImportFacts()
    private var authHold: (instance: String, until: Date)?
    private var intake: ImportIntakeLine?
    private var addChain: Task<Void, Never>?
    private var runningMarker: URL { store.root.appendingPathComponent(".intake-running") }
    private var interruptedMarker: URL { store.root.appendingPathComponent(".intake-interrupted") }
    static let authHoldInterval: TimeInterval = 15 * 60

    init(
        directory: URL,
        transport: any ImportTransport,
        clock: @escaping @Sendable () -> Date = Date.init,
        freeSpace: (@Sendable () -> Int64)? = nil,
        convertHEIC: @escaping @Sendable (URL, URL) throws -> Void = importConvertHEICToJPEG,
        maxBytes: Int64 = importMaxBytes,
        storeFsync: @escaping @Sendable (URL) throws -> Void = importFullFsync,
        onDelivered: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        let store = ImportCustodyStore(root: directory, clock: clock, fsync: storeFsync)
        self.store = store
        self.transport = transport
        self.clock = clock
        self.freeSpace = freeSpace ?? { importAvailableCapacity(directory) }
        self.convertHEIC = convertHEIC
        self.maxBytes = maxBytes
        self.onDelivered = onDelivered
    }

    private func ensureStarted() {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        if fm.fileExists(atPath: runningMarker.path) {
            fm.createFile(atPath: interruptedMarker.path, contents: nil)
            try? fm.removeItem(at: runningMarker)
        }
        store.recover()
    }

    // MARK: - adding

    /// Copies each file into the store before returning, one add at a time.
    func add(_ urls: [URL]) async -> ImportAddResult {
        ensureStarted()
        if store.unreadable {
            return ImportAddResult(outcomes: urls.map { ($0.lastPathComponent, .refused(.noSpace)) })
        }
        let previous = addChain
        let job = Task<ImportAddResult, Never> { [store, freeSpace, convertHEIC, maxBytes, runningMarker] in
            await previous?.value
            return await Task.detached {
                importIntake(
                    urls, store: store, freeSpace: freeSpace, convertHEIC: convertHEIC,
                    maxBytes: maxBytes, runningMarker: runningMarker
                )
            }.value
        }
        addChain = Task { _ = await job.value }
        intake = .copying(done: 0, total: urls.count)
        let result = await job.value
        let refused = result.outcomes.compactMap { item -> ImportRefusedItem? in
            if case .refused(let reason) = item.outcome { return ImportRefusedItem(name: item.name, reason: reason) }
            return nil
        }
        intake = .finished(accepted: result.outcomes.count - refused.count, refused: refused)
        return result
    }

    func dismissInterrupted() {
        try? FileManager.default.removeItem(at: interruptedMarker)
    }

    func intakeSeen() {
        if case .finished = intake { intake = nil }
    }

    // MARK: - delivery

    private func gateOpen(_ facts: ImportFacts) -> (serverURL: String, instance: String, version: String)? {
        guard facts.paired, facts.markConfirmed, !facts.syncPaused, !facts.pairingRefused,
              let serverURL = facts.serverURL, let instance = facts.instance, let version = facts.version,
              importVersionGate(version) == .supported else { return nil }
        if let hold = authHold, hold.instance == instance, hold.until > clock() { return nil }
        return (serverURL, instance, version)
    }

    private func isCurrent(_ instance: String) -> Bool {
        gateOpen(latest)?.instance == instance
    }

    /// Runs one delivery pass when the gate is open and none is running.
    func tick(_ facts: ImportFacts) async -> ImportSnapshot {
        ensureStarted()
        noteFacts(facts)
        guard !running, !store.unreadable, let open = gateOpen(facts) else { return snapshot(facts) }
        running = true
        let before = store.lastDeliveredAt()
        let result = await deliverImports(
            transport: transport, store: store, serverURL: open.serverURL, instance: open.instance,
            journalVersion: open.version, gate: .supported,
            stillCurrent: { [weak self] in await self?.isCurrent(open.instance) ?? false },
            now: clock
        )
        running = false
        if result == .authStop {
            authHold = (open.instance, clock().addingTimeInterval(Self.authHoldInterval))
        }
        if store.lastDeliveredAt() != before {
            // The journal the requests went to, captured before they were sent.
            await onDelivered(open.instance)
        }
        return snapshot(latest)
    }

    private func noteFacts(_ facts: ImportFacts) {
        if let hold = authHold, hold.instance != facts.instance { authHold = nil }
        latest = facts
    }

    /// The tunnel connected again: a held auth stop gets its next try now.
    func tunnelReconnected() {
        authHold = nil
    }

    var isRunning: Bool { running }

    // MARK: - the owner's changes

    func retry(_ id: String) -> ImportActionResult {
        ensureStarted()
        guard !store.unreadable else { return .storeUnreadable }
        switch store.retry(id) {
        case .done: return .done
        case .inFlight: return .busy
        case .delivered: return .alreadyDelivered
        case .gone: return .gone
        case .refused: return .notApplicable
        }
    }

    func remove(_ id: String) -> ImportActionResult {
        ensureStarted()
        guard !store.unreadable else { return .storeUnreadable }
        let saved = store.hasSavedProgress(id)
        switch store.remove(id) {
        case .done: return .removed(savedAtJournal: saved)
        case .inFlight: return .busy
        case .delivered: return .alreadyDelivered
        case .gone: return .gone
        case .refused: return .notApplicable
        }
    }

    // MARK: - reading

    func snapshot(_ facts: ImportFacts) -> ImportSnapshot {
        ensureStarted()
        noteFacts(facts)
        let gate = facts.instance == nil ? ImportVersionGate.unknown : importVersionGate(facts.version)
        let items = store.items(instance: facts.instance, journalVersion: facts.version)
        // An auth stop holds imports for a while and clears on its own, so it reads as waiting:
        // this Mac's pairing itself is unchanged.
        let reason = importWaitingReason(facts, gate: gate, sending: items.contains { $0.inFlight })
        let rows = items.map { item -> ImportRow in
            let kind: ImportRowKind
            if item.inFlight { kind = .sending }
            else if item.scope == .here { kind = .refused(item.error ?? importGenericRefusal) }
            else if item.scope == .elsewhere { kind = .goingAgain }
            else if item.scope == .local { kind = .missingCopy }
            else { kind = .waiting }
            let refusedHere: Bool
            if case .refused = kind { refusedHere = true } else { refusedHere = false }
            return ImportRow(
                id: item.id, name: item.displayName, kind: kind,
                retryable: refusedHere && importRetryableReasons.contains(item.reasonCode ?? "")
                    && !importNotRetryableKinds.contains(item.kind ?? ""),
                savedAtJournal: item.hasSavedProgress || item.inFlight
            )
        }
        let going = rows.filter { row in
            switch row.kind {
            case .waiting, .sending, .goingAgain: return true
            case .refused, .missingCopy: return false
            }
        }.count
        var snapshot = ImportSnapshot()
        snapshot.rows = rows
        snapshot.waiting = reason
        snapshot.countsAsWaiting = gate == .tooOld ? 0 : going
        snapshot.needsOwner = !rows.isEmpty && (gate == .tooOld || going == 0)
        snapshot.deliveredToCurrentJournal = facts.instance != nil && store.lastDeliveredInstance() == facts.instance
        snapshot.interruptedAdd = FileManager.default.fileExists(atPath: interruptedMarker.path)
        snapshot.storeUnreadable = store.unreadable
        snapshot.intake = intake
        return snapshot
    }
}

/// Copies `urls` into the store, as the Android app's intake does: checked against the journal's
/// size limit and the free space capture needs as it goes, with a marker while it runs so one cut
/// short by the app ending is reported afterwards.
func importIntake(
    _ urls: [URL],
    store: ImportCustodyStore,
    freeSpace: @Sendable () -> Int64,
    convertHEIC: (URL, URL) throws -> Void,
    maxBytes: Int64,
    runningMarker: URL,
    copyChunk: Int = 64 * 1024,
    spaceCheckEvery: Int64 = 4 * 1024 * 1024
) -> ImportAddResult {
    let fm = FileManager.default
    fm.createFile(atPath: runningMarker.path, contents: nil)
    defer { try? fm.removeItem(at: runningMarker) }
    var outcomes: [(String, ImportAddOutcome)] = []
    for url in urls {
        outcomes.append((url.lastPathComponent, takeOne(url)))
    }
    return ImportAddResult(outcomes: outcomes)

    func takeOne(_ url: URL) -> ImportAddOutcome {
        guard !store.unreadable else { return .refused(.noSpace) }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey])
        if values?.isDirectory == true { return .refused(.unsupportedType) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let decision = importIntakeDecision(type)
        if case .refuse(let reason) = decision { return .refused(reason) }
        let reported = values?.fileSize.map(Int64.init)
        if let reported, reported > maxBytes { return .refused(.tooLarge) }
        let free = freeSpace()
        if let reported, free - reported < importMinFreeBytes { return .refused(.noSpace) }
        if free < importMinFreeBytes { return .refused(.noSpace) }
        guard let id = store.begin() else { return .refused(.noSpace) }
        let payload = store.stagingPayloadURL(id)
        func abandon(_ reason: ImportIntakeRefusal) -> ImportAddOutcome {
            store.abandon(id)
            return .refused(reason)
        }
        switch decision {
        case .accept(let mime):
            if let refusal = copy(url, to: payload) { return abandon(refusal) }
            return publish(id, name: importIntakeName(url.lastPathComponent, mime: mime), mime: mime, payload: payload, abandon: abandon)
        case .convertToJPEG:
            let raw = payload.deletingLastPathComponent().appendingPathComponent("original")
            if let refusal = copy(url, to: raw) { return abandon(refusal) }
            do {
                try convertHEIC(raw, payload)
            } catch {
                return abandon(.cannotConvert)
            }
            try? fm.removeItem(at: raw)
            let name = importIntakeName(url.lastPathComponent, mime: type?.preferredMIMEType ?? "image/heic", convertedToJPEG: true)
            return publish(id, name: name, mime: "image/jpeg", payload: payload, abandon: abandon)
        case .refuse(let reason):
            return abandon(reason)
        }
    }

    func publish(_ id: String, name: String, mime: String, payload: URL, abandon: (ImportIntakeRefusal) -> ImportAddOutcome) -> ImportAddOutcome {
        guard let size = (try? fm.attributesOfItem(atPath: payload.path))?[.size] as? NSNumber,
              store.publish(id, displayName: name, mime: mime, size: size.int64Value) else { return abandon(.noSpace) }
        return .added(id: id)
    }

    /// Copies `source` to `target`, stopping at the size limit or the free-space floor.
    func copy(_ source: URL, to target: URL) -> ImportIntakeRefusal? {
        guard let input = try? FileHandle(forReadingFrom: source) else { return .unreadable }
        defer { try? input.close() }
        guard fm.createFile(atPath: target.path, contents: nil), let output = try? FileHandle(forWritingTo: target) else { return .noSpace }
        defer { try? output.close() }
        var copied: Int64 = 0
        var sinceCheck = spaceCheckEvery
        while true {
            let chunk: Data
            do {
                guard let read = try input.read(upToCount: copyChunk) else { break }
                chunk = read
            } catch {
                return .unreadable
            }
            if chunk.isEmpty { break }
            if copied + Int64(chunk.count) > maxBytes { return .tooLarge }
            if sinceCheck >= spaceCheckEvery {
                if freeSpace() - spaceCheckEvery < importMinFreeBytes { return .noSpace }
                sinceCheck = 0
            }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                return .noSpace
            }
            copied += Int64(chunk.count)
            sinceCheck += Int64(chunk.count)
        }
        return nil
    }
}
