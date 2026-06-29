// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import Testing
@testable import solstone

@Suite("TunnelLifecycleOwner")
@MainActor
struct TunnelLifecycleOwnerTests {
    @Test func dormancyNilThrowAndNoUsableCandidatesAreIdentical() async throws {
        let scenarios: [PairingStore] = [
            PairingStore(pairing: nil),
            PairingStore(pairing: pairing(), loadError: SPLKeychainError.loadFailed(status: -1)),
            PairingStore(pairing: pairing(relayEnrollment: .unavailable, localEndpoints: [])),
        ]

        for store in scenarios {
            let transport = FakeTunnelTransport()
            let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

            owner.start()
            try await waitUntil { owner.state == .disconnected }
            await owner.stop()

            #expect(transport.connectAttempts == 0)
            #expect(owner.state == .disconnected)
            #expect(owner.health == .unknown)
        }
    }

    @Test func stateTransitionsToConnectedWithLanAndRelayRoutes() async throws {
        let lanTransport = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 12345, via: .lan))
        let lanOwner = makeOwner(factory: FakeTransportFactory([lanTransport]))
        lanOwner.start()
        try await waitUntil { lanOwner.state == .connected(localPort: 12345, via: .lan) }
        await lanOwner.stop()

        let relayTransport = FakeTunnelTransport(connectionMode: .plViaSpl, connection: .init(localPort: 23456, via: .relay))
        let relayOwner = makeOwner(factory: FakeTransportFactory([relayTransport]))
        relayOwner.start()
        try await waitUntil { relayOwner.state == .connected(localPort: 23456, via: .relay) }
        await relayOwner.stop()

        #expect(lanTransport.connectAttempts == 1)
        #expect(relayTransport.connectAttempts == 1)
    }

    @Test func tunnelManagedSignalSurvivesTransientDisconnect() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 23456, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))

        #expect(owner.isTunnelManaged)
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 23456, via: .relay) }
        #expect(owner.isTunnelManaged)

        transport.emit(.disconnected)
        try await waitUntil { owner.state == .disconnected }
        await owner.stop()

        #expect(owner.isTunnelManaged)
    }

    @Test func connectedObservationFiresExactlyOnceOnTransitionEdge() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 34567, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))
        let observer = TunnelConnectedEdgeObserver(owner: owner)

        observer.start()
        owner.start()
        try await waitUntil { observer.triggerCount == 1 }

        transport.emit(.connected(via: URL(string: "ws://relay.example")!.relayConnectedVia))
        try await Task.sleep(for: .milliseconds(100))
        observer.stop()
        await owner.stop()

        #expect(observer.triggerCount == 1)
    }

    @Test func coldStartOfflineRetriesAndRecoversOnEstablishmentBackoff() async throws {
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
            .failure(SessionError.transportFailed("offline")),
            .success(.init(localPort: 31337, via: .relay)),
        ])
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { transport.connectAttempts == 2 }
        try await waitUntil { await sleeper.sleepCount == 2 }
        await sleeper.advance()
        try await waitUntil { owner.state == .connected(localPort: 31337, via: .relay) }
        let attemptsAfterConnect = transport.connectAttempts
        await sleeper.advance()
        await sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))
        await owner.stop()

        let sleeps = await sleeper.sleepDurations
        #expect(attemptsAfterConnect == 3)
        #expect(transport.connectAttempts == 3)
        #expect(transport.maxConnectInFlight == 1)
        expectDuration(sleeps[0], inMilliseconds: 750...1250)
        expectDuration(sleeps[1], inMilliseconds: 3750...6250)
    }

    @Test func coldStartOfflineStopCancelsEstablishmentRetry() async throws {
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
        ])
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await owner.stop()
        let attemptsAfterStop = transport.connectAttempts
        await sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))

        #expect(owner.state == .disconnected)
        #expect(transport.connectAttempts == attemptsAfterStop)
    }

    @Test func tokenExpiredDuringBootstrapStopsRetryAndRunsReactiveRefresh() async throws {
        let current = pairing(deviceToken: "old-token")
        let updated = pairing(deviceToken: "new-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.refreshed(updated)]
        )
        let sleeper = ManualSleeper()
        let first = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
            .failure(SessionError.tokenExpired),
        ])
        let second = FakeTunnelTransport(connection: .init(localPort: 41414, via: .relay))
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([first, second]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { first.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { second.connectAttempts == 1 }
        await owner.stop()

        #expect(first.connectAttempts == 2)
        #expect(second.connectedPairings == [updated])
        #expect(store.currentPairing == updated)
        #expect(!store.deleted)
        #expect(await sleeper.establishmentSleepCount == 1)
    }

    @Test func revokedDuringBootstrapStopsRetryAndRetiresPairing() async throws {
        let sleeper = ManualSleeper()
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
            .failure(SessionError.revoked),
        ])
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { owner.state == .error(.revoked) }
        let attemptsAtTerminal = transport.connectAttempts
        await sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))
        await owner.stop()

        #expect(store.deleted)
        #expect(attemptsAtTerminal == 2)
        #expect(transport.connectAttempts == 2)
        #expect(await sleeper.establishmentSleepCount == 1)
    }

    @Test func bootstrapStopsAfterFirstSuccessAndDoesNotOwnerReconnectAgain() async throws {
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
            .success(.init(localPort: 51515, via: .relay)),
        ])
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { owner.state == .connected(localPort: 51515, via: .relay) }
        let attemptsAfterSuccess = transport.connectAttempts
        await sleeper.advance()
        await sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))
        await owner.stop()

        #expect(attemptsAfterSuccess == 2)
        #expect(transport.connectAttempts == 2)
        #expect(transport.maxConnectInFlight == 1)
    }

    @Test func probeDegradesAfterTwoFailuresAndRequestsReconnectAfterThree() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [false, false, false])
        let transport = FakeTunnelTransport(connection: .init(localPort: 34567, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34567, via: .relay) }

        await sleeper.advance()
        try await waitUntil { await probe.count == 1 }
        #expect(owner.health == .unknown)
        await sleeper.advance()
        try await waitUntil { await probe.count == 2 }
        #expect(owner.health == .degraded)
        await sleeper.advance()
        try await waitUntil { transport.requestReconnectCount == 1 }
        #expect(owner.health == .degraded)

        await owner.stop()
    }

    @Test func probeFailureSuppressedWhenInboundActivityIncreases() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [false])
        let transport = FakeTunnelTransport(connection: .init(localPort: 45678, via: .relay))
        transport.inboundSnapshots = [0, 1]
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45678, via: .relay) }
        await sleeper.advance()
        try await waitUntil { await probe.count == 1 }
        await owner.stop()

        #expect(owner.health == .unknown || owner.health == .healthy)
        #expect(transport.requestReconnectCount == 0)
    }

    @Test func proactiveRefreshSavesAndConnectsUpdatedPairing() async throws {
        let current = pairing(deviceToken: "old-token")
        let updated = pairing(deviceToken: "new-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(ifNeededResults: [.refreshed(updated)])
        let transport = FakeTunnelTransport()
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport])
        )

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        await owner.stop()

        #expect(store.savedPairings == [updated])
        #expect(transport.connectedPairings == [updated])
        #expect(!store.deleted)
    }

    @Test func reactiveTokenExpiredRefreshesWithoutDeletingAndSwapsSessionAfterDisconnect() async throws {
        let current = pairing(deviceToken: "old-token")
        let updated = pairing(deviceToken: "new-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.refreshed(updated)]
        )
        let tracker = ActiveSessionTracker()
        let first = FakeTunnelTransport(tracker: tracker)
        let second = FakeTunnelTransport(connection: .init(localPort: 4567, via: .relay), tracker: tracker)
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([first, second])
        )

        owner.start()
        try await waitUntil { first.connectAttempts == 1 }
        first.emit(.failed(.tokenExpired))
        try await waitUntil { second.connectAttempts == 1 }
        await owner.stop()

        #expect(store.savedPairings == [updated])
        #expect(store.currentPairing == updated)
        #expect(!store.deleted)
        #expect(first.disconnectCount >= 1)
        #expect(second.connectedPairings == [updated])
        #expect(tracker.activeAtConstruction == [0, 0])
        #expect(tracker.maxActive == 1)
    }

    @Test func reactiveTokenExpiredDefinitiveFailureRetiresPairing() async throws {
        let current = pairing(deviceToken: "old-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.definitiveAuthFailure]
        )
        let transport = FakeTunnelTransport()
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport])
        )

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        transport.emit(.failed(.tokenExpired))
        try await waitUntil { owner.state == .error(.revoked) }
        await owner.stop()

        #expect(store.deleted)
        #expect(transport.disconnectCount >= 1)
    }

    @Test func loopbackBindRetryIsBoundedAndDisconnectsOnExhaustion() async throws {
        let retryTransport = FakeTunnelTransport(results: [
            .failure(LoopbackProxyError.listenerFailed("one")),
            .success(.init(localPort: 5678, via: .relay)),
        ])
        let retrySleeper = ManualSleeper()
        let retryOwner = makeOwner(factory: FakeTransportFactory([retryTransport]), sleep: { try await retrySleeper.sleep($0) })
        retryOwner.start()
        await retrySleeper.advance()
        try await waitUntil { retryOwner.state == .connected(localPort: 5678, via: .relay) }
        await retryOwner.stop()
        #expect(retryTransport.connectAttempts == 2)

        let exhaustedTransport = FakeTunnelTransport(results: [
            .failure(LoopbackProxyError.listenerFailed("one")),
            .failure(LoopbackProxyError.listenerFailed("two")),
            .failure(LoopbackProxyError.listenerFailed("three")),
        ])
        let exhaustedSleeper = ManualSleeper()
        let exhaustedOwner = makeOwner(factory: FakeTransportFactory([exhaustedTransport]), sleep: { try await exhaustedSleeper.sleep($0) })
        exhaustedOwner.start()
        await exhaustedSleeper.advance()
        await exhaustedSleeper.advance()
        try await waitUntil { exhaustedOwner.state == .error(.loopbackUnavailable) }
        await exhaustedOwner.stop()

        #expect(exhaustedTransport.connectAttempts == 3)
        #expect(exhaustedTransport.disconnectCount >= 1)
    }

    @Test func pathBucketChangeWhileConnectedRequestsReconnectOnceAndDuplicatesAreIgnored() async throws {
        let pathSource = FakePathMonitoringSource()
        let transport = FakeTunnelTransport()
        let owner = makeOwner(factory: FakeTransportFactory([transport]), pathSource: pathSource)

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 8080, via: .relay) }
        pathSource.emit(NetworkPathStatus(bucket: .wifi, isSatisfied: true, isExpensive: false, isConstrained: false))
        try await Task.sleep(for: .milliseconds(350))
        #expect(transport.requestReconnectCount == 0)

        pathSource.emit(NetworkPathStatus(bucket: .wired, isSatisfied: true, isExpensive: false, isConstrained: false))
        try await waitUntil { transport.requestReconnectCount == 1 }
        #expect(transport.requestReconnectCount == 1)

        pathSource.emit(NetworkPathStatus(bucket: .wired, isSatisfied: true, isExpensive: false, isConstrained: false))
        try await Task.sleep(for: .milliseconds(350))
        #expect(transport.requestReconnectCount == 1)

        pathSource.emit(NetworkPathStatus(bucket: .cellular, isSatisfied: false, isExpensive: false, isConstrained: false))
        try await Task.sleep(for: .milliseconds(350))
        await owner.stop()

        #expect(transport.requestReconnectCount == 1)
    }

    @Test func reevaluatePairingWhileDormantConnectsAddedPairing() async throws {
        let store = PairingStore(pairing: nil)
        let transport = FakeTunnelTransport(connection: .init(localPort: 45454, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .disconnected }
        try store.save(pairing())

        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: 45454, via: .relay) }
        await owner.stop()

        #expect(owner.isTunnelManaged)
        #expect(transport.connectAttempts == 1)
        #expect(transport.maxConnectInFlight == 1)
    }

    @Test func reevaluatePairingAfterUnpairBecomesDormantWithoutError() async throws {
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 56565, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 56565, via: .relay) }
        try store.delete()

        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .disconnected }
        await owner.stop()

        #expect(!owner.isTunnelManaged)
        #expect(transport.disconnectCount >= 1)
        #expect(transport.connectAttempts == 1)
    }

    @Test func notEntitledDuringBootstrapSetsTerminalOwnerError() async throws {
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.notEntitled),
        ])
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { owner.state == .error(.notEntitled) }
        let attemptsAtTerminal = transport.connectAttempts
        await sleeper.advance()
        try await Task.sleep(for: .milliseconds(50))
        await owner.stop()

        #expect(attemptsAtTerminal == 1)
        #expect(transport.connectAttempts == 1)
    }

    @Test func notEntitledStateUpdateSetsTerminalOwnerError() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 67676, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 67676, via: .relay) }
        transport.emit(.failed(.notEntitled))
        try await waitUntil { owner.state == .error(.notEntitled) }
        await owner.stop()

        #expect(transport.disconnectCount >= 1)
    }

    private func makeOwner(
        store: PairingStore = PairingStore(pairing: pairing()),
        refresher: TunnelDeviceTokenRefreshing? = nil,
        factory: FakeTransportFactory,
        pathSource: (any PathMonitoringSource)? = NoopPathMonitoringSource(),
        probe: @escaping @Sendable (Int, Duration) async -> Bool = { _, _ in true },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(10)) }
    ) -> TunnelLifecycleOwner {
        TunnelLifecycleOwner(
            loadPairing: { try store.load() },
            savePairing: { try store.save($0) },
            deletePairing: { try store.delete() },
            tokenRefresher: refresher ?? FakeTokenRefresher(ifNeededResults: [.notNeeded(store.currentPairing ?? pairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: pathSource,
            probe: probe,
            sleep: sleep
        )
    }
}

@MainActor
private final class TunnelConnectedEdgeObserver {
    private let owner: TunnelLifecycleOwner
    private var enabled = false
    private var previousState: TunnelLifecycleState?
    private(set) var triggerCount = 0

    init(owner: TunnelLifecycleOwner) {
        self.owner = owner
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        previousState = owner.state
        observe()
    }

    func stop() {
        enabled = false
        previousState = nil
    }

    private func observe() {
        guard enabled else { return }
        let current = withObservationTracking {
            owner.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        handle(current)
    }

    private func handle(_ state: TunnelLifecycleState) {
        let previous = previousState
        previousState = state
        guard isConnected(state), !isConnected(previous) else { return }
        triggerCount += 1
    }

    private func isConnected(_ state: TunnelLifecycleState?) -> Bool {
        guard let state else { return false }
        if case .connected = state {
            return true
        }
        return false
    }
}
