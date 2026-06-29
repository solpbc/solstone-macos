// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

final class PairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?
    private let loadError: (any Error)?
    private let saveError: (any Error)?
    private let deleteError: (any Error)?
    private(set) var savedPairings: [StoredPairing] = []
    private(set) var deleted = false
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    var currentPairing: StoredPairing? {
        lock.withLock { pairing }
    }

    init(
        pairing: StoredPairing?,
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil,
        deleteError: (any Error)? = nil
    ) {
        self.pairing = pairing
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
    }

    func load() throws -> StoredPairing? {
        if let loadError {
            throw loadError
        }
        return lock.withLock {
            loadCount += 1
            return pairing
        }
    }

    func save(_ pairing: StoredPairing) throws {
        lock.withLock {
            saveCount += 1
        }
        if let saveError {
            throw saveError
        }
        lock.withLock {
            self.pairing = pairing
            savedPairings.append(pairing)
        }
    }

    func delete() throws {
        lock.withLock {
            self.deleteCount += 1
        }
        if let deleteError {
            throw deleteError
        }
        lock.withLock {
            pairing = nil
            deleted = true
        }
    }
}

actor FakeTokenRefresher {
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
final class FakeTransportFactory: @unchecked Sendable {
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
final class FakeTunnelTransport: TunnelTransporting {
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
final class ActiveSessionTracker: @unchecked Sendable {
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

final class FakePathMonitoringSource: PathMonitoringSource, @unchecked Sendable {
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

actor ManualSleeper {
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

actor ProbeScript {
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

extension URL {
    var relayConnectedVia: ConnectedVia {
        .relay(endpoint: self)
    }
}

func pairing(
    instanceID: String = "instance-1",
    deviceToken: String = "device-token",
    relayEndpoint: String = "ws://relay.example",
    relayEnrollment: RelayEnrollment? = nil,
    localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "127.0.0.1", port: 1234, scope: "local")]
) -> StoredPairing {
    StoredPairing(
        instanceID: instanceID,
        homeLabel: "test-home",
        relayEndpoint: relayEndpoint,
        fingerprint: "fingerprint",
        clientCertPEM: "cert",
        clientKeyPEM: "key",
        caChainPEM: "ca",
        relayEnrollment: relayEnrollment ?? .enrolled(deviceToken: deviceToken, expiresAt: nil),
        localEndpoints: localEndpoints,
        pairedAt: Date(timeIntervalSince1970: 0)
    )
}

func waitUntil(
    timeout: Duration = .seconds(10),
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

func expectDuration(_ duration: Duration, inMilliseconds range: ClosedRange<Int>) {
    #expect(range.contains(durationMilliseconds(duration)))
}

func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
}
