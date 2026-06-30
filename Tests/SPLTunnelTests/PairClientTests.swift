// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import Network
import Security
import Testing
@testable import SPLTunnel

private final class PairURLProtocolStore: @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var body: String
        var error: URLError?
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String?] = []

    func reset() {
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
            requestBodies.removeAll()
        }
    }

    func enqueue(statusCode: Int = 200, body: String = "", error: URLError? = nil) {
        lock.withLock {
            responses.append(Response(statusCode: statusCode, body: body, error: error))
        }
    }

    func next(for request: URLRequest) -> Response {
        lock.withLock {
            requests.append(request)
            requestBodies.append(Self.bodyString(from: request))
            if responses.isEmpty {
                return Response(statusCode: 500, body: "", error: URLError(.badServerResponse))
            }
            return responses.removeFirst()
        }
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class PairURLProtocol: URLProtocol {
    static let store = PairURLProtocolStore()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.store.next(for: request)
        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !next.body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("PairClient", .serialized)
struct PairClientTests {
    @Test func happyPathBuildsStoredPairing() async throws {
        PairURLProtocol.store.reset()
        let before = Date()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        let pairing = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )

        #expect(pairing.instanceID == "instance-1")
        #expect(pairing.homeLabel == "living room mac")
        #expect(pairing.relayEndpoint == "https://spl.solpbc.org")
        #expect(pairing.fingerprint == "sha256:\(TestCertificates.cert1Fingerprint)")
        #expect(pairing.clientCertPEM == TestCertificates.cert1)
        #expect(pairing.clientKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
        #expect(pairing.caChainPEM == "\(TestCertificates.cert2)\n")
        #expect(pairing.relayEnrollment == .enrolled(deviceToken: "device-token", expiresAt: "2026-05-11T00:00:00Z"))
        #expect(pairing.localEndpoints == [])
        #expect(pairing.pairedAt >= before)
    }

    @Test func pairResponseWithLocalEndpointsPopulatesStoredPairing() async throws {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON(localEndpoints: [[
            "host": "192.168.1.10",
            "port": 7657,
            "scope": "local",
        ]]))
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        let pairing = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )

        #expect(pairing.localEndpoints == [
            LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "local")
        ])
    }

    @Test func lanRequestShape() async throws {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        _ = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )

        let request = try #require(PairURLProtocol.store.requests.first)
        #expect(request.url?.absoluteString == "https://192.0.2.42:7070/app/network/pair")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == nil)

        let body = try jsonBody(index: 0)
        #expect(body["nonce"] as? String == "a1b2c3d4e5f607181122334455667788")
        #expect(body["device_label"] as? String == "test mac")
        #expect((body["csr"] as? String)?.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n") == true)
    }

    @Test func relayRequestShape() async throws {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        _ = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org/")!
        )

        let request = try #require(PairURLProtocol.store.requests.dropFirst().first)
        #expect(request.url?.absoluteString == "https://spl.solpbc.org/enroll/device")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "solstone-macos/0.0.0-dev")
        #expect(request.value(forHTTPHeaderField: "Accept") == nil)

        let body = try jsonBody(index: 1)
        #expect(body["instance_id"] as? String == "instance-1")
        #expect(body["home_attestation"] as? String == "attestation")
        #expect(body["client_cert"] == nil)
    }

    @Test func lanStatusMappings() async throws {
        await expectPairError(.nonceExpired, lanStatus: 410)
        await expectPairError(.lanResponseInvalid(status: 400), lanStatus: 400)
        await expectPairError(.lanResponseInvalid(status: 404), lanStatus: 404)
        await expectPairError(.lanRequestFailed(underlying: nil), lanStatus: 500)
    }

    @Test func lanMalformedResponsesMapInvalid() async throws {
        await expectPairError(.lanResponseInvalid(status: 200), lanBody: "{")
        await expectPairError(.lanResponseInvalid(status: 200), lanBody: #"{"instance_id":"instance-1"}"#)
    }

    @Test func relayEnrollmentFailureCompletesPairingAsUnavailable() async throws {
        for status in [400, 401, 403, 404, 409, 503] {
            let pairing = try await pairWithRelay(status: status, body: relayResponseJSON())
            #expect(pairing.relayEnrollment == .unavailable)
        }
    }

    @Test func relayMalformedResponseCompletesPairingAsUnavailable() async throws {
        let malformed = try await pairWithRelay(body: "{")
        #expect(malformed.relayEnrollment == .unavailable)

        let missingExpiry = try await pairWithRelay(body: #"{"device_token":"token"}"#)
        #expect(missingExpiry.relayEnrollment == .enrolled(deviceToken: "token", expiresAt: nil))
    }

    @Test func transportErrorsMapRequestFailed() async throws {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(error: URLError(.cannotConnectToHost))
        await expectPairError(.lanRequestFailed(underlying: nil), usingExistingQueue: true)

        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(error: URLError(.cannotConnectToHost))
        let pairing = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )
        #expect(pairing.relayEnrollment == .unavailable)
    }

    @Test func relayInstanceIDMismatchThrowsBeforeEnrollment() throws {
        let caSPKI = try Self.caSPKI(caCertificatePEM: TestCertificates.cert2)
        let lanResponse = try PairClient.decodeLANResponse(data: Data(lanResponseJSON(
            instanceID: "different-instance",
            caChain: [TestCertificates.cert2]
        ).utf8))

        do {
            try PairClient.verifyRelayPairResponse(lanResponse, caSPKIDER: caSPKI)
            Issue.record("Expected relayInstanceMismatch")
        } catch let error as PairError {
            #expect(error == .relayInstanceMismatch)
        } catch {
            Issue.record("Expected relayInstanceMismatch, got \(error)")
        }
    }

    @Test func relayCAChainMismatchThrowsBeforeEnrollment() throws {
        let caSPKI = try Self.caSPKI(caCertificatePEM: TestCertificates.cert1)
        let lanResponse = try PairClient.decodeLANResponse(data: Data(lanResponseJSON(
            instanceID: CertChain.jidFromSPKI(caSPKI),
            caChain: [TestCertificates.cert2]
        ).utf8))

        do {
            try PairClient.verifyRelayPairResponse(lanResponse, caSPKIDER: caSPKI)
            Issue.record("Expected relayInstanceMismatch")
        } catch let error as PairError {
            #expect(error == .relayInstanceMismatch)
        } catch {
            Issue.record("Expected relayInstanceMismatch, got \(error)")
        }
    }

    @Test func relayFormCeremonyProducesStoredPairingWithRelayEnrollment() async throws {
        let bundle = try TestCA.make()
        let instanceID = try Self.jid(caCertificatePEM: bundle.caCertificatePEM)
        let pairingServer = RelayPairingMuxServer(
            bundle: bundle,
            responseJSON: lanResponseJSON(instanceID: instanceID, caChain: [bundle.caCertificatePEM], localEndpoints: [[
                "host": "127.0.0.1",
                "port": 7657,
                "scope": "loopback",
            ]])
        )
        try await pairingServer.start()
        let relay = RelayBridgeServer(tlsPort: await pairingServer.port)
        try await relay.start()
        defer {
            Task {
                await relay.stop()
                await pairingServer.stop()
            }
        }

        let relayEndpoint = try #require(URL(string: "ws://127.0.0.1:\(await relay.port)"))
        let pairURL = try Self.makeRelayPairURL(caCertificatePEM: bundle.caCertificatePEM)
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        let pairing = try await makeClient().pair(
            pairURL: pairURL,
            deviceLabel: "relay mac",
            relayEndpoint: relayEndpoint
        )

        #expect(pairing.instanceID == instanceID)
        #expect(pairing.homeLabel == "living room mac")
        #expect(pairing.relayEndpoint == relayEndpoint.absoluteString)
        #expect(pairing.relayEnrollment == .enrolled(deviceToken: "device-token", expiresAt: "2026-05-11T00:00:00Z"))
        #expect(pairing.localEndpoints == [LocalEndpoint(host: "127.0.0.1", port: 7657, scope: "loopback")])
        let requests = PairURLProtocol.store.requests
        #expect(requests.map { $0.url?.path } == ["/enroll/device"])
        #expect(await relay.authorizationHeader == nil)
        #expect(await relay.pairKeyHeader == "e34481a4cde647ba9c9fb29a59e18271")
    }

    @Test func pairWindowRKMatchesReferenceVector() throws {
        let rk = try PairClient.derivePairWindowRK(sBytes: [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        #expect(Self.hex(rk) == "e34481a4cde647ba9c9fb29a59e18271")
    }

    @Test func tunnelPairHTTPRequestUsesRelativeMuxPath() throws {
        let body = Data(#"{"csr":"pem","device_label":"mac"}"#.utf8)
        let request = PairClient.buildHTTPRequest(
            method: "POST",
            path: "/app/network/pair?token=012345",
            body: body
        )
        let text = try #require(String(data: request, encoding: .utf8))

        #expect(text.hasPrefix("POST /app/network/pair?token=012345 HTTP/1.1\r\n"))
        #expect(text.contains("Host: spl.local\r\n"))
        #expect(text.contains("User-Agent: solstone-macos/0.0.0-dev\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.hasSuffix(String(data: body, encoding: .utf8)!))
    }

    @Test func pairClientDoesNotTouchKeychain() async throws {
        let service = "app.solstone.observer.spl.pairclient.test"
        try SPLKeychain._delete(service: service)
        defer { try? SPLKeychain._delete(service: service) }
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(body: relayResponseJSON())

        _ = try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )

        #expect(try SPLKeychain._load(service: service) == nil)
    }

    private func makeClient() -> PairClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairURLProtocol.self]
        return PairClient(session: URLSession(configuration: config))
    }

    private func makePairURL() throws -> PairURL {
        try PairURL.parse(URL(string: "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!)
    }

    private func lanResponseJSON(
        instanceID: String = "instance-1",
        caChain: [String] = [TestCertificates.cert2],
        localEndpoints: [[String: Any]]? = nil
    ) -> String {
        var response: [String: Any] = [
            "client_cert": TestCertificates.cert1,
            "ca_chain": caChain,
            "instance_id": instanceID,
            "home_label": "living room mac",
            "home_attestation": "attestation",
            "fingerprint": "ignored",
        ]
        if let localEndpoints {
            response["local_endpoints"] = localEndpoints
        }
        return json(response)
    }

    private func relayResponseJSON() -> String {
        json([
            "device_token": "device-token",
            "expires_at": "2026-05-11T00:00:00Z",
        ])
    }

    private func pairWithRelay(status: Int = 200, body: String) async throws -> StoredPairing {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(statusCode: status, body: body)

        return try await makeClient().pair(
            pairURL: makePairURL(),
            deviceLabel: "test mac",
            relayEndpoint: URL(string: "https://spl.solpbc.org")!
        )
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func jsonBody(index: Int) throws -> [String: Any] {
        let body = try #require(PairURLProtocol.store.requestBodies[index])
        let data = Data(body.utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectPairError(
        _ expected: PairError,
        lanStatus: Int = 200,
        lanBody: String? = nil,
        relayStatus: Int = 200,
        relayBody: String? = nil,
        usingExistingQueue: Bool = false
    ) async {
        if !usingExistingQueue {
            PairURLProtocol.store.reset()
            PairURLProtocol.store.enqueue(statusCode: lanStatus, body: lanBody ?? lanResponseJSON())
            if lanStatus == 200 {
                PairURLProtocol.store.enqueue(statusCode: relayStatus, body: relayBody ?? relayResponseJSON())
            }
        }

        do {
            _ = try await makeClient().pair(
                pairURL: makePairURL(),
                deviceLabel: "test mac",
                relayEndpoint: URL(string: "https://spl.solpbc.org")!
            )
            Issue.record("Expected \(expected)")
        } catch let error as PairError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected \(expected), got \(error)")
        }
    }

    private static func makeRelayPairURL(caCertificatePEM: String) throws -> PairURL {
        let caCertificate = try #require(try CertChain.certificates(fromPEM: caCertificatePEM).first)
        let spkiDER = try CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: caCertificate)
        let spkiPrefix = Array(SHA256.hash(data: Data(spkiDER)).prefix(16))
        var bytes: [UInt8] = [
            0x06,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01,
        ]
        bytes.append(contentsOf: spkiPrefix)
        bytes.append(0)
        return try PairURL.parse(URL(string: "https://go.solstone.app/p#\(Self.encodeBase32(bytes))")!)
    }

    private static func jid(caCertificatePEM: String) throws -> String {
        CertChain.jidFromSPKI(try caSPKI(caCertificatePEM: caCertificatePEM))
    }

    private static func caSPKI(caCertificatePEM: String) throws -> [UInt8] {
        let caCertificate = try #require(try CertChain.certificates(fromPEM: caCertificatePEM).first)
        return try CertChain.canonicalP256SubjectPublicKeyInfoDER(certificate: caCertificate)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}

private actor RelayPairingMuxServer {
    private static let queue = DispatchQueue(label: "app.solstone.observer.spl.tests.relay-pair")

    private let bundle: TestCA.Bundle
    private let responseJSON: String
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var boundPort: NWEndpoint.Port?

    init(bundle: TestCA.Bundle, responseJSON: String) {
        self.bundle = bundle
        self.responseJSON = responseJSON
    }

    var port: Int {
        Int(boundPort?.rawValue ?? 0)
    }

    func start() async throws {
        let identity = try TestCA.secIdentity(
            certificatePEM: "\(bundle.serverCertificatePEM)\n\(bundle.caCertificatePEM)",
            privateKeyPEM: bundle.serverPrivateKeyPEM
        )
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)
        sec_protocol_options_set_local_identity(secOptions, identity)

        let listener = try NWListener(using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()), on: .any)
        let waiter = RelayPairingListenerWaiter()
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
        listener.newConnectionHandler = { [weak self] connection in
            Task {
                await self?.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: Self.queue)
        try await waiter.wait()
        boundPort = listener.port
    }

    func stop() {
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
        connection.start(queue: Self.queue)
        Task {
            await handle(connection)
        }
    }

    private nonisolated func handle(_ connection: NWConnection) async {
        let mux = Multiplexer(sink: { data in
            try await MockHTTPConnection.send(data, to: connection)
        }, role: .listener)
        let receiveTask = Task {
            do {
                while !Task.isCancelled {
                    guard let chunk = try await Self.receive(from: connection), !chunk.isEmpty else {
                        await mux.tearDown(reason: .transportFailure)
                        return
                    }
                    try await mux.feedInbound(chunk)
                }
            } catch {
                await mux.tearDown(reason: .transportFailure)
            }
        }

        for await stream in mux.incomingStreams {
            Task {
                await handle(stream: stream)
            }
        }
        receiveTask.cancel()
    }

    private nonisolated func handle(stream: MuxStream) async {
        do {
            let request = try await Self.readRequest(from: stream)
            guard request.method == "POST",
                  request.path == "/app/network/pair?token=0123456789abcdef" else {
                try await Self.write(status: 404, body: #"{"error":"not_found"}"#, to: stream)
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  json["csr"] as? String != nil,
                  json["device_label"] as? String == "relay mac" else {
                try await Self.write(status: 400, body: #"{"error":"bad_request"}"#, to: stream)
                return
            }
            try await Self.write(status: 200, body: responseJSON, to: stream)
        } catch {
            await stream.reset(reason: .internalError)
        }
    }

    private nonisolated static func readRequest(from stream: MuxStream) async throws -> MockHTTPRequest {
        let inbound = await stream.inbound
        var iterator = inbound.makeAsyncIterator()
        var buffer = Data()
        while !buffer.pairClientContainsHeaderTerminator {
            guard let chunk = try await iterator.next() else {
                throw MockHTTPError.closed
            }
            buffer.append(chunk)
            if buffer.count > MockHTTPConnection.maxBodySize {
                throw MockHTTPError.bodyTooLarge
            }
        }

        let headerEnd = buffer.pairClientHeaderTerminatorRange!.lowerBound
        let bodyStart = buffer.pairClientHeaderTerminatorRange!.upperBound
        let headerData = buffer[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8),
              let requestLine = headerText.components(separatedBy: "\r\n").first else {
            throw MockHTTPError.invalidRequest
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw MockHTTPError.invalidRequest
        }
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let index = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(buffer[bodyStart...])
        while body.count < contentLength {
            guard let chunk = try await iterator.next() else {
                throw MockHTTPError.closed
            }
            body.append(chunk)
        }
        if body.count > contentLength {
            body = Data(body.prefix(contentLength))
        }
        return MockHTTPRequest(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private nonisolated static func write(status: Int, body: String, to stream: MuxStream) async throws {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await stream.write(Data(response.utf8))
        try await stream.close()
    }

    private nonisolated static func receive(from connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }
}

private final class RelayPairingListenerWaiter: @unchecked Sendable {
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

private extension Data {
    var pairClientHeaderTerminatorRange: Range<Data.Index>? {
        range(of: Data("\r\n\r\n".utf8))
    }

    var pairClientContainsHeaderTerminator: Bool {
        pairClientHeaderTerminatorRange != nil
    }
}

enum TestCertificates {
    static let cert1Fingerprint = "005a64c08d69da268c62971466aca5324eaba7ead27e3d4e33ddaa244535e168"

    static let cert1 = """
    -----BEGIN CERTIFICATE-----
    MIIBdTCCARugAwIBAgIUVMEtHY4txnB9yvPieVZOPQb8B/swCgYIKoZIzj0EAwIw
    EDEOMAwGA1UEAwwFdGVzdDEwHhcNMjYwNTExMDU0OTI4WhcNMzYwNTA4MDU0OTI4
    WjAQMQ4wDAYDVQQDDAV0ZXN0MTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPih
    dGj0TbzBAXX6uLTt/rKpwd7t8DohOFLZ44i9KlffKSrMHvo2DufP/oUVB+V/jJy9
    0PQuCc+/j2NrTtHOh3yjUzBRMB0GA1UdDgQWBBQrAyo4k6cTcZB56UCx7ZcJPWxH
    ezAfBgNVHSMEGDAWgBQrAyo4k6cTcZB56UCx7ZcJPWxHezAPBgNVHRMBAf8EBTAD
    AQH/MAoGCCqGSM49BAMCA0gAMEUCIA0cayl/grfqS8xzPnv3+A6Wqb7NL8QvfgPu
    ZBXoDWAEAiEAgCfoRUL0QMRHSW4FKBCyqn63nZBYfgcl2q4I+kYz0y4=
    -----END CERTIFICATE-----
    """

    static let cert2 = """
    -----BEGIN CERTIFICATE-----
    MIIBdjCCARugAwIBAgIUPmc8qjlLPIA4EFu09uWC+SpZMBAwCgYIKoZIzj0EAwIw
    EDEOMAwGA1UEAwwFdGVzdDIwHhcNMjYwNTExMDU0OTI4WhcNMzYwNTA4MDU0OTI4
    WjAQMQ4wDAYDVQQDDAV0ZXN0MjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABE34
    z7zq08sFkDWZCydwYPbUZ0p6axn7HVfFfMvoBSJI1sx0ugGzsO20gUKvQkS1f82o
    wPZALFfM/2QhFxaXibajUzBRMB0GA1UdDgQWBBS0hMPoitOyZ9HNf6Jn9N62yCtN
    yzAfBgNVHSMEGDAWgBS0hMPoitOyZ9HNf6Jn9N62yCtNyzAPBgNVHRMBAf8EBTAD
    AQH/MAoGCCqGSM49BAMCA0kAMEYCIQCp2/epKon4CeHgWUTFJT7SjTpDODpJONYu
    C+oCUlJiOQIhAPO48QBJMB7pJ3gRqUFTGg5j2lBpky934j0CPQvU/w8V
    -----END CERTIFICATE-----
    """
}
