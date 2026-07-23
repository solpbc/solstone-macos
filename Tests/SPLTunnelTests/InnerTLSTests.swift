// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import Testing
@testable import SPLTunnel

private struct TestTimeout: Error, Sendable {}

@Suite("InnerTLS", .serialized)
struct InnerTLSTests {
    @Test func lanOneKiBPlaintextRoundTripByteEqualAgainstInProcessTLSEcho() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture)
        try await server.start()
        let port = await server.port

        let tls = try await InnerTLS.connectLAN(host: "127.0.0.1", port: port, pairing: fixture.pairing)
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        try await tls.send(payload)
        let echoed = try await firstInbound(from: tls.inbound)
        await tls.close()
        await server.stop()

        #expect(echoed == payload)
    }

    @Test func lanWrongCAInPinFailsHandshake() async throws {
        let fixture = try TestCA.make()
        let wrongServerFixture = try TestCA.make()
        let server = TLSEchoServer(bundle: wrongServerFixture, clientCAPEM: fixture.caCertificatePEM)
        try await server.start()
        let port = await server.port

        await expectPeerNotPinned {
            _ = try await InnerTLS.connectLAN(host: "127.0.0.1", port: port, pairing: fixture.pairing)
        }
        await server.stop()
    }

    @Test func lanServerRejectingClientCertFailsHandshake() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture, rejectClientCertificate: true)
        try await server.start()
        let port = await server.port

        await expectClientCertificateRejection {
            let tls = try await InnerTLS.connectLAN(host: "127.0.0.1", port: port, pairing: fixture.pairing)
            try await tls.send(Data([0x01]))
            guard try await firstInbound(from: tls.inbound) != nil else {
                throw InnerTLSError.handshakeFailed("server closed")
            }
            await tls.close()
        }
        #expect(await server.clientLeafFingerprint == (try TestCA.fingerprint(certificatePEM: fixture.clientCertificatePEM)))
        await server.stop()
    }

    @Test func lanServerFixtureCapturesClientLeafCertificate() async throws {
        let fixture = try TestCA.make()
        let server = TLSEchoServer(bundle: fixture)
        try await server.start()
        let port = await server.port

        let tls = try await InnerTLS.connectLAN(host: "127.0.0.1", port: port, pairing: fixture.pairing)
        try await tls.send(Data([0x01]))
        _ = try await firstInbound(from: tls.inbound)
        let captured = await server.clientLeafFingerprint
        await tls.close()
        await server.stop()

        #expect(captured == (try TestCA.fingerprint(certificatePEM: fixture.clientCertificatePEM)))
    }

    @Test func relayOneKiBPlaintextRoundTripViaWSToTLSBridgeByteEqual() async throws {
        let fixture = try TestCA.make()
        let tlsServer = TLSEchoServer(bundle: fixture)
        try await tlsServer.start()
        let tlsPort = await tlsServer.port
        let relay = RelayBridgeServer(tlsPort: tlsPort)
        try await relay.start()
        let relayPort = await relay.port

        let transport = try await DialClient.dial(.relay(
            endpoint: try #require(URL(string: "ws://127.0.0.1:\(relayPort)")),
            instanceID: fixture.pairing.instanceID,
            deviceToken: deviceToken(from: fixture.pairing)
        ))
        let tls = try await InnerTLS.connectViaTransport(transport: transport, pairing: fixture.pairing)
        let payload = Data((0..<1024).map { UInt8(($0 * 7) % 251) })
        try await tls.send(payload)
        let echoed = try await firstInbound(from: tls.inbound)
        await tls.close()
        await relay.stop()
        await tlsServer.stop()

        #expect(echoed == payload)
    }

    @Test func lanParametersPinOnlyRFC1918IPv4LiteralsToNonOtherInterfaces() {
        let pinnedRFC1918 = InnerTLS.lanParametersForTesting(host: "192.168.1.10", unpinnedInterface: false)
        #expect(pinnedRFC1918.prohibitedInterfaceTypes == [.other])

        let unpinnedRFC1918 = InnerTLS.lanParametersForTesting(host: "192.168.1.10", unpinnedInterface: true)
        #expect(unpinnedRFC1918.prohibitedInterfaceTypes?.contains(.other) != true)

        for host in ["fd12:3456::1", "100.64.0.1", "203.0.113.10", "home.local"] {
            let parameters = InnerTLS.lanParametersForTesting(host: host, unpinnedInterface: false)
            #expect(parameters.prohibitedInterfaceTypes?.contains(.other) != true)
        }
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
                throw InnerTLSError.receiveFailed("timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func deviceToken(from pairing: StoredPairing) -> String {
        if case .enrolled(let deviceToken, _) = pairing.relayEnrollment {
            return deviceToken
        }
        return ""
    }

    private func expectPeerNotPinned(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw TestTimeout()
                }
                try await group.next()!
                group.cancelAll()
            }
            Issue.record("Expected peerNotPinned")
        } catch InnerTLSError.peerNotPinned {
        } catch {
            Issue.record("Expected peerNotPinned, got \(error)")
        }
    }

    private func expectClientCertificateRejection(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw TestTimeout()
                }
                try await group.next()!
                group.cancelAll()
            }
            Issue.record("Expected client certificate rejection")
        } catch InnerTLSError.handshakeFailed(_) {
        } catch InnerTLSError.receiveFailed(_) {
        } catch {
            Issue.record("Expected handshakeFailed or receiveFailed, got \(error)")
        }
    }
}
