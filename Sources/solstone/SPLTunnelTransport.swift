// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

enum TunnelConnectionRoute: Sendable, Equatable {
    case lan
    case relay
}

struct TunnelTransportConnection: Sendable, Equatable {
    let localPort: Int
    let via: TunnelConnectionRoute
}

@MainActor
protocol TunnelTransporting: AnyObject, Sendable {
    var stateUpdates: AsyncStream<TunnelState> { get }
    var connectionModeUpdates: AsyncStream<ConnectionMode?> { get }
    var attemptStateUpdates: AsyncStream<TunnelSupervisorAttemptState> { get }
    var connectionMode: ConnectionMode? { get }

    func connect(
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        onLocalProxyStart: (@MainActor (Bool) -> Void)?
    ) async throws -> TunnelTransportConnection
    func disconnect() async
    func requestReconnect() async
    func inboundActivitySnapshot() async -> UInt64
}

extension TunnelTransporting {
    func connect(
        pairing: StoredPairing,
        candidates: [TransportEndpoint]
    ) async throws -> TunnelTransportConnection {
        try await connect(pairing: pairing, candidates: candidates, onLocalProxyStart: nil)
    }
}

protocol TunnelReconnecting: TunnelSessioning, MuxStreamOpening {
    func requestReconnect() async
    func attemptStateUpdates() async -> AsyncStream<TunnelSupervisorAttemptState>
}

extension TunnelSupervisor: TunnelReconnecting {}

@MainActor
final class SPLTunnelTransport: TunnelTransporting {
    private var stateContinuations: [UUID: AsyncStream<TunnelState>.Continuation] = [:]
    private var connectionModeContinuations: [UUID: AsyncStream<ConnectionMode?>.Continuation] = [:]
    private var attemptContinuations: [UUID: AsyncStream<TunnelSupervisorAttemptState>.Continuation] = [:]
    private var lastState: TunnelState = .disconnected
    private var lastAttemptState: TunnelSupervisorAttemptState = .idle
    private(set) var connectionMode: ConnectionMode?

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
            self.connectionModeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.connectionModeContinuations.removeValue(forKey: id)
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

    private let clientInfo: SPLClientInfo
    private let policy: SessionPolicy
    private let makeSession: @Sendable (StoredPairing, SPLClientInfo, SessionPolicy) -> any TunnelReconnecting

    private var generation: UInt64 = 0
    private var session: (any TunnelReconnecting)?
    private var proxy: LoopbackProxy?
    private var stateForwardTask: Task<Void, Never>?
    private var connectionModeForwardTask: Task<Void, Never>?
    private var attemptStateForwardTask: Task<Void, Never>?

    init(
        clientInfo: SPLClientInfo = SPLRuntime.clientInfo,
        policy: SessionPolicy = SessionPolicy(keepalive: KeepalivePolicy(runsOnRelayPath: true)),
        makeSession: @escaping @Sendable (StoredPairing, SPLClientInfo, SessionPolicy) -> any TunnelReconnecting = {
            TunnelSupervisor(pairing: $0, clientInfo: $1, policy: $2)
        }
    ) {
        self.clientInfo = clientInfo
        self.policy = policy
        self.makeSession = makeSession
    }

    func connect(
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        onLocalProxyStart: (@MainActor (Bool) -> Void)? = nil
    ) async throws -> TunnelTransportConnection {
        let capturedGeneration = generation
        let session = activeSession(for: pairing)
        _ = try await session.connect(endpoints: candidates)
        guard generation == capturedGeneration, !Task.isCancelled else {
            await session.disconnect()
            throw CancellationError()
        }
        let mode = await session.connectionMode
        guard generation == capturedGeneration, !Task.isCancelled else {
            await session.disconnect()
            throw CancellationError()
        }
        connectionMode = mode
        let proxy = LoopbackProxy(opener: session)
        self.proxy = proxy
        onLocalProxyStart?(true)
        defer { onLocalProxyStart?(false) }
        do {
            let port = try await proxy.start()
            guard generation == capturedGeneration, !Task.isCancelled else {
                await proxy.stop()
                await session.disconnect()
                throw CancellationError()
            }
            return TunnelTransportConnection(
                localPort: Int(port),
                via: Self.route(for: connectionMode)
            )
        } catch {
            await proxy.stop()
            if self.proxy === proxy {
                self.proxy = nil
            }
            throw error
        }
    }

    func disconnect() async {
        generation &+= 1
        let oldProxy = proxy
        let oldSession = session
        proxy = nil
        session = nil
        stateForwardTask?.cancel()
        stateForwardTask = nil
        connectionModeForwardTask?.cancel()
        connectionModeForwardTask = nil
        attemptStateForwardTask?.cancel()
        attemptStateForwardTask = nil

        connectionMode = nil
        lastState = .disconnected
        lastAttemptState = .idle
        stateContinuations.values.forEach { $0.finish() }
        stateContinuations.removeAll()
        connectionModeContinuations.values.forEach { $0.finish() }
        connectionModeContinuations.removeAll()
        attemptContinuations.values.forEach { $0.finish() }
        attemptContinuations.removeAll()

        // Retire reconnect eligibility before waiting for local proxy drainage.
        await oldSession?.disconnect()
        await oldProxy?.stop()
    }

    func requestReconnect() async {
        await session?.requestReconnect()
    }

    func inboundActivitySnapshot() async -> UInt64 {
        guard let session else {
            return 0
        }
        return await session.inboundActivitySnapshot()
    }

    private func activeSession(for pairing: StoredPairing) -> any TunnelReconnecting {
        if let session {
            return session
        }

        let session = makeSession(pairing, clientInfo, policy)
        self.session = session
        observe(session)
        observeConnectionMode(session)
        observeAttemptState(session)
        return session
    }

    private func observe(_ session: any TunnelSessioning) {
        stateForwardTask?.cancel()
        let capturedGeneration = generation
        stateForwardTask = Task { @MainActor [weak self] in
            for await state in session.stateUpdates {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                self.lastState = state
                self.stateContinuations.values.forEach { $0.yield(state) }
            }
            guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
            self.stateContinuations.values.forEach { $0.finish() }
            self.stateContinuations.removeAll()
        }
    }

    private func observeConnectionMode(_ session: any TunnelSessioning) {
        connectionModeForwardTask?.cancel()
        let capturedGeneration = generation
        connectionModeForwardTask = Task { @MainActor [weak self] in
            for await mode in session.connectionModeUpdates {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                self.connectionMode = mode
                self.connectionModeContinuations.values.forEach { $0.yield(mode) }
            }
            guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
            self.connectionModeContinuations.values.forEach { $0.finish() }
            self.connectionModeContinuations.removeAll()
        }
    }

    private func observeAttemptState(_ session: any TunnelReconnecting) {
        attemptStateForwardTask?.cancel()
        let capturedGeneration = generation
        attemptStateForwardTask = Task { @MainActor [weak self] in
            let stream = await session.attemptStateUpdates()
            for await attemptState in stream {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                self.lastAttemptState = attemptState
                self.attemptContinuations.values.forEach { $0.yield(attemptState) }
            }
            guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
            self.attemptContinuations.values.forEach { $0.finish() }
            self.attemptContinuations.removeAll()
        }
    }

    private static func route(for mode: ConnectionMode?) -> TunnelConnectionRoute {
        switch mode {
        case .plDirect:
            return .lan
        case .plViaSpl, nil:
            return .relay
        }
    }
}
