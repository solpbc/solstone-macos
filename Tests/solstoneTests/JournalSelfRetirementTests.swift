// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("JournalSelfRetirement")
struct JournalSelfRetirementTests {
    @Test(arguments: [200, 204, 404])
    func successfulStatusCodesReturnRetired(statusCode: Int) async throws {
        let certs = try CertChain.certificates(fromPEM: testCACertPEM)
        let firstCert = try #require(certs.first)
        let expectedCid = CertChain.sha256Fingerprint(of: firstCert)
        let localPort = 54321
        let testPairing = pairing(clientCertPEM: testCACertPEM)

        let transport = RequestRecordingTransport(statusCode: statusCode)
        let retirement = JournalSelfRetirement(
            transport: { try await transport.send($0) },
            timeout: .seconds(2)
        )

        let outcome = await retirement.retire(pairing: testPairing, localPort: localPort)
        #expect(outcome == .retired)

        let requests = await transport.requests
        #expect(requests.count == 1)
        let req = try #require(requests.first)
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.host == "127.0.0.1")
        #expect(req.url?.port == localPort)
        #expect(req.url?.absoluteString == "http://127.0.0.1:\(localPort)/app/network/api/clients/sha256%3A\(expectedCid)")
        #expect(req.value(forHTTPHeaderField: "Cookie") == LoopbackCapability.process.cookieHeaderValue)
        #expect(req.httpShouldHandleCookies == false)
    }

    @Test(arguments: [401, 500])
    func failureStatusCodesReturnNotTold(statusCode: Int) async throws {
        let testPairing = pairing(clientCertPEM: testCACertPEM)
        let transport = RequestRecordingTransport(statusCode: statusCode)
        let retirement = JournalSelfRetirement(
            transport: { try await transport.send($0) },
            timeout: .seconds(2)
        )

        let outcome = await retirement.retire(pairing: testPairing, localPort: 54321)
        #expect(outcome == .notTold)
        #expect(await transport.requests.count == 1)
    }

    @Test func thrownTransportErrorReturnsNotTold() async throws {
        let testPairing = pairing(clientCertPEM: testCACertPEM)
        let retirement = JournalSelfRetirement(
            transport: { _ in throw URLError(.cannotConnectToHost) },
            timeout: .seconds(2)
        )

        let outcome = await retirement.retire(pairing: testPairing, localPort: 54321)
        #expect(outcome == .notTold)
    }

    @Test func transportTimeoutReturnsNotTold() async throws {
        let testPairing = pairing(clientCertPEM: testCACertPEM)
        let retirement = JournalSelfRetirement(
            transport: { _ in
                try await Task.sleep(for: .seconds(10))
                return (Data(), HTTPURLResponse(url: URL(string: "http://127.0.0.1")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            timeout: .milliseconds(50)
        )

        let outcome = await retirement.retire(pairing: testPairing, localPort: 54321)
        #expect(outcome == .notTold)
    }

    @Test(arguments: ["fixture-ca", "cert"])
    func unparseableClientCertReturnsNotToldWithoutCallingTransport(unparseablePEM: String) async throws {
        let testPairing = pairing(clientCertPEM: unparseablePEM)
        let transport = RequestRecordingTransport(statusCode: 200)
        let retirement = JournalSelfRetirement(
            transport: { try await transport.send($0) },
            timeout: .seconds(2)
        )

        let outcome = await retirement.retire(pairing: testPairing, localPort: 54321)
        #expect(outcome == .notTold)
        #expect(await transport.requests.isEmpty)
    }
}

private actor RequestRecordingTransport {
    private let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
