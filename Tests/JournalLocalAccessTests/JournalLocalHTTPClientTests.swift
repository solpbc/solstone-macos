// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalLocalAccess

/// Answers by path and keeps what it was asked, so a test can say nothing went over TCP.
private final class FakeJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, String)]
    private var calls: [(path: String, route: JournalLocalRoute)] = []
    private var bodies: [String] = []
    var unreachable = false

    init(_ routes: [String: (Int, String)] = [:]) { self.routes = routes }

    func exchange(_ request: URLRequest, _ route: JournalLocalRoute) throws -> (Data, URLResponse) {
        try lock.withLock {
            let path = request.url!.path
            calls.append((path, route))
            bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            if unreachable { throw URLError(.cannotConnectToHost) }
            let (status, body) = routes[path] ?? (404, "")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    var tcpCalls: Int { lock.withLock { calls.filter { $0.route.socket == nil }.count } }
    var paths: [String] { lock.withLock { calls.map(\.path) } }
    var sentBodies: [String] { lock.withLock { bodies } }
}

private let socket = "/tmp/solstone-test/journal.sock"
private let record = JournalLocalRuntime(generation: "g1", journalRoot: "/tmp/own-journal", tcpPort: 15915, socketPath: socket)
private let liveBody = #"{"generation":"g1","journal_root":"/tmp/own-journal","tcp_port":15915,"socket_path":"\#(socket)"}"#

private func client(
    _ journal: FakeJournal,
    record: JournalLocalRuntime? = nil,
    socketExists: @escaping @Sendable (String) throws -> Bool = { _ in false },
    roots: [String] = []
) -> JournalLocalHTTPClient {
    JournalLocalHTTPClient(
        environment: ["SOLSTONE_JOURNAL_SOCKET": socket],
        ownRoots: { roots },
        socketExists: socketExists,
        readRecord: { _ in record },
        exchange: { try journal.exchange($0, $1) }
    )
}

private func journalFolder(instanceID: String?, relative: String = "link/state.json") throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let instanceID {
        let state = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"instance_id":"\#(instanceID)"}"#.utf8).write(to: state)
    }
    return root.path
}

struct JournalLocalAccessRouteTests {
    @Test func aLinkIsMadeOverTheOwnSocketForTheWholeDestinationAndReturnedUnchanged() async throws {
        let journal = FakeJournal([
            "/_solstone/local-runtime": (200, liveBody),
            "/_solstone/browser-link": (200, #"{"url":"http://localhost:15915/?auth=one-time","expires_in":60}"#),
        ])
        let client = client(journal, record: record, socketExists: { _ in true })

        let url = try await client.browserLink(path: "/app/chat?pane=owner#event-9", anchor: .ownJournal)

        #expect(url.absoluteString == "http://localhost:15915/?auth=one-time")
        #expect(journal.paths == ["/_solstone/local-runtime", "/_solstone/browser-link"])
        let body = try #require(journal.sentBodies.last.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] })
        #expect(body == ["path": "/app/chat?pane=owner#event-9"])
        #expect(journal.tcpCalls == 0)
    }

    @Test func aSocketJournalWithoutLinksGetsItsPlainAddress() async throws {
        let journal = FakeJournal(["/_solstone/local-runtime": (200, liveBody)])
        let client = client(journal, record: record, socketExists: { _ in true })

        let url = try await client.browserLink(path: "/app/backup", anchor: .ownJournal)

        #expect(url.absoluteString == "http://127.0.0.1:15915/app/backup")
        #expect(journal.tcpCalls == 0)
    }

    @Test(arguments: [
        (400, #"{"error":"too many unused links; try again in a minute"}"#),
        (500, ""),
        (200, #"{"url":"http://localhost:15916/?auth=x"}"#),
        (200, #"{"url":"http://127.0.0.1:15915/app/backup"}"#),
        (200, "not json"),
    ])
    func anyOtherAnswerFailsWithoutAPlainAddress(status: Int, body: String) async throws {
        let journal = FakeJournal(["/_solstone/local-runtime": (200, liveBody), "/_solstone/browser-link": (status, body)])
        let client = client(journal, record: record, socketExists: { _ in true })

        await #expect {
            _ = try await client.browserLink(path: "/", anchor: .ownJournal)
        } throws: { error in
            if case JournalLocalHTTPError.linkFailed = error { return true }
            return false
        }
    }

    @Test func aJournalWithNoSocketIsOpenedAtItsPlainAddressWithoutAskingForALink() async throws {
        let journal = FakeJournal(["/app/link/api/identity": (200, #"{"committed":true,"instance_id":"abc"}"#)])

        let url = try await client(journal).browserLink(path: "/", anchor: .instance("abc"))

        #expect(url.absoluteString == "http://127.0.0.1:5015/")
        #expect(!journal.paths.contains("/_solstone/browser-link"))
    }

    @Test func aSocketAnsweringForAnotherGenerationNeverFallsBackToTCP() async throws {
        let journal = FakeJournal(["/_solstone/local-runtime": (200, liveBody.replacingOccurrences(of: "g1", with: "g2"))])
        let client = client(journal, record: record, socketExists: { _ in true })

        await #expect(throws: JournalLocalHTTPError.notOwnJournal) { try await client.verify(.ownJournal) }
        #expect(journal.tcpCalls == 0)
    }

    @Test func aRefusedSocketNeverFallsBackToTCP() async throws {
        let journal = FakeJournal()
        let client = client(journal, record: record, socketExists: { _ in throw JournalLocalHTTPError.refused })

        await #expect(throws: JournalLocalHTTPError.refused) { try await client.verify(.ownJournal) }
        #expect(journal.paths.isEmpty)
    }

    @Test func aSocketThatCannotAnswerNeverFallsBackToTCP() async throws {
        let journal = FakeJournal()
        journal.unreachable = true
        let client = client(journal, record: record, socketExists: { _ in true })

        await #expect(throws: URLError.self) { try await client.verify(.ownJournal) }
        #expect(journal.tcpCalls == 0)
    }

    @Test func aSocketWithAnExpectedInstanceMustNameIt() async throws {
        let journal = FakeJournal([
            "/_solstone/local-runtime": (200, liveBody),
            "/app/link/api/identity": (200, #"{"committed":true,"instance_id":"other"}"#),
        ])
        let client = client(journal, record: record, socketExists: { _ in true })

        await #expect(throws: JournalLocalHTTPError.notOwnJournal) { try await client.verify(.instance("expected")) }
    }
}

struct JournalLocalAccessFallbackTests {
    @Test(arguments: ["link/state.json", "link/ca/state.json"])
    func withNoSocketAJournalNamingThisAccountsInstanceIsItsOwn(relative: String) async throws {
        let root = try journalFolder(instanceID: "own-id", relative: relative)
        let journal = FakeJournal(["/app/link/api/identity": (200, #"{"committed":true,"instance_id":"own-id"}"#)])

        let route = try await client(journal, roots: [root]).verify(.ownJournal)

        #expect(route == JournalLocalRoute(socket: nil, port: JournalLocalEndpoint.defaultTCPPort))
    }

    @Test func anotherAccountsJournalNeverMatches() async throws {
        let root = try journalFolder(instanceID: "own-id")
        let journal = FakeJournal(["/app/link/api/identity": (200, #"{"committed":true,"instance_id":"their-id"}"#)])

        await #expect(throws: JournalLocalHTTPError.notOwnJournal) {
            try await client(journal, roots: [root]).verify(.ownJournal)
        }
    }

    @Test func withNoOwnJournalFolderNothingCountsAsItsOwn() async throws {
        let journal = FakeJournal(["/app/link/api/identity": (200, #"{"committed":true,"instance_id":"their-id"}"#)])

        await #expect(throws: JournalLocalHTTPError.notOwnJournal) {
            try await client(journal, roots: ["/nonexistent/journal"]).verify(.ownJournal)
        }
    }

    @Test func nothingListeningStaysDifferentFromTheWrongJournal() async throws {
        let journal = FakeJournal()
        journal.unreachable = true

        await #expect(throws: URLError.self) { try await client(journal).verify(.ownJournal) }
    }

    @Test func aFirstRunJournalIsKnownByItsSetupFolder() async throws {
        let root = try journalFolder(instanceID: nil)
        let body = try String(data: JSONSerialization.data(withJSONObject: ["journal_path": root]), encoding: .utf8)!
        let journal = FakeJournal(["/app/link/api/identity": (302, ""), "/init/api/state": (200, body)])

        _ = try await client(journal, roots: [root]).verify(.ownJournal)
    }

    @Test func aFirstRunJournalInAnotherFolderIsNotItsOwn() async throws {
        let root = try journalFolder(instanceID: nil)
        let journal = FakeJournal(["/app/link/api/identity": (302, ""), "/init/api/state": (200, #"{"journal_path":"/Users/other/journal"}"#)])

        await #expect(throws: JournalLocalHTTPError.notOwnJournal) {
            try await client(journal, roots: [root]).verify(.ownJournal)
        }
    }

    @Test func anExpectedInstanceIsEnoughWithoutAFolder() async throws {
        let journal = FakeJournal(["/app/link/api/identity": (200, #"{"committed":true,"instance_id":"ABC"}"#)])
        _ = try await client(journal).verify(.instance("abc"))
    }
}

struct JournalHTTPFramingTests {
    let url = URL(string: "http://localhost/init")!

    @Test func fragmentedContentLengthCompletesWithoutEOF() throws {
        let message = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        for count in 0..<message.count {
            #expect(try JournalHTTPFraming.parse(Data(message.prefix(count)), url: url) == nil)
        }
        let result = try #require(try JournalHTTPFraming.parse(message, url: url))
        #expect(result.0 == Data("hello".utf8))
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func chunkExtensionsAndTrailersAreFramedAcrossFragments() throws {
        let message = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;test=yes\r\nabc\r\n2\r\nde\r\n0\r\nX-Finished: yes\r\n\r\n".utf8)
        for count in 0..<message.count {
            #expect(try JournalHTTPFraming.parse(Data(message.prefix(count)), url: url) == nil)
        }
        #expect(try JournalHTTPFraming.parse(message, url: url)?.0 == Data("abcde".utf8))
    }

    @Test func redirectIsReturnedNotFollowed() throws {
        let message = Data("HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\n\r\n".utf8)
        let result = try #require(try JournalHTTPFraming.parse(message, url: url))
        #expect((result.1 as? HTTPURLResponse)?.statusCode == 302)
        #expect(result.1.url == url)
    }

    @Test(arguments: [
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
    ])
    func invalidFramingIsRefused(_ message: String) {
        #expect(throws: (any Error).self) { try JournalHTTPFraming.parse(Data(message.utf8), url: url) }
    }
}
