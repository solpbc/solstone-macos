// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("UploadClient")
struct UploadClientTests {
    private let client = UploadClient()
    private let localNetworkMessage = "Can't reach local network. Open System Settings → Privacy & Security → Local Network and allow solstone."

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

    @Test func errorMessageUsesLocalNetworkMessageForLocalHosts() {
        #expect(UploadClient.errorMessage(for: URLError(.cannotConnectToHost), host: "myserver") == localNetworkMessage)
        #expect(UploadClient.errorMessage(for: URLError(.notConnectedToInternet), host: "192.168.1.20") == localNetworkMessage)
        #expect(UploadClient.errorMessage(for: URLError(.networkConnectionLost), host: "fe80::1") == localNetworkMessage)
        #expect(UploadClient.errorMessage(for: URLError(.timedOut), host: "nas.local") == localNetworkMessage)
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
}
