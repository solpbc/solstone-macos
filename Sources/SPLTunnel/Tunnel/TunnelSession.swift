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
    case invalidRelayURL(String)
    case transportFailed(String)
    case tlsFailed(String)
}

public enum TunnelState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int, candidates: [TransportEndpoint])
    case tlsHandshaking(via: ConnectedVia)
    case connected(via: ConnectedVia)
    case failed(SessionError)
}

public actor TunnelSession {
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
    private var state: TunnelState = .disconnected
    private var reconnectTask: Task<Void, Never>?
    private var inboundPumpTask: Task<Void, Never>?
    private var innerTLS: InnerTLS?
    private var multiplexer: Multiplexer?
    private var lastTrustedDirectEndpoint: TransportEndpoint?
    private var trustDirectUntil: ContinuousClock.Instant?

    public init(pairing: StoredPairing) {
        self.pairing = pairing
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
        installConnected(connected.tls)
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
        return try await multiplexer.openStream()
    }

    private func monitorAndReconnect(endpoints: [TransportEndpoint]) async {
        var attempt = 1
        while !Task.isCancelled {
            let pump = inboundPumpTask
            await pump?.value
            await tearDownCurrent(reason: .transportFailure)

            do {
                let connected = try await connectOnce(attempt: attempt, endpoints: endpoints)
                attempt = 1
                installConnected(connected.tls)
            } catch {
                let delay = jitter(backoff(forAttempt: attempt))
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    break
                }
                attempt += 1
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
            let result = try await RaceCoordinator<ConnectedAttempt> { endpoint in
                try await self.connectEndpoint(endpoint, attempt: attempt)
            }.connect(endpoints: endpoints)
            publishConnected(result.value, endpoint: result.endpoint)
            return result.value
        } catch let error as SessionError {
            publish(.failed(error))
            throw error
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
        case .lan(let host, let port, _):
            let tls = try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectLAN(host: host, port: port, pairing: self.pairing)
            }
            logger.debug("connected transport=\("lan", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
            return ConnectedAttempt(via: via, tls: tls)

        case .relay:
            let transport = try await DialClient.dial(endpoint, timeout: .seconds(5))
            let tls = try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectViaTransport(transport: transport, pairing: self.pairing)
            }
            logger.debug("connected transport=\("relay", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
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

    private func installConnected(_ tls: InnerTLS) {
        innerTLS = tls
        let mux = Multiplexer { data in
            try await tls.send(data)
        }
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
    }

    private func tearDownCurrent(reason: TearDownReason) async {
        inboundPumpTask?.cancel()
        inboundPumpTask = nil
        await innerTLS?.close()
        innerTLS = nil
        await multiplexer?.tearDown(reason: reason)
        multiplexer = nil
        setConnectionMode(nil)
    }

    private func publish(_ newState: TunnelState) {
        state = newState
        stateContinuation.yield(newState)
    }

    private func setConnectionMode(_ newMode: ConnectionMode?) {
        connectionMode = newMode
        connectionModeContinuation.yield(newMode)
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
