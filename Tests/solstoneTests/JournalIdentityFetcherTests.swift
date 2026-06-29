// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("JournalIdentityFetcher", .serialized)
struct JournalIdentityFetcherTests {
    @Test func fetchReturnsValidMark() async throws {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let mark = await fetcher.fetch(baseURL: "http://127.0.0.1:7071/")

        #expect(mark?.words == ["afoot", "unfixed"])
        let request = try #require(JournalIdentityURLProtocol.store.snapshotRequests().first)
        #expect(request.url?.path == "/app/link/api/identity")
        #expect(request.timeoutInterval == 2)
    }

    @Test func fetchReturnsNilWhenUncommitted() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: false, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let mark = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(mark == nil)
    }

    @Test func fetchReturnsNilWhenMarkNull() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: NSNull()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let mark = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(mark == nil)
    }

    @Test func fetchReturnsNilForNon2xx() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(statusCode: 404, body: #"{"error":"not found"}"#)
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let mark = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(mark == nil)
    }

    @Test func fetchReturnsNilForGarbageJSON() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: "not json")
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let mark = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(mark == nil)
    }

    @Test func fetchReturnsNilForInvalidMark() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        var mark = Self.markObject()
        var icon2 = mark["icon2"] as! [String: Any]
        icon2["rot"] = 90
        mark["icon2"] = icon2
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: mark))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let fetched = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(fetched == nil)
    }

    private static func identityJSON(committed: Bool, mark: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "committed": committed,
            "instance_id": "instance-123",
            "mark": mark,
        ])
        return String(data: data, encoding: .utf8)!
    }

    private static func markObject() -> [String: Any] {
        [
            "icon1": [
                "name": "bug",
                "color": ["hex": "#f59e0b"],
                "rot": 0,
                "svg": JournalMark.uiTestSample.icon1.svg,
            ],
            "icon2": [
                "name": "gem",
                "color": ["hex": "#84cc16"],
                "rot": 45,
                "svg": JournalMark.uiTestSample.icon2.svg,
            ],
            "words": ["afoot", "unfixed"],
        ]
    }
}

private final class JournalIdentityURLProtocol: URLProtocol {
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

private func journalIdentityURLProtocolConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JournalIdentityURLProtocol.self]
    config.timeoutIntervalForRequest = 0
    config.timeoutIntervalForResource = 0
    return config
}
