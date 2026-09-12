// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import AppKit
import Observation
import SPLTunnel
import Testing
@testable import solstone

@Suite("TunnelLifecycleOwner", .serialized)
@MainActor
struct TunnelLifecycleOwnerTests {
    @Test func nilAndNoUsableCandidatesStayDormant() async throws {
        let scenarios: [PairingStore] = [
            PairingStore(pairing: nil),
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

    @Test func thrownLoadFailureSurfacesKeychainUnavailable() async throws {
        let store = PairingStore(pairing: pairing(), loadError: SPLKeychainError.loadFailed(status: -1))
        let transport = FakeTunnelTransport()
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .error(.keychainUnavailable) }

        #expect(transport.connectAttempts == 0)
        #expect(owner.state == .error(.keychainUnavailable))
        #expect(owner.health == .unknown)
        await owner.stop()
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

    @Test func singleLoadPerColdLaunch() async throws {
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport()
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 8080, via: .relay) }

        #expect(store.loadCount == 1)
        #expect(owner.state == .connected(localPort: 8080, via: .relay))
        await owner.stop()
    }

    @Test func cachedFailureSurfacesOnHotPathAndCachedNilStaysDormant() async throws {
        do {
            let store = PairingStore(pairing: pairing(), loadError: SPLKeychainError.loadFailed(status: -1))
            let transport = FakeTunnelTransport()
            let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

            owner.start()
            try await waitUntil { owner.state == .error(.keychainUnavailable) }
            await owner.stop()

            #expect(store.loadCount == 1)
            #expect(transport.connectAttempts == 0)
        }

        do {
            let store = PairingStore(pairing: nil)
            let transport = FakeTunnelTransport()
            let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

            owner.start()
            try await waitUntil { owner.state == .disconnected }
            await owner.stop()

            #expect(store.loadCount == 1)
            #expect(transport.connectAttempts == 0)
        }
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

    @Test func authRefreshRequiredDuringBootstrapStopsRetryAndRunsReactiveRefresh() async throws {
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
            .failure(SessionError.authRefreshRequired),
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

    @Test func probeWatchdogPolicyMatchesShippedConstantsAndProbeTimeout() async throws {
        let policy = TunnelLifecycleOwner.probeWatchdogPolicy
        #expect(durationMilliseconds(policy.healthyInterval) == 30_000)
        #expect(durationMilliseconds(policy.degradedInterval) == 5_000)
        #expect(durationMilliseconds(policy.forcedReconnectDegradedIntervalCap) == 120_000)
        #expect(policy.silentFailureLimit == 3)
        #expect(policy.activeInboundFailureLimit == 6)
        #expect(policy.jitterRange == 1.0...1.0)

        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [true])
        let transport = FakeTunnelTransport(connection: .init(localPort: 34566, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, timeout in
                #expect(durationMilliseconds(timeout) == 3_000)
                return await probe.run(port: port)
            },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34566, via: .relay) }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { await probe.count == 1 }
        await owner.stop()
    }

    @Test func watchdogForcedReconnectCadenceBacksOffOnPersistentFailure() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: false, count: 9))
        let transport = FakeTunnelTransport(connection: .init(localPort: 34568, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )
        let expectedMilliseconds = [
            30_000, 5_000, 5_000,
            30_000, 10_000, 10_000,
            30_000, 20_000, 20_000,
        ]

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34568, via: .relay) }

        for expectedSleepCount in 1...expectedMilliseconds.count {
            await waitBrieflyUntil { await sleeper.sleepCount == expectedSleepCount }
            #expect(await sleeper.sleepCount == expectedSleepCount)
            await sleeper.advance()
            await waitBrieflyUntil { await probe.count == expectedSleepCount }
        }
        await waitBrieflyUntil { transport.requestReconnectCount == 3 }
        await owner.stop()

        let sleepMilliseconds = (await sleeper.sleepDurations).map(durationMilliseconds)
        let observedMilliseconds = Array(sleepMilliseconds.prefix(expectedMilliseconds.count))
        try #require(observedMilliseconds.count == expectedMilliseconds.count)
        #expect(observedMilliseconds == expectedMilliseconds)
        let firstBackedOffGap = observedMilliseconds[3..<6].reduce(0, +)
        let secondBackedOffGap = observedMilliseconds[6..<9].reduce(0, +)
        #expect(transport.requestReconnectCount == 3)
        #expect(firstBackedOffGap == 50_000)
        #expect(secondBackedOffGap == 70_000)
        #expect(firstBackedOffGap < secondBackedOffGap)
    }

    @Test func watchdogFirstForcedReconnectTimingUnchanged() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: false, count: 3))
        let transport = FakeTunnelTransport(connection: .init(localPort: 34569, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )
        let expectedMilliseconds = [30_000, 5_000, 5_000]

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34569, via: .relay) }

        for expectedSleepCount in 1...expectedMilliseconds.count {
            await waitBrieflyUntil { await sleeper.sleepCount == expectedSleepCount }
            #expect(await sleeper.sleepCount == expectedSleepCount)
            await sleeper.advance()
            await waitBrieflyUntil { await probe.count == expectedSleepCount }
        }
        await waitBrieflyUntil { transport.requestReconnectCount == 1 }
        await owner.stop()

        let sleepMilliseconds = (await sleeper.sleepDurations).map(durationMilliseconds)
        #expect(Array(sleepMilliseconds.prefix(expectedMilliseconds.count)) == expectedMilliseconds)
        #expect(await probe.count == 3)
        #expect(transport.requestReconnectCount == 1)
    }

    @Test func watchdogForcedReconnectBackoffResetsAfterSuccessfulProbe() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [false, false, false, true, false, false, false])
        let transport = FakeTunnelTransport(connection: .init(localPort: 34570, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )
        let expectedMilliseconds = [
            30_000, 5_000, 5_000,
            30_000,
            30_000, 5_000, 5_000,
        ]

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34570, via: .relay) }

        for expectedSleepCount in 1...expectedMilliseconds.count {
            await waitBrieflyUntil { await sleeper.sleepCount == expectedSleepCount }
            #expect(await sleeper.sleepCount == expectedSleepCount)
            await sleeper.advance()
            await waitBrieflyUntil { await probe.count == expectedSleepCount }
        }
        await waitBrieflyUntil { transport.requestReconnectCount == 2 }
        await owner.stop()

        let sleepMilliseconds = (await sleeper.sleepDurations).map(durationMilliseconds)
        let observedMilliseconds = Array(sleepMilliseconds.prefix(expectedMilliseconds.count))
        try #require(observedMilliseconds.count == expectedMilliseconds.count)
        #expect(observedMilliseconds == expectedMilliseconds)
        #expect(Array(observedMilliseconds[4..<7]) == [30_000, 5_000, 5_000])
        #expect(transport.requestReconnectCount == 2)
    }

    @Test func forcedReconnectBackoffEscalationSurvivesReconnectTransitions() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: false, count: 4))
        let transport = FakeTunnelTransport(connection: .init(localPort: 34571, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 34571, via: .relay) }

        for expectedProbeCount in 1...3 {
            try await waitUntil { await sleeper.sleepCount == expectedProbeCount }
            await sleeper.advance()
            try await waitUntil { await probe.count == expectedProbeCount }
        }
        try await waitUntil { transport.requestReconnectCount == 1 }

        transport.emit(.connecting(candidates: []))
        try await waitUntil { owner.state == .connecting }
        let sleepCountBeforeReconnectConnected = await sleeper.sleepCount
        transport.emit(.connected(via: URL(string: "ws://relay.example")!.relayConnectedVia))
        try await waitUntil { owner.state == .connected(localPort: 34571, via: .relay) }

        try await waitUntil { await sleeper.sleepCount > sleepCountBeforeReconnectConnected }
        let failedProbeSleepCount = await sleeper.sleepCount
        await sleeper.advance()
        try await waitUntil { await probe.count == 4 }
        try await waitUntil { await sleeper.sleepCount > failedProbeSleepCount }

        await owner.stop()

        let sleepMilliseconds = (await sleeper.sleepDurations).map(durationMilliseconds)
        try #require(sleepMilliseconds.count > failedProbeSleepCount)
        #expect(sleepMilliseconds[failedProbeSleepCount] == 10_000)
    }

    @Test func probeFailuresWithInboundActivityReconnectAtRaisedThreshold() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: false, count: 6))
        let transport = FakeTunnelTransport(connection: .init(localPort: 45678, via: .relay))
        transport.inboundSnapshots = [
            0, 1,
            1, 2,
            2, 3,
            3, 4,
            4, 5,
            5, 6,
        ]
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45678, via: .relay) }

        for expectedCount in 1...5 {
            await sleeper.advance()
            try await waitUntil { await probe.count == expectedCount }
            #expect(owner.health != .healthy)
            #expect(transport.requestReconnectCount == 0)
        }
        await sleeper.advance()
        try await waitUntil { await probe.count == 6 }
        try await waitUntil { transport.requestReconnectCount == 1 }
        await owner.stop()

        #expect(owner.health != .healthy)
        #expect(transport.requestReconnectCount == 1)
    }

    @Test func wakeProbeFailureRequestsReconnectOnce() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [false])
        let transport = FakeTunnelTransport(connection: .init(localPort: 45679, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45679, via: .relay) }
        await owner.handleWakeOrUnlock()
        await owner.stop()

        #expect(await probe.count == 1)
        #expect(transport.requestReconnectCount == 1)
    }

    @Test func wakeProbeFailureReachesInjectedSupervisor() async throws {
        let supervisor = FakeTunnelReconnectingSession()
        let transport = SPLTunnelTransport(
            clientInfo: SPLClientInfo(userAgent: "solstone-macos/test"),
            makeSession: { _, _, _ in supervisor }
        )
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { _, _ in false }
        )

        owner.start()
        try await waitUntil { owner.localPort != nil }
        await owner.handleWakeOrUnlock()
        try await waitUntil { await supervisor.requestReconnectCount == 1 }
        await owner.stop()

        #expect(await supervisor.requestReconnectCount == 1)
    }

    @Test func wakeProbeSuccessDoesNotRequestReconnect() async throws {
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [true])
        let transport = FakeTunnelTransport(connection: .init(localPort: 45680, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45680, via: .relay) }
        await owner.handleWakeOrUnlock()
        #expect(owner.health == .healthy)
        await owner.stop()

        #expect(await probe.count == 1)
        #expect(transport.requestReconnectCount == 0)
    }

    @Test func wakeProbeSkipsWhenStoppedOrDisconnected() async throws {
        let stoppedProbe = ProbeScript(results: [false])
        let stoppedTransport = FakeTunnelTransport(connection: .init(localPort: 45681, via: .relay))
        let stoppedOwner = makeOwner(
            factory: FakeTransportFactory([stoppedTransport]),
            probe: { port, _ in await stoppedProbe.run(port: port) }
        )
        await stoppedOwner.handleWakeOrUnlock()

        let dormantProbe = ProbeScript(results: [false])
        let dormantOwner = makeOwner(
            store: PairingStore(pairing: nil),
            factory: FakeTransportFactory([FakeTunnelTransport()]),
            probe: { port, _ in await dormantProbe.run(port: port) }
        )
        dormantOwner.start()
        try await waitUntil { dormantOwner.state == .disconnected }
        await dormantOwner.handleWakeOrUnlock()
        await dormantOwner.stop()

        #expect(await stoppedProbe.count == 0)
        #expect(await dormantProbe.count == 0)
        #expect(stoppedTransport.requestReconnectCount == 0)
    }

    @Test func wakeObserversAreRemovedOnStopAndNotDuplicatedAcrossRestart() async throws {
        let probe = ProbeScript(results: [false, false])
        let first = FakeTunnelTransport(connection: .init(localPort: 45682, via: .relay))
        let second = FakeTunnelTransport(connection: .init(localPort: 45683, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([first, second]),
            probe: { port, _ in await probe.run(port: port) }
        )

        owner.start()
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45682, via: .relay) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { first.requestReconnectCount == 1 }
        await waitBrieflyUntil { first.requestReconnectCount > 1 }
        #expect(first.requestReconnectCount == 1)

        await owner.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        await waitBrieflyUntil { first.requestReconnectCount > 1 }
        #expect(first.requestReconnectCount == 1)

        owner.start()
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 45683, via: .relay) }
        DistributedNotificationCenter.default().post(name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        try await waitUntil { second.requestReconnectCount == 1 }
        await waitBrieflyUntil { second.requestReconnectCount > 1 }
        await owner.stop()

        #expect(second.requestReconnectCount == 1)
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

    @Test func tokenRefreshSaveCarriesUpdatedPairingToTransport() async throws {
        let current = pairing(deviceToken: "old-token")
        let updated = pairing(deviceToken: "refreshed-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(ifNeededResults: [.refreshed(updated)])
        let transport = FakeTunnelTransport()
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport])
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 8080, via: .relay) }
        await owner.stop()

        let connected = try #require(transport.connectedPairings.last)
        #expect(connected.relayEnrollment == .enrolled(deviceToken: "refreshed-token", expiresAt: nil))
        #expect(transport.connectedPairings == [updated])
    }

    @Test func reactiveAuthRefreshRequiredRefreshesWithoutDeletingAndSwapsSessionAfterDisconnect() async throws {
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
        first.emit(.failed(.authRefreshRequired))
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

    @Test func reactiveAuthRefreshRequiredDefinitiveFailureRetiresPairing() async throws {
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
        transport.emit(.failed(.authRefreshRequired))
        try await waitUntil { owner.state == .error(.revoked) }
        await owner.stop()

        #expect(store.deleted)
        #expect(transport.disconnectCount >= 1)
    }

    @Test func reactiveAuthRefreshDefinitiveFailureAgainstNewerPairingDoesNotDeleteNewerPairing() async throws {
        let pairingA = pairing(instanceID: "instance-A", deviceToken: "token-A")
        let pairingB = pairing(instanceID: "instance-B", deviceToken: "token-B")
        let store = PairingStore(pairing: pairingA)
        let refresh = ControlledTokenRefresher()
        let transportA = FakeTunnelTransport(connection: .init(localPort: 61241, via: .relay))
        let transportB = FakeTunnelTransport(connection: .init(localPort: 61242, via: .relay))
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transportA, transportB])
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 61241, via: .relay) }

        // Start reactive refresh on pairingA
        transportA.emit(.failed(.authRefreshRequired))
        try await waitUntil { await refresh.pendingNowCount == 1 }

        // Reevaluate / re-pair to pairingB (advances pairingGeneration)
        try store.save(pairingB)
        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: 61242, via: .relay) }

        // Complete the old refresh from pairingA with .definitiveAuthFailure
        await refresh.completeNext(with: .definitiveAuthFailure)

        // Allow any asynchronous outcome handling to settle
        try await Task.sleep(for: .milliseconds(50))

        // Newer pairingB must NOT be deleted from store or retired
        #expect(store.deleted == false)
        #expect(store.currentPairing?.instanceID == "instance-B")
        #expect(owner.state == .connected(localPort: 61242, via: .relay))

        await owner.stop()
    }

    @Test func republishedConnectedRestoresRememberedLoopbackPort() async throws {
        let port = 61234
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(connection: .init(localPort: port, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: port, via: .relay) }
        transport.emit(.connecting(candidates: []))
        try await waitUntil { owner.state == .connecting }
        transport.emit(.connected(via: .lanDirect(host: "127.0.0.1", port: port)))
        await waitBrieflyUntil { owner.state == .connected(localPort: port, via: .lan) }
        #expect(owner.state == .connected(localPort: port, via: .lan))
        await owner.stop()
    }

    @Test func republishedConnectedRearmsProbe() async throws {
        let port = 61235
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [true])
        let transport = FakeTunnelTransport(connection: .init(localPort: port, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: port, via: .relay) }
        try await waitUntil { await sleeper.sleepCount == 1 }
        transport.emit(.connecting(candidates: []))
        try await waitUntil { owner.state == .connecting }
        transport.emit(.connected(via: .lanDirect(host: "127.0.0.1", port: port)))
        await waitBrieflyUntil { await sleeper.sleepCount == 2 }
        await sleeper.advance()
        await waitBrieflyUntil { await probe.count == 1 }
        await owner.stop()

        #expect(await probe.count == 1)
    }

    @Test func rearmedProbeStillRequestsReconnectAfterFailures() async throws {
        let port = 61236
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [false, false, false])
        let transport = FakeTunnelTransport(connection: .init(localPort: port, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([transport]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: port, via: .relay) }
        try await waitUntil { await sleeper.sleepCount == 1 }
        transport.emit(.connecting(candidates: []))
        try await waitUntil { owner.state == .connecting }
        transport.emit(.connected(via: .lanDirect(host: "127.0.0.1", port: port)))
        try await waitUntil { await sleeper.sleepCount == 2 }

        await sleeper.advance()
        try await waitUntil { await probe.count == 1 }
        try await waitUntil { await sleeper.sleepCount == 3 }
        await sleeper.advance()
        try await waitUntil { await probe.count == 2 }
        try await waitUntil { await sleeper.sleepCount == 4 }
        await sleeper.advance()
        try await waitUntil { transport.requestReconnectCount == 1 }
        await owner.stop()

        #expect(await probe.count == 3)
        #expect(transport.requestReconnectCount == 1)
    }

    @Test func republishedConnectedUsesPayloadRouteAfterModeDrain() async throws {
        let port = 61237
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(
            connectionMode: .plDirect,
            connection: .init(localPort: port, via: .lan)
        )
        let owner = makeOwner(factory: FakeTransportFactory([transport]), sleep: { try await sleeper.sleep($0) })

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: port, via: .lan) }
        transport.emitMode(.plViaSpl)
        try await waitUntil { owner.state == .connected(localPort: port, via: .relay) }
        transport.emit(.connecting(candidates: []))
        try await waitUntil { owner.state == .connecting }
        transport.emit(.connected(via: .lanDirect(host: "127.0.0.1", port: port)))
        await waitBrieflyUntil { owner.state == .connected(localPort: port, via: .lan) }
        #expect(owner.state == .connected(localPort: port, via: .lan))
        await owner.stop()
    }

    @Test func transientReactiveRefreshSchedulesBackoffRetry() async throws {
        let current = pairing(deviceToken: "old-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.transientFailure(current)]
        )
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { transport.connectAttempts == 1 }
        await waitBrieflyUntil { await sleeper.sleepCount == 1 }
        #expect(await sleeper.sleepCount == 1)
        await sleeper.advance()
        await waitBrieflyUntil { await sleeper.sleepCount == 2 }
        await owner.stop()

        #expect(await sleeper.sleepCount == 2)
        #expect(transport.connectAttempts == 1)
    }

    @Test func transientReactiveRefreshEventuallyReconnects() async throws {
        let current = pairing(deviceToken: "old-token")
        let updated = pairing(deviceToken: "new-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.transientFailure(current), .refreshed(updated)]
        )
        let sleeper = ManualSleeper()
        let first = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let second = FakeTunnelTransport(connection: .init(localPort: 61238, via: .relay))
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
        try await waitUntil { owner.state == .connected(localPort: 61238, via: .relay) }
        await owner.stop()

        #expect(store.savedPairings == [updated])
        #expect(store.currentPairing == updated)
        #expect(second.connectedPairings == [updated])
    }

    @Test func reactiveRefreshBackoffUsesEstablishmentBands() async throws {
        let current = pairing(deviceToken: "old-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.transientFailure(current)]
        )
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport]),
            sleep: { try await sleeper.sleep($0) }
        )
        let expectedBands = [
            750...1250,
            3750...6250,
            7500...12500,
            22500...37500,
        ]

        owner.start()
        for index in expectedBands.indices {
            try await waitUntil { await sleeper.sleepCount == index + 1 }
            let sleeps = await sleeper.sleepDurations
            expectDuration(sleeps[index], inMilliseconds: expectedBands[index])
            if index < expectedBands.indices.last! {
                await sleeper.advance()
            }
        }
        await owner.stop()

        #expect(await sleeper.sleepCount == expectedBands.count)
        #expect(transport.connectAttempts == 1)
    }

    @Test func reentrantRefreshedAuthRefreshRequiredBacksOffAndClimbsBands() async throws {
        let current = pairing(deviceToken: "old-token")
        let updates = (1...4).map { pairing(deviceToken: "refresh-\($0)") }
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: updates.map { .refreshed($0) }
        )
        let sleeper = ManualSleeper()
        let transports = (0..<5).map { _ in
            FakeTunnelTransport(results: [
                .failure(SessionError.authRefreshRequired),
            ])
        }
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory(transports),
            sleep: { try await sleeper.sleep($0) }
        )
        let expectedBands = [
            750...1250,
            3750...6250,
            7500...12500,
            22500...37500,
        ]

        owner.start()
        for index in expectedBands.indices {
            try await waitUntil { await sleeper.sleepCount == index + 1 }
            let sleeps = await sleeper.sleepDurations
            expectDuration(sleeps[index], inMilliseconds: expectedBands[index])
            let totalAttempts = transports.reduce(0) { $0 + $1.connectAttempts }
            #expect(totalAttempts == index + 2)
            if index < expectedBands.indices.last! {
                await sleeper.advance()
            }
        }
        await owner.stop()

        #expect(await sleeper.sleepCount == expectedBands.count)
        #expect(transports.reduce(0) { $0 + $1.connectAttempts } == expectedBands.count + 1)
    }

    @Test func stopCancelsPendingReactiveRefreshRetry() async throws {
        let current = pairing(deviceToken: "old-token")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.transientFailure(current)]
        )
        let sleeper = ManualSleeper()
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([transport]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { await sleeper.sleepCount == 1 }
        await owner.stop()
        let attemptsAfterStop = transport.connectAttempts
        await sleeper.advance()
        await waitBrieflyUntil { await sleeper.sleepCount > 1 }

        #expect(owner.state == .disconnected)
        #expect(transport.connectAttempts == attemptsAfterStop)
        #expect(await sleeper.sleepCount == 1)
        #expect(store.savedPairings.isEmpty)
    }

    @Test func republishedConnectedStaysConnectingAfterMemoryCleared() async throws {
        let store = PairingStore(pairing: pairing())
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [true])
        let first = FakeTunnelTransport(connection: .init(localPort: 61239, via: .relay))
        let second = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
        ])
        let owner = makeOwner(
            store: store,
            factory: FakeTransportFactory([first, second]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 61239, via: .relay) }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await owner.reevaluatePairing()
        try await waitUntil { second.connectAttempts == 1 }
        try await waitUntil { owner.state == .connecting }
        second.emit(.connected(via: URL(string: "ws://relay.example")!.relayConnectedVia))
        await waitBrieflyUntil { owner.state == .connected(localPort: 61239, via: .relay) }
        #expect(owner.state == .connecting)
        await sleeper.advance()
        await waitBrieflyUntil { await probe.count > 0 }
        #expect(await probe.count == 0)
        await owner.stop()
    }

    @Test func reentrantAuthRefreshRequiredDrainsPendingReactiveRefresh() async throws {
        let current = pairing(deviceToken: "old-token")
        let firstUpdate = pairing(deviceToken: "first-refresh")
        let secondUpdate = pairing(deviceToken: "second-refresh")
        let store = PairingStore(pairing: current)
        let refresh = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)],
            nowResults: [.refreshed(firstUpdate), .refreshed(secondUpdate)]
        )
        let sleeper = ManualSleeper()
        let first = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let second = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let third = FakeTunnelTransport(connection: .init(localPort: 61240, via: .relay))
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([first, second, third]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { first.connectAttempts == 1 }
        try await waitUntil { second.connectAttempts == 1 }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await sleeper.advance()
        try await waitUntil { third.connectAttempts == 1 }
        #expect(first.connectAttempts == 1)
        #expect(second.connectAttempts == 1)
        #expect(third.connectAttempts == 1)
        #expect(store.savedPairings == [firstUpdate, secondUpdate])
        #expect(owner.state == .connected(localPort: 61240, via: .relay))
        await owner.stop()
    }

    @Test func cancelledRefreshCannotClearOrActOnNewRefresh() async throws {
        let current = pairing(deviceToken: "old-token")
        let stale = pairing(deviceToken: "stale-token")
        let updated = pairing(deviceToken: "updated-token")
        let store = PairingStore(pairing: current)
        let refresh = ControlledTokenRefresher()
        let sleeper = ManualSleeper()
        let first = FakeTunnelTransport(connection: .init(localPort: 61241, via: .relay))
        let second = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let third = FakeTunnelTransport(connection: .init(localPort: 61242, via: .relay))
        let owner = makeOwner(
            store: store,
            refresher: refresh.seam,
            factory: FakeTransportFactory([first, second, third]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 61241, via: .relay) }
        first.emit(.failed(.authRefreshRequired))
        try await waitUntil { await refresh.pendingNowCount == 1 }
        await owner.reevaluatePairing()
        try await waitUntil { second.connectAttempts == 1 }
        try await waitUntil { await refresh.pendingNowCount == 2 }

        let retiredCandidateDisconnects = second.disconnectCount
        await refresh.completeNext(with: .refreshed(stale))
        await waitBrieflyUntil {
            let savedPairing = !store.savedPairings.isEmpty
            let disconnectedNewTransport = second.disconnectCount > retiredCandidateDisconnects
            let connectedFallbackTransport = third.connectAttempts > 0
            return savedPairing || disconnectedNewTransport || connectedFallbackTransport
        }
        #expect(store.savedPairings.isEmpty)
        #expect(second.disconnectCount == retiredCandidateDisconnects)
        #expect(third.connectAttempts == 0)

        await owner.stop()
        await refresh.completeNext(with: .refreshed(updated))
        await waitBrieflyUntil {
            let savedPairing = !store.savedPairings.isEmpty
            let connectedFallbackTransport = third.connectAttempts > 0
            return savedPairing || connectedFallbackTransport
        }

        #expect(owner.state == .disconnected)
        #expect(store.savedPairings.isEmpty)
        #expect(third.connectAttempts == 0)
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
        let wifiStatus = NetworkPathStatus(bucket: .wifi, isSatisfied: true, isExpensive: false, isConstrained: false)
        let wiredStatus = NetworkPathStatus(bucket: .wired, isSatisfied: true, isExpensive: false, isConstrained: false)
        let cellularUnsatisfiedStatus = NetworkPathStatus(
            bucket: .cellular,
            isSatisfied: false,
            isExpensive: false,
            isConstrained: false
        )

        pathSource.emit(wifiStatus)
        try await waitUntil { currentPathSignature(of: owner) == wifiStatus.signature }
        #expect(transport.requestReconnectCount == 0)

        pathSource.emit(wiredStatus)
        try await waitUntil { transport.requestReconnectCount == 1 }
        #expect(transport.requestReconnectCount == 1)

        pathSource.emit(wiredStatus)
        #expect(transport.requestReconnectCount == 1)

        pathSource.emit(cellularUnsatisfiedStatus)
        try await waitUntil { currentPathSignature(of: owner) == cellularUnsatisfiedStatus.signature }
        await owner.stop()

        #expect(transport.requestReconnectCount == 1)
    }

    @Test func pathBucketChangeWhileConnectedReachesInjectedSupervisor() async throws {
        let pathSource = FakePathMonitoringSource()
        let supervisor = FakeTunnelReconnectingSession()
        let transport = SPLTunnelTransport(
            clientInfo: SPLClientInfo(userAgent: "solstone-macos/test"),
            makeSession: { _, _, _ in supervisor }
        )
        let owner = makeOwner(factory: FakeTransportFactory([transport]), pathSource: pathSource)
        let wifiStatus = NetworkPathStatus(bucket: .wifi, isSatisfied: true, isExpensive: false, isConstrained: false)
        let wiredStatus = NetworkPathStatus(bucket: .wired, isSatisfied: true, isExpensive: false, isConstrained: false)

        owner.start()
        try await waitUntil { owner.localPort != nil }
        pathSource.emit(wifiStatus)
        try await waitUntil { currentPathSignature(of: owner) == wifiStatus.signature }
        #expect(await supervisor.requestReconnectCount == 0)

        pathSource.emit(wiredStatus)
        try await waitUntil { await supervisor.requestReconnectCount == 1 }
        await owner.stop()

        #expect(await supervisor.requestReconnectCount == 1)
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

    @Test func unpairThenReevaluateGoesDormant() async throws {
        let stored = pairing()
        let store = PairingStore(pairing: nil, loadOutcomes: [.success(stored), .success(nil)])
        let transport = FakeTunnelTransport(connection: .init(localPort: 56565, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 56565, via: .relay) }
        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .disconnected }
        await owner.stop()

        #expect(!owner.isTunnelManaged)
        #expect(transport.disconnectCount >= 1)
        #expect(transport.connectAttempts == 1)
        #expect(store.loadCount == 2)
    }

    @Test func retryFromKeychainErrorReachesConnected() async throws {
        let store = PairingStore(
            pairing: nil,
            loadOutcomes: [
                .failure(SPLKeychainError.loadFailed(status: -1)),
                .success(pairing()),
            ]
        )
        let transport = FakeTunnelTransport(connection: .init(localPort: 67676, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .error(.keychainUnavailable) }
        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: 67676, via: .relay) }
        await owner.stop()

        #expect(!transport.connectedPairings.isEmpty)
        #expect(store.loadCount == 2)
    }

    @Test func concurrentReevaluatePairingUsesSingleReplacementConnect() async throws {
        let store = PairingStore(pairing: pairing())
        let sleeper = ManualSleeper()
        let initialPort = 68100
        let replacementPort = 68101
        let initial = FakeTunnelTransport(connection: .init(localPort: initialPort, via: .relay))
        let replacement = FakeTunnelTransport(connection: .init(localPort: replacementPort, via: .relay))
        initial.armDisconnectGate()
        replacement.armConnectGate()
        let owner = makeOwner(
            store: store,
            factory: FakeTransportFactory([
                initial,
                replacement,
                FakeTunnelTransport(),
                FakeTunnelTransport(),
            ]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: initialPort, via: .relay) }
        // ManualSleeper is advanced only after the intended newest sleep parks;
        // this holds its "at most one sleep live at a time" test-harness invariant.
        try await waitUntil { await sleeper.sleepCount == 1 }

        let reevaluateA = Task { await owner.reevaluatePairing() }
        try await waitUntil { initial.pendingDisconnectCount == 1 }
        let reevaluateB = Task { await owner.reevaluatePairing() }
        await waitBrieflyUntil { replacement.pendingConnectCount >= 1 }
        initial.releaseNextDisconnect()
        await waitBrieflyUntil { replacement.pendingConnectCount == 2 }
        await drainConnectGate(replacement)

        await reevaluateA.value
        await reevaluateB.value
        try await waitUntil { owner.state == .connected(localPort: replacementPort, via: .relay) }
        await owner.stop()

        #expect(replacement.connectAttempts == 1)
        #expect(replacement.maxConnectInFlight == 1)
    }

    @Test func concurrentReevaluatePairingKeepsProbeRunning() async throws {
        let store = PairingStore(pairing: pairing())
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: true, count: 4))
        let initialPort = 68200
        let firstReplacementPort = 68201
        let secondReplacementPort = 68202
        let initial = FakeTunnelTransport(connection: .init(localPort: initialPort, via: .relay))
        let replacement = FakeTunnelTransport(results: [
            .success(.init(localPort: firstReplacementPort, via: .relay)),
            .success(.init(localPort: secondReplacementPort, via: .relay)),
        ])
        initial.armDisconnectGate()
        replacement.armConnectGate()
        let owner = makeOwner(
            store: store,
            factory: FakeTransportFactory([
                initial,
                replacement,
                FakeTunnelTransport(),
                FakeTunnelTransport(),
            ]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: initialPort, via: .relay) }
        // ManualSleeper is advanced only after the intended newest sleep parks;
        // this holds its "at most one sleep live at a time" test-harness invariant.
        try await waitUntil { await sleeper.sleepCount == 1 }

        let reevaluateA = Task { await owner.reevaluatePairing() }
        try await waitUntil { initial.pendingDisconnectCount == 1 }
        let reevaluateB = Task { await owner.reevaluatePairing() }
        await waitBrieflyUntil { replacement.pendingConnectCount >= 1 }
        initial.releaseNextDisconnect()
        await waitBrieflyUntil { replacement.pendingConnectCount == 2 }
        await drainConnectGate(replacement)

        await reevaluateA.value
        await reevaluateB.value
        try await waitUntil {
            owner.state == .connected(localPort: firstReplacementPort, via: .relay) ||
                owner.state == .connected(localPort: secondReplacementPort, via: .relay)
        }
        try await waitUntil { await sleeper.sleepCount >= 2 }

        let probeRounds = 3
        for expectedCount in 1...probeRounds {
            await sleeper.advance()
            await waitBrieflyUntil { await probe.count >= expectedCount }
            await waitBrieflyUntil { await sleeper.sleepCount >= expectedCount + 2 }
        }
        await owner.stop()

        // Pre-fix red: this stays 0 because probe_1 exits on the P1/P2 port
        // divergence and probeTask never clears, so future startProbe calls refuse.
        let finalProbeCount = await probe.count
        #expect(finalProbeCount == probeRounds)
    }

    @Test func probeUsesLiveLoopbackPortAfterReplacementConnect() async throws {
        let store = PairingStore(pairing: pairing())
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: [true])
        let initialPort = 68210
        let replacementPort = 68211
        let initial = FakeTunnelTransport(connection: .init(localPort: initialPort, via: .relay))
        let replacement = FakeTunnelTransport(connection: .init(localPort: replacementPort, via: .relay))
        let owner = makeOwner(
            store: store,
            factory: FakeTransportFactory([initial, replacement]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: initialPort, via: .relay) }
        try await waitUntil { await sleeper.sleepCount == 1 }
        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: replacementPort, via: .relay) }
        try await waitUntil { await sleeper.sleepCount >= 2 }
        await sleeper.advance()
        try await waitUntil { await probe.count == 1 }
        await owner.stop()

        #expect(await probe.ports == [replacementPort])
    }

    @Test func characterizationRepublishedConnectedDoesNotResetProbeInterval() async throws {
        let port = 68300
        let sleeper = ManualSleeper()
        let probe = ProbeScript(results: Array(repeating: true, count: 4))
        let transport = FakeTunnelTransport(connection: .init(localPort: port, via: .relay))
        let owner = makeOwner(
            factory: FakeTransportFactory([
                transport,
                FakeTunnelTransport(),
                FakeTunnelTransport(),
                FakeTunnelTransport(),
            ]),
            probe: { port, _ in await probe.run(port: port) },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: port, via: .relay) }
        // CHARACTERIZATION: this locks that a republished connected state does
        // not reset the probe interval. ManualSleeper is advanced only after the
        // intended newest sleep parks, holding its one-live-sleep invariant.
        var expectedSleepCount = 1
        try await waitUntil { await sleeper.sleepCount == expectedSleepCount }

        for expectedProbeCount in 1...3 {
            transport.emit(.connected(via: URL(string: "ws://relay.example")!.relayConnectedVia))
            await waitBrieflyUntil { await sleeper.sleepCount > expectedSleepCount }
            let durations = await sleeper.sleepDurations
            #expect(durations.count == expectedSleepCount)

            await sleeper.advance()
            try await waitUntil { await probe.count == expectedProbeCount }
            expectedSleepCount += 1
            try await waitUntil { await sleeper.sleepCount == expectedSleepCount }
        }
        await owner.stop()
    }

    @Test func concurrentReevaluatePairingWaitsForPriorDisconnectBeforeReplacementConnect() async throws {
        let store = PairingStore(pairing: pairing())
        let sleeper = ManualSleeper()
        let tracker = ActiveSessionTracker()
        let initialPort = 68400
        let replacementPort = 68401
        let initial = FakeTunnelTransport(connection: .init(localPort: initialPort, via: .relay), tracker: tracker)
        let replacement = FakeTunnelTransport(connection: .init(localPort: replacementPort, via: .relay), tracker: tracker)
        initial.armDisconnectGate()
        replacement.armConnectGate()
        let owner = makeOwner(
            store: store,
            factory: FakeTransportFactory([
                initial,
                replacement,
                FakeTunnelTransport(tracker: tracker),
                FakeTunnelTransport(tracker: tracker),
            ]),
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: initialPort, via: .relay) }
        // ManualSleeper is advanced only after the intended newest sleep parks;
        // this holds its "at most one sleep live at a time" test-harness invariant.
        try await waitUntil { await sleeper.sleepCount == 1 }

        let reevaluateA = Task { await owner.reevaluatePairing() }
        try await waitUntil { initial.pendingDisconnectCount == 1 }
        let reevaluateB = Task { await owner.reevaluatePairing() }
        await waitBrieflyUntil { replacement.pendingConnectCount >= 1 }
        if replacement.pendingConnectCount > 0 {
            replacement.releaseNextConnect()
            await waitBrieflyUntil { tracker.maxActive == 2 }
        }
        initial.releaseNextDisconnect()
        await waitBrieflyUntil { replacement.pendingConnectCount == 1 }
        await drainConnectGate(replacement)

        await reevaluateA.value
        await reevaluateB.value
        try await waitUntil { owner.state == .connected(localPort: replacementPort, via: .relay) }
        await owner.stop()

        // This does not observe an NWListener directly; LoopbackProxy and
        // TunnelSession live inside SPLTunnelTransport. Any listener leak is
        // inferred from duplicate replacement connects here.
        #expect(tracker.maxActive == 1)
        #expect(replacement.connectAttempts == 1)
    }

    @Test func shouldShowPairingRetryPredicate() {
        #expect(shouldShowPairingRetry(for: .error(.keychainUnavailable)))
        #expect(!shouldShowPairingRetry(for: .disconnected))
        #expect(!shouldShowPairingRetry(for: .connecting))
        #expect(!shouldShowPairingRetry(for: .connected(localPort: 1, via: .relay)))
        #expect(shouldShowPairingRetry(for: .error(.revoked)))
        #expect(!shouldShowPairingRetry(for: .error(.notEntitled)))
        #expect(shouldShowPairingRetry(for: .error(.loopbackUnavailable)))
        #expect(shouldShowPairingRetry(for: .connecting, failureCause: .keychainUnavailable))
        #expect(shouldShowPairingRetry(for: .connecting, failureCause: .noRoute))
        #expect(shouldShowPairingRetry(for: .connecting, failureCause: .unreachable(nil)))
        #expect(shouldShowPairingRetry(for: .connecting, failureCause: .loopbackUnavailable))
        #expect(shouldShowPairingRetry(for: .connecting, failureCause: .revoked))
        #expect(!shouldShowPairingRetry(for: .connecting, failureCause: .notEntitled))
        #expect(!shouldShowPairingRetry(for: .connecting, failureCause: .mismatch))
        #expect(!shouldShowPairingRetry(for: .connecting, failureCause: .notServing))
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

    @Test func installedTransportNotEntitledClearsRememberedConnection() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 67676, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 67676, via: .relay) }
        transport.emit(.failed(.notEntitled))
        try await waitUntil { owner.state == .error(.notEntitled) }
        #expect(owner.localPort == nil)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.attention)
        await owner.stop()
    }

    @Test func replaceLiveTransportWithPairingUpdatesTransportWithoutDisconnectTransition() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let second = FakeTunnelTransport(connection: .init(localPort: 22222, via: .relay))
        let owner = makeOwner(factory: FakeTransportFactory([first, second]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }

        let updatedPairing = pairing(
            instanceID: "instance-1",
            deviceToken: "new-token",
            relayEndpoint: "https://new-relay.solstone.test",
            localEndpoints: [LocalEndpoint(host: "10.0.0.1", port: 5000, scope: "local")]
        )

        await owner.replaceLiveTransport(with: updatedPairing)
        try await waitUntil { owner.state == .connected(localPort: 22222, via: .relay) }

        #expect(first.disconnectCount >= 1)
        #expect(second.connectAttempts == 1)
        #expect(owner.state == .connected(localPort: 22222, via: .relay))
        await owner.stop()
    }

    @Test func reactiveTokenRefreshNotNeededPreservesLANPairing() async throws {
        let lanPairing = pairing(
            instanceID: "instance-lan",
            deviceToken: "token",
            relayEnrollment: .unavailable,
            localEndpoints: [LocalEndpoint(host: "192.168.1.100", port: 4444, scope: "local")]
        )
        let store = PairingStore(pairing: lanPairing)
        let refresher = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(lanPairing)],
            nowResults: [.notNeeded(lanPairing)]
        )
        let transport1 = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let transport2 = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 33333, via: .lan))
        let owner = makeOwner(
            store: store,
            refresher: refresher.seam,
            factory: FakeTransportFactory([transport1, transport2])
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 33333, via: .lan) }

        #expect(store.deleteCount == 0)
        #expect(store.currentPairing != nil)
        #expect(owner.state == .connected(localPort: 33333, via: .lan))
        await owner.stop()
    }

    @Test func failedReadyCandidateLeavesCurrentTransportActiveAndDisconnectsCandidate() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let failingCandidate = FakeTunnelTransport(results: [
            .failure(SessionError.unreachable),
        ])
        let owner = makeOwner(factory: FakeTransportFactory([first, failingCandidate]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }

        let updatedPairing = pairing(
            instanceID: "instance-1",
            deviceToken: "new-token",
            relayEndpoint: "https://new-relay.solstone.test"
        )

        await owner.replaceLiveTransport(with: updatedPairing)

        try await waitUntil { failingCandidate.disconnectCount >= 1 }
        #expect(failingCandidate.disconnectCount >= 1)
        #expect(first.disconnectCount == 0)
        #expect(owner.state == .connected(localPort: 11111, via: .relay))

        first.emit(.connected(via: URL(string: "https://relay.example")!.relayConnectedVia))
        #expect(owner.state == .connected(localPort: 11111, via: .relay))

        await owner.stop()
    }

    @Test(arguments: [SessionError.authRefreshRequired, .revoked, .notEntitled])
    func retainedTransportFailureSurvivesRelayCredentialUpdate(failure: SessionError) async throws {
        let current = pairing(deviceToken: "old-token")
        let store = PairingStore(pairing: current)
        let credentials = PairingCredentialStore(store: store)
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let failing = FakeTunnelTransport(results: [.failure(SessionError.unreachable)])
        let recovered = FakeTunnelTransport(connection: .init(localPort: 22222, via: .relay))
        let refreshed = pairing(deviceToken: "refreshed-token")
        let refresher = FakeTokenRefresher(
            ifNeededResults: [.notNeeded(current)], nowResults: [.refreshed(refreshed)]
        )
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: refresher.seam,
            makeTransport: FakeTransportFactory([first, failing, recovered]).make,
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }
        let before = credentials.currentGenerations()
        let (updated, after) = try credentials.updateRelayAccess(
            expectedPairingGen: before.pairingGeneration,
            expectedAccessGen: before.accessMutationGeneration,
            relayOrigin: current.relayEndpoint,
            deviceToken: "new-token",
            expiresAtString: "2030-01-01T00:00:00Z"
        )
        await owner.handleRelayAccessOutcome(.ready(
            pairing: updated, pairingGen: before.pairingGeneration,
            accessGen: before.accessMutationGeneration, newAccessGen: after
        ))
        #expect(first.disconnectCount == 0)

        first.emit(.failed(failure))
        let expectedState: TunnelLifecycleState = switch failure {
        case .revoked: .error(.revoked)
        case .notEntitled: .error(.notEntitled)
        default: .connected(localPort: 22222, via: .relay)
        }
        do {
            try await waitUntil { owner.state == expectedState }
        } catch {
            await owner.stop()
            throw error
        }
        if failure == .authRefreshRequired {
            #expect(recovered.connectedPairings == [refreshed])
        }
        #expect(store.deleted == (failure == .revoked))
        await owner.stop()
    }

    @Test func failedReplacementStreamCompletionPreservesInstalledRoute() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let failing = FakeTunnelTransport(results: [.failure(SessionError.unreachable)])
        let owner = makeOwner(factory: FakeTransportFactory([first, failing]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }
        await owner.replaceLiveTransport(with: pairing(deviceToken: "new-token"))
        // Real SPLTunnelTransport.disconnect finishes its outward streams.
        failing.finishAttemptUpdates()
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.disconnectCount == 0)
        #expect(owner.state == .connected(localPort: 11111, via: .relay))
        // The installed transport must still be observed after replacement fails.
        first.emitAttemptState(.attempting)
        try await waitUntil { owner.supervisorAttemptState == .attempting }
        await owner.stop()
    }

    @Test func failedReplacementDoesNotWaitForStalledDisposal() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let failing = FakeTunnelTransport(results: [.failure(SessionError.unreachable)])
        failing.armDisconnectGate()
        let owner = makeOwner(factory: FakeTransportFactory([first, failing]))
        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }
        let returned = LockedValue<Bool>()
        let replacement = Task { @MainActor in
            await owner.replaceLiveTransport(with: pairing(deviceToken: "new-token"))
            returned.set(true)
        }
        try await waitUntil { failing.pendingDisconnectCount > 0 }
        // Assert before releasing disposal; release even if the assertion fails.
        try await Task.sleep(for: .milliseconds(30))
        #expect(returned.current == true)
        #expect(first.disconnectCount == 0)
        failing.releaseNextDisconnect()
        await replacement.value
        await owner.stop()
    }

    @Test func queuedRelayOutcomeAcrossPairingReplacementRefusesStaleGenerations() async throws {
        let firstPairing = pairing(instanceID: "inst-1", deviceToken: "tok-1")
        let secondPairing = pairing(instanceID: "inst-2", deviceToken: "tok-2")
        let store = PairingStore(pairing: firstPairing)
        let credStore = PairingCredentialStore(store: store)
        let first = FakeTunnelTransport(connection: .init(localPort: 11111, via: .relay))
        let second = FakeTunnelTransport(connection: .init(localPort: 22222, via: .relay))

        let owner = TunnelLifecycleOwner(
            credentialStore: credStore,
            tokenRefresher: FakeTokenRefresher(ifNeededResults: [.notNeeded(firstPairing)]).seam,
            makeTransport: FakeTransportFactory([first, second]).make,
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 11111, via: .relay) }

        // Advance stored pairing to secondPairing (bumps pairingGen)
        try store.save(secondPairing)
        await owner.reevaluatePairing()
        try await waitUntil { owner.state == .connected(localPort: 22222, via: .relay) }

        // Send stale ready outcome matching first pairingGen (gen 1)
        await owner.handleRelayAccessOutcome(.ready(
            pairing: firstPairing,
            pairingGen: 1,
            accessGen: 1,
            newAccessGen: 2
        ))

        // State remains on second transport
        #expect(owner.state == .connected(localPort: 22222, via: .relay))
        #expect(second.disconnectCount == 0)

        await owner.stop()
    }

    @Test func inFlightRefreshDefinitiveAuthFailureTransitionsToRevoked() async throws {
        let testPairing = pairing(instanceID: "instance-1", deviceToken: "token-1")
        let store = PairingStore(pairing: testPairing)
        let refresher = FakeTokenRefresher(
            ifNeededResults: [.definitiveAuthFailure],
            nowResults: [.definitiveAuthFailure]
        )
        let transport = FakeTunnelTransport(results: [
            .failure(SessionError.authRefreshRequired),
        ])
        let owner = makeOwner(
            store: store,
            refresher: refresher.seam,
            factory: FakeTransportFactory([transport])
        )

        owner.start()
        try await waitUntil { owner.state == .error(.revoked) }

        #expect(store.deleteCount == 1)
        #expect(store.currentPairing == nil)
        #expect(owner.state == .error(.revoked))

        await owner.stop()
    }

    private func makeOwner(
        store: PairingStore = PairingStore(pairing: pairing()),
        refresher: TunnelDeviceTokenRefreshing? = nil,
        factory: FakeTransportFactory,
        pathSource: (any PathMonitoringSource)? = NoopPathMonitoringSource(),
        probe: @escaping @Sendable (Int, Duration) async -> Bool = { _, _ in true },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(10)) }
    ) -> TunnelLifecycleOwner {
        let credStore = PairingCredentialStore(store: store)
        return TunnelLifecycleOwner(
            credentialStore: credStore,
            tokenRefresher: refresher ?? FakeTokenRefresher(ifNeededResults: [.notNeeded(store.currentPairing ?? pairing())]).seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: pathSource,
            probe: probe,
            sleep: sleep
        )
    }

    private func drainConnectGate(_ transport: FakeTunnelTransport) async {
        for _ in 0..<10 {
            if transport.pendingConnectCount == 0 {
                await waitBrieflyUntil { transport.pendingConnectCount > 0 }
            }
            guard transport.pendingConnectCount > 0 else {
                return
            }
            transport.releaseNextConnect()
        }
    }

    @Test func supervisorAttemptStateUpdatesDriveConnectionVerdict() async throws {
        let store = PairingStore(pairing: pairing())
        let transport = FakeTunnelTransport(connection: .init(localPort: 8080, via: .relay))
        let owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 8080, via: .relay) }
        #expect(owner.connectionVerdict.severity == .good)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)

        transport.emitAttemptState(.attempting)
        try await waitUntil { owner.supervisorAttemptState == .attempting }

        transport.emitAttemptState(.unavailable(.retrying(failureClass: .unreachable, attempt: 1, retryAfter: .seconds(5))))
        try await waitUntil {
            if case .unavailable = owner.supervisorAttemptState { return true }
            return false
        }

        transport.emitAttemptState(.connected)
        try await waitUntil { owner.supervisorAttemptState == .connected }
        #expect(owner.connectionVerdict.severity == .good)

        await owner.stop()
    }

    @Test func threeLayerReducerTransitions() {
        // Neutral: no pairing
        let neutral = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: false,
            isTunnelManaged: false,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(neutral.severity == .calm)
        #expect(neutral.axToken == PairingConnectionAXState.disconnected.axToken)

        // Live installed route: green
        let liveRoute = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connected(localPort: 8080, via: .relay),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .connected,
            isProxyStarting: false,
            establishedLoopbackPort: 8080,
            hasTransport: true
        )
        #expect(liveRoute.severity == .good)
        #expect(liveRoute.axToken == PairingConnectionAXState.connected.axToken)

        // Active attempt in flight: yellow via proxy starting
        let proxyStarting = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connecting,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: true,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(proxyStarting.severity == .warn)
        #expect(proxyStarting.axToken == PairingConnectionAXState.connecting.axToken)

        // Active attempt in flight: yellow via supervisor attempting
        let supervisorAttempting = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connecting,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .attempting,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: true
        )
        #expect(supervisorAttempting.severity == .warn)
        #expect(supervisorAttempting.axToken == PairingConnectionAXState.connecting.axToken)

        // Held pairing in .connecting with .idle supervisor and NOT proxy starting MUST be red unreachable (not yellow)
        let connectingNotAttempting = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .connecting,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(connectingNotAttempting.severity == .attention)
        #expect(connectingNotAttempting.axToken == PairingConnectionAXState.unreachable.axToken)
        #expect(connectingNotAttempting.failureCause == .unreachable(nil))

        // Failure layer: no route red
        let noRoute = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: true,
            isTunnelManaged: false,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(noRoute.severity == .attention)
        #expect(noRoute.axToken == PairingConnectionAXState.noRoute.axToken)
        #expect(noRoute.failureCause == .noRoute)

        // Failure layer: terminal errors
        let notEntitled = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.notEntitled),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(notEntitled.severity == .attention)
        #expect(notEntitled.axToken == PairingConnectionAXState.notEntitled.axToken)
        #expect(notEntitled.failureCause == .notEntitled)

        let revoked = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.revoked),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(revoked.severity == .attention)
        #expect(revoked.axToken == PairingConnectionAXState.revoked.axToken)
        #expect(revoked.failureCause == .revoked)

        let loopbackUnavail = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.loopbackUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(loopbackUnavail.severity == .attention)
        #expect(loopbackUnavail.axToken == PairingConnectionAXState.loopbackUnavailable.axToken)
        #expect(loopbackUnavail.failureCause == .loopbackUnavailable)

        let keychainUnavail = TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.keychainUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
        #expect(keychainUnavail.severity == .attention)
        #expect(keychainUnavail.axToken == PairingConnectionAXState.keychainUnavailable.axToken)
        #expect(keychainUnavail.failureCause == .keychainUnavailable)
    }

    @Test func controlledAttemptingYellowAndUnavailableRetryRed() async throws {
        let sleeper = ManualSleeper()
        let supervisors = ActualSupervisorRecorder(armGate: true)
        let disk = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: disk)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        let child1 = supervisors.children[0]

        // While outer connect is still gated: emit attempting -> yellow connecting
        try await waitUntil { await child1.pendingConnectCount == 1 }
        child1.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connecting.axToken)

        // While outer connect is still gated: emit unavailable(.retrying) -> red unreachable and !isProxyStarting
        child1.emitAttemptState(.unavailable(.retrying(failureClass: .unreachable, attempt: 1, retryAfter: .seconds(5))))
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.attention }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)
        #expect(owner.connectionVerdict.failureCause == JournalConnectionFailureCause.unreachable(nil))
        #expect(!owner.isProxyStarting)

        // Sleeper holds backoff: without recovery action, successor session/connect count stays 0
        try await Task.sleep(for: .milliseconds(50))
        #expect(supervisors.children.count == 1)

        // Rapid 3x mapped Settings action -> exactly one successor
        #expect(journalConnectionRecoveryAction(for: owner.connectionVerdict.failureCause) == .coalescedReconnect)
        await owner.requestCoalescedReconnect()
        await owner.requestCoalescedReconnect()
        await owner.requestCoalescedReconnect()

        try await waitUntil { supervisors.children.count == 2 }
        let child2 = supervisors.children[1]
        try await waitUntil { await child2.pendingConnectCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(supervisors.children.count == 2)

        // Child 2 emits attempting -> yellow
        child2.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connecting.axToken)

        // Release connect / success -> green
        await child2.releaseNextConnect()
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)

        await owner.stop()
    }

    @Test func controlledAttemptingYellowAndUnavailableRetryRedNoActionTwin() async throws {
        let sleeper = ManualSleeper()
        let supervisors = ActualSupervisorRecorder(armGate: true)
        let disk = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: disk)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        let child1 = supervisors.children[0]
        try await waitUntil { await child1.pendingConnectCount == 1 }

        child1.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }

        child1.emitAttemptState(.unavailable(.retrying(failureClass: .unreachable, attempt: 1, retryAfter: .seconds(5))))
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.attention }
        #expect(!owner.isProxyStarting)

        // No-action twin: successor connect / session count stays 0
        try await Task.sleep(for: .milliseconds(60))
        #expect(supervisors.children.count == 1)
        #expect(await child1.pendingConnectCount == 1)

        await owner.stop()
    }

    @Test func transportReturnStaysYellowUntilProxyInstallAndOwnerConnected() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 34567, via: .relay))
        transport.armConnectGate()
        let factory = FakeTransportFactory([transport])
        let owner = makeOwner(factory: factory)

        owner.start()
        try await waitUntil { transport.pendingConnectCount == 1 }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.warn)

        transport.releaseNextConnect()
        try await waitUntil { owner.state == .connected(localPort: 34567, via: .relay) }

        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)
        await owner.stop()
    }

    @Test func oldUsableRouteGreenThroughReplacementFailure() async throws {
        let initial = FakeTunnelTransport(connection: .init(localPort: 12121, via: .relay))
        let failingReplacement = FakeTunnelTransport(results: [.failure(SessionError.unreachable)])
        let factory = FakeTransportFactory([initial, failingReplacement])
        let owner = makeOwner(factory: factory)

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 12121, via: .relay) }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)

        // Replacement connect attempt fails
        await owner.replaceLiveTransport(with: pairing(deviceToken: "replacement-token"))
        #expect(owner.state == .connected(localPort: 12121, via: .relay))
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)

        // If old route is then lost while successor is attempting -> yellow
        let successor = FakeTunnelTransport(connection: .init(localPort: 12122, via: .relay))
        successor.armConnectGate()
        factory.enqueue([successor])

        initial.emit(.failed(.unreachable))
        try await waitUntil { owner.state == .connecting }
        let replaceTask = Task { await owner.replaceLiveTransport(with: pairing(deviceToken: "token-3")) }
        try await waitUntil { successor.pendingConnectCount == 1 }
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }

        // Successor connects -> green
        successor.releaseNextConnect()
        _ = await replaceTask.result
        try await waitUntil { owner.state == .connected(localPort: 12122, via: .relay) }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)

        await owner.stop()
    }

    @Test func zeroCandidatePersistedPairingShowsRedNoRoute() async throws {
        let zeroCandidatePairing = pairing(relayEnrollment: .unavailable, localEndpoints: [])
        let disk = PairingStore(pairing: zeroCandidatePairing)
        let credentials = PairingCredentialStore(store: disk)
        let transport = FakeTunnelTransport()
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { transport },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await Task.sleep(for: .milliseconds(50))

        #expect(owner.hasPersistedPairing)
        #expect(!owner.isTunnelManaged)
        #expect(transport.connectAttempts == 0)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.attention)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.noRoute.axToken)
        #expect(owner.connectionVerdict.failureCause == JournalConnectionFailureCause.noRoute)

        await owner.stop()
    }

    @Test func nilPairingStaysNeutralDormant() async throws {
        let disk = PairingStore(pairing: nil)
        let credentials = PairingCredentialStore(store: disk)
        let transport = FakeTunnelTransport()
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { transport },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await Task.sleep(for: .milliseconds(50))

        #expect(!owner.hasPersistedPairing)
        #expect(!owner.isTunnelManaged)
        #expect(transport.connectAttempts == 0)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.calm)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.disconnected.axToken)
        #expect(owner.connectionVerdict.failureCause == nil)

        await owner.stop()
    }

    @Test func sameMacUploadSyncedAndSyncPausedPreservesRouteTruth() async throws {
        let transport = FakeTunnelTransport(connectionMode: .plDirect, connection: .init(localPort: 18181, via: .lan))
        let owner = makeOwner(factory: FakeTransportFactory([transport]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 18181, via: .lan) }

        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)

        // Route loss -> red even if higher-level sync is paused
        transport.emit(.failed(.unreachable))
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.attention }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)

        await owner.stop()
    }

    @Test func adversarialCauseRankingAndLiveRouteProtection() async throws {
        let transport = FakeTunnelTransport(connection: .init(localPort: 19191, via: .relay))
        let failingCandidate = FakeTunnelTransport(results: [.failure(SessionError.notEntitled)])
        let owner = makeOwner(factory: FakeTransportFactory([transport, failingCandidate]))

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 19191, via: .relay) }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)

        // When live route is present, background credential refresh failure does not tear down live transport
        await owner.replaceLiveTransport(with: pairing(deviceToken: "background-refresh"))
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)
        #expect(owner.state == .connected(localPort: 19191, via: .relay))

        await owner.stop()
    }

    @Test func proxyStartingActiveOnlyDuringLoopbackProxyStart() async throws {
        var proxyStartObserved = false
        var verdictDuringProxyStart: JournalConnectionVerdict?

        let transport = FakeTunnelTransport(connection: .init(localPort: 8080, via: .relay))
        let store = PairingStore(pairing: pairing())
        var owner: TunnelLifecycleOwner!
        owner = makeOwner(store: store, factory: FakeTransportFactory([transport]))

        transport.onProxyStartingHook = {
            proxyStartObserved = true
            verdictDuringProxyStart = owner.connectionVerdict
        }

        owner.start()
        try await waitUntil { owner.state == .connected(localPort: 8080, via: .relay) }

        #expect(proxyStartObserved)
        #expect(verdictDuringProxyStart?.severity == .warn)
        #expect(verdictDuringProxyStart?.message == "connecting to your journal…")
        #expect(verdictDuringProxyStart?.axToken == PairingConnectionAXState.connecting.axToken)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)

        await owner.stop()
    }

    @Test func disconnectEagerlyReplacesOutwardStreams() async throws {
        let transport = SPLTunnelTransport()
        let states1 = transport.stateUpdates
        let modes1 = transport.connectionModeUpdates
        let attempts1 = transport.attemptStateUpdates

        let stateTask = Task {
            var observed: [TunnelState] = []
            for await state in states1 {
                observed.append(state)
            }
            return observed
        }

        let modeTask = Task {
            var observed: [ConnectionMode?] = []
            for await mode in modes1 {
                observed.append(mode)
            }
            return observed
        }

        let attemptTask = Task {
            var observed: [TunnelSupervisorAttemptState] = []
            for await attempt in attempts1 {
                observed.append(attempt)
            }
            return observed
        }

        await transport.disconnect()

        let observedStates = await stateTask.value
        let observedModes = await modeTask.value
        let observedAttempts = await attemptTask.value

        #expect(!observedStates.isEmpty)
        #expect(!observedModes.isEmpty)
        #expect(!observedAttempts.isEmpty)

        // After disconnect, new subscribers get newly allocated fresh streams that start cleanly
        let states2 = transport.stateUpdates
        let nextStateTask = Task {
            var count = 0
            for await _ in states2 {
                count += 1
                if count >= 1 { break }
            }
            return count
        }
        let nextCount = await nextStateTask.value
        #expect(nextCount == 1)
    }

    @Test func overlappingProxyStartsOlderEndDoesNotClearNewer() async throws {
        let first = FakeTunnelTransport(connection: .init(localPort: 34567, via: .relay))
        let successor = FakeTunnelTransport(connection: .init(localPort: 34568, via: .relay))
        first.armConnectGate()
        successor.armConnectGate()
        let factory = FakeTransportFactory([first, successor])
        let owner = makeOwner(factory: factory)

        owner.start()
        try await waitUntil { first.pendingConnectCount == 1 }
        let firstAttempt = owner.transportAttemptID
        #expect(owner.isProxyStarting)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.warn)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connecting.axToken)

        // Trigger new generation while transport is still in proxy start
        await owner.requestCoalescedReconnect()
        try await waitUntil { successor.pendingConnectCount == 1 }
        let successorAttempt = owner.transportAttemptID
        #expect(owner.isProxyStarting)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.warn)

        // Older generation ends: must NOT clear newer yellow / isProxyStarting
        owner.endProxyStart(attempt: firstAttempt)
        #expect(owner.isProxyStarting)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.warn)

        // Current generation ends: clears proxy start
        owner.endProxyStart(attempt: successorAttempt)
        #expect(!owner.isProxyStarting)

        await owner.stop()
    }

    @Test func reusedAdapterEstablishmentFailureRetryEmitsAttemptingYellowOnNewSession() async throws {
        let sleeper = ManualSleeper()
        let supervisors = ActualSupervisorRecorder(armGate: true, sessionErrors: [SessionError.unreachable])
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            sleep: { try await sleeper.sleep($0) }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        let child1 = supervisors.children[0]
        try await waitUntil { await child1.pendingConnectCount == 1 }

        // Release child 1 to hit the configured SessionError.unreachable
        await child1.releaseNextConnect()

        // Sleeper parks on establishment backoff
        try await waitUntil { await sleeper.sleepCount == 1 }

        // Retrying starts next generation with new session
        await sleeper.advance()
        try await waitUntil { supervisors.children.count == 2 }
        let child2 = supervisors.children[1]
        try await waitUntil { await child2.pendingConnectCount == 1 }

        // Child 2 emits attempting on the new inner session -> owner goes yellow
        child2.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connecting.axToken)

        // Child 2 completes connect -> owner goes green
        await child2.releaseNextConnect()
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.connected.axToken)

        await owner.stop()
    }

    @Test func innerSessionStateSourceLossWithPairingFailsClosedRedAndRejectsInFlightConnect() async throws {
        let supervisors = ActualSupervisorRecorder(armGate: false)
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }
        let child1 = supervisors.children[0]

        // Finish inner state updates: propagates through SPLTunnelTransport
        child1.finishStateUpdates()

        try await waitUntil { owner.state == .disconnected }
        #expect(owner.health == .unknown)
        #expect(owner.supervisorAttemptState == .idle)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.attention)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)
        #expect(await child1.isDisconnected)

        await owner.stop()
    }

    @Test func innerSessionStateSourceLossWithNoPairingStaysNeutralDormant() async throws {
        let store = PairingStore(pairing: nil)
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { FakeTunnelTransport() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.calm)

        // Trigger stream completion without pairing: stays neutral/calm
        await owner.handleUnexpectedStateStreamCompletion(forIncarnation: nil)
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.calm)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.disconnected.axToken)

        await owner.stop()
    }

    @Test func innerSessionAttemptSourceLossWhileYellowFailsClosedRed() async throws {
        let supervisors = ActualSupervisorRecorder(armGate: true)
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        let child1 = supervisors.children[0]
        try await waitUntil { await child1.pendingConnectCount == 1 }

        // Emit attempting -> yellow
        child1.emitAttemptState(.attempting)
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.warn }

        // Finish inner attempt updates: propagates through SPLTunnelTransport
        child1.finishAttemptUpdates()

        try await waitUntil { owner.state == .disconnected }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.attention)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)
        #expect(await child1.isDisconnected)

        await owner.stop()
    }

    @Test func innerSessionAttemptSourceLossWhileGreenFailsClosedRed() async throws {
        let supervisors = ActualSupervisorRecorder(armGate: false)
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }
        let child1 = supervisors.children[0]

        // Losing the attempt stream makes future reconnect state unknowable, so retire the route.
        child1.finishAttemptUpdates()
        try await waitUntil { owner.state == .disconnected }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.attention)
        #expect(owner.connectionVerdict.axToken == PairingConnectionAXState.unreachable.axToken)
        #expect(await child1.isDisconnected)

        await owner.stop()
    }

    @Test func intentionalStopDoesNotFailClosed() async throws {
        let supervisors = ActualSupervisorRecorder(armGate: false)
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { supervisors.children.count >= 1 }
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }

        await owner.stop()
        #expect(owner.state == .disconnected)
        #expect(owner.supervisorAttemptState == .idle)
    }

    @Test func productionSupervisorBackoffSettingsRecoveryCreatesFreshSupervisor() async throws {
        let supervisors = ActualSupervisorRecorder(
            sessionErrors: [SessionError.unreachable, nil],
            useActualSupervisor: true
        )
        let store = PairingStore(pairing: pairing())
        let credentials = PairingCredentialStore(store: store)
        let owner = TunnelLifecycleOwner(
            credentialStore: credentials,
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: {
                SPLTunnelTransport(
                    makeSession: { supervisors.make(pairing: $0, info: $1, policy: $2) }
                )
            },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true }
        )

        owner.start()
        try await waitUntil { supervisors.children.count == 1 }
        let child1 = supervisors.children[0]
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.attention }
        #expect(supervisors.count == 1)

        // The Settings action retires the SDK supervisor that owns the backoff and
        // starts a fresh app-owned establishment attempt.
        #expect(journalConnectionRecoveryAction(for: owner.connectionVerdict.failureCause) == .coalescedReconnect)
        await owner.requestCoalescedReconnect()
        try await waitUntil { supervisors.count == 2 }
        try await waitUntil { owner.connectionVerdict.severity == StatusDotSeverity.good }
        #expect(supervisors.children.count == 2)
        #expect(await child1.isDisconnected)

        await owner.stop()
    }

    @Test func productionExhaustedLoopbackSettingsRecoverySuccessor() async throws {
        let sleeper = ManualSleeper()
        let retryTransport1 = FakeTunnelTransport(results: [
            .failure(LoopbackProxyError.listenerFailed("one")),
            .failure(LoopbackProxyError.listenerFailed("two")),
            .failure(LoopbackProxyError.listenerFailed("three")),
        ])
        let retryTransport2 = FakeTunnelTransport(results: [
            .success(.init(localPort: 5678, via: .relay)),
        ])
        let factory = FakeTransportFactory([retryTransport1, retryTransport2])
        let owner = makeOwner(factory: factory, sleep: { try await sleeper.sleep($0) })

        owner.start()
        await sleeper.advance()
        await sleeper.advance()
        try await waitUntil { owner.state == .error(.loopbackUnavailable) }
        #expect(owner.connectionVerdict.failureCause == .loopbackUnavailable)

        // Mapped Settings action is .coalescedReconnect
        #expect(journalConnectionRecoveryAction(for: owner.connectionVerdict.failureCause) == .coalescedReconnect)
        #expect(factory.makeCount == 1)
        await owner.requestCoalescedReconnect()
        await owner.requestCoalescedReconnect()
        await owner.requestCoalescedReconnect()

        try await waitUntil { factory.makeCount == 2 }
        #expect(factory.makeCount == 2)
        try await waitUntil { owner.state == .connected(localPort: 5678, via: .relay) }
        #expect(owner.connectionVerdict.severity == StatusDotSeverity.good)

        await owner.stop()
    }

    private func waitBrieflyUntil(_ condition: @escaping @MainActor @Sendable () async -> Bool) async {
        try? await waitUntil(timeout: .milliseconds(200), condition)
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
