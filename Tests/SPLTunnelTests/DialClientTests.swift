// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import SPLTunnel

@Suite("DialClient", .serialized)
struct DialClientTests {
    @Test func lanConnectsSendsAndReceivesBytesThroughTCPEcho() async throws {
        let server = TCPEchoServer()
        try await server.start()
        let port = await server.port

        let transport = try await DialClient.dial(.lan(host: "127.0.0.1", port: port, scope: "local"))
        try await transport.send(Data([0x01, 0x02, 0x03]))
        let echoed = try await transport.receive()
        await transport.close()
        await server.stop()

        #expect(echoed == Data([0x01, 0x02, 0x03]))
        #expect(transport.transportKind == "lan")
    }

    @Test func lanConnectTimeoutToUnreachableIPFiresConnectTimeout() async {
        await expectDialError(.connectTimeout) {
            _ = try await DialClient.dial(
                .lan(host: "10.255.255.1", port: 65_534, scope: "local"),
                timeout: .milliseconds(200)
            )
        }
    }

    @Test func relayConnectTimeoutCancelsPendingOpen() async throws {
        let server = TCPHangingServer()
        try await server.start()
        let port = await server.port

        await expectDialError(.connectTimeout) {
            _ = try await DialClient.dial(.relay(
                endpoint: try relayEndpoint(port: port),
                instanceID: "instance-1",
                deviceToken: "device-token"
            ), timeout: .milliseconds(200))
        }
        await server.stop()
    }

    @Test func relayConnectsSendsReceivesAndCarriesAuthorizationHeader() async throws {
        let server = WebSocketEchoServer()
        try await server.start()
        let port = await server.port

        let transport = try await DialClient.dial(.relay(
            endpoint: try relayEndpoint(port: port),
            instanceID: "instance-1",
            deviceToken: "device-token"
        ))
        try await transport.send(Data([0x04, 0x05, 0x06]))
        let echoed = try await transport.receive()
        await transport.close()
        let authorization = await server.authorizationHeader
        await server.stop()

        #expect(echoed == Data([0x04, 0x05, 0x06]))
        #expect(authorization == "Bearer device-token")
        #expect(transport.transportKind == "relay")
    }

    @Test func pairRelayConnectsWithPairDialPathAndTicketAuthorization() async throws {
        let server = WebSocketEchoServer()
        try await server.start()
        let port = await server.port

        let transport = try await DialClient.dialPairRelay(
            endpoint: try relayEndpoint(port: port),
            instanceID: "instance-1",
            pairTicket: "pair-ticket"
        )
        try await transport.send(Data([0x07, 0x08, 0x09]))
        let echoed = try await transport.receive()
        await transport.close()
        let authorization = await server.authorizationHeader
        await server.stop()

        #expect(echoed == Data([0x07, 0x08, 0x09]))
        #expect(authorization == "Bearer pair-ticket")
        #expect(transport.transportKind == "relay")
    }

    @Test func webSocketURLBuildsSessionAndPairDialPaths() throws {
        let relayURL = try RelayWSTransport.webSocketURL(
            endpoint: URL(string: "https://link.solstone.app")!,
            path: "session/dial",
            instanceID: "instance-123"
        )
        let pairURL = try RelayWSTransport.webSocketURL(
            endpoint: URL(string: "https://link.solstone.app/base")!,
            path: "session/pair-dial",
            instanceID: "instance-123"
        )

        #expect(relayURL.absoluteString == "wss://link.solstone.app/session/dial?instance=instance-123")
        #expect(pairURL.absoluteString == "wss://link.solstone.app/base/session/pair-dial?instance=instance-123")
    }

    @Test func relay401MapsUnauthorized() async throws {
        try await expectRelayStatus(401, .relayUnauthorized)
    }

    @Test func relay403MapsUnauthorized() async throws {
        try await expectRelayStatus(403, .relayUnauthorized)
    }

    @Test func relay404MapsInstanceUnknown() async throws {
        try await expectRelayStatus(404, .relayInstanceUnknown)
    }

    @Test func relay500MapsHandshakeFailed() async throws {
        try await expectRelayStatus(500, .wsHandshakeFailed(httpStatus: 500))
    }

    @Test func relayTextFrameMapsUnexpectedTextFrame() async throws {
        let server = WebSocketEchoServer(textOnConnect: "nope")
        try await server.start()
        let port = await server.port

        let transport = try await DialClient.dial(.relay(
            endpoint: try relayEndpoint(port: port),
            instanceID: "instance-1",
            deviceToken: "device-token"
        ))
        await expectDialError(.unexpectedTextFrame) {
            _ = try await transport.receive()
        }
        await transport.close()
        await server.stop()
    }

    private func expectRelayStatus(_ status: Int, _ expected: DialError) async throws {
        let server = WebSocketFailingServer(statusCode: status)
        try await server.start()
        let port = await server.port

        await expectDialError(expected) {
            _ = try await DialClient.dial(.relay(
                endpoint: try relayEndpoint(port: port),
                instanceID: "instance-1",
                deviceToken: "device-token"
            ))
        }
        await server.stop()
    }

    private func relayEndpoint(port: Int) throws -> URL {
        try #require(URL(string: "ws://127.0.0.1:\(port)"))
    }

    private func expectDialError(
        _ expected: DialError,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as DialError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }
}
