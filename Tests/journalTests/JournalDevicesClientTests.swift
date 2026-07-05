// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import journal

@Suite("JournalDevicesClient", .serialized)
struct JournalDevicesClientTests {
    @Test func listDevicesBuildsRequestAndDecodesRows() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: """
        {"devices":[{"display_label":"phone","device_label":"phone raw","kind":"mobile","role":"phone","network":"wifi","paired_at":123,"last_seen_at":"now","fingerprint":"abc123","observer_handle":"handle"}]}
        """)
        let client = makeClient(store: store)

        let devices = try await client.listDevices()
        let request = try #require(store.snapshotRequests().first)
        let row = try #require(devices.first)

        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/network/api/devices")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 5)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(row.displayLabel == "phone")
        #expect(row.deviceLabel == "phone raw")
        #expect(row.kind == "mobile")
        #expect(row.role == "phone")
        #expect(row.network == "wifi")
        #expect(row.pairedAt == "123")
        #expect(row.lastSeenAt == "now")
        #expect(row.fingerprint == "abc123")
        #expect(row.observerHandle == "handle")
    }

    @Test func startPairingPostsEmptyJSONWithTwentySecondTimeout() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"nonce":"n","pair_link":"https://go.solstone.app/p#abc","expires_in":300,"device_label":"","ca_fingerprint":"ca"}"#)
        let client = makeClient(store: store)

        let response = try await client.startPairing()
        let request = try #require(store.snapshotRequests().first)
        let body = try #require(store.requestBodies.first ?? nil)

        #expect(response.nonce == "n")
        #expect(response.pairLink == "https://go.solstone.app/p#abc")
        #expect(response.expiresIn == 300)
        #expect(response.deviceLabel == "")
        #expect(response.caFingerprint == "ca")
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/network/pair-start")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 20)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body == "{}")
    }

    @Test func nonceStatusUsesQueryParam() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"present":true,"used":false}"#)
        let client = makeClient(store: store)

        let response = try await client.nonceStatus(nonce: "nonce value")
        let request = try #require(store.snapshotRequests().first)

        #expect(response.present)
        #expect(!response.used)
        #expect(request.url?.path == "/app/network/api/pair/nonce-status")
        #expect(request.url?.query == "nonce=nonce%20value")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 5)
    }

    @Test func renameDevicePostsFingerprintAndLabel() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"ok":true}"#)
        let client = makeClient(store: store)

        try await client.renameDevice(fingerprint: "abc", label: "new name")
        let request = try #require(store.snapshotRequests().first)
        let body = try #require(store.requestBodies.first ?? nil)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]

        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/network/rename")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 5)
        #expect(object?["fingerprint"] as? String == "abc")
        #expect(object?["label"] as? String == "new name")
    }

    @Test func unpairDevicePostsFingerprintAndDecodesResponse() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"unpaired":true}"#)
        let client = makeClient(store: store)

        let response = try await client.unpairDevice(fingerprint: "abc")
        let request = try #require(store.snapshotRequests().first)
        let body = try #require(store.requestBodies.first ?? nil)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]

        #expect(response.unpaired)
        #expect(request.url?.absoluteString == "http://127.0.0.1:5015/app/network/unpair")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 5)
        #expect(object?["fingerprint"] as? String == "abc")
    }

    @Test func nonSuccessJSONEnvelopeThrowsServerEnvelope() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 400, body: #"{"error":"missing","reason_code":"missing_required_field","detail":"fingerprint required"}"#)
        let client = makeClient(store: store)

        do {
            _ = try await client.listDevices()
            Issue.record("expected server envelope")
        } catch let error as JournalDevicesClientError {
            #expect(error == .server(.init(
                error: "missing",
                reasonCode: "missing_required_field",
                detail: "fingerprint required"
            )))
        }
    }

    @Test func pairedDeviceNotFoundLiteralIsCaptured() async throws {
        #expect(JournalDevicesErrorEnvelope.pairedDeviceNotFound == "PAIRED_DEVICE_NOT_FOUND")
    }

    @Test func nonSuccessJSONWithoutEnvelopeThrowsServerStatus() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(statusCode: 503, body: #"{"status":"down"}"#)
        let client = makeClient(store: store)

        do {
            _ = try await client.listDevices()
            Issue.record("expected server status")
        } catch let error as JournalDevicesClientError {
            #expect(error == .serverStatus(503))
        }
    }

    @Test func redirectsAndNonJSONBodiesThrowNotReady() async throws {
        let redirectStore = ObserverURLProtocolStore()
        redirectStore.enqueue(statusCode: 302, body: #"{"ok":true}"#)
        let redirectClient = makeClient(store: redirectStore)

        do {
            _ = try await redirectClient.listDevices()
            Issue.record("expected redirect notReady")
        } catch let error as JournalDevicesClientError {
            #expect(error == .notReady)
        }

        let finalURLClient = makeFinalURLClient(finalPath: "/init", body: #"{"ok":true}"#)

        do {
            _ = try await finalURLClient.listDevices()
            Issue.record("expected redirected final URL notReady")
        } catch let error as JournalDevicesClientError {
            #expect(error == .notReady)
        }

        let htmlStore = ObserverURLProtocolStore()
        htmlStore.enqueue(body: "<!doctype html><html></html>")
        let htmlClient = makeClient(store: htmlStore)

        do {
            _ = try await htmlClient.listDevices()
            Issue.record("expected html notReady")
        } catch let error as JournalDevicesClientError {
            #expect(error == .notReady)
        }
    }

    @Test func validJSONWithWrongSuccessShapeThrowsDecoding() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(body: #"{"devices":[{"display_label":"missing fingerprint"}]}"#)
        let client = makeClient(store: store)

        do {
            _ = try await client.listDevices()
            Issue.record("expected decoding")
        } catch let error as JournalDevicesClientError {
            #expect(error == .decoding)
        }
    }

    @Test func transportErrorsUseStableNSErrorDomainAndCode() async throws {
        let store = ObserverURLProtocolStore()
        store.enqueue(error: URLError(.cannotConnectToHost))
        let client = makeClient(store: store)

        do {
            _ = try await client.listDevices()
            Issue.record("expected transport")
        } catch let error as JournalDevicesClientError {
            #expect(error == .transport("\(NSURLErrorDomain):\(URLError.cannotConnectToHost.rawValue)"))
        }
    }

    private func makeClient(store: ObserverURLProtocolStore) -> JournalDevicesClient {
        JournalDevicesClient(
            baseURL: "http://127.0.0.1:5015/",
            sessionConfiguration: observerURLProtocolConfiguration(store: store)
        )
    }

    private func makeFinalURLClient(finalPath: String, statusCode: Int = 200, body: String) -> JournalDevicesClient {
        FinalURLProtocol.configure(
            responseURL: URL(string: "http://127.0.0.1:5015\(finalPath)")!,
            statusCode: statusCode,
            body: body
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinalURLProtocol.self]
        return JournalDevicesClient(
            baseURL: "http://127.0.0.1:5015/",
            sessionConfiguration: configuration
        )
    }
}

private final class FinalURLProtocol: URLProtocol {
    private static let store = FinalURLProtocolStore()

    static func configure(responseURL: URL, statusCode: Int, body: String) {
        store.configure(responseURL: responseURL, statusCode: statusCode, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.store.snapshot()
        let response = HTTPURLResponse(
            url: stub.responseURL,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FinalURLProtocolStore: @unchecked Sendable {
    struct Stub: Sendable {
        var responseURL: URL
        var statusCode: Int
        var body: Data
    }

    private let lock = NSLock()
    private var stub = Stub(
        responseURL: URL(string: "http://127.0.0.1:5015/init")!,
        statusCode: 200,
        body: Data()
    )

    func configure(responseURL: URL, statusCode: Int, body: String) {
        lock.withLock {
            stub = Stub(responseURL: responseURL, statusCode: statusCode, body: Data(body.utf8))
        }
    }

    func snapshot() -> Stub {
        lock.withLock { stub }
    }
}
