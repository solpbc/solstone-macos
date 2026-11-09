// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

/// A vault this journal already has, from another device.
struct ObsidianJournalVault: Decodable, Equatable, Sendable {
    let vault: String
    let device: String?
    let lastSyncedAt: String?

    enum CodingKeys: String, CodingKey {
        case vault, device
        case lastSyncedAt = "last_synced_at"
    }
}

enum ObsidianSendOutcome: Equatable, Sendable {
    case delivered
    case ahead
    case invalid
    case retry
}

/// The journal side of delivery. A protocol so tests run without a network.
protocol ObsidianJournalTransport: Sendable {
    func capabilities(serverURL: String) async throws -> [String]
    func vaults(serverURL: String) async throws -> [ObsidianJournalVault]
    func send(file: ObsidianOutboxFile, serverURL: String, stagingDirectory: URL) async -> ObsidianSendOutcome
}

enum ObsidianDelivery {
    private struct Answer: Decodable {
        let status: IngestProtocolV3.UploadStatus
    }

    /// The answers table. The journal replaces a note file with its own memory, so a good
    /// answer names a different file or none, and there's no part to prove against the upload.
    /// Anything not named here is retried.
    static func classify(statusCode: Int, body: Data) -> ObsidianSendOutcome {
        if (200...299).contains(statusCode) {
            return (try? JSONDecoder().decode(Answer.self, from: body)) != nil ? .delivered : .retry
        }
        switch parseIngestErrorBody(body).reasonCode {
        case "segment_removed": return .delivered
        case "obsidian_note_ahead": return .ahead
        case "obsidian_note_invalid": return .invalid
        default: return .retry
        }
    }
}

extension UploadClient: ObsidianJournalTransport {
    func capabilities(serverURL: String) async throws -> [String] {
        try await journalCapabilities(serverURL: serverURL)
    }

    func vaults(serverURL: String) async throws -> [ObsidianJournalVault] {
        try await obsidianVaults(serverURL: serverURL)
    }

    func send(file: ObsidianOutboxFile, serverURL: String, stagingDirectory: URL) async -> ObsidianSendOutcome {
        let bodyURL = stagingDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        do {
            let prepared = try prepareUpload(
                serverURL: serverURL,
                day: file.window.day,
                segment: file.window.segment,
                mediaFiles: [file.url],
                metadata: nil,
                source: ObsidianWire.source,
                bodyURL: bodyURL
            )
            return await uploadObsidianStaged(prepared: prepared)
        } catch {
            Logger.upload.error("Obsidian upload not prepared: \(error.localizedDescription, privacy: .public)")
            return .retry
        }
    }
}

struct ObsidianFoundVault: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    var id: String { url.path }
}

enum ObsidianVaultChoice: Equatable {
    case accepted(name: String)
    case refusedNotAVault
    case refusedUnreadable
    case refusedUnusableName

    static func evaluate(_ url: URL) -> ObsidianVaultChoice {
        switch ObsidianVaultWalker.configFolder(in: url) {
        case .absent: return .refusedNotAVault
        case .unreadable: return .refusedUnreadable
        case .present: break
        }
        let name = url.lastPathComponent
        guard ObsidianWire.isUsableVaultName(name) else { return .refusedUnusableName }
        return .accepted(name: name)
    }
}

/// Obsidian's own vault list, read only to offer choices.
enum ObsidianVaultLocator {
    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    static func foundVaults(configURL: URL = defaultConfigURL) -> [ObsidianFoundVault] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let entries: [[String: Any]]
        if let keyed = root["vaults"] as? [String: [String: Any]] {
            entries = Array(keyed.values)
        } else if let list = root["vaults"] as? [[String: Any]] {
            entries = list
        } else {
            return []
        }
        var seen = Set<String>()
        var found: [ObsidianFoundVault] = []
        for entry in entries {
            guard let path = entry["path"] as? String, seen.insert(path).inserted else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard ObsidianVaultWalker.looksLikeVault(url), ObsidianWire.isUsableVaultName(url.lastPathComponent) else { continue }
            found.append(ObsidianFoundVault(name: url.lastPathComponent, url: url))
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The source's lifecycle, its status for Settings, and its delivery to the journal.
@MainActor @Observable
final class ObsidianVaultSource {
    enum Phase: Equatable, Sendable {
        case off, on, paused, waitingForJournalUpdate, needsAttention
    }

    enum Refusal: Equatable, Sendable {
        case notAVault, unreadable, unusableName
    }

    struct AlreadySynced: Equatable, Sendable {
        let vault: String
        let device: String?
        let lastSyncedAt: String?
    }

    private(set) var phase: Phase = .off
    private(set) var snapshot = ObsidianEngineSnapshot.empty
    private(set) var foundVaults: [ObsidianFoundVault] = []
    private(set) var alreadySynced: AlreadySynced?
    var refusal: Refusal?

    var isOn: Bool { active }

    private let engine: ObsidianEngine
    private let transport: any ObsidianJournalTransport
    private let resolver: HomeBaseURLResolver
    private let isHeld: @MainActor () -> Bool
    private let clock: @Sendable () -> Date
    private let configURL: URL
    private let runsLoop: Bool

    private var active = false
    private var journalListsCapability: Bool?
    private var nextScanAt = Date.distantPast
    private var nextDeliveryAt = Date.distantPast
    private var retryDelay: TimeInterval = ObsidianVaultSource.tickSeconds
    private var loopTask: Task<Void, Never>?
    private var isSleeping = false
    private var wakeRequested = false
    private var tickRunning = false

    static let tickSeconds: TimeInterval = 60
    private static let retryCapSeconds: TimeInterval = 15 * 60

    /// The time until the next scan after one that took `duration` seconds.
    static func scanInterval(afterScanTaking duration: TimeInterval) -> TimeInterval {
        guard duration > 0.6 else { return tickSeconds }
        return min(duration * 100, 15 * 60)
    }

    init(
        engine: ObsidianEngine,
        transport: any ObsidianJournalTransport,
        resolver: HomeBaseURLResolver,
        isHeld: @escaping @MainActor () -> Bool,
        clock: @escaping @Sendable () -> Date = Date.init,
        configURL: URL = ObsidianVaultLocator.defaultConfigURL,
        runsLoop: Bool = true
    ) {
        self.engine = engine
        self.transport = transport
        self.resolver = resolver
        self.isHeld = isHeld
        self.clock = clock
        self.configURL = configURL
        self.runsLoop = runsLoop
    }

    /// Picks up where the last launch left off.
    func start() async {
        await engine.load()
        let state = await engine.currentState()
        if state.enabled, state.vaultPath != nil {
            active = true
            snapshot = await engine.snapshot()
            startLoop()
        }
        refreshPhase()
    }

    func refreshFoundVaults() {
        foundVaults = ObsidianVaultLocator.foundVaults(configURL: configURL)
    }

    func turnOn(_ url: URL) async {
        // Off the main thread: the first read of a protected folder can wait on a macOS prompt.
        let choice = await Task.detached { ObsidianVaultChoice.evaluate(url) }.value
        switch choice {
        case .refusedNotAVault:
            refusal = .notAVault
            return
        case .refusedUnreadable:
            refusal = .unreadable
            return
        case .refusedUnusableName:
            refusal = .unusableName
            return
        case .accepted(let name):
            refusal = nil
            alreadySynced = nil
            await engine.adoptVault(root: url, name: name)
            active = true
            journalListsCapability = nil
            nextScanAt = .distantPast
            snapshot = await engine.snapshot()
            startLoop()
            refreshPhase()
        }
    }

    /// Stops scanning and delivery. Nothing is removed from the journal, and what's waiting stays.
    func turnOff() async {
        active = false
        stopLoop()
        alreadySynced = nil
        await engine.setEnabled(false)
        snapshot = await engine.snapshot()
        refreshPhase()
    }

    /// The owner goes ahead although the journal has this vault from elsewhere.
    func continueAfterAlreadySynced() async {
        alreadySynced = nil
        await engine.setFirstSendCleared()
        refreshPhase()
        nudge()
    }

    /// The owner declines: the source stays off and nothing it read is kept.
    func cancelAfterAlreadySynced() async {
        alreadySynced = nil
        active = false
        stopLoop()
        await engine.discardUnsentVault()
        snapshot = await engine.snapshot()
        refreshPhase()
    }

    /// Ends the loop as the app quits. Everything waiting is already on disk.
    func shutdown() {
        stopLoop()
    }

    /// Runs one pass soon, without waiting for the next tick.
    func nudge() {
        guard active, runsLoop else { return }
        if isSleeping {
            loopTask?.cancel()
            loopTask = nil
            isSleeping = false
            startLoop()
        } else {
            wakeRequested = true
        }
    }

    private func startLoop() {
        guard runsLoop, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        isSleeping = false
    }

    private func runLoop() async {
        while !Task.isCancelled, active {
            await tick()
            if wakeRequested {
                wakeRequested = false
                continue
            }
            isSleeping = true
            try? await Task.sleep(for: .seconds(Self.tickSeconds))
            isSleeping = false
        }
    }

    /// One pass: scan if it's time, then close windows and deliver unless held.
    func tick() async {
        guard active, !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }
        let now = clock()
        if now >= nextScanAt {
            snapshot = await engine.scan(now: now)
            nextScanAt = now.addingTimeInterval(Self.scanInterval(afterScanTaking: snapshot.lastWalkSeconds))
        }
        if !isHeld() {
            let serverURL = await journalReadyForDelivery()
            snapshot = await engine.closeDueWindows(now: now)
            if let serverURL { await sendOutbox(serverURL: serverURL, now: now) }
        }
        snapshot = await engine.snapshot()
        refreshPhase()
    }

    private func refreshPhase() {
        guard active else {
            phase = .off
            return
        }
        if snapshot.vaultUnreadable || snapshot.partUnreadable || snapshot.setAside > 0 {
            phase = .needsAttention
        } else if isHeld() {
            phase = .paused
        } else if journalListsCapability == false {
            phase = .waitingForJournalUpdate
        } else {
            phase = .on
        }
    }

    /// The paired journal's address, once it takes notes and this vault's first send is cleared.
    private func journalReadyForDelivery() async -> String? {
        guard case .url(let serverURL) = await resolver.resolve() else { return nil }
        do {
            journalListsCapability = try await transport.capabilities(serverURL: serverURL).contains(ObsidianWire.capability)
        } catch {
            Logger.upload.info("Obsidian capability check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard journalListsCapability == true, active else { return nil }
        if alreadySynced != nil { return nil }
        let state = await engine.currentState()
        if !state.firstSendCleared {
            do {
                let vaults = try await transport.vaults(serverURL: serverURL)
                guard active else { return nil }
                let matches = vaults.filter { $0.vault == state.vaultName }
                if let match = matches.max(by: { ($0.lastSyncedAt ?? "") < ($1.lastSyncedAt ?? "") }) {
                    alreadySynced = AlreadySynced(vault: match.vault, device: match.device, lastSyncedAt: match.lastSyncedAt)
                    return nil
                }
                await engine.setFirstSendCleared()
            } catch {
                Logger.upload.info("Obsidian vault list not read: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return serverURL
    }

    private func sendOutbox(serverURL: String, now: Date) async {
        guard now >= nextDeliveryAt else { return }
        let stagingDirectory = await engine.stagingDirectory
        for file in await engine.outboxFiles() {
            guard active, !isHeld() else { return }
            switch await transport.send(file: file, serverURL: serverURL, stagingDirectory: stagingDirectory) {
            case .delivered:
                await engine.markDelivered(file)
                retryDelay = Self.tickSeconds
                nextDeliveryAt = .distantPast
            case .invalid:
                await engine.setAside(file)
            case .ahead, .retry:
                nextDeliveryAt = clock().addingTimeInterval(retryDelay)
                retryDelay = min(retryDelay * 2, Self.retryCapSeconds)
                return
            }
        }
    }
}

extension ObsidianVaultSource {
    static func make(appSupportDirectory: URL, resolver: HomeBaseURLResolver, isHeld: @escaping @MainActor () -> Bool) -> ObsidianVaultSource {
        ObsidianVaultSource(
            engine: ObsidianEngine(directory: appSupportDirectory.appendingPathComponent("Solstone/obsidian", isDirectory: true)),
            transport: UploadClient(),
            resolver: resolver,
            isHeld: isHeld
        )
    }

    /// For the running app: the engine's own decisions are the status; this names them for AX.
    var axState: ObsidianSourceAXState {
        if alreadySynced != nil { return .confirming }
        switch phase {
        case .off: return .off
        case .on: return .on
        case .paused: return .paused
        case .waitingForJournalUpdate: return .waitingForJournalUpdate
        case .needsAttention: return .needsAttention
        }
    }
}
