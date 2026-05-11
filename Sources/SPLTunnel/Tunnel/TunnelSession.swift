// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let logger = Logger(subsystem: "app.solstone.observer.spl", category: "session")

public enum TransportCandidate: Sendable, Equatable {
    case lan(host: String, port: Int)
    case relay
}

public enum ConnectedVia: Sendable, Equatable {
    case lanDirect(host: String, port: Int)
    case relay(endpoint: URL)
}

public enum SessionError: Error, Equatable, Sendable {
    case notConnected
    case invalidRelayURL(String)
    case transportFailed(String)
    case tlsFailed(String)
}

public enum TunnelState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int, candidate: TransportCandidate)
    case tlsHandshaking(via: ConnectedVia)
    case connected(via: ConnectedVia)
    case failed(SessionError)
}

public actor TunnelSession {
    public nonisolated var stateUpdates: AsyncStream<TunnelState> {
        stateStream
    }

    private let pairing: StoredPairing
    private let stateStream: AsyncStream<TunnelState>
    private let stateContinuation: AsyncStream<TunnelState>.Continuation
    private var state: TunnelState = .disconnected
    private var reconnectTask: Task<Void, Never>?
    private var inboundPumpTask: Task<Void, Never>?
    private var innerTLS: InnerTLS?
    private var multiplexer: Multiplexer?

    public init(pairing: StoredPairing) {
        self.pairing = pairing
        var continuation: AsyncStream<TunnelState>.Continuation!
        self.stateStream = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
        continuation.yield(.disconnected)
    }

    public func connect() {
        guard reconnectTask == nil else {
            return
        }
        reconnectTask = Task {
            await runReconnectLoop()
        }
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await tearDownCurrent(reason: .normalShutdown)
        publish(.disconnected)
        stateContinuation.finish()
    }

    public func openStream() async throws -> MuxStream {
        guard case .connected = state, let multiplexer else {
            throw SessionError.notConnected
        }
        return try await multiplexer.openStream()
    }

    private func runReconnectLoop() async {
        var attempt = 1
        while !Task.isCancelled {
            if let connected = await connectOnce(attempt: attempt) {
                attempt = 1
                await runConnected(connected)
            } else {
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

    private func connectOnce(attempt: Int) async -> InnerTLS? {
        let pairing = self.pairing
        for endpoint in pairing.localEndpoints {
            let via = ConnectedVia.lanDirect(host: endpoint.host, port: endpoint.port)
            publish(.connecting(attempt: attempt, candidate: .lan(host: endpoint.host, port: endpoint.port)))
            publish(.tlsHandshaking(via: via))
            let startedAt = ContinuousClock.now
            do {
                let tls = try await withSessionTimeout(.seconds(5)) {
                    try await InnerTLS.connectLAN(host: endpoint.host, port: endpoint.port, pairing: pairing)
                }
                logger.debug("connected transport=\("lan", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
                publish(.connected(via: via))
                return tls
            } catch {
                publish(.failed(.tlsFailed(error.localizedDescription)))
            }
        }

        guard let endpoint = URL(string: pairing.relayEndpoint) else {
            publish(.failed(.invalidRelayURL(pairing.relayEndpoint)))
            return nil
        }

        publish(.connecting(attempt: attempt, candidate: .relay))
        let startedAt = ContinuousClock.now
        do {
            let transport = try await DialClient.dial(.relay(
                endpoint: endpoint,
                instanceID: pairing.instanceID,
                deviceToken: pairing.deviceToken
            ), timeout: .seconds(5))
            let via = ConnectedVia.relay(endpoint: endpoint)
            publish(.tlsHandshaking(via: via))
            let tls = try await withSessionTimeout(.seconds(5)) {
                try await InnerTLS.connectViaTransport(transport: transport, pairing: pairing)
            }
            logger.debug("connected transport=\("relay", privacy: .public) attempt=\(attempt, privacy: .public) duration_ms=\(startedAt.duration(to: .now).milliseconds, privacy: .public)")
            publish(.connected(via: via))
            return tls
        } catch let error as DialError {
            publish(.failed(.transportFailed(String(describing: error))))
        } catch {
            publish(.failed(.tlsFailed(error.localizedDescription)))
        }
        return nil
    }

    private func runConnected(_ tls: InnerTLS) async {
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
        await pump.value
        await tearDownCurrent(reason: .transportFailure)
    }

    private func tearDownCurrent(reason: TearDownReason) async {
        inboundPumpTask?.cancel()
        inboundPumpTask = nil
        await innerTLS?.close()
        innerTLS = nil
        await multiplexer?.tearDown(reason: reason)
        multiplexer = nil
    }

    private func publish(_ newState: TunnelState) {
        state = newState
        stateContinuation.yield(newState)
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
