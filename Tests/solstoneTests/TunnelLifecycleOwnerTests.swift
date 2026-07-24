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

        await refresh.completeNext(with: .refreshed(stale))
        await waitBrieflyUntil {
            let savedPairing = !store.savedPairings.isEmpty
            let disconnectedNewTransport = second.disconnectCount > 0
            let connectedFallbackTransport = third.connectAttempts > 0
            return savedPairing || disconnectedNewTransport || connectedFallbackTransport
        }
        #expect(store.savedPairings.isEmpty)
        #expect(second.disconnectCount == 0)
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
        #expect(!shouldShowPairingRetry(for: .error(.revoked)))
        #expect(!shouldShowPairingRetry(for: .error(.notEntitled)))
        #expect(!shouldShowPairingRetry(for: .error(.loopbackUnavailable)))
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
