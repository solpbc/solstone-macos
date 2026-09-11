// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import Testing
@testable import solstone

final class PairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?
    private var loadOutcomes: [Result<StoredPairing?, any Error>]
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
        loadOutcomes: [Result<StoredPairing?, any Error>] = [],
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil,
        deleteError: (any Error)? = nil
    ) {
        self.pairing = pairing
        self.loadOutcomes = loadOutcomes
        self.loadError = loadError
        self.saveError = saveError
        self.deleteError = deleteError
    }

    func load() throws -> StoredPairing? {
        lock.lock()
        defer { lock.unlock() }
        loadCount += 1
        if !loadOutcomes.isEmpty {
            switch loadOutcomes.removeFirst() {
            case .success(let value):
                pairing = value
                return value
            case .failure(let error):
                throw error
            }
        }
        if let loadError {
            throw loadError
        }
        return pairing
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

extension PairingStore: PairingStoring {}

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

actor ControlledTokenRefresher {
    private var nowContinuations: [CheckedContinuation<DeviceTokenRefreshResult, Never>] = []
    private(set) var nowCount = 0

    nonisolated var seam: TunnelDeviceTokenRefreshing {
        TunnelDeviceTokenRefreshing(
            refreshIfNeeded: { pairing, _ in
                .notNeeded(pairing)
            },
            refreshNow: { pairing in
                await self.refreshNow(pairing: pairing)
            }
        )
    }

    var pendingNowCount: Int {
        nowContinuations.count
    }

    func completeNext(with result: DeviceTokenRefreshResult) {
        guard !nowContinuations.isEmpty else {
            return
        }
        nowContinuations.removeFirst().resume(returning: result)
    }

    private func refreshNow(pairing _: StoredPairing) async -> DeviceTokenRefreshResult {
        nowCount += 1
        return await withCheckedContinuation { continuation in
            nowContinuations.append(continuation)
        }
    }
}

@MainActor
final class FakeTransportFactory: @unchecked Sendable {
    private var transports: [any TunnelTransporting]

    private(set) var makeCount = 0

    init(_ transports: [any TunnelTransporting]) {
        self.transports = transports
    }

    func make() -> any TunnelTransporting {
        guard !transports.isEmpty else {
            preconditionFailure("Missing fake tunnel transport")
        }
        makeCount += 1
        let transport = transports.removeFirst()
        (transport as? FakeTunnelTransport)?.recordConstruction()
        return transport
    }

    func enqueue(_ newTransports: [any TunnelTransporting]) {
        transports.append(contentsOf: newTransports)
    }
}

actor FakeTunnelReconnectingSession: TunnelReconnecting {
    private final class StateBox: @unchecked Sendable {
        var stateContinuations: [UUID: AsyncStream<TunnelState>.Continuation] = [:]
        var modeContinuations: [UUID: AsyncStream<ConnectionMode?>.Continuation] = [:]
        var attemptContinuations: [UUID: AsyncStream<TunnelSupervisorAttemptState>.Continuation] = [:]
        var lastState: TunnelState = .disconnected
        var lastAttemptState: TunnelSupervisorAttemptState = .idle
    }

    private let lock = NSLock()
    private let box = StateBox()

    nonisolated var stateUpdates: AsyncStream<TunnelState> {
        AsyncStream { continuation in
            let id = UUID()
            let state: TunnelState = self.lock.withLock {
                self.box.stateContinuations[id] = continuation
                return self.box.lastState
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.box.stateContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(state)
        }
    }

    nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> {
        AsyncStream { continuation in
            let id = UUID()
            let mode = self.lock.withLock {
                self.box.modeContinuations[id] = continuation
                return self.connectionModeValue
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.box.modeContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(mode)
        }
    }

    private let connectionModeValue: ConnectionMode?
    private let connectedVia: ConnectedVia
    nonisolated let pairing: StoredPairing?
    let clientInfo: SPLClientInfo?
    let policy: SessionPolicy?
    private var connectContinuations: [CheckedContinuation<Void, Never>]?
    var shouldThrowOnConnect: Error?

    private(set) var requestReconnectCount = 0
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var recordedEndpoints: [[TransportEndpoint]] = []
    private(set) var isDisconnected = false

    init(
        connectionMode: ConnectionMode? = .plViaSpl,
        connectedVia: ConnectedVia = URL(string: "https://relay.example")!.relayConnectedVia,
        pairing: StoredPairing? = nil,
        clientInfo: SPLClientInfo? = nil,
        policy: SessionPolicy? = nil,
        shouldThrowOnConnect: Error? = nil,
        armConnectGate: Bool = false
    ) {
        self.connectionModeValue = connectionMode
        self.connectedVia = connectedVia
        self.pairing = pairing
        self.clientInfo = clientInfo
        self.policy = policy
        self.shouldThrowOnConnect = shouldThrowOnConnect
        if armConnectGate {
            self.connectContinuations = []
        }
    }

    var connectionMode: ConnectionMode? {
        connectionModeValue
    }

    var pendingConnectCount: Int { connectContinuations?.count ?? 0 }
    func armConnectGate() { connectContinuations = [] }
    func releaseNextConnect() {
        if connectContinuations?.isEmpty == false { connectContinuations!.removeFirst().resume() }
    }
    func releasePendingConnect() {
        if let conts = connectContinuations {
            connectContinuations = []
            conts.forEach { $0.resume() }
        }
    }

    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        connectCallCount += 1
        recordedEndpoints.append(endpoints)
        if connectContinuations != nil {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connectContinuations?.append(continuation)
                }
            } onCancel: {
                Task {
                    await self.releasePendingConnect()
                }
            }
            try Task.checkCancellation()
        }
        if let shouldThrowOnConnect {
            throw shouldThrowOnConnect
        }
        isDisconnected = false
        emitState(.connected(via: connectedVia))
        emitAttemptState(.connected)
        return connectedVia
    }

    func disconnect() async {
        disconnectCallCount += 1
        isDisconnected = true
        if let conts = connectContinuations {
            connectContinuations = []
            conts.forEach { $0.resume() }
        }
        emitState(.disconnected)
        emitAttemptState(.idle)
    }

    nonisolated func emitState(_ state: TunnelState) {
        let continuations = lock.withLock { () -> [AsyncStream<TunnelState>.Continuation] in
            box.lastState = state
            return Array(box.stateContinuations.values)
        }
        continuations.forEach { $0.yield(state) }
    }

    nonisolated func emitAttemptState(_ state: TunnelSupervisorAttemptState) {
        let continuations = lock.withLock { () -> [AsyncStream<TunnelSupervisorAttemptState>.Continuation] in
            box.lastAttemptState = state
            return Array(box.attemptContinuations.values)
        }
        continuations.forEach { $0.yield(state) }
    }

    nonisolated func finishStateUpdates() {
        let continuations = lock.withLock { () -> [AsyncStream<TunnelState>.Continuation] in
            let arr = Array(box.stateContinuations.values)
            box.stateContinuations.removeAll()
            return arr
        }
        continuations.forEach { $0.finish() }
    }

    nonisolated func finishAttemptUpdates() {
        let continuations = lock.withLock { () -> [AsyncStream<TunnelSupervisorAttemptState>.Continuation] in
            let arr = Array(box.attemptContinuations.values)
            box.attemptContinuations.removeAll()
            return arr
        }
        continuations.forEach { $0.finish() }
    }

    nonisolated func attemptStateUpdates() async -> AsyncStream<TunnelSupervisorAttemptState> {
        AsyncStream { continuation in
            let id = UUID()
            let attempt: TunnelSupervisorAttemptState = self.lock.withLock {
                self.box.attemptContinuations[id] = continuation
                return self.box.lastAttemptState
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock {
                    _ = self?.box.attemptContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(attempt)
        }
    }

    func openStream() async throws -> MuxStream {
        throw SessionError.notConnected
    }

    func inboundActivitySnapshot() async -> UInt64 {
        0
    }

    func requestReconnect() async {
        requestReconnectCount += 1
        if let lastEndpoints = recordedEndpoints.last {
            _ = try? await connect(endpoints: lastEndpoints)
        }
    }
}

final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [FakeTunnelReconnectingSession] = []

    init() {}

    func append(_ session: FakeTunnelReconnectingSession) {
        lock.lock()
        defer { lock.unlock() }
        _sessions.append(session)
    }

    var sessions: [FakeTunnelReconnectingSession] {
        lock.lock()
        defer { lock.unlock() }
        return _sessions
    }

    subscript(index: Int) -> FakeTunnelReconnectingSession {
        lock.lock()
        defer { lock.unlock() }
        return _sessions[index]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _sessions.count
    }
}

@MainActor
final class FakeTunnelTransport: TunnelTransporting {
    private var stateContinuations: [UUID: AsyncStream<TunnelState>.Continuation] = [:]
    private var modeContinuations: [UUID: AsyncStream<ConnectionMode?>.Continuation] = [:]
    private var attemptContinuations: [UUID: AsyncStream<TunnelSupervisorAttemptState>.Continuation] = [:]
    private var lastState: TunnelState = .disconnected
    private var lastAttemptState: TunnelSupervisorAttemptState = .idle
    private(set) var connectionMode: ConnectionMode?
    var inboundSnapshots: [UInt64] = []

    var stateUpdates: AsyncStream<TunnelState> {
        AsyncStream { continuation in
            let id = UUID()
            self.stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stateContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(self.lastState)
        }
    }

    var connectionModeUpdates: AsyncStream<ConnectionMode?> {
        AsyncStream { continuation in
            let id = UUID()
            self.modeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.modeContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(self.connectionMode)
        }
    }

    var attemptStateUpdates: AsyncStream<TunnelSupervisorAttemptState> {
        AsyncStream { continuation in
            let id = UUID()
            self.attemptContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attemptContinuations.removeValue(forKey: id)
                }
            }
            continuation.yield(self.lastAttemptState)
        }
    }

    private var results: [Result<TunnelTransportConnection, Error>]
    private let tracker: ActiveSessionTracker?
    private var active = false
    private var connectContinuations: [CheckedContinuation<Void, Never>]?
    private var disconnectContinuations: [CheckedContinuation<Void, Never>]?

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
    }

    func emitAttemptState(_ state: TunnelSupervisorAttemptState) {
        lastAttemptState = state
        attemptContinuations.values.forEach { $0.yield(state) }
    }

    var pendingConnectCount: Int {
        connectContinuations?.count ?? 0
    }

    var pendingDisconnectCount: Int {
        disconnectContinuations?.count ?? 0
    }

    func armConnectGate() {
        connectContinuations = []
    }

    func armDisconnectGate() {
        disconnectContinuations = []
    }

    func releaseNextConnect() {
        if connectContinuations?.isEmpty == false {
            connectContinuations!.removeFirst().resume()
        }
    }

    func releaseNextDisconnect() {
        if disconnectContinuations?.isEmpty == false {
            disconnectContinuations!.removeFirst().resume()
        }
    }

    func releasePendingConnect() {
        if let conts = connectContinuations {
            connectContinuations = []
            conts.forEach { $0.resume() }
        }
    }

    var onConnectHook: (@MainActor () -> Void)?
    var onProxyStartingHook: (@MainActor () -> Void)?

    func finishStateUpdates() {
        stateContinuations.values.forEach { $0.finish() }
        stateContinuations.removeAll()
    }

    func finishAttemptUpdates() {
        attemptContinuations.values.forEach { $0.finish() }
        attemptContinuations.removeAll()
    }

    func connect(
        pairing: StoredPairing,
        candidates _: [TransportEndpoint],
        onLocalProxyStart: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> TunnelTransportConnection {
        connectInFlight += 1
        maxConnectInFlight = max(maxConnectInFlight, connectInFlight)
        defer {
            connectInFlight -= 1
        }
        connectAttempts += 1
        connectedPairings.append(pairing)
        onConnectHook?()
        onLocalProxyStart?(true)
        onProxyStartingHook?()
        defer { onLocalProxyStart?(false) }
        let result = results.count > 1 ? results.removeFirst() : results[0]
        if connectContinuations != nil {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connectContinuations?.append(continuation)
                }
            } onCancel: {
                Task { @MainActor in
                    self.releasePendingConnect()
                }
            }
            try Task.checkCancellation()
        }
        switch result {
        case .success(let connection):
            if !active {
                active = true
                tracker?.didConnect()
            }
            modeContinuations.values.forEach { $0.yield(self.connectionMode) }
            let s: TunnelState = connection.via == .lan
                ? .connected(via: .lanDirect(host: "127.0.0.1", port: connection.localPort))
                : .connected(via: URL(string: "ws://relay.example")!.relayConnectedVia)
            lastState = s
            stateContinuations.values.forEach { $0.yield(s) }
            return connection
        case .failure(let error):
            throw error
        }
    }

    func disconnect() async {
        disconnectCount += 1
        if disconnectContinuations != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                disconnectContinuations?.append(continuation)
            }
        }
        if active {
            active = false
            tracker?.didDisconnect()
        }
        lastState = .disconnected
        lastAttemptState = .idle
        stateContinuations.values.forEach { $0.finish() }
        stateContinuations.removeAll()
        modeContinuations.values.forEach { $0.finish() }
        modeContinuations.removeAll()
        attemptContinuations.values.forEach { $0.finish() }
        attemptContinuations.removeAll()
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
        lastState = state
        stateContinuations.values.forEach { $0.yield(state) }
    }

    func emitMode(_ mode: ConnectionMode?) {
        connectionMode = mode
        modeContinuations.values.forEach { $0.yield(mode) }
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
    private struct ParkedSleep {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var continuations: [ParkedSleep] = []
    private var cancelledIDs: Set<UUID> = []
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
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuations.append(ParkedSleep(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancel(id)
            }
        }
    }

    func advance() {
        guard !continuations.isEmpty else {
            permits += 1
            return
        }
        // Resume the newest parked sleep. In this harness at most one sleep is
        // ever live at a time; when a waiter is re-armed (for example, a probe
        // cancelled then restarted) the prior sleep is cancelled and removed
        // asynchronously via `cancel(_:)`. Tests park the intended new waiter
        // before advancing, so newest is deterministic even if that cancelled
        // sleep's async removal has not landed yet.
        continuations.removeLast().continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = continuations.firstIndex(where: { $0.id == id }) else {
            cancelledIDs.insert(id)
            return
        }
        continuations.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

actor ProbeScript {
    private var results: [Bool]
    private(set) var count = 0
    private(set) var ports: [Int] = []

    init(results: [Bool]) {
        self.results = results
    }

    func run(port: Int) -> Bool {
        count += 1
        ports.append(port)
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

let testCACertPEM = """
-----BEGIN CERTIFICATE-----
MIIBdTCCARugAwIBAgIUVMEtHY4txnB9yvPieVZOPQb8B/swCgYIKoZIzj0EAwIw
EDEOMAwGA1UEAwwFdGVzdDEwHhcNMjYwNTExMDU0OTI4WhcNMzYwNTA4MDU0OTI4
WjAQMQ4wDAYDVQQDDAV0ZXN0MTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPih
dGj0TbzBAXX6uLTt/rKpwd7t8DohOFLZ44i9KlffKSrMHvo2DufP/oUVB+V/jJy9
0PQuCc+/j2NrTtHOh3yjUzBRMB0GA1UdDgQWBBQrAyo4k6cTcZB56UCx7ZcJPWxH
ezAfBgNVHSMEGDAWgBQrAyo4k6cTcZB56UCx7ZcJPWxHezAPBgNVHRMBAf8EBTAD
AQH/MAoGCCqGSM49BAMCA0gAMEUCIA0cayl/grfqS8xzPnv3+A6Wqb7NL8QvfgPu
ZBXoDWAEAiEAgCfoRUL0QMRHSW4FKBCyqn63nZBYfgcl2q4I+kYz0y4=
-----END CERTIFICATE-----
"""

func pairing(
    instanceID: String = "instance-1",
    deviceToken: String = "device-token",
    relayEndpoint: String = "ws://relay.example",
    relayEnrollment: RelayEnrollment? = nil,
    localEndpoints: [LocalEndpoint] = [LocalEndpoint(host: "127.0.0.1", port: 1234, scope: "local")],
    caChainPEM: String = testCACertPEM
) -> StoredPairing {
    StoredPairing(
        instanceID: instanceID,
        homeLabel: "test-home",
        relayEndpoint: relayEndpoint,
        fingerprint: "fingerprint",
        clientCertPEM: "cert",
        clientKeyPEM: "key",
        caChainPEM: caChainPEM,
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

@MainActor
func currentPathSignature(of owner: TunnelLifecycleOwner) -> NetworkPathSignature? {
    for child in Mirror(reflecting: owner).children where child.label == "currentPathSignature" {
        if let signature = child.value as? NetworkPathSignature {
            return signature
        }
        let optional = Mirror(reflecting: child.value)
        return optional.children.first?.value as? NetworkPathSignature
    }
    Issue.record("TunnelLifecycleOwner.currentPathSignature missing - product rename broke the test seam")
    return nil
}

func expectDuration(_ duration: Duration, inMilliseconds range: ClosedRange<Int>) {
    #expect(range.contains(durationMilliseconds(duration)))
}

func durationMilliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
}


extension FakeTunnelReconnectingSession: TunnelGeneration {
    func connect(endpoints: [TransportEndpoint], preferredEndpoint: TransportEndpoint?) async throws -> ConnectedVia {
        emitState(.connecting(candidates: endpoints.map(\.connectedVia)))
        return try await connect(endpoints: endpoints)
    }

    func connectedEndpoint() async -> TransportEndpoint? {
        recordedEndpoints.last?.first
    }
}

final class ActualSupervisorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var supervisors: [TunnelSupervisor] = []
    let children = SessionRecorder()
    private let armGate: Bool
    private var sessionErrors: [Error?]
    private let useActualSupervisor: Bool

    init(armGate: Bool = false, sessionErrors: [Error?] = [], useActualSupervisor: Bool = false) {
        self.armGate = armGate
        self.sessionErrors = sessionErrors
        self.useActualSupervisor = useActualSupervisor
    }

    var count: Int { lock.withLock { useActualSupervisor ? supervisors.count : children.count } }
    subscript(index: Int) -> TunnelSupervisor { lock.withLock { supervisors[index] } }

    func make(pairing: StoredPairing, info: SPLClientInfo, policy: SessionPolicy) -> any TunnelReconnecting {
        let arm = armGate
        if useActualSupervisor {
            let supervisor = TunnelSupervisor(
                pairing: pairing,
                clientInfo: info,
                policy: policy,
                makeSession: { [children, weak self] p, i, pol in
                    let err: Error? = self?.lock.withLock {
                        (self?.sessionErrors.isEmpty == false) ? self?.sessionErrors.removeFirst() : nil
                    }
                    let child = FakeTunnelReconnectingSession(pairing: p, clientInfo: i, policy: pol, shouldThrowOnConnect: err, armConnectGate: arm)
                    children.append(child)
                    return child
                }
            )
            lock.withLock { supervisors.append(supervisor) }
            return supervisor
        }
        let err: Error? = lock.withLock {
            sessionErrors.isEmpty ? nil : sessionErrors.removeFirst()
        }
        let child = FakeTunnelReconnectingSession(pairing: pairing, clientInfo: info, policy: policy, shouldThrowOnConnect: err, armConnectGate: arm)
        children.append(child)
        return child
    }
}

actor AccessRefreshBarrier {
    private var continuation: CheckedContinuation<DeviceTokenRefreshResult, Never>?
    private(set) var entered = false
    private(set) var completed = false
    func wait() async -> DeviceTokenRefreshResult {
        entered = true
        let result = await withCheckedContinuation { continuation = $0 }
        completed = true
        return result
    }
    func release(_ result: DeviceTokenRefreshResult) { continuation?.resume(returning: result); continuation = nil }
}


final class AccessHTTPReplyBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var arrived = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return arrived }
    func wait() {
        condition.lock()
        arrived = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
