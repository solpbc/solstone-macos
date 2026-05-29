// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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
        #expect(pairing.deviceToken == "device-token")
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
        #expect(request.url?.absoluteString == "https://192.0.2.42:7070/app/link/pair")
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
        #expect(body["client_cert"] as? String == TestCertificates.cert1)
        #expect(body["home_attestation"] as? String == "attestation")
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

    @Test func relayStatusMappings() async throws {
        await expectPairError(.relayRequestFailed(underlying: nil), relayStatus: 503)
        await expectPairError(.relayResponseInvalid(status: 400), relayStatus: 400)
        await expectPairError(.relayResponseInvalid(status: 404), relayStatus: 404)
        await expectPairError(.attestationRejected(status: 401), relayStatus: 401)
        await expectPairError(.attestationRejected(status: 403), relayStatus: 403)
        await expectPairError(.attestationRejected(status: 409), relayStatus: 409)
    }

    @Test func relayMalformedResponsesMapInvalid() async throws {
        await expectPairError(.relayResponseInvalid(status: 200), relayBody: "{")
        await expectPairError(.relayResponseInvalid(status: 200), relayBody: #"{"device_token":"token"}"#)
    }

    @Test func transportErrorsMapRequestFailed() async throws {
        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(error: URLError(.cannotConnectToHost))
        await expectPairError(.lanRequestFailed(underlying: nil), usingExistingQueue: true)

        PairURLProtocol.store.reset()
        PairURLProtocol.store.enqueue(body: lanResponseJSON())
        PairURLProtocol.store.enqueue(error: URLError(.cannotConnectToHost))
        await expectPairError(.relayRequestFailed(underlying: nil), usingExistingQueue: true)
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
        try PairURL.parse(URL(string: "https://link.solpbc.org/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!)
    }

    private func lanResponseJSON(localEndpoints: [[String: Any]]? = nil) -> String {
        var response: [String: Any] = [
            "client_cert": TestCertificates.cert1,
            "ca_chain": [TestCertificates.cert2],
            "instance_id": "instance-1",
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
