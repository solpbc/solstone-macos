// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "session")

public enum ConnectedVia: Sendable, Equatable {
    case lanDirect(host: String, port: Int)
    case relay(endpoint: URL)
}

public enum ConnectionMode: Sendable, Equatable {
    case plDirect
    case plViaSpl
}

public enum SessionError: Error, Equatable, Sendable {
    case notConnected
    case unreachable
    case directKeepaliveMissed
    case relayKeepaliveMissed
    case invalidRelayURL(String)
    case transportFailed(String)
    case tlsFailed(String)
    case revoked
    case tokenExpired
    case notEntitled
}

public enum TunnelState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int, candidates: [TransportEndpoint])
    case tlsHandshaking(via: ConnectedVia)
    case connected(via: ConnectedVia)
    case failed(SessionError)
}

public protocol TunnelSessioning: Sendable {
    nonisolated var stateUpdates: AsyncStream<TunnelState> { get }
    nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> { get }
    var connectionMode: ConnectionMode? { get async }

    @discardableResult
    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia
    func disconnect() async
    func openStream() async throws -> MuxStream
    func requestReconnect() async
    func inboundActivitySnapshot() async -> UInt64
}

public actor TunnelSession: TunnelSessioning {
    public nonisolated var stateUpdates: AsyncStream<TunnelState> {
        stateStream
    }

    public nonisolated var connectionModeUpdates: AsyncStream<ConnectionMode?> {
        connectionModeStream
    }

    public private(set) var connectionMode: ConnectionMode?

    private let pairing: StoredPairing
    private let stateStream: AsyncStream<TunnelState>
    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let connectionModeStream: AsyncStream<ConnectionMode?>
    private let connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation
    private let makeMultiplexer: @Sendable (InnerTLS) -> Multiplexer
    private let reconnectSignal = ReconnectSignal()
    private var state: TunnelState = .disconnected
    private var reconnectTask: Task<Void, Never>?
    private var inboundPumpTask: Task<Void, Never>?
    private var keepaliveWatchTask: Task<Void, Never>?
    private var innerTLS: InnerTLS?
    private var multiplexer: Multiplexer?
    private var lastTrustedDirectEndpoint: TransportEndpoint?
    private var trustDirectUntil: ContinuousClock.Instant?
    private var relayOnlyNextReconnect = false
    private var reconnectRequestPending = false

    public init(pairing: StoredPairing) {
        self.init(
            pairing: pairing,
            multiplexerFactory: { tls in
                Multiplexer { data in
                    try await tls.send(data)
                }
            }
        )
    }

    init(pairing: StoredPairing, multiplexerFactory: @escaping @Sendable (InnerTLS) -> Multiplexer) {
        self.pairing = pairing
        self.makeMultiplexer = multiplexerFactory
        var continuation: AsyncStream<TunnelState>.Continuation!
        self.stateStream = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        var modeContinuation: AsyncStream<ConnectionMode?>.Continuation!
        self.connectionModeStream = AsyncStream { modeContinuation = $0 }
        self.connectionModeContinuation = modeContinuation
        continuation.yield(.disconnected)
        modeContinuation.yield(nil)
    }

    @discardableResult
    public func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        guard !endpoints.isEmpty else {
            throw SessionError.unreachable
        }
        guard reconnectTask == nil else {
            if case .connected(let via) = state {
                return via
            }
            throw SessionError.transportFailed("connect already in progress")
        }

        let connected = try await connectOnce(attempt: 1, endpoints: endpoints)
        await installConnected(connected)
        reconnectTask = Task { [endpoints] in
            await monitorAndReconnect(endpoints: endpoints)
        }
        return connected.via
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDownCurrent(reason: .normalShutdown)
        setConnectionMode(nil)
        publish(.disconnected)
        stateContinuation.finish()
        connectionModeContinuation.finish()
    }

    public func openStream() async throws -> MuxStream {
        guard case .connected = state, let multiplexer else {
            throw SessionError.notConnected
        }
        do {
            return try await multiplexer.openStream()
        } catch MuxError.transportClosed {
            if case .connected = state {
                await requestReconnect()
            }
            throw SessionError.notConnected
        }
    }

    public func requestReconnect() async {
        guard reconnectTask != nil else {
            return
        }
        guard !reconnectRequestPending else {
            return
        }

        reconnectRequestPending = true
        reconnectSignal.send()
    }

    public func inboundActivitySnapshot() async -> UInt64 {
        guard let multiplexer else {
            return 0
        }
        return await multiplexer.inboundActivitySnapshot()
    }

    private func monitorAndReconnect(endpoints: [TransportEndpoint]) async {
        var attempt = 1
        while !Task.isCancelled {
            let pump = inboundPumpTask
            switch await waitForPumpOrReconnect(pump) {
            case .pumpCompleted, .requested:
                break
            case .cancelled:
                return
            }
            await tearDownCurrent(reason: .transportFailure)

            do {
                beginReconnectCycle()
                let candidates = reconnectCandidates(from: endpoints)
                let connected = try await connectOnce(attempt: attempt, endpoints: candidates)
                attempt = 1
                await installConnected(connected)
            } catch {
                let delay = jitter(backoff(forAttempt: attempt))
                switch await waitForBackoffOrReconnect(delay) {
                case .elapsed:
                    attempt += 1
                case .requested:
                    attempt = 1
                case .cancelled:
                    return
                }
            }
        }
    }

    private func connectOnce(attempt: Int, endpoints: [TransportEndpoint]) async throws -> ConnectedAttempt {
        publish(.connecting(attempt: attempt, candidates: endpoints))

        if let trustedEndpoint = lastTrustedDirectEndpoint,
           let trustedUntil = trustDirectUntil,
           ContinuousClock.now < trustedUntil {
            do {
                let connected = try await connectEndpoint(trustedEndpoint, attempt: attempt)
                publishConnected(connected, endpoint: trustedEndpoint)
                return connected
            } catch {
                trustDirectUntil = nil
                lastTrustedDirectEndpoint = nil
            }
        }

        do {
            let result = try await RaceCoordinator<ConnectedAttempt>(
                dial: { endpoint in try await self.connectEndpoint(endpoint, attempt: attempt) },
                discard: { attempt in await attempt.tls.close() }
            ).connect(endpoints: endpoints)
            publishConnected(result.value, endpoint: result.endpoint)
            return result.value
        } catch let error as SessionError {
            publish(.failed(error))
            throw error
        } catch DialError.relayUnauthorized {
            publish(.failed(.tokenExpired))
            throw SessionError.tokenExpired
        } catch DialError.relayTokenExpired {
            publish(.failed(.tokenExpired))
            throw SessionError.tokenExpired
        } catch {
            let sessionError = SessionError.transportFailed(error.localizedDescription)
            publish(.failed(sessionError))
            throw sessionError
        }
    }

    private func connectEndpoint(_ endpoint: TransportEndpoint, attempt: Int) async throws -> ConnectedAttempt {
        let via = endpoint.connectedVia
        publish(.tlsHandshaking(via: via))
        let startedAt = ContinuousClock.now

        switch endpoint {
        case .lan(let host, let port, _, _):
            let tls = try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectLAN(
                    host: host,
                    port: port,
                    pairing: self.pairing,
                    unpinnedInterface: endpoint.unpinnedInterface
                )
            }
            logger.notice("connected transport=\("lan", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
            return ConnectedAttempt(via: via, tls: tls)

        case .relay:
            let transport = try await DialClient.dial(endpoint, timeout: .seconds(5))
            let tls = try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectViaTransport(transport: transport, pairing: self.pairing)
            }
            logger.notice("connected transport=\("relay", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
            return ConnectedAttempt(via: via, tls: tls)
        }
    }

    private func publishConnected(_ connected: ConnectedAttempt, endpoint: TransportEndpoint) {
        if endpoint.isDirect {
            lastTrustedDirectEndpoint = endpoint
            trustDirectUntil = ContinuousClock.now + .seconds(5)
            setConnectionMode(.plDirect)
        } else {
            lastTrustedDirectEndpoint = nil
            trustDirectUntil = nil
            setConnectionMode(.plViaSpl)
        }
        publish(.connected(via: connected.via))
    }

    private func installConnected(_ connected: ConnectedAttempt) async {
        let tls = connected.tls
        innerTLS = tls
        let mux = makeMultiplexer(tls)
        multiplexer = mux
        let pump = Task {
            do {
                for try await chunk in tls.inbound {
                    try await mux.feedInbound(chunk)
                }
            } catch {
            }
        }
        inboundPumpTask = pump

        await mux.startKeepalive()
        keepaliveWatchTask = Task { [mux] in
            for await _ in mux.keepaliveLost {
                await self.handleKeepaliveLost()
                break
            }
        }
    }

    private func tearDownCurrent(reason: TearDownReason) async {
        keepaliveWatchTask?.cancel()
        keepaliveWatchTask = nil
        inboundPumpTask?.cancel()
        inboundPumpTask = nil
        await innerTLS?.close()
        innerTLS = nil
        await multiplexer?.tearDown(reason: reason)
        multiplexer = nil
        setConnectionMode(nil)
    }

    private func handleKeepaliveLost() async {
        switch connectionMode {
        case .plDirect:
            logger.notice("keepalive lost route=\("direct", privacy: .public)")
            relayOnlyNextReconnect = true
            lastTrustedDirectEndpoint = nil
            trustDirectUntil = nil
            publish(.failed(.directKeepaliveMissed))
            await tearDownCurrent(reason: .transportFailure)
        case .plViaSpl:
            logger.notice("keepalive lost route=\("relay", privacy: .public)")
            publish(.failed(.relayKeepaliveMissed))
            await tearDownCurrent(reason: .transportFailure)
        case nil:
            return
        }
    }

    private func reconnectCandidates(from endpoints: [TransportEndpoint]) -> [TransportEndpoint] {
        guard relayOnlyNextReconnect else {
            return endpoints
        }
        relayOnlyNextReconnect = false
        let relayEndpoints = endpoints.filter { endpoint in
            if case .relay = endpoint {
                return true
            }
            return false
        }
        return relayEndpoints.isEmpty ? endpoints : relayEndpoints
    }

    private func publish(_ newState: TunnelState) {
        if case .failed(let error) = newState {
            logger.notice("session failed error=\(String(describing: error), privacy: .public)")
        }
        state = newState
        stateContinuation.yield(newState)
    }

    private func setConnectionMode(_ newMode: ConnectionMode?) {
        connectionMode = newMode
        connectionModeContinuation.yield(newMode)
    }

    private func beginReconnectCycle() {
        reconnectRequestPending = false
    }

    private func waitForPumpOrReconnect(_ pump: Task<Void, Never>?) async -> ConnectedWaitResult {
        let signal = reconnectSignal
        let race = WaitRace<ConnectedWaitResult>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.setContinuation(continuation)
                let pumpTask = Task.detached {
                    guard !Task.isCancelled else {
                        race.complete(.cancelled)
                        return
                    }
                    await pump?.value
                    race.complete(.pumpCompleted)
                }
                let signalTask = Task.detached {
                    await signal.wait()
                    race.complete(.requested)
                }
                race.setTasks([pumpTask, signalTask])
            }
        } onCancel: {
            race.complete(.cancelled)
        }
    }

    private func waitForBackoffOrReconnect(_ delay: Duration) async -> BackoffWaitResult {
        let signal = reconnectSignal
        let race = WaitRace<BackoffWaitResult>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.setContinuation(continuation)
                let sleepTask = Task.detached {
                    do {
                        try await Task.sleep(for: delay)
                        race.complete(.elapsed)
                    } catch {
                        race.complete(.cancelled)
                    }
                }
                let signalTask = Task.detached {
                    await signal.wait()
                    race.complete(.requested)
                }
                race.setTasks([sleepTask, signalTask])
            }
        } onCancel: {
            race.complete(.cancelled)
        }
    }

    private func backoff(forAttempt attempt: Int) -> Duration {
        [.seconds(1), .seconds(5), .seconds(10), .seconds(30)][min(max(attempt - 1, 0), 3)]
    }

    private func jitter(_ duration: Duration) -> Duration {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return .milliseconds(Int(seconds * 1_000 * Double.random(in: 0.75...1.25)))
    }
}

private final class WaitRace<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var completed = false
    private var pendingResult: Result?

    func setContinuation(_ continuation: CheckedContinuation<Result, Never>) {
        let pending = lock.withLock {
            if completed {
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        let shouldCancel = lock.withLock {
            guard !completed else {
                return true
            }
            self.tasks = tasks
            return false
        }
        if shouldCancel {
            tasks.forEach { $0.cancel() }
        }
    }

    func complete(_ result: Result) {
        let completion = lock.withLock {
            guard !completed else {
                return nil as (CheckedContinuation<Result, Never>, [Task<Void, Never>])?
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            if continuation == nil {
                pendingResult = result
            }
            let tasks = self.tasks
            self.tasks = []
            guard let continuation else {
                return nil
            }
            return (continuation, tasks)
        }

        guard let completion else {
            return
        }
        completion.1.forEach { $0.cancel() }
        completion.0.resume(returning: result)
    }
}

private final class ReconnectSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var signaled = false

    func send() {
        let waiters = lock.withLock {
            let waiters = self.waiters
            self.waiters.removeAll()
            signaled = waiters.isEmpty
            return waiters
        }
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if signaled {
                        signaled = false
                        return true
                    }
                    waiters[id] = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock {
            waiters.removeValue(forKey: id)
        }
        continuation?.resume()
    }
}

private enum ConnectedWaitResult: Sendable {
    case pumpCompleted
    case requested
    case cancelled
}

private enum BackoffWaitResult: Sendable {
    case elapsed
    case requested
    case cancelled
}

private struct ConnectedAttempt: Sendable {
    let via: ConnectedVia
    let tls: InnerTLS
}

private func withSessionTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SessionError.transportFailed("connect timeout")
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
