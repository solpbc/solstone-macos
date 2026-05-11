// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

@Suite("TunnelSession", .serialized)
struct TunnelSessionTests {
    @Test func lanDirectHappyPathStateSequenceAndOpenStreamPayload() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture, mode: .mux)
        try await server.start()
        let port = await server.port
        let pairing = pairing(from: fixture, localPort: port)
        let session = TunnelSession(pairing: pairing)
        let recorder = StateRecorder()
        let observation = observe(session: session, recorder: recorder)

        try await session.connect(endpoints: TransportEndpoint.candidates(for: pairing))
        try await waitUntil {
            await recorder.states.contains { state in
                state == .connected(via: .lanDirect(host: "127.0.0.1", port: port))
            }
        }
        let stream = try await session.openStream()
        let payload = Data([0x10, 0x20, 0x30])
        try await stream.write(payload)
        let echoed = try await firstInbound(from: await stream.inbound)

        await session.disconnect()
        observation.cancel()
        await server.stop()

        let states = await recorder.states
        let candidates = try TransportEndpoint.candidates(for: pairing)
        #expect(Array(states.prefix(3)) == [
            .disconnected,
            .connecting(attempt: 1, candidates: candidates),
            .tlsHandshaking(via: .lanDirect(host: "127.0.0.1", port: port)),
        ])
        #expect(states.contains(.connected(via: .lanDirect(host: "127.0.0.1", port: port))))
        #expect(echoed == payload)
    }

    @Test func reconnectSurvivesThreeServerKillRestartCycles() async throws {
        let fixedPort = Int.random(in: 20_000...60_000)
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture, port: fixedPort)
        try await server.start()
        let pairing = pairing(from: fixture, localPort: fixedPort)
        let session = TunnelSession(pairing: pairing)
        let recorder = StateRecorder()
        let observation = observe(session: session, recorder: recorder)

        try await session.connect(endpoints: TransportEndpoint.candidates(for: pairing))
        try await waitForConnected(recorder, via: .lanDirect(host: "127.0.0.1", port: fixedPort), minimumCount: 1)

        for cycle in 1...3 {
            await server.stop()
            try await waitUntil {
                await recorder.states.contains { state in
                    if case .connecting = state { return true }
                    if case .failed = state { return true }
                    return false
                }
            }
            try await server.start()
            try await waitForConnected(recorder, via: .lanDirect(host: "127.0.0.1", port: fixedPort), minimumCount: cycle + 1)
        }

        await session.disconnect()
        observation.cancel()
        await server.stop()
    }

    @Test func disconnectTearsDownAndOpenStreamThrowsNotConnected() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture)
        try await server.start()
        let port = await server.port
        let pairing = pairing(from: fixture, localPort: port)
        let session = TunnelSession(pairing: pairing)
        let recorder = StateRecorder()
        let observation = observe(session: session, recorder: recorder)

        try await session.connect(endpoints: TransportEndpoint.candidates(for: pairing))
        try await waitForConnected(recorder, via: .lanDirect(host: "127.0.0.1", port: port), minimumCount: 1)
        await session.disconnect()
        observation.cancel()
        await server.stop()

        await expectSessionError(.notConnected) {
            _ = try await session.openStream()
        }
        #expect(await recorder.states.contains(.disconnected))
    }

    @Test func emptyLocalEndpointsFallsThroughToRelay() async throws {
        let fixture = try TestCA.make()
        let tlsServer = TLSEchoServer(bundle: fixture)
        try await tlsServer.start()
        let tlsPort = await tlsServer.port
        let relay = RelayBridgeServer(tlsPort: tlsPort)
        try await relay.start()
        let relayPort = await relay.port
        let pairing = pairing(from: fixture, relayPort: relayPort, localEndpoints: [])
        let session = TunnelSession(pairing: pairing)
        let recorder = StateRecorder()
        let observation = observe(session: session, recorder: recorder)

        try await session.connect(endpoints: TransportEndpoint.candidates(for: pairing))
        let relayURL = try #require(URL(string: "ws://127.0.0.1:\(relayPort)"))
        try await waitForConnected(recorder, via: .relay(endpoint: relayURL), minimumCount: 1)

        await session.disconnect()
        observation.cancel()
        await relay.stop()
        await tlsServer.stop()

        let candidates = try TransportEndpoint.candidates(for: pairing)
        #expect(await recorder.states.contains(.connecting(attempt: 1, candidates: candidates)))
        #expect(await recorder.states.contains(.connected(via: .relay(endpoint: relayURL))))
    }

    @Test func trustDirectUntilAttemptsCachedDirectEndpointFirst() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture, mode: .mux)
        try await server.start()
        let port = await server.port
        let pairing = pairing(from: fixture, localPort: port)
        let session = TunnelSession(pairing: pairing)
        let direct = TransportEndpoint.lan(host: "127.0.0.1", port: port, scope: "local")
        let relayOnly = TransportEndpoint.relay(
            endpoint: URL(string: "ws://127.0.0.1:1")!,
            instanceID: pairing.instanceID,
            deviceToken: pairing.deviceToken
        )

        let firstVia = try await session.connect(endpoints: [direct])
        await session.disconnect()
        let secondVia = try await session.connect(endpoints: [relayOnly])

        await session.disconnect()
        await server.stop()

        #expect(firstVia == .lanDirect(host: "127.0.0.1", port: port))
        #expect(secondVia == .lanDirect(host: "127.0.0.1", port: port))
    }

    private func pairing(
        from fixture: TestCA.Bundle,
        localPort: Int? = nil,
        relayPort: Int = 1,
        localEndpoints: [LocalEndpoint]? = nil
    ) -> StoredPairing {
        StoredPairing(
            instanceID: fixture.pairing.instanceID,
            homeLabel: fixture.pairing.homeLabel,
            relayEndpoint: "ws://127.0.0.1:\(relayPort)",
            fingerprint: fixture.pairing.fingerprint,
            clientCertPEM: fixture.clientCertificatePEM,
            clientKeyPEM: fixture.clientPrivateKeyPEM,
            caChainPEM: fixture.caCertificatePEM,
            deviceToken: fixture.pairing.deviceToken,
            localEndpoints: localEndpoints ?? [LocalEndpoint(host: "127.0.0.1", port: localPort ?? 1, scope: "local")],
            pairedAt: fixture.pairing.pairedAt
        )
    }

    private func observe(session: TunnelSession, recorder: StateRecorder) -> Task<Void, Never> {
        Task {
            for await state in session.stateUpdates {
                await recorder.append(state)
            }
        }
    }

    private func waitForConnected(_ recorder: StateRecorder, via: ConnectedVia, minimumCount: Int) async throws {
        try await waitUntil {
            await recorder.states.filter { $0 == .connected(via: via) }.count >= minimumCount
        }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SessionError.transportFailed("condition timeout")
    }

    private func firstInbound(from stream: AsyncThrowingStream<Data, Error>) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                for try await data in stream {
                    return data
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw SessionError.transportFailed("inbound timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func expectSessionError(
        _ expected: SessionError,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as SessionError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}

private actor StateRecorder {
    private var values: [TunnelState] = []

    var states: [TunnelState] {
        values
    }

    func append(_ state: TunnelState) {
        values.append(state)
    }
}
