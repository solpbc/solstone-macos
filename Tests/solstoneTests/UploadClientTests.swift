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

    @Test func stripSegmentPrefixMatchesAndStrips() {
        let result = client.stripSegmentPrefix("143022_300_audio.m4a", segment: "143022_300")
        #expect(result == "audio.m4a")
    }

    @Test func stripSegmentPrefixNoMatchPassesThrough() {
        let result = client.stripSegmentPrefix("other_file.m4a", segment: "143022_300")
        #expect(result == "other_file.m4a")
    }

    @Test func stripSegmentPrefixHandlesMultiComponentSegment() {
        let result = client.stripSegmentPrefix("143022_300_display_1_screen.mp4", segment: "143022_300")
        #expect(result == "display_1_screen.mp4")
    }

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

        #expect(request.url?.absoluteString == "http://example.com/app/observer/ingest/event")
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

    @Test(arguments: [401, 403, 500])
    func getServerSegmentsThrowsServerErrorForHTTPFailure(statusCode: Int) async throws {
        store.reset()
        store.enqueue(statusCode: statusCode, body: #"{"error":"sensitive"}"#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        do {
            _ = try await uploadClient.getServerSegments(
                serverURL: "http://journal.example",
                serverKey: "secret",
                day: "20260703"
            )
            Issue.record("Expected UploadError.serverError")
        } catch let error as UploadError {
            guard case .serverError(let actualStatusCode, let message) = error else {
                Issue.record("Expected UploadError.serverError, got \(error)")
                return
            }
            #expect(actualStatusCode == statusCode)
            #expect(message == "segment listing")
        } catch {
            Issue.record("Expected UploadError.serverError, got \(error)")
        }
    }

    @Test(arguments: ["{}", "not json"])
    func getServerSegmentsThrowsInvalidResponseForMalformedSuccessBody(body: String) async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: body)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        do {
            _ = try await uploadClient.getServerSegments(
                serverURL: "http://journal.example",
                serverKey: "secret",
                day: "20260703"
            )
            Issue.record("Expected UploadError.invalidResponse")
        } catch let error as UploadError {
            guard case .invalidResponse = error else {
                Issue.record("Expected UploadError.invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected UploadError.invalidResponse, got \(error)")
        }
    }

    @Test func getServerSegmentsReturnsEmptyArrayForEmptyDay() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: "[]")
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        let segments = try await uploadClient.getServerSegments(
            serverURL: "http://journal.example",
            serverKey: "secret",
            day: "20260703"
        )

        #expect(segments.isEmpty)
    }

    @Test func getServerSegmentsParsesValidListing() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"""
        [{
          "key": "120000_300-1",
          "original_key": "120000_300",
          "files": [{
            "name": "audio.m4a",
            "submitted_name": "120000_300_audio.m4a",
            "sha256": "abc123",
            "size": 5,
            "status": "relocated",
            "current_path": "segments/audio.m4a"
          }]
        }]
        """#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        let segments = try await uploadClient.getServerSegments(
            serverURL: "http://journal.example",
            serverKey: "secret",
            day: "20260703"
        )

        let segment = try #require(segments.first)
        #expect(segments.count == 1)
        #expect(segment.key == "120000_300-1")
        #expect(segment.originalKey == "120000_300")
        let file = try #require(segment.files.first)
        #expect(segment.files.count == 1)
        #expect(file.name == "audio.m4a")
        #expect(file.submittedName == "120000_300_audio.m4a")
        #expect(file.sha256 == "abc123")
        #expect(file.size == 5)
        #expect(file.status == .unknown)
    }

    @Test func getServerSegmentsDecodedTerminalStatusCanProveHeld() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"""
        [{
          "key": "120000_300",
          "original_key": null,
          "files": [{
            "name": "audio.m4a",
            "submitted_name": "120000_300_audio.m4a",
            "sha256": "abc123",
            "size": 5,
            "status": "processed"
          }]
        }]
        """#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        let segments = try await uploadClient.getServerSegments(
            serverURL: "http://journal.example",
            serverKey: "secret",
            day: "20260703"
        )

        let segment = try #require(segments.first)
        let verdict = proveServerHoldsUploadFiles(
            localSHAByFilename: ["120000_300_audio.m4a": "abc123"],
            serverSegment: segment
        )
        #expect(verdict.isHeld == true)
    }

    @Test func getServerSegmentsDropsMalformedElementsInsideValidArray() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"""
        [
          {"files": []},
          {"key": "120000_300", "files": [{"name": "audio.m4a", "size": 5}]}
        ]
        """#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        let segments = try await uploadClient.getServerSegments(
            serverURL: "http://journal.example",
            serverKey: "secret",
            day: "20260703"
        )

        let segment = try #require(segments.first)
        #expect(segments.count == 1)
        #expect(segment.key == "120000_300")
        #expect(segment.files.count == 1)
    }

    @Test func uploadSegmentParsesSuccessfulIngestBodies() async throws {
        let ok = try await uploadResult(body: #"{"status":"ok","segment":{"key":"120000_300"}}"#)
        #expect(ok == UploadSuccessInfo(status: .ok, storedSegmentKey: "120000_300"))

        let collision = try await uploadResult(body: #"{"status":"collision","segment":{"key":"120000_300-1"}}"#)
        #expect(collision == UploadSuccessInfo(status: .collision, storedSegmentKey: "120000_300-1"))

        let duplicate = try await uploadResult(body: #"{"status":"duplicate","existing_segment":{"key":"115959_300"}}"#)
        #expect(duplicate == UploadSuccessInfo(status: .duplicate, storedSegmentKey: "115959_300"))

        let duplicateString = try await uploadResult(body: #"{"status":"duplicate","existing_segment":"115959_300"}"#)
        #expect(duplicateString == UploadSuccessInfo(status: .duplicate, storedSegmentKey: "115959_300"))

        let empty = try await uploadResult(body: "")
        #expect(empty == UploadSuccessInfo(status: .ok, storedSegmentKey: nil))

        let garbage = try await uploadResult(body: "not-json")
        #expect(garbage == UploadSuccessInfo(status: .ok, storedSegmentKey: nil))

        let noStatus = try await uploadResult(body: #"{"segment":{"key":"ignored"}}"#)
        #expect(noStatus == UploadSuccessInfo(status: .ok, storedSegmentKey: nil))

        let okMissingSegment = try await uploadResult(body: #"{"status":"ok"}"#)
        #expect(okMissingSegment == UploadSuccessInfo(status: .ok, storedSegmentKey: nil))

        let duplicateMissingExistingSegment = try await uploadResult(body: #"{"status":"duplicate"}"#)
        #expect(duplicateMissingExistingSegment == UploadSuccessInfo(status: .duplicate, storedSegmentKey: nil))

        let unknownMissingSegment = try await uploadResult(body: #"{"status":"surprise"}"#)
        #expect(unknownMissingSegment == UploadSuccessInfo(status: .unknown("surprise"), storedSegmentKey: nil))
    }

    private func uploadResult(body: String) async throws -> UploadSuccessInfo {
        UploadClientURLProtocol.store.reset()
        UploadClientURLProtocol.store.enqueue(statusCode: 200, body: body)
        let uploadClient = UploadClient(sessionConfiguration: uploadClientURLProtocolConfiguration())
        let root = try makeTempDirectory("upload-client-response")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("120000_300_audio.m4a")
        try Data("audio".utf8).write(to: file)

        let result = await uploadClient.uploadSegment(
            serverURL: "http://journal.example",
            serverKey: "secret",
            segmentURL: root,
            day: "20260703",
            segment: "120000_300",
            mediaFiles: [file]
        )

        guard case .success(let info) = result else {
            Issue.record("Expected successful upload result")
            throw UploadClientTestError.unexpectedResult
        }
        return info
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
