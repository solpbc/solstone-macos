// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// Import on this Mac. The engine decides; this runs its loop and publishes the snapshot the
/// shell draws.
@MainActor @Observable
final class ImportSource {
    private(set) var snapshot = ImportSnapshot()

    private let engine: ImportEngine
    private let facts: @MainActor () -> ImportFacts
    private let serverURL: @Sendable () async -> String?
    private let runsLoop: Bool
    private var loop: Task<Void, Never>?

    init(
        engine: ImportEngine,
        facts: @escaping @MainActor () -> ImportFacts,
        serverURL: @escaping @Sendable () async -> String?,
        runsLoop: Bool = true
    ) {
        self.engine = engine
        self.facts = facts
        self.serverURL = serverURL
        self.runsLoop = runsLoop
    }

    static func make(
        appSupportDirectory: URL,
        resolver: HomeBaseURLResolver,
        facts: @escaping @MainActor () -> ImportFacts,
        reportDelivery: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> ImportSource {
        ImportSource(
            engine: ImportEngine(
                directory: appSupportDirectory.appendingPathComponent("Solstone/import", isDirectory: true),
                transport: ImportLiveTransport(),
                onDelivered: reportDelivery
            ),
            facts: facts,
            serverURL: {
                guard case .url(let url) = await resolver.resolve() else { return nil }
                return url
            }
        )
    }

    func start() async {
        await refresh(sending: false)
        guard runsLoop else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.nudge()
                await self.refresh(sending: false)
                let busy = await self.engine.isRunning
                try? await Task.sleep(for: busy ? .seconds(1) : .seconds(15))
            }
        }
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    /// For renders: show this snapshot instead of the engine's.
    func showForSnapshot(_ snapshot: ImportSnapshot) { self.snapshot = snapshot }
#endif

    func shutdown() {
        loop?.cancel()
        loop = nil
    }

    /// Starts a delivery run if none is going; the snapshot is read again when it ends.
    func nudge() {
        Task { await refresh(sending: true) }
    }

    /// The tunnel connected again.
    func tunnelReconnected() {
        Task {
            await engine.tunnelReconnected()
            await refresh(sending: true)
        }
    }

    @discardableResult
    func add(_ urls: [URL]) async -> ImportAddResult {
        let result = await engine.add(urls)
        await refresh(sending: false)
        nudge()
        return result
    }

    @discardableResult
    func retry(_ id: String) async -> ImportActionResult {
        let result = await engine.retry(id)
        await refresh(sending: false)
        nudge()
        return result
    }

    @discardableResult
    func remove(_ id: String) async -> ImportActionResult {
        let result = await engine.remove(id)
        await refresh(sending: false)
        return result
    }

    func dismissInterrupted() async {
        await engine.dismissInterrupted()
        await refresh(sending: false)
    }

    func intakeSeen() async {
        await engine.intakeSeen()
        await refresh(sending: false)
    }

    private func refresh(sending: Bool) async {
        var current = facts()
        current.serverURL = await serverURL()
        if sending {
            snapshot = await engine.tick(current)
        } else {
            snapshot = await engine.snapshot(current)
        }
    }
}
