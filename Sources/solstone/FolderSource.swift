// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Coordinator for the folders source on this Mac. Drives the periodic scan/delivery loop
/// via `FolderSyncWorker`, refreshes `/supported` and `/facets`, runs `/estimate` during
/// preview, and publishes `FoldersSnapshot` for the desktop shell and SwiftUI views.
@MainActor @Observable
final class FolderSource {
    private(set) var snapshot = FoldersSnapshot.empty

    private let engine: FolderSourceEngine
    private let reader: any FolderSystemReading
    private let transport: any FolderSourceTransport
    private let ownerPaused: @MainActor () -> Bool
    private let paired: @MainActor () -> Bool
    private let syncPaused: @MainActor () -> Bool
    private let serverURL: @Sendable () async -> String?
    private let overlapContext: @MainActor () -> FolderSourceEngine.OverlapContext
    private let now: @Sendable () -> Date
    private let runsLoop: Bool

    private let worker = FolderSyncWorker()
    private var capability = FolderSyncCapability(FolderSourceWireConstants.capability, policy: .untilSupported(recheck: 60))
    private var backoff = FolderSyncBackoff(initial: 15, limit: 900)
    private var shuttingDown = false
    private var facets: [FolderFacet] = []
    private var facetsState: FolderFacetsState = .unpaired
    private var pairingGeneration: UInt64 = 0
    private var supportedRefreshDue = Date.distantPast

    init(
        engine: FolderSourceEngine,
        reader: any FolderSystemReading = FolderSourceMacReader(),
        transport: any FolderSourceTransport,
        ownerPaused: @escaping @MainActor () -> Bool,
        paired: @escaping @MainActor () -> Bool,
        syncPaused: @escaping @MainActor () -> Bool,
        serverURL: @escaping @Sendable () async -> String?,
        overlapContext: @escaping @MainActor () -> FolderSourceEngine.OverlapContext = { .init() },
        now: @escaping @Sendable () -> Date = Date.init,
        runsLoop: Bool = true
    ) {
        self.engine = engine
        self.reader = reader
        self.transport = transport
        self.ownerPaused = ownerPaused
        self.paired = paired
        self.syncPaused = syncPaused
        self.serverURL = serverURL
        self.overlapContext = overlapContext
        self.now = now
        self.runsLoop = runsLoop
    }

    static func make(
        appSupportDirectory: URL,
        journal: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver,
        ownerPaused: @escaping @MainActor () -> Bool,
        paired: @escaping @MainActor () -> Bool,
        syncPaused: @escaping @MainActor () -> Bool,
        overlapContext: @escaping @MainActor () -> FolderSourceEngine.OverlapContext,
        sourceTotals: SourceTotals? = nil,
        reportDelivery: @escaping @Sendable () async -> Void = {}
    ) -> FolderSource {
        let reader = FolderSourceMacReader()
        let engine = FolderSourceEngine(
            directory: appSupportDirectory.appendingPathComponent("Solstone/folders", isDirectory: true),
            reader: reader,
            totals: sourceTotals,
            onDelivered: reportDelivery
        )
        return FolderSource(
            engine: engine,
            reader: reader,
            transport: FolderLiveTransport(journal: journal),
            ownerPaused: ownerPaused,
            paired: paired,
            syncPaused: syncPaused,
            serverURL: {
                guard case .url(let url) = await resolver.resolve() else { return nil }
                return url
            },
            overlapContext: overlapContext
        )
    }

    func start() async {
        shuttingDown = false
        await publishSnapshot()
        guard runsLoop, !shuttingDown else { return }
        worker.start { [weak self] in
            guard let self else { return nil }
            await self.tick()
            return self.snapshot.busy ? .seconds(2) : .seconds(15)
        }
    }

    func shutdown() {
        shuttingDown = true
        worker.stop()
    }

    func nudge() {
        worker.wake()
    }

    // MARK: - Owner actions

    func pickFolder(url: URL, allowOverlap: Bool = false) async -> FolderPickOutcome {
        let bookmark = FolderSourceMacReader.makeBookmark(for: url)
        let outcome = await engine.checkAndAddFolder(
            rawPath: url.path,
            bookmark: bookmark,
            overlapContext: overlapContext(),
            allowOverlap: allowOverlap
        )
        await publishSnapshot()
        if case .added(let id) = outcome {
            await refreshFacets()
            await refreshPreview(id: id)
        }
        return outcome
    }

    func repointFolder(id: String, url: URL) async -> Bool {
        let bookmark = FolderSourceMacReader.makeBookmark(for: url)
        let ok = await engine.repointFolder(id: id, newPath: url.path, bookmark: bookmark)
        if ok {
            await engine.scanAll(now: now())
        }
        await publishSnapshot()
        nudge()
        return ok
    }

    func setKinds(id: String, kinds: FolderKinds) async {
        let changed = await engine.updateKinds(id: id, kinds: kinds)
        await publishSnapshot()
        if changed, let summary = snapshot.folders.first(where: { $0.id == id }),
           summary.mode == .settingUp || summary.widening {
            await refreshPreview(id: id)
        }
    }

    func setFacet(id: String, facet: String?) async {
        _ = await engine.updateFacet(id: id, facet: facet)
        await publishSnapshot()
    }

    func selectSpan(id: String, span: FolderSpan) async {
        _ = await engine.selectSpan(id: id, span: span)
        await refreshPreview(id: id)
    }

    func startWidening(id: String) async {
        if await engine.startWidening(id: id) {
            await publishSnapshot()
            await refreshPreview(id: id)
        }
    }

    func cancelWidening(id: String) async {
        await engine.cancelWidening(id: id)
        await publishSnapshot()
    }

    func confirmFolder(id: String) async {
        _ = await engine.confirmFolder(id: id, now: now())
        await publishSnapshot()
        nudge()
    }

    func pauseFolder(id: String) async {
        _ = await engine.pauseFolder(id: id)
        await publishSnapshot()
        nudge()
    }

    func resumeFolder(id: String) async {
        _ = await engine.resumeFolder(id: id)
        await publishSnapshot()
        nudge()
    }

    func turnOffFolder(id: String) async {
        _ = await engine.turnOffFolder(id: id)
        await publishSnapshot()
    }

    func turnOnFolder(id: String) async {
        if await engine.turnOnFolder(id: id) {
            await publishSnapshot()
            await refreshFacets()
            await refreshPreview(id: id)
        }
    }

    func removeFolder(id: String) async {
        _ = await engine.removeFolder(id: id)
        await publishSnapshot()
    }

    func retryScan() async {
        await engine.scanAll(now: now())
        await publishSnapshot()
        nudge()
    }

    /// Called when the Mac pairs with a new journal. Resets capability/supported caches and
    /// returns active/paused folders to setup while preserving the confirmed outbox.
    func restartFirstSetup() async {
        pairingGeneration &+= 1
        capability.reset()
        backoff.reset()
        supportedRefreshDue = .distantPast
        facets = []
        facetsState = paired() ? .offline : .unpaired
        await engine.restartFirstSetup()
        await publishSnapshot()
    }

    func refreshFacets() async {
        guard paired() else {
            facets = []
            facetsState = .unpaired
            await publishSnapshot()
            return
        }
        guard let url = await serverURL() else {
            facetsState = .offline
            await publishSnapshot()
            return
        }
        let supportedOK = await ensureCapability(serverURL: url)
        guard supportedOK else {
            facetsState = capability.supported == false ? .needsJournalUpdate : .offline
            await publishSnapshot()
            return
        }
        do {
            let list = try await transport.fetchFacets(serverURL: url)
            facets = list
            facetsState = .ready
        } catch {
            facetsState = .offline
        }
        await publishSnapshot()
    }

    func refreshPreview(id: String) async {
        await engine.setPreviewScanning(id: id)
        await publishSnapshot()

        if paired(), let url = await serverURL(), await ensureCapability(serverURL: url) {
            await refreshSupported(serverURL: url)
        }

        guard let (_, estimateItems) = await engine.computePreview(id: id, now: now()) else {
            await publishSnapshot()
            return
        }

        if estimateItems.isEmpty {
            await engine.applyEstimate(id: id, estimate: nil, state: .idle)
            await publishSnapshot()
            return
        }

        guard paired() else {
            await engine.applyEstimate(id: id, estimate: nil, state: .unpaired)
            await publishSnapshot()
            return
        }

        guard let url = await serverURL() else {
            await engine.applyEstimate(id: id, estimate: nil, state: .offline)
            await publishSnapshot()
            return
        }

        guard await ensureCapability(serverURL: url) else {
            let state: FolderEstimateState = capability.supported == false ? .needsJournalUpdate : .offline
            await engine.applyEstimate(id: id, estimate: nil, state: state)
            await publishSnapshot()
            return
        }

        await engine.applyEstimate(id: id, estimate: nil, state: .loading)
        await publishSnapshot()

        let request = FolderEstimateRequest(folderID: id, items: estimateItems)
        do {
            let est = try await transport.fetchEstimate(serverURL: url, request: request)
            await engine.applyEstimate(id: id, estimate: est, state: .ready)
        } catch {
            await engine.applyEstimate(id: id, estimate: nil, state: .offline)
        }
        await publishSnapshot()
    }

    // MARK: - Periodic tick

    func tick() async {
        let currentNow = now()
        let generation = pairingGeneration
        let canConnect = paired() && !shuttingDown && !ownerPaused() && !syncPaused()
        let url = canConnect ? await serverURL() : nil
        var hasCapability = false
        if let url {
            hasCapability = await ensureCapability(serverURL: url)
            if hasCapability && currentNow >= supportedRefreshDue { await refreshSupported(serverURL: url) }
        } else {
            supportedRefreshDue = .distantPast
            if !paired() { facetsState = .unpaired }
        }

        // Scanning stays local even while the connection or delivery is paused.
        await engine.scanAll(now: currentNow)
        guard let url, generation == pairingGeneration, hasCapability else {
            await publishSnapshot()
            return
        }

        if backoff.isDue(at: currentNow) {
            let supportedList = await engine.supportedList()
            // Drain ready chunks up to a small per-tick cap so UI stays responsive.
            for _ in 0..<8 {
                guard !shuttingDown, !ownerPaused(), !syncPaused() else { break }
                guard let upload = await engine.nextDelivery(now: now(), ownerPaused: ownerPaused()) else { break }
                let answer = await transport.sendSegment(
                    upload,
                    reader: reader,
                    supported: supportedList,
                    serverURL: url,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return await self.canSend(upload, generation: generation)
                    }
                )
                guard generation == pairingGeneration else { break }
                await engine.recordAnswer(answer, for: upload, now: now())
                switch answer {
                case .delivered, .deliveredWithRefused, .allFilesRefused, .invalid:
                    backoff.reset()
                case .ahead, .retry:
                    backoff.deferUntilRetry(from: now())
                    await publishSnapshot()
                    return
                }
            }
        }

        await publishSnapshot()
    }

    private func refreshSupported(serverURL: String) async {
        let generation = pairingGeneration
        guard let list = try? await transport.fetchSupported(serverURL: serverURL),
              generation == pairingGeneration else { return }
        await engine.setSupportedList(list)
        supportedRefreshDue = now().addingTimeInterval(900)
    }

    private func canSend(_ upload: FolderSegmentUpload, generation: UInt64) async -> Bool {
        guard await engine.canSend(upload) else { return false }
        return generation == pairingGeneration && paired() && !shuttingDown && !syncPaused() && !ownerPaused()
    }

    private func ensureCapability(serverURL: String) async -> Bool {
        let currentNow = now()
        if capability.needsCheck(at: currentNow) {
            do {
                let listed = try await capability.check(using: transport, serverURL: serverURL)
                capability.record(listed, at: currentNow)
            } catch {
                return false
            }
        }
        return capability.supported == true
    }

    private func publishSnapshot() async {
        let journalNeedsUpdate = paired() && capability.supported == false
        snapshot = await engine.snapshot(
            paired: paired(),
            ownerPaused: ownerPaused(),
            journalNeedsUpdate: journalNeedsUpdate,
            facets: facets,
            facetsState: facetsState
        )
    }
}
