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
    var connectionMode: ConnectionMode? { get }

    func connect(pairing: StoredPairing, candidates: [TransportEndpoint]) async throws -> TunnelTransportConnection
    func disconnect() async
    func requestReconnect() async
    func inboundActivitySnapshot() async -> UInt64
}

protocol TunnelReconnecting: TunnelSessioning, MuxStreamOpening {
    func requestReconnect() async
}

extension TunnelSupervisor: TunnelReconnecting {}

@MainActor
final class SPLTunnelTransport: TunnelTransporting {
    private(set) var stateUpdates: AsyncStream<TunnelState>
    private(set) var connectionModeUpdates: AsyncStream<ConnectionMode?>
    private(set) var connectionMode: ConnectionMode?

    private let clientInfo: SPLClientInfo
    private let policy: SessionPolicy
    private let makeSession: @Sendable (StoredPairing, SPLClientInfo, SessionPolicy) -> any TunnelReconnecting
    private var stateContinuation: AsyncStream<TunnelState>.Continuation
    private var connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation

    private var generation: UInt64 = 0
    private var session: (any TunnelReconnecting)?
    private var proxy: LoopbackProxy?
    private var stateForwardTask: Task<Void, Never>?
    private var connectionModeForwardTask: Task<Void, Never>?

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
        let state = AsyncStream<TunnelState>.makeStream()
        self.stateUpdates = state.stream
        self.stateContinuation = state.continuation
        let mode = AsyncStream<ConnectionMode?>.makeStream()
        self.connectionModeUpdates = mode.stream
        self.connectionModeContinuation = mode.continuation
        state.continuation.yield(.disconnected)
        mode.continuation.yield(nil)
    }

    func connect(pairing: StoredPairing, candidates: [TransportEndpoint]) async throws -> TunnelTransportConnection {
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

        connectionMode = nil
        connectionModeContinuation.yield(nil)
        stateContinuation.yield(.disconnected)
        stateContinuation.finish()
        connectionModeContinuation.finish()
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

        if generation > 0 {
            // Reusing an adapter after disconnect starts new observation streams;
            // failed attempts must not replay buffered auth events into a retry.
            let states = AsyncStream<TunnelState>.makeStream()
            stateUpdates = states.stream
            stateContinuation = states.continuation
            let modes = AsyncStream<ConnectionMode?>.makeStream()
            connectionModeUpdates = modes.stream
            connectionModeContinuation = modes.continuation
        }
        let session = makeSession(pairing, clientInfo, policy)
        self.session = session
        observe(session)
        observeConnectionMode(session)
        return session
    }

    private func observe(_ session: any TunnelSessioning) {
        stateForwardTask?.cancel()
        let continuation = stateContinuation
        let capturedGeneration = generation
        stateForwardTask = Task { @MainActor [weak self] in
            for await state in session.stateUpdates {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                continuation.yield(state)
            }
        }
    }

    private func observeConnectionMode(_ session: any TunnelSessioning) {
        connectionModeForwardTask?.cancel()
        let capturedGeneration = generation
        connectionModeForwardTask = Task { @MainActor [weak self] in
            for await mode in session.connectionModeUpdates {
                guard let self, self.generation == capturedGeneration, !Task.isCancelled else { return }
                self.connectionMode = mode
                self.connectionModeContinuation.yield(mode)
            }
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
