// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import Network
import Security
@testable import SPLTunnel

private let serverQueue = DispatchQueue(label: "app.solstone.observer.spl.tests.echo")

actor TCPEchoServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        echo(connection)
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            guard let server = self else {
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in
                Task {
                    await server.echo(connection)
                }
            })
        }
    }
}

actor TCPHangingServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
    }
}

actor WebSocketEchoServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?
    private(set) var authorizationHeader: String?
    private let textOnConnect: String?

    init(textOnConnect: String? = nil) {
        self.textOnConnect = textOnConnect
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(serverQueue) { [weak self] _, headers in
            if let authorization = headers.first(where: { $0.name.lowercased() == "authorization" })?.value {
                Task {
                    await self?.setAuthorizationHeader(authorization)
                }
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
        authorizationHeader = nil
    }

    private func setAuthorizationHeader(_ value: String) {
        authorizationHeader = value
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        if let textOnConnect {
            sendText(textOnConnect, on: connection)
        } else {
            receiveMessage(on: connection)
        }
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
            guard let server = self else {
                return
            }
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                Task {
                    await server.receiveMessage(on: connection)
                }
            })
        }
    }

    private func sendText(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

actor WebSocketClosingServer {
    private let closeCode: UInt16
    private let closeDelay: TimeInterval
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(closeCode: UInt16, closeDelay: TimeInterval = 0.1) {
        self.closeCode = closeCode
        self.closeDelay = closeDelay
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        readHandshake(on: connection, buffered: Data())
    }

    private func readHandshake(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }

            var request = buffered
            request.append(data)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task {
                    await self?.sendAcceptAndClose(on: connection, request: request)
                }
            } else {
                Task {
                    await self?.readHandshake(on: connection, buffered: request)
                }
            }
        }
    }

    private func sendAcceptAndClose(on connection: NWConnection, request: Data) {
        guard let key = Self.webSocketKey(from: request) else {
            connection.cancel()
            return
        }

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(Self.acceptValue(for: key))\r\n" +
            "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [closeCode, closeDelay] _ in
            serverQueue.asyncAfter(deadline: .now() + closeDelay) {
                let closeFrame = Data([
                    0x88,
                    0x02,
                    UInt8((closeCode >> 8) & 0xff),
                    UInt8(closeCode & 0xff),
                ])
                connection.send(content: closeFrame, completion: .contentProcessed { _ in
                    serverQueue.asyncAfter(deadline: .now() + 0.05) {
                        connection.cancel()
                    }
                })
            }
        })
    }

    private static func webSocketKey(from request: Data) -> String? {
        guard let text = String(data: request, encoding: .utf8) else {
            return nil
        }
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sec-websocket-key"
            else {
                continue
            }
            return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func acceptValue(for key: String) -> String {
        let data = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest).base64EncodedString()
    }
}

actor WebSocketFailingServer {
    private let statusCode: Int
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [statusCode] _, _, _, _ in
            let reason = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            let response = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Length: 0\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

enum TLSEchoMode {
    case raw
    case mux
    case muxDropControl
}

actor TLSEchoServer {
    private let bundle: TestCA.Bundle
    private let clientCAPEM: String
    private let rejectClientCertificate: Bool
    private let mode: TLSEchoMode
    private let requestedPort: Int?
    private let capture = CertificateCapture()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(
        bundle: TestCA.Bundle,
        clientCAPEM: String? = nil,
        rejectClientCertificate: Bool = false,
        mode: TLSEchoMode = .raw,
        port: Int? = nil
    ) {
        self.bundle = bundle
        self.clientCAPEM = clientCAPEM ?? bundle.caCertificatePEM
        self.rejectClientCertificate = rejectClientCertificate
        self.mode = mode
        self.requestedPort = port
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    var clientLeafFingerprint: String? {
        capture.fingerprint
    }

    func start() async throws {
        let tlsOptions = try makeServerTLSOptions()
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let port = requestedPort.flatMap { NWEndpoint.Port(rawValue: UInt16(clamping: $0)) }
        let listener = try NWListener(using: parameters, on: port ?? .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: serverQueue)
        if rejectClientCertificate {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { _, _, _, _ in
                connection.cancel()
            }
            return
        }
        switch mode {
        case .raw:
            echo(connection)
        case .mux:
            muxEcho(connection, decoder: MuxEchoDecoder(respondsToControlFrames: true))
        case .muxDropControl:
            muxEcho(connection, decoder: MuxEchoDecoder(respondsToControlFrames: false))
        }
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            guard let server = self else {
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in
                Task {
                    await server.echo(connection)
                }
            })
        }
    }

    private func muxEcho(_ connection: NWConnection, decoder: MuxEchoDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }
            do {
                let response = try decoder.response(to: data)
                guard let server = self else {
                    return
                }
                connection.send(content: response.isEmpty ? nil : response, completion: .contentProcessed { _ in
                    Task {
                        await server.muxEcho(connection, decoder: decoder)
                    }
                })
            } catch {
                connection.cancel()
            }
        }
    }

    private func makeServerTLSOptions() throws -> NWProtocolTLS.Options {
        let anchors = try CertChain.certificates(fromPEM: clientCAPEM)
        let identity = try TestCA.secIdentity(
            certificatePEM: bundle.serverCertificatePEM,
            privateKeyPEM: bundle.serverPrivateKeyPEM
        )
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_local_identity(secOptions, identity)
        sec_protocol_options_set_peer_authentication_required(secOptions, true)
        sec_protocol_options_set_verify_block(secOptions, { [capture, rejectClientCertificate] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
               let leaf = chain.first {
                capture.setFingerprint(CertChain.sha256Fingerprint(of: leaf))
            }
            guard !rejectClientCertificate else {
                complete(false)
                return
            }
            SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(secTrust, true)
            var error: CFError?
            complete(SecTrustEvaluateWithError(secTrust, &error))
        }, serverQueue)
        return options
    }
}

private final class MuxEchoDecoder: @unchecked Sendable {
    // why: Network callbacks can overlap; the test mux peer keeps decoder state serialized by lock.
    private let lock = NSLock()
    private let respondsToControlFrames: Bool
    private var decoder = FrameDecoder()

    init(respondsToControlFrames: Bool) {
        self.respondsToControlFrames = respondsToControlFrames
    }

    func response(to data: Data) throws -> Data {
        try lock.withLock {
            decoder.feed(data)
            var response = Data()
            while let frame = try decoder.next() {
                if respondsToControlFrames && frame.streamID == 0 && frame.flags & FrameFlags.ping.rawValue != 0 {
                    response.append(try encodeFrame(buildPong(nonce: try parseControlNonce(from: frame.payload))))
                }
                if frame.flags & FrameFlags.data.rawValue != 0 {
                    response.append(try encodeFrame(buildData(streamID: frame.streamID, payload: frame.payload)))
                }
                if frame.flags & FrameFlags.close.rawValue != 0 {
                    response.append(try encodeFrame(buildClose(streamID: frame.streamID)))
                }
            }
            return response
        }
    }
}

actor RelayBridgeServer {
    private let tlsPort: Int
    private var listener: NWListener?
    private var webSocketConnections: [NWConnection] = []
    private var tcpConnections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(tlsPort: Int) {
        self.tlsPort = tlsPort
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(serverQueue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        try await startAndWaitForListenerReady(listener)
        boundPort = listener.port
    }

    func stop() async {
        for connection in webSocketConnections + tcpConnections {
            connection.cancel()
        }
        webSocketConnections.removeAll()
        tcpConnections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func accept(_ webSocket: NWConnection) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: tlsPort)), 1...65535 ~= tlsPort else {
            webSocket.cancel()
            return
        }
        let tcp = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        webSocketConnections.append(webSocket)
        tcpConnections.append(tcp)
        webSocket.start(queue: serverQueue)
        tcp.start(queue: serverQueue)
        pumpWebSocket(webSocket, to: tcp)
        pumpTCP(tcp, to: webSocket)
    }

    private func pumpWebSocket(_ webSocket: NWConnection, to tcp: NWConnection) {
        webSocket.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data else {
                tcp.cancel()
                webSocket.cancel()
                return
            }
            guard let server = self else {
                return
            }
            tcp.send(content: data, completion: .contentProcessed { _ in
                Task {
                    await server.pumpWebSocket(webSocket, to: tcp)
                }
            })
        }
    }

    private func pumpTCP(_ tcp: NWConnection, to webSocket: NWConnection) {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                if isComplete {
                    webSocket.cancel()
                    tcp.cancel()
                }
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "bridge", metadata: [metadata])
            guard let server = self else {
                return
            }
            webSocket.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
                Task {
                    await server.pumpTCP(tcp, to: webSocket)
                }
            })
        }
    }
}

private final class CertificateCapture: @unchecked Sendable {
    // why: Security verify callbacks run on a dispatch queue and tests read through actor access.
    private let lock = NSLock()
    private var value: String?

    var fingerprint: String? {
        lock.withLock { value }
    }

    func setFingerprint(_ fingerprint: String) {
        lock.withLock {
            value = fingerprint
        }
    }
}

private final class ListenerReadyWaiter: @unchecked Sendable {
    // why: NWListener invokes state callbacks concurrently with test tasks; NSLock provides one-shot resume.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, Error>? = lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }

            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<Void, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private func startAndWaitForListenerReady(_ listener: NWListener) async throws {
    let waiter = ListenerReadyWaiter()
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            waiter.complete(.success(()))
        case .failed(let error):
            waiter.complete(.failure(error))
        case .cancelled:
            waiter.complete(.failure(DialError.connectionFailed("listener cancelled")))
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }
    listener.start(queue: serverQueue)
    try await waiter.wait()
}
