// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

/// A transport whose connect keeps trying until it is disconnected, the way the
/// real supervisor does while every path to its journal fails. Cancelling the
/// caller does not end it; only `disconnect()` does.
@MainActor
private final class RetriesUntilDisconnectedTransport: TunnelTransporting {
    var stateUpdates: AsyncStream<TunnelState> { AsyncStream { $0.yield(.connecting(candidates: [])) } }
    var connectionModeUpdates: AsyncStream<ConnectionMode?> { AsyncStream { $0.yield(nil) } }
    var attemptStateUpdates: AsyncStream<TunnelSupervisorAttemptState> { AsyncStream { $0.yield(.attempting) } }
    var connectionMode: ConnectionMode? { nil }

    private(set) var connectedPairings: [StoredPairing] = []
    private(set) var disconnectCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func connect(
        pairing: StoredPairing,
        candidates _: [TransportEndpoint],
        onLocalProxyStart _: (@MainActor (Bool) -> Void)?
    ) async throws -> TunnelTransportConnection {
        connectedPairings.append(pairing)
        await withCheckedContinuation { waiters.append($0) }
        throw CancellationError()
    }

    func disconnect() async {
        disconnectCount += 1
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func requestReconnect() async {}
    func requestUpgrade() async {}
    func inboundActivitySnapshot() async -> UInt64 { 0 }
}

@Suite("Re-pairing while the journal is unreachable", .serialized)
@MainActor
struct TunnelRepairTests {
    @Test("A new pairing takes effect even while the old one is still being dialed")
    func repairReplacesAnAttemptThatNeverConnects() async throws {
        let oldPairing = pairing(instanceID: "old-journal", deviceToken: "old-token")
        let store = PairingStore(pairing: oldPairing)
        let stuck = RetriesUntilDisconnectedTransport()
        let next = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 9090, via: .lan))
        let factory = FakeTransportFactory([stuck, next])
        let owner = TunnelLifecycleOwner(
            credentialStore: PairingCredentialStore(store: store),
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(oldPairing)]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { _ in try await Task.sleep(for: .seconds(10)) },
            unlockNotificationCenter: NotificationCenter()
        )
        owner.start()
        try await waitUntil { stuck.connectedPairings.count == 1 }

        let newPairing = pairing(instanceID: "new-journal", deviceToken: "new-token")
        try store.save(newPairing)
        await owner.reevaluatePairing()

        try await waitUntil(timeout: .seconds(5)) { @MainActor in next.connectedPairings.count == 1 }
        let stuckDisconnects = stuck.disconnectCount
        let dialedInstance = next.connectedPairings.first?.instanceID
        #expect(stuckDisconnects >= 1)
        #expect(dialedInstance == "new-journal")
        try await waitUntil { owner.state == .connected(localPort: 9090, via: .lan) }
        await owner.stop()
    }

    @Test("Retiring an unpaired credential gives up when the journal never answers")
    func retirementGivesUpOnAnUnreachableJournal() async throws {
        let stored = pairing(instanceID: "gone-journal", deviceToken: "gone-token")
        let credentialStore = PairingCredentialStore(store: PairingStore(pairing: stored))
        let invalidation = try credentialStore.beginInvalidation(for: stored)
        let stuck = RetriesUntilDisconnectedTransport()
        let factory = FakeTransportFactory([stuck])
        let owner = TunnelLifecycleOwner(
            credentialStore: credentialStore,
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(stored)]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            retirementControlBudget: .milliseconds(200),
            unlockNotificationCenter: NotificationCenter()
        )

        let started = ContinuousClock.now
        let retired = await owner.retireInvalidatedPairing(stored, operationID: invalidation.operationID)
        let elapsed = ContinuousClock.now - started

        #expect(retired == false)
        #expect(stuck.connectedPairings.count == 1)
        #expect(stuck.disconnectCount >= 1)
        #expect(elapsed < .seconds(5))
    }
}
