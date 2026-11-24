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
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    private var retryWakeTask: Task<Void, Never>?
    private var isShutDown = false

    static let idlePollInterval: TimeInterval = 15

    init(
        engine: ImportEngine,
        facts: @escaping @MainActor () -> ImportFacts,
        serverURL: @escaping @Sendable () async -> String?,
        runsLoop: Bool = true,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.facts = facts
        self.serverURL = serverURL
        self.runsLoop = runsLoop
        self.retrySleep = retrySleep
    }

    static func make(
        appSupportDirectory: URL,
        resolver: HomeBaseURLResolver,
        facts: @escaping @MainActor () -> ImportFacts,
        sourceTotals: SourceTotals? = nil,
        reportDelivery: @escaping @Sendable (String) async -> Void = { _ in },
        reportPairingRefused: @escaping @Sendable (String) async -> Void = { _ in }
    ) -> ImportSource {
        ImportSource(
            engine: ImportEngine(
                directory: appSupportDirectory.appendingPathComponent("Solstone/import", isDirectory: true),
                transport: ImportLiveTransport(),
                sourceTotals: sourceTotals,
                onDelivered: reportDelivery,
                onPairingRefused: reportPairingRefused
            ),
            facts: facts,
            serverURL: {
                guard case .url(let url) = await resolver.resolve() else { return nil }
                return url
            }
        )
    }

    func start() async {
        isShutDown = false
        await refresh(sending: false)
        await reconcileNow()
        guard runsLoop else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.nudge()
                if self.snapshot.readyToReviewCount > 0 {
                    await self.reconcileNow()
                }
                await self.refresh(sending: false)
                let busy = await self.engine.isRunning
                try? await Task.sleep(for: busy ? .seconds(1) : .seconds(Self.idlePollInterval))
            }
        }
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    /// For renders: show this snapshot instead of the engine's.
    func showForSnapshot(_ snapshot: ImportSnapshot) { self.snapshot = snapshot }
#endif

    func shutdown() {
        isShutDown = true
        loop?.cancel()
        loop = nil
        retryWakeTask?.cancel()
        retryWakeTask = nil
    }

    /// Starts a delivery run if none is going; the snapshot is read again when it ends.
    func nudge() {
        Task { await refresh(sending: true) }
    }

    /// Reconciles `ready to review` items via `GET /app/import/api/<id>` even when `waiting == 0`.
    func reconcile() {
        Task { await reconcileNow() }
    }

    func reconcileNow() async {
        var current = facts()
        current.serverURL = await serverURL()
        snapshot = await engine.reconcile(current)
    }

    /// The tunnel connected again.
    func tunnelReconnected() {
        Task {
            await engine.tunnelReconnected()
            await reconcileNow()
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

    /// Files the journal window handed over: kept with the page's area and context.
    func addHandedOver(_ urls: [URL], handoff: ImportHandoff) async -> ImportAddResult {
        let result = await engine.add(urls, handoff: handoff)
        await refresh(sending: false)
        nudge()
        return result
    }

    func handoffStatus(_ id: String) async -> ImportHandoffStatus {
        await engine.handoffStatus(id)
    }

    @discardableResult
    func retry(_ id: String) async -> ImportActionResult {
        let result = await engine.retry(id)
        await refresh(sending: false)
        nudge()
        return result
    }

    @discardableResult
    func sendAgain(_ id: String) async -> ImportActionResult {
        let result = await engine.sendAgain(id)
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
            retryWakeTask?.cancel()
            retryWakeTask = nil
            snapshot = await engine.tick(current)
            await scheduleRetryWakeIfNeeded(for: current)
        } else {
            snapshot = await engine.snapshot(current)
        }
    }

    private func scheduleRetryWakeIfNeeded(for facts: ImportFacts) async {
        guard runsLoop, !isShutDown else { return }
        guard !(await engine.isRunning),
              let delay = await engine.nextRetryDelay(for: facts),
              delay > 0,
              delay < Self.idlePollInterval,
              !isShutDown else { return }
        retryWakeTask?.cancel()
        let wait = max(delay, 0.1)
        let sleep = retrySleep
        retryWakeTask = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(wait))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isShutDown else { return }
            self.nudge()
        }
    }
}
