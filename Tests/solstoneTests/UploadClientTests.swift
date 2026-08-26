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

    @Test func segmentsDayRequiresProtocolVersionThree() async throws {
        for body in [
            #"{"total":1,"items":[{"key":"120000_300","observed":true,"files":[{"name":"audio.m4a","submitted_name":"120000_300_audio.m4a","sha256":"abc","size":5,"status":"present"}]}]}"#,
            #"{"protocol_version":2,"total":1,"items":[{"key":"120000_300","observed":true,"files":[{"name":"audio.m4a","submitted_name":"120000_300_audio.m4a","sha256":"abc","size":5,"status":"present"}]}]}"#,
        ] {
            store.reset()
            store.enqueue(statusCode: 200, body: body)
            let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))
            await #expect(throws: UploadError.self) {
                _ = try await uploadClient.getSegmentsDay(serverURL: "http://journal.example", day: "20260703")
            }
        }
    }

    @Test func segmentsDayPreservesOutOfContractCustodyForFailClosedProof() async throws {
        store.reset()
        store.enqueue(statusCode: 200, body: #"{"protocol_version":3,"total":1,"items":[{"key":"120000_300","observed":true,"files":[{"name":"audio.m4a","submitted_name":"120000_300_audio.m4a","sha256":"abc","size":5,"status":"elsewhere"}]}]}"#)
        let uploadClient = UploadClient(sessionConfiguration: observerURLProtocolConfiguration(store: store))

        let response = try await uploadClient.getSegmentsDay(serverURL: "http://journal.example", day: "20260703")

        #expect(response.items.first?.files.first?.status == .outOfContract("elsewhere"))
    }

    @Test func multipartBuilderMakesEnvelopeCorrespondToFileParts() throws {
        let root = try makeTempDirectory("v3-upload-builder")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("120000_300_audio.m4a")
        let video = root.appendingPathComponent("120000_300_screen.mp4")
        try Data("audio".utf8).write(to: audio)
        try Data("video".utf8).write(to: video)
        let bodyURL = root.appendingPathComponent("body.tmp")
        let prepared = try IngestV3UploadRequestBuilder.build(
            baseURL: "http://journal.example",
            day: "20260703",
            segment: "120000_300",
            selectedFiles: [audio, video],
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
        for filename in [audio.lastPathComponent, video.lastPathComponent] {
            #expect(body.contains("\"submitted\":\"\(filename)\""))
            #expect(body.contains("name=\"files\"; filename=\"\(filename)\""))
        }
        #expect(body.components(separatedBy: "name=\"files\"; filename=").count == 3)
        #expect(!body.contains("name=\"platform\""))
    }

    @Test func uploadAcceptsOnlyDocumentedSuccessBodies() async throws {
        let ok = try await uploadResult(body: #"{"status":"ok","segment":"120000_300"}"#)
        #expect(ok == UploadSuccessInfo(status: .ok, storedSegmentKey: "120000_300"))
        let duplicate = try await uploadResult(body: #"{"status":"duplicate","existing_segment":"115959_300"}"#)
        #expect(duplicate == UploadSuccessInfo(status: .duplicate, storedSegmentKey: "115959_300"))
        let collision = try await uploadResult(body: #"{"status":"collision","segment":"120000_300"}"#)
        #expect(collision == UploadSuccessInfo(status: .collision, storedSegmentKey: "120000_300"))

        for body in ["", "not-json", #"{"status":"failed","error":"no"}"#, #"{"status":"conflict","error":"no"}"#, #"{"status":"unknown","segment":"120000_300"}"#, #"{"status":"ok"}"#] {
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
