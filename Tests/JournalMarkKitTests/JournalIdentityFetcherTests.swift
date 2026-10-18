// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalMarkKit

@Suite("JournalIdentityFetcher", .serialized)
struct JournalIdentityFetcherTests {
    @Test func fetchReturnsValidMark() async throws {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071/")

        guard case .mark(let mark) = read else {
            Issue.record("expected .mark, got \(read)")
            return
        }
        #expect(mark.words == ["afoot", "unfixed"])
        let request = try #require(JournalIdentityURLProtocol.store.snapshotRequests().first)
        #expect(request.url?.path == "/app/link/api/identity")
        #expect(request.timeoutInterval == 2)
    }

    @Test func identityRedirectSendsNoFollowUpRequest() async throws {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        let destination = URL(string: "http://127.0.0.1:7072/app/link/api/identity")!
        JournalIdentityURLProtocol.store.enqueue(statusCode: 302, redirectURL: destination)
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let session = URLSession(configuration: journalIdentityURLProtocolConfiguration())
        defer { session.invalidateAndCancel() }
        let fetcher = JournalIdentityFetcher(session: session, prepareRequest: {
            $0.setValue("test-capability", forHTTPHeaderField: "Cookie")
        })

        let result = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "instance-123")

        // URLProtocol does not finish the original body after its redirect callback is refused.
        // Either a returned 302 or the bounded task timeout must remain a failed identity read.
        switch result {
        case .failed(.httpStatus(302)), .failed(.timeout): break
        default: Issue.record("redirect must not resolve identity: \(result)")
        }
        let requests = JournalIdentityURLProtocol.store.snapshotRequests()
        #expect(requests.count == 1)
        #expect(!requests.contains { $0.url == destination })
    }

    @Test func identityRejectsUnexpectedResponseURLBeforeDecoding() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(
            body: Self.identityJSON(committed: true, mark: Self.markObject()),
            responseURL: URL(string: "http://127.0.0.1:7072/app/link/api/identity")!
        )
        let session = URLSession(configuration: journalIdentityURLProtocolConfiguration())
        defer { session.invalidateAndCancel() }
        let fetcher = JournalIdentityFetcher(session: session)
        #expect(await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071") == .failed(.unexpectedResponseURL))
    }

    @Test func fetchRefusesAnotherJournalsMarkWhenAnInstanceIsExpected() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let other = await fetcher.fetch(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "instance-456")
        let own = await fetcher.fetch(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "INSTANCE-123")

        #expect(other == .unavailable)
        guard case .mark(let mark) = own else {
            Issue.record("expected .mark, got \(own)")
            return
        }
        #expect(mark.words == ["afoot", "unfixed"])
    }

    @Test func fetchReturnsUncommittedWhenNotCommitted() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: false, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(read == .uncommitted)
    }

    @Test func expectedIdentityRejectsMissingInstanceIDEvenWithTheSameMark() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        let body = Self.identityJSON(committed: true, mark: Self.markObject())
        var object = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        object.removeValue(forKey: "instance_id")
        let missingID = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        JournalIdentityURLProtocol.store.enqueue(body: missingID)
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))
        #expect(await fetcher.fetch(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "instance-123") == .unavailable)
    }

    @Test func fetchReturnsUnavailableWhenMarkNull() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: NSNull()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(read == .unavailable)
    }

    @Test func fetchReturnsUnavailableForNon2xx() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(statusCode: 404, body: #"{"error":"not found"}"#)
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(read == .unavailable)
    }

    @Test func fetchReturnsUnavailableForGarbageJSON() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: "not json")
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(read == .unavailable)
    }

    @Test func fetchReturnsUnavailableForInvalidMark() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        var mark = Self.markObject()
        var icon2 = mark["icon2"] as! [String: Any]
        icon2["rot"] = 90
        mark["icon2"] = icon2
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: mark))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let read = await fetcher.fetch(baseURL: "http://127.0.0.1:7071")

        #expect(read == .unavailable)
    }

    @Test func resolveIdentityReturnsValidMarkAndInstanceID() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "instance-123")
        guard case .mark(let mark, let instanceID) = res else {
            Issue.record("expected .mark, got \(res)")
            return
        }
        #expect(mark.words == ["afoot", "unfixed"])
        #expect(instanceID == "instance-123")
    }

    @Test func resolveIdentityReturnsUncommittedWithInstanceID() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: false, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .uncommitted(instanceID: "instance-123"))
    }

    @Test func resolveIdentityReturnsUncommittedWithNilInstanceID() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        let body = String(data: try! JSONSerialization.data(withJSONObject: ["committed": false]), encoding: .utf8)!
        JournalIdentityURLProtocol.store.enqueue(body: body)
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .uncommitted(instanceID: nil))
    }

    @Test func resolveIdentityRejectsMissingInstanceIDWhenCommitted() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        let body = String(data: try! JSONSerialization.data(withJSONObject: [
            "committed": true,
            "mark": Self.markObject()
        ]), encoding: .utf8)!
        JournalIdentityURLProtocol.store.enqueue(body: body)
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .failed(.missingInstanceID))
    }

    @Test func resolveIdentityRejectsInstanceMismatch() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: Self.identityJSON(committed: true, mark: Self.markObject()))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071", expectedInstanceID: "other-instance")
        #expect(res == .failed(.instanceMismatch))
    }

    @Test func resolveIdentityReturnsAbsentOnCannotConnect() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(error: URLError(.cannotConnectToHost))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .absent)
    }

    @Test func resolveIdentityReturnsFailedTimeout() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(error: URLError(.timedOut))
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .failed(.timeout))
    }

    @Test func resolveIdentityReturnsFailedHttpStatus() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(statusCode: 503, body: "error")
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .failed(.httpStatus(503)))
    }

    @Test func resolveIdentityReturnsFailedDecodeError() async {
        JournalIdentityURLProtocol.store.reset()
        defer { JournalIdentityURLProtocol.store.reset() }
        JournalIdentityURLProtocol.store.enqueue(body: "not json")
        let fetcher = JournalIdentityFetcher(session: URLSession(configuration: journalIdentityURLProtocolConfiguration()))

        let res = await fetcher.resolveIdentity(baseURL: "http://127.0.0.1:7071")
        #expect(res == .failed(.decodeError))
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

private final class JournalIdentityURLProtocolStore: @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var data: Data
        var error: URLError?
        var redirectURL: URL? = nil
        var responseURL: URL? = nil
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var requests: [URLRequest] = []

    func reset() {
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
        }
    }

    func enqueue(statusCode: Int = 200, body: String = "", error: URLError? = nil,
                 redirectURL: URL? = nil, responseURL: URL? = nil) {
        lock.withLock {
            responses.append(Response(statusCode: statusCode, data: Data(body.utf8), error: error,
                                      redirectURL: redirectURL, responseURL: responseURL))
        }
    }

    func next(for request: URLRequest) -> Response {
        lock.withLock {
            requests.append(request)
            if responses.isEmpty {
                return Response(statusCode: 500, data: Data(), error: nil)
            }
            return responses.removeFirst()
        }
    }

    func snapshotRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}

private final class JournalIdentityURLProtocol: URLProtocol {
    static let store = JournalIdentityURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.store.next(for: request)
        if let error = next.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: next.responseURL ?? request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        if let target = next.redirectURL {
            var followUp = request
            followUp.url = target
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            return
        }
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
