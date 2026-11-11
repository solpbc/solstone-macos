// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// The screenshots source on this Mac. The engine decides; this runs the loop and
/// publishes the snapshot the shell draws.
@MainActor @Observable
final class ScreenshotSource {
    private(set) var snapshot = ScreenshotSnapshot.notSetUp

    private let engine: ScreenshotEngine
    private let journalID: @MainActor () -> String?
    private let pauseFact: @MainActor () -> ScreenshotPauseFact
    private let paired: @MainActor () -> Bool
    private let syncPaused: @MainActor () -> Bool
    private let serverURL: @Sendable () async -> String?
    private let runsLoop: Bool

    private var loop: Task<Void, Never>?

    init(
        engine: ScreenshotEngine,
        journalID: @escaping @MainActor () -> String?,
        pauseFact: @escaping @MainActor () -> ScreenshotPauseFact,
        paired: @escaping @MainActor () -> Bool,
        syncPaused: @escaping @MainActor () -> Bool,
        serverURL: @escaping @Sendable () async -> String?,
        runsLoop: Bool = true
    ) {
        self.engine = engine
        self.journalID = journalID
        self.pauseFact = pauseFact
        self.paired = paired
        self.syncPaused = syncPaused
        self.serverURL = serverURL
        self.runsLoop = runsLoop
    }

    static func make(
        appSupportDirectory: URL,
        resolver: HomeBaseURLResolver,
        journalID: @escaping @MainActor () -> String?,
        pauseFact: @escaping @MainActor () -> ScreenshotPauseFact,
        paired: @escaping @MainActor () -> Bool,
        syncPaused: @escaping @MainActor () -> Bool,
        sourceTotals: SourceTotals? = nil,
        reportDelivery: @escaping @Sendable () async -> Void = {}
    ) -> ScreenshotSource {
        ScreenshotSource(
            engine: ScreenshotEngine(
                directory: appSupportDirectory.appendingPathComponent("Solstone/screenshots", isDirectory: true),
                reader: ScreenshotMacReader(),
                transport: ScreenshotLiveTransport(),
                totals: sourceTotals,
                onDelivered: reportDelivery
            ),
            journalID: journalID,
            pauseFact: pauseFact,
            paired: paired,
            syncPaused: syncPaused,
            serverURL: {
                guard case .url(let url) = await resolver.resolve() else { return nil }
                return url
            }
        )
    }

    func start() async {
        snapshot = await engine.snapshot(now: Date(), pause: pauseFact(), journalID: journalID(), paired: paired())
        guard runsLoop else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                let delay: Duration = self.snapshot.busy ? .seconds(1) : .seconds(15)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func shutdown() {
        loop?.cancel()
        loop = nil
    }

    func nudge() {
        Task { await refresh() }
    }

    func allow() async {
        snapshot = await engine.allow(now: Date(), pause: pauseFact(), journalID: journalID(), paired: paired())
    }

    func choose(_ folder: ScreenshotFolder) async {
        snapshot = await engine.choose(folder, now: Date(), pause: pauseFact(), journalID: journalID(), paired: paired())
    }

    func turnOff() async {
        await engine.turnOff()
        await refresh()
    }

    func turnBackOn() async {
        await engine.turnBackOn(now: Date())
        await refresh()
    }

    /// The tile's or the page's switch turned on.
    func turnOn() async {
        snapshot = await engine.turnOn(now: Date(), pause: pauseFact(), journalID: journalID(), paired: paired())
        await refresh()
    }

    func select(span: ScreenshotSpan) async {
        await engine.select(span: span, now: Date())
        await refresh()
    }

    func confirm() async {
        await engine.confirm(now: Date())
        await refresh()
    }

    func retryCount() async {
        await refresh()
    }

    func retryUnreadable() async {
        await engine.retryUnreadable()
        await refresh()
    }

    private func refresh() async {
        let url = await serverURL()
        snapshot = await engine.tick(
            now: Date(), pause: pauseFact(), journalID: journalID(),
            serverURL: url, paired: paired(), syncPaused: syncPaused()
        )
    }
}
