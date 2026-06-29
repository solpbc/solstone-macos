// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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

private final class PairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?
    private let loadError: (any Error)?
    private(set) var savedPairings: [StoredPairing] = []
    private(set) var deleted = false

    var currentPairing: StoredPairing? {
        lock.withLock { pairing }
    }

    init(pairing: StoredPairing?, loadError: (any Error)? = nil) {
        self.pairing = pairing
        self.loadError = loadError
    }

    func load() throws -> StoredPairing? {
        if let loadError {
            throw loadError
        }
        return lock.withLock { pairing }
    }

    func save(_ pairing: StoredPairing) throws {
        lock.withLock {
            self.pairing = pairing
            savedPairings.append(pairing)
        }
    }

    func delete() throws {
        lock.withLock {
            pairing = nil
            deleted = true
        }
    }
}

private actor FakeTokenRefresher {
    private var ifNeededResults: [DeviceTokenRefreshResult]
    private var nowResults: [DeviceTokenRefreshResult]

    nonisolated var seam: TunnelDeviceTokenRefreshing {
        TunnelDeviceTokenRefreshing(
            refreshIfNeeded: { pairing, _ in
                await self.nextIfNeeded(defaultingTo: .notNeeded(pairing))
            },
            refreshNow: { pairing in
                await self.nextNow(defaultingTo: .transientFailure(pairing))
            }
        )
    }

    init(ifNeededResults: [DeviceTokenRefreshResult] = [], nowResults: [DeviceTokenRefreshResult] = []) {
        self.ifNeededResults = ifNeededResults
        self.nowResults = nowResults
    }

    private func nextIfNeeded(defaultingTo fallback: DeviceTokenRefreshResult) -> DeviceTokenRefreshResult {
        guard !ifNeededResults.isEmpty else {
            return fallback
        }
        return ifNeededResults.removeFirst()
    }

    private func nextNow(defaultingTo fallback: DeviceTokenRefreshResult) -> DeviceTokenRefreshResult {
        guard !nowResults.isEmpty else {
            return fallback
        }
        return nowResults.removeFirst()
    }
}

@MainActor
private final class FakeTransportFactory: @unchecked Sendable {
    private var transports: [FakeTunnelTransport]

    init(_ transports: [FakeTunnelTransport]) {
        self.transports = transports
    }

    func make() -> any TunnelTransporting {
        guard !transports.isEmpty else {
            preconditionFailure("Missing fake tunnel transport")
        }
        let transport = transports.removeFirst()
        transport.recordConstruction()
        return transport
    }
}

@MainActor
private final class FakeTunnelTransport: TunnelTransporting {
    let stateUpdates: AsyncStream<TunnelState>
    let connectionModeUpdates: AsyncStream<ConnectionMode?>
    private(set) var connectionMode: ConnectionMode?
    var inboundSnapshots: [UInt64] = []

    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let modeContinuation: AsyncStream<ConnectionMode?>.Continuation
    private var results: [Result<TunnelTransportConnection, Error>]
    private let tracker: ActiveSessionTracker?
    private var active = false

    private(set) var connectAttempts = 0
    private(set) var connectInFlight = 0
    private(set) var maxConnectInFlight = 0
    private(set) var disconnectCount = 0
    private(set) var requestReconnectCount = 0
    private(set) var connectedPairings: [StoredPairing] = []

    init(
        connectionMode: ConnectionMode? = .plViaSpl,
        connection: TunnelTransportConnection = .init(localPort: 8080, via: .relay),
        results: [Result<TunnelTransportConnection, Error>]? = nil,
        tracker: ActiveSessionTracker? = nil
    ) {
        self.connectionMode = connectionMode
        self.results = results ?? [.success(connection)]
        self.tracker = tracker
        let states = AsyncStream<TunnelState>.makeStream()
        self.stateUpdates = states.stream
        self.stateContinuation = states.continuation
        let modes = AsyncStream<ConnectionMode?>.makeStream()
        self.connectionModeUpdates = modes.stream
        self.modeContinuation = modes.continuation
        modes.continuation.yield(connectionMode)
    }

    func connect(pairing: StoredPairing, candidates _: [TransportEndpoint]) async throws -> TunnelTransportConnection {
        connectInFlight += 1
        maxConnectInFlight = max(maxConnectInFlight, connectInFlight)
        defer {
            connectInFlight -= 1
        }
        connectAttempts += 1
        connectedPairings.append(pairing)
        let result = results.count > 1 ? results.removeFirst() : results[0]
        switch result {
        case .success(let connection):
            if !active {
                active = true
                tracker?.didConnect()
            }
            modeContinuation.yield(connectionMode)
            stateContinuation.yield(connection.via == .lan
                ? .connected(via: .lanDirect(host: "127.0.0.1", port: connection.localPort))
                : .connected(via: URL(string: "ws://relay.example")!.relayConnectedVia))
            return connection
        case .failure(let error):
            throw error
        }
    }

    func disconnect() async {
        disconnectCount += 1
        if active {
            active = false
            tracker?.didDisconnect()
        }
        stateContinuation.yield(.disconnected)
    }

    func requestReconnect() async {
        requestReconnectCount += 1
    }

    func inboundActivitySnapshot() async -> UInt64 {
        guard !inboundSnapshots.isEmpty else {
            return 0
        }
        return inboundSnapshots.removeFirst()
    }

    func emit(_ state: TunnelState) {
        stateContinuation.yield(state)
    }

    func recordConstruction() {
        tracker?.didConstruct()
    }
}

@MainActor
private final class ActiveSessionTracker: @unchecked Sendable {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var activeAtConstruction: [Int] = []

    func didConstruct() {
        activeAtConstruction.append(active)
    }

    func didConnect() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func didDisconnect() {
        active -= 1
    }
}

private final class FakePathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NetworkPathStatus) -> Void)?

    func start(onPathChange: @Sendable @escaping (NetworkPathStatus) -> Void) {
        lock.withLock {
            handler = onPathChange
        }
    }

    func stop() {
        lock.withLock {
            handler = nil
        }
    }

    func emit(_ status: NetworkPathStatus) {
        let handler: (@Sendable (NetworkPathStatus) -> Void)? = lock.withLock { self.handler }
        handler?(status)
    }
}

private actor ManualSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var permits = 0
    private var durations: [Duration] = []

    var sleepCount: Int {
        durations.count
    }

    var sleepDurations: [Duration] {
        durations
    }

    var establishmentSleepCount: Int {
        durations.filter { durationMilliseconds($0) < 30_000 }.count
    }

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task {
                await self.cancelOldest()
            }
        }
    }

    func advance() {
        guard !continuations.isEmpty else {
            permits += 1
            return
        }
        continuations.removeFirst().resume()
    }

    private func cancelOldest() {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(throwing: CancellationError())
    }
}

private actor ProbeScript {
    private var results: [Bool]
    private(set) var count = 0

    init(results: [Bool]) {
        self.results = results
    }

    func run(port _: Int) -> Bool {
        count += 1
        guard !results.isEmpty else {
            return true
        }
        return results.removeFirst()
    }
}

private extension URL {
    var relayConnectedVia: ConnectedVia {
        .relay(endpoint: self)
    }
}

private func pairing(
    deviceToken: String = "device-token",
    relayEnrollment: RelayEnrollment? = nil,
    localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "127.0.0.1", port: 1234, scope: "local")]
) -> StoredPairing {
    StoredPairing(
        instanceID: "instance-1",
        homeLabel: "test-home",
        relayEndpoint: "ws://relay.example",
        fingerprint: "fingerprint",
        clientCertPEM: "cert",
        clientKeyPEM: "key",
        caChainPEM: "ca",
        relayEnrollment: relayEnrollment ?? .enrolled(deviceToken: deviceToken, expiresAt: nil),
        localEndpoints: localEndpoints,
        pairedAt: Date(timeIntervalSince1970: 0)
    )
}

private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CancellationError()
}

private func expectDuration(_ duration: Duration, inMilliseconds range: ClosedRange<Int>) {
    #expect(range.contains(durationMilliseconds(duration)))
}

private func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
}
