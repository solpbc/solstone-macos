// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("UploadClient", .serialized)
struct UploadClientTests {
    private let store = ObserverURLProtocolStore()
    private let client = UploadClient()
    private let localAddressMessage = "can't reach your journal at this address. check that it's running and reachable."

    @Test func isLocalNetworkHostRecognizesHostnameForms() {
        #expect(UploadClient.isLocalNetworkHost("nas.local"))
        #expect(UploadClient.isLocalNetworkHost("NAS.LOCAL."))
        #expect(UploadClient.isLocalNetworkHost("myserver"))
        #expect(UploadClient.isLocalNetworkHost("NAS"))
    }

    @Test func isLocalNetworkHostRecognizesPrivateIPv4Ranges() {
        #expect(UploadClient.isLocalNetworkHost("10.0.0.5"))
        #expect(UploadClient.isLocalNetworkHost("172.16.0.1"))
        #expect(UploadClient.isLocalNetworkHost("172.31.255.255"))
        #expect(UploadClient.isLocalNetworkHost("192.168.1.20"))
        #expect(UploadClient.isLocalNetworkHost("169.254.10.2"))
    }

    @Test func isLocalNetworkHostRecognizesCGNATRange() {
        #expect(UploadClient.isLocalNetworkHost("100.64.0.1"))
        #expect(UploadClient.isLocalNetworkHost("100.121.250.106"))
        #expect(UploadClient.isLocalNetworkHost("100.127.255.255"))
        #expect(!UploadClient.isLocalNetworkHost("100.63.255.255"))
        #expect(!UploadClient.isLocalNetworkHost("100.128.0.0"))
    }

    @Test func isLocalNetworkHostRecognizesPrivateIPv6Ranges() {
        #expect(UploadClient.isLocalNetworkHost("fe80::1"))
        #expect(UploadClient.isLocalNetworkHost("FE80::ABCD"))
        #expect(UploadClient.isLocalNetworkHost("fc00::1"))
        #expect(UploadClient.isLocalNetworkHost("fd12:3456::1"))
    }

    @Test func isLocalNetworkHostRejectsLoopbackAndPublicHosts() {
        #expect(!UploadClient.isLocalNetworkHost("localhost"))
        #expect(!UploadClient.isLocalNetworkHost("127.0.0.1"))
        #expect(!UploadClient.isLocalNetworkHost("::1"))
        #expect(!UploadClient.isLocalNetworkHost("8.8.8.8"))
        #expect(!UploadClient.isLocalNetworkHost("172.15.0.1"))
        #expect(!UploadClient.isLocalNetworkHost("172.32.0.1"))
        #expect(!UploadClient.isLocalNetworkHost("api.solstone.app"))
        #expect(!UploadClient.isLocalNetworkHost("example.com"))
    }

    @Test func isLocalNetworkHostRejectsInvalidIPv4Literals() {
        #expect(!UploadClient.isLocalNetworkHost("192.168.1"))
        #expect(!UploadClient.isLocalNetworkHost("999.1.1.1"))
    }

    @Test func errorMessageUsesLocalAddressMessageForLocalHosts() {
        #expect(UploadClient.errorMessage(for: URLError(.cannotConnectToHost), host: "myserver") == localAddressMessage)
        #expect(UploadClient.errorMessage(for: URLError(.notConnectedToInternet), host: "192.168.1.20") == localAddressMessage)
        #expect(UploadClient.errorMessage(for: URLError(.networkConnectionLost), host: "fe80::1") == localAddressMessage)
        #expect(UploadClient.errorMessage(for: URLError(.timedOut), host: "nas.local") == localAddressMessage)
    }

    @Test func errorMessagePreservesNonLocalStrings() {
        #expect(UploadClient.errorMessage(for: URLError(.cannotConnectToHost), host: "localhost") == "can't reach your journal")
        #expect(UploadClient.errorMessage(for: URLError(.cannotConnectToHost), host: "example.com") == "can't reach your journal")
        #expect(UploadClient.errorMessage(for: URLError(.notConnectedToInternet), host: "example.com") == "No internet connection")
        #expect(UploadClient.errorMessage(for: URLError(.cannotFindHost), host: "nas.local") == "journal not found")
        #expect(UploadClient.errorMessage(for: URLError(.timedOut), host: "localhost") == "Connection timed out")
    }

    @Test func errorMessageFallsBackToLocalizedDescriptionForUnhandledCodes() {
        let error = URLError(.badServerResponse)
        #expect(UploadClient.errorMessage(for: error, host: "example.com") == error.localizedDescription)
    }

    @Test(arguments: [true, false])
    func buildObserverStatusRequestLegacyShape(paused: Bool) throws {
        let request = try client.buildObserverStatusRequest(
            serverURL: "http://example.com",
            serverKey: "secret123",
            paused: paused,
            health: nil
        )

        #expect(request.url?.absoluteString == "http://example.com/app/devices/ingest/event")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 5)

        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload.count == 4)
        #expect(payload["tract"] as? String == "observe")
        #expect(payload["event"] as? String == "status")
        #expect(payload["paused"] as? Bool == paused)
        #expect(payload["source"] as? String == "heartbeat")
    }

    @Test func buildObserverStatusRequestIncludesHealthSnapshot() throws {
        let lastSync = Date(timeIntervalSince1970: 1_700_000_000)
        let health = ObserverHealthSnapshot(
            name: "desktop-one",
            streamType: "desktop",
            version: "1.2.3",
            uptimeSeconds: 42,
            lastSuccessfulSync: lastSync,
            pendingQueueDepth: 7,
            recentErrorCount: 3,
            lastErrorReason: "http_503"
        )

        let request = try client.buildObserverStatusRequest(
            serverURL: "http://example.com",
            serverKey: "secret123",
            paused: false,
            health: health
        )

        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(payload.keys) == [
            "tract",
            "event",
            "paused",
            "source",
            "name",
            "stream_type",
            "version",
            "uptime",
            "last_successful_sync",
            "pending_queue_depth",
            "recent_error_count",
            "last_error_reason"
        ])
        #expect(payload["tract"] as? String == "observe")
        #expect(payload["event"] as? String == "status")
        #expect(payload["paused"] as? Bool == false)
        #expect(payload["source"] as? String == "heartbeat")
        #expect(payload["name"] as? String == "desktop-one")
        #expect(payload["stream_type"] as? String == "desktop")
        #expect(payload["version"] as? String == "1.2.3")
        #expect(payload["uptime"] as? Int == 42)
        #expect(payload["last_successful_sync"] as? String == ISO8601DateFormatter().string(from: lastSync))
        #expect(payload["pending_queue_depth"] as? Int == 7)
        #expect(payload["recent_error_count"] as? Int == 3)
        #expect(payload["last_error_reason"] as? String == "http_503")
    }

    @Test func buildObserverStatusRequestOmitsNilHealthFields() throws {
        let health = ObserverHealthSnapshot(
            name: nil,
            streamType: "desktop",
            version: "1.2.3",
            uptimeSeconds: 42,
            lastSuccessfulSync: nil,
            pendingQueueDepth: 0,
            recentErrorCount: 0,
            lastErrorReason: nil
        )

        let request = try client.buildObserverStatusRequest(
            serverURL: "http://example.com",
            serverKey: "secret123",
            paused: true,
            health: health
        )

        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(payload.keys) == [
            "tract",
            "event",
            "paused",
            "source",
            "stream_type",
            "version",
            "uptime",
            "pending_queue_depth",
            "recent_error_count"
        ])
        #expect(payload["name"] == nil)
        #expect(payload["last_successful_sync"] == nil)
        #expect(payload["last_error_reason"] == nil)
    }

    @Test func manifestReadUsesProtocolHeaderWithoutBearer() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"{"days":{}}"#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        let manifest = try await uploadClient.getManifest(serverURL: "http://journal.example")
        #expect(manifest.days.isEmpty)
        let request = try #require(store.snapshotRequests().first)
        #expect(request.url?.path == IngestProtocolV3.manifestPath)
        #expect(request.value(forHTTPHeaderField: IngestProtocolV3.headerName) == "3")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func malformedV3ReadFailsWholeResponse() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"{"protocol_version":3,"total":1,"items":[{"key":"120000_300"}]}"#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
        await #expect(throws: UploadError.self) {
            _ = try await uploadClient.getSegmentsDay(serverURL: "http://journal.example", day: "20260703")
        }
    }

    @Test func multipartBuilderMakesEnvelopeCorrespondToFileParts() throws {
        let root = try makeTempDirectory("v3-upload-builder")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: file)
        let bodyURL = root.appendingPathComponent("body.tmp")
        let prepared = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://journal.example",
            day: "20260703",
            segment: "120000_300",
            selectedFiles: [file],
            meta: ["source": .string("probe")],
            boundary: "fixed-boundary",
            bodyURL: bodyURL
        )
        let body = try String(contentsOf: bodyURL)
        #expect(prepared.request.url?.path == IngestProtocolV3.uploadPath)
        #expect(prepared.request.value(forHTTPHeaderField: IngestProtocolV3.headerName) == "3")
        #expect(prepared.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body.contains("name=\"envelope\""))
        #expect(body.contains("\"day\":\"20260703\""))
        #expect(body.contains("\"segment\":\"120000_300\""))
        #expect(body.contains("\"submitted\":\"120000_300_audio.m4a\""))
        #expect(body.contains("name=\"files\"; filename=\"120000_300_audio.m4a\""))
        #expect(!body.contains("name=\"platform\""))
    }

    @Test func uploadAcceptsOnlyDocumentedSuccessBodies() async throws {
        let ok = try await uploadResult(body: #"{"status":"ok","segment":"120000_300"}"#)
        #expect(ok == UploadSuccessInfo(status: .ok, storedSegmentKey: "120000_300"))
        let duplicate = try await uploadResult(body: #"{"status":"duplicate","existing_segment":"115959_300"}"#)
        #expect(duplicate == UploadSuccessInfo(status: .duplicate, storedSegmentKey: "115959_300"))

        for body in ["", "not-json", #"{"status":"failed","error":"no"}"#, #"{"status":"conflict","error":"no"}"#, #"{"status":"ok"}"#] {
            let result = try await uploadRawResult(body: body)
            guard case .failure = result else {
                Issue.record("Expected failed v3 upload body")
                continue
            }
        }
    }

    private func uploadResult(body: String) async throws -> UploadSuccessInfo {
        let result = try await uploadRawResult(body: body)

        guard case .success(let info) = result else {
            Issue.record("Expected successful upload result")
            throw UploadClientTestError.unexpectedResult
        }
        return info
    }

    private func uploadRawResult(body: String) async throws -> UploadResult {
        UploadClientURLProtocol.store.reset()
        UploadClientURLProtocol.store.enqueue(statusCode: 200, body: body)
        let uploadClient = UploadClient(sessionConfiguration: uploadClientURLProtocolConfiguration())
        let root = try makeTempDirectory("upload-client-response")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: file)

        let result = await uploadClient.uploadSegment(
            serverURL: "http://journal.example",
            day: "20260703",
            segment: "120000_300",
            mediaFiles: [file],
            metadata: nil
        )
        return result
    }
}

private enum UploadClientTestError: Error {
    case unexpectedResult
}

private final class UploadClientURLProtocol: URLProtocol {
    static let store = ObserverURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
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
        if !next.data.isEmpty {
            client?.urlProtocol(self, didLoad: next.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func uploadClientURLProtocolConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UploadClientURLProtocol.self]
    config.timeoutIntervalForRequest = 0
    config.timeoutIntervalForResource = 0
    return config
}
