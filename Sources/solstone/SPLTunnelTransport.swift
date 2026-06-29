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

@MainActor
final class SPLTunnelTransport: TunnelTransporting {
    let stateUpdates: AsyncStream<TunnelState>
    let connectionModeUpdates: AsyncStream<ConnectionMode?>
    private(set) var connectionMode: ConnectionMode?

    private let makeSession: @Sendable (StoredPairing) -> any TunnelSessioning
    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private let connectionModeContinuation: AsyncStream<ConnectionMode?>.Continuation

    private var session: (any TunnelSessioning)?
    private var proxy: LoopbackProxy?
    private var stateForwardTask: Task<Void, Never>?
    private var connectionModeForwardTask: Task<Void, Never>?

    init(makeSession: @escaping @Sendable (StoredPairing) -> any TunnelSessioning = { TunnelSession(pairing: $0) }) {
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
        let session = activeSession(for: pairing)
        _ = try await session.connect(endpoints: candidates)
        connectionMode = await session.connectionMode

        let proxy = LoopbackProxy(tunnel: session)
        self.proxy = proxy
        do {
            let port = try await proxy.start()
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
        stateForwardTask?.cancel()
        stateForwardTask = nil
        connectionModeForwardTask?.cancel()
        connectionModeForwardTask = nil

        await proxy?.stop()
        proxy = nil
        await session?.disconnect()
        session = nil

        connectionMode = nil
        connectionModeContinuation.yield(nil)
        stateContinuation.yield(.disconnected)
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

    private func activeSession(for pairing: StoredPairing) -> any TunnelSessioning {
        if let session {
            return session
        }

        let session = makeSession(pairing)
        self.session = session
        observe(session)
        observeConnectionMode(session)
        return session
    }

    private func observe(_ session: any TunnelSessioning) {
        stateForwardTask?.cancel()
        let continuation = stateContinuation
        stateForwardTask = Task {
            for await state in session.stateUpdates {
                continuation.yield(state)
            }
        }
    }

    private func observeConnectionMode(_ session: any TunnelSessioning) {
        connectionModeForwardTask?.cancel()
        connectionModeForwardTask = Task { @MainActor [weak self] in
            for await mode in session.connectionModeUpdates {
                self?.connectionMode = mode
                self?.connectionModeContinuation.yield(mode)
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
