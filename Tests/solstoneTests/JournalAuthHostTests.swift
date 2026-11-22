// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
import WebKit
@testable import solstone

@MainActor
private final class NoOpImportIntake: JournalImportIntake {
    func addHandedOver(_ urls: [URL], handoff: ImportHandoff) async -> ImportAddResult {
        ImportAddResult(outcomes: [])
    }

    func handoffStatus(_ id: String) async -> ImportHandoffStatus { .gone }
}

private func sendRawLoopbackHTTP(port: UInt16, request: String) throws -> String {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { Darwin.close(fd) }

    var tv = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    let data = Data(request.utf8)
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
            if n <= 0 { break }
            sent += n
        }
    }

    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        response.append(contentsOf: buf[..<n])
    }
    return String(decoding: response, as: UTF8.self)
}

@Suite("Journal OAuth broker host")
@MainActor
struct JournalAuthHostTests {
    private let base = URL(string: "http://127.0.0.1:52123/")!
    private let top = JournalImportSender(isMainFrame: true, scheme: "http", host: "127.0.0.1", port: 52123, isThisWebView: true)

    private func importContract() throws -> JournalImportContract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/solstone/Resources/import-host-contract.json"))
        return try #require(JournalImportContract(data: data))
    }

    private func authContract() throws -> JournalAuthContract {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/solstone/Resources/auth-host-contract.json"))
        return try #require(JournalAuthContract(data: data))
    }

    private func makeHost(
        openURL: @escaping JournalAuthURLOpener = { _ in true },
        listenerFactory: LoopbackListenerFactory? = nil
    ) throws -> (JournalImportHost, JournalAuthHost) {
        let auth = JournalAuthHost(
            contract: try authContract(),
            openExternalURL: openURL,
            listenerFactory: listenerFactory ?? { host, path, port in
                try LoopbackOAuthListener(host: host, path: path, port: port)
            }
        )
        let base = self.base
        let intake = NoOpImportIntake()
        let host = JournalImportHost(
            contract: try importContract(),
            authHost: auth,
            intake: { intake },
            liveBaseURL: { base }
        )
        return (host, auth)
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func decode(_ reply: String?) throws -> [String: Any] {
        let text = try #require(reply)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func packagedAuthContractMatchesFrozenSchemaAndAdvertisesAllTypes() throws {
        let contract = try authContract()
        #expect(contract.version == 2)
        #expect(contract.capability == "solstoneJournalHost")
        #expect(contract.prepare == "auth.prepare")
        #expect(contract.prepared == "auth.prepared")
        #expect(contract.authorize == "auth.authorize")
        #expect(contract.cancel == "auth.cancel")
        #expect(contract.result == "auth.result")
        #expect(contract.unsupported == "unsupported")
        #expect(JournalAuthContract(data: Data(#"{"version":1}"#.utf8)) == nil)

        let (host, _) = try makeHost()
        let script = try #require(host.userScript(for: base))
        #expect(script.isForMainFrameOnly)
        #expect(script.source.contains(#""prepare":"auth.prepare""#) || script.source.contains(#""prepare": "auth.prepare""#))
        #expect(script.source.contains("auth.prepare"))
        #expect(script.source.contains("auth.authorize"))
        #expect(script.source.contains("auth.cancel"))
    }

    @Test func happyPathLoopbackPrepareAuthorizeAndCallback() async throws {
        var openedURLs: [URL] = []
        let (host, _) = try makeHost(openURL: { url in
            openedURLs.append(url)
            return true
        })
        defer { host.tearDown() }

        let prepReply = try decode(await host.handle(body: json([
            "type": "auth.prepare",
            "id": "prep-1",
            "preferences": [
                ["mode": "custom_scheme", "uri": "solstone://oauth/callback"],
                ["mode": "loopback", "host": "127.0.0.1", "path": "/auth/callback", "port": 0],
            ],
        ]), from: top))

        #expect(prepReply["type"] as? String == "auth.prepared")
        #expect(prepReply["id"] as? String == "prep-1")
        #expect(prepReply["outcome"] as? String == "ready")
        #expect(prepReply["mode"] as? String == "loopback")
        let sessionID = try #require(prepReply["session_id"] as? String)
        let redirectURI = try #require(prepReply["redirect_uri"] as? String)
        let redirectComponents = try #require(URLComponents(string: redirectURI))
        #expect(redirectComponents.scheme == "http")
        #expect(redirectComponents.host == "127.0.0.1")
        #expect(redirectComponents.path == "/auth/callback")
        let port = try #require(redirectComponents.port.map(UInt16.init))

        let authorizeTask = Task {
            await host.handle(body: json([
                "type": "auth.authorize",
                "id": "auth-1",
                "session_id": sessionID,
                "authorize_url": "https://provider.example/oauth/authorize?client_id=test",
                "expected_state": "state_abc_123",
                "timeout_seconds": 30,
            ]), from: top)
        }

        while openedURLs.isEmpty { await Task.yield() }
        #expect(openedURLs == [URL(string: "https://provider.example/oauth/authorize?client_id=test")!])

        // Wrong Host, wrong path, non-GET, duplicate query keys, and wrong state must all be
        // rejected with 400/404 WITHOUT closing the listener or consuming the session.
        let wrongHost = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /auth/callback?code=c1&state=state_abc_123 HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n"
        )
        #expect(wrongHost.hasPrefix("HTTP/1.1 400 "))

        let wrongPath = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(wrongPath.hasPrefix("HTTP/1.1 404 "))

        let wrongMethod = try sendRawLoopbackHTTP(
            port: port,
            request: "POST /auth/callback?code=c1&state=state_abc_123 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(wrongMethod.hasPrefix("HTTP/1.1 400 "))

        let dupQuery = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /auth/callback?code=c1&state=state_abc_123&state=other HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(dupQuery.hasPrefix("HTTP/1.1 400 "))

        let wrongState = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /auth/callback?code=c1&state=wrong_state HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(wrongState.hasPrefix("HTTP/1.1 400 "))

        // Valid callback still succeeds after all five rejected probes.
        let okResponse = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /auth/callback?code=secret_code_42&state=state_abc_123 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(okResponse.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(okResponse.contains("Cache-Control: no-store"))
        #expect(okResponse.hasSuffix(JournalAuthValidation.successBody))

        let authReply = try decode(await authorizeTask.value)
        #expect(authReply["type"] as? String == "auth.result")
        #expect(authReply["id"] as? String == "auth-1")
        #expect(authReply["outcome"] as? String == "callback")
        #expect(authReply["callback_url"] as? String == "http://127.0.0.1:\(port)/auth/callback?code=secret_code_42&state=state_abc_123")
    }

    @Test func localhostPreferenceUsesLocalhostInRedirectAndHostCheck() async throws {
        var opened = false
        let (host, _) = try makeHost(openURL: { _ in opened = true; return true })
        defer { host.tearDown() }

        let prep = try decode(await host.handle(body: json([
            "type": "auth.prepare",
            "id": "prep-lh",
            "preferences": [["mode": "loopback", "host": "localhost", "path": "/cb"]],
        ]), from: top))
        #expect(prep["outcome"] as? String == "ready")
        let sessionID = try #require(prep["session_id"] as? String)
        let redirectURI = try #require(prep["redirect_uri"] as? String)
        #expect(redirectURI.hasPrefix("http://localhost:"))
        let port = try #require(URLComponents(string: redirectURI)?.port.map(UInt16.init))

        let authorizeTask = Task {
            await host.handle(body: json([
                "type": "auth.authorize",
                "id": "auth-lh",
                "session_id": sessionID,
                "authorize_url": "https://provider.example/auth",
                "expected_state": "st-lh",
            ]), from: top)
        }
        while !opened { await Task.yield() }

        // Host: 127.0.0.1:<port> must be rejected when localhost was requested.
        let mismatchedHost = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /cb?code=ok&state=st-lh HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        )
        #expect(mismatchedHost.hasPrefix("HTTP/1.1 400 "))

        let ok = try sendRawLoopbackHTTP(
            port: port,
            request: "GET /cb?error=access_denied&state=st-lh HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n"
        )
        #expect(ok.hasPrefix("HTTP/1.1 200 OK"))

        let reply = try decode(await authorizeTask.value)
        #expect(reply["outcome"] as? String == "callback")
        #expect(reply["callback_url"] as? String == "http://localhost:\(port)/cb?error=access_denied&state=st-lh")
    }

    @Test func invalidAuthorizeURLAndStateAndReusedSessionAreRefusedWithoutOpeningBrowser() async throws {
        var openedCount = 0
        let (host, _) = try makeHost(openURL: { _ in openedCount += 1; return true })
        defer { host.tearDown() }

        let prep = try decode(await host.handle(body: json([
            "type": "auth.prepare",
            "id": "prep-val",
            "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
        ]), from: top))
        let sessionID = try #require(prep["session_id"] as? String)

        let badURLs = [
            "http://provider.example/auth",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,hi",
            "https://user:pass@provider.example/auth",
            "https://user@provider.example/auth",
            "https://provider.example/has space",
            "https://provider.example/line\nbreak",
            "https://provider.example/" + String(repeating: "a", count: 8200),
            "",
        ]
        for (idx, url) in badURLs.enumerated() {
            let reply = try decode(await host.handle(body: json([
                "type": "auth.authorize",
                "id": "bad-url-\(idx)",
                "session_id": sessionID,
                "authorize_url": url,
                "expected_state": "valid_state",
            ]), from: top))
            #expect(reply["type"] as? String == "auth.result")
            #expect(reply["id"] as? String == "bad-url-\(idx)")
            #expect(reply["outcome"] as? String == "refused")
        }

        // Invalid states
        for badState in ["", "has space", "line\nfeed", String(repeating: "s", count: 1025)] {
            let reply = try decode(await host.handle(body: json([
                "type": "auth.authorize",
                "id": "bad-state",
                "session_id": sessionID,
                "authorize_url": "https://provider.example/auth",
                "expected_state": badState,
            ]), from: top))
            #expect(reply["outcome"] as? String == "refused")
        }

        // Unknown session_id
        let badSession = try decode(await host.handle(body: json([
            "type": "auth.authorize",
            "id": "bad-sess",
            "session_id": "nonexistent",
            "authorize_url": "https://provider.example/auth",
            "expected_state": "valid_state",
        ]), from: top))
        #expect(badSession["outcome"] as? String == "refused")
        #expect(openedCount == 0)
    }

    @Test func cancelSupersedingPrepareWebViewTeardownAndTimeoutSettlePendingAuthorize() async throws {
        // 1. Explicit auth.cancel settles in-flight auth.authorize as cancelled.
        do {
            var opened = false
            let (host, _) = try makeHost(openURL: { _ in opened = true; return true })
            defer { host.tearDown() }
            let prep = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p1",
                "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
            ]), from: top))
            let sid = try #require(prep["session_id"] as? String)
            let authTask = Task {
                await host.handle(body: json([
                    "type": "auth.authorize", "id": "a1", "session_id": sid,
                    "authorize_url": "https://provider.example/auth", "expected_state": "st1",
                ]), from: top)
            }
            while !opened { await Task.yield() }

            let cancelReply = try decode(await host.handle(body: json([
                "type": "auth.cancel", "id": "c1", "session_id": sid,
            ]), from: top))
            #expect(cancelReply["type"] as? String == "auth.result")
            #expect(cancelReply["id"] as? String == "c1")
            #expect(cancelReply["outcome"] as? String == "cancelled")

            let authReply = try decode(await authTask.value)
            #expect(authReply["type"] as? String == "auth.result")
            #expect(authReply["id"] as? String == "a1")
            #expect(authReply["outcome"] as? String == "cancelled")
        }

        // 2. Superseding auth.prepare settles prior in-flight auth.authorize as cancelled and frees fixed port.
        do {
            var opened = false
            let (host, _) = try makeHost(openURL: { _ in opened = true; return true })
            defer { host.tearDown() }
            let prep1 = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p2",
                "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
            ]), from: top))
            let sid1 = try #require(prep1["session_id"] as? String)
            let redirect1 = try #require(prep1["redirect_uri"] as? String)
            let port1 = try #require(URLComponents(string: redirect1)?.port)
            let authTask = Task {
                await host.handle(body: json([
                    "type": "auth.authorize", "id": "a2", "session_id": sid1,
                    "authorize_url": "https://provider.example/auth", "expected_state": "st2",
                ]), from: top)
            }
            while !opened { await Task.yield() }

            let prep2 = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p3",
                "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb", "port": port1]],
            ]), from: top))
            #expect(prep2["outcome"] as? String == "ready")
            #expect(prep2["redirect_uri"] as? String == "http://127.0.0.1:\(port1)/cb")

            let priorAuthReply = try decode(await authTask.value)
            #expect(priorAuthReply["id"] as? String == "a2")
            #expect(priorAuthReply["outcome"] as? String == "cancelled")
        }

        // 3. WebView teardown / navigation settles in-flight auth.authorize as cancelled.
        do {
            var opened = false
            let (host, _) = try makeHost(openURL: { _ in opened = true; return true })
            let prep = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p4",
                "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
            ]), from: top))
            let sid = try #require(prep["session_id"] as? String)
            let authTask = Task {
                await host.handle(body: json([
                    "type": "auth.authorize", "id": "a4", "session_id": sid,
                    "authorize_url": "https://provider.example/auth", "expected_state": "st4",
                ]), from: top)
            }
            while !opened { await Task.yield() }
            host.mainFrameCommitted()

            let reply = try decode(await authTask.value)
            #expect(reply["id"] as? String == "a4")
            #expect(reply["outcome"] as? String == "cancelled")
        }

        // 4. Timeout settles in-flight auth.authorize with outcome "timeout".
        do {
            var opened = false
            let (host, _) = try makeHost(openURL: { _ in opened = true; return true })
            defer { host.tearDown() }
            let prep = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p5",
                "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
            ]), from: top))
            let sid = try #require(prep["session_id"] as? String)
            let authReply = try decode(await host.handle(body: json([
                "type": "auth.authorize", "id": "a5", "session_id": sid,
                "authorize_url": "https://provider.example/auth", "expected_state": "st5",
                "timeout_seconds": 1,
            ]), from: top))
            #expect(opened)
            #expect(authReply["type"] as? String == "auth.result")
            #expect(authReply["id"] as? String == "a5")
            #expect(authReply["outcome"] as? String == "timeout")
        }
    }

    @Test func busyFixedPortFallsBackOrReturnsUnavailableAndCustomSchemeOnlyIsNoCompatibleMode() async throws {
        let (host, _) = try makeHost()
        defer { host.tearDown() }

        // Custom-scheme-only on desktop returns no_compatible_mode.
        let customOnly = try decode(await host.handle(body: json([
            "type": "auth.prepare", "id": "p-cs",
            "preferences": [["mode": "custom_scheme", "uri": "solstone://oauth/callback"]],
        ]), from: top))
        #expect(customOnly["outcome"] as? String == "no_compatible_mode")

        // Invalid loopback host / path / port is refused.
        for badPref in [
            ["mode": "loopback", "host": "0.0.0.0", "path": "/cb"],
            ["mode": "loopback", "host": "127.0.0.1", "path": "/a/../b"],
            ["mode": "loopback", "host": "127.0.0.1", "path": "no-leading-slash"],
            ["mode": "loopback", "host": "127.0.0.1", "path": "/cb", "port": 80],
        ] as [[String: Any]] {
            let reply = try decode(await host.handle(body: json([
                "type": "auth.prepare", "id": "p-bad", "preferences": [badPref],
            ]), from: top))
            #expect(reply["outcome"] as? String == "refused")
        }

        // Busy fixed port returns unavailable when no fallback preference exists.
        let blocker = try LoopbackOAuthListener(host: "127.0.0.1", path: "/held", port: 0)
        defer { blocker.stop() }
        let busyReply = try decode(await host.handle(body: json([
            "type": "auth.prepare", "id": "p-busy",
            "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb", "port": Int(blocker.boundPort)]],
        ]), from: top))
        #expect(busyReply["outcome"] as? String == "unavailable")

        // Busy fixed port skips to next ephemeral preference when provided.
        let fallbackReply = try decode(await host.handle(body: json([
            "type": "auth.prepare", "id": "p-fb",
            "preferences": [
                ["mode": "loopback", "host": "127.0.0.1", "path": "/cb", "port": Int(blocker.boundPort)],
                ["mode": "loopback", "host": "127.0.0.1", "path": "/cb", "port": 0],
            ],
        ]), from: top))
        #expect(fallbackReply["outcome"] as? String == "ready")
    }

    @Test func topFrameAndOriginIsolationAppliesToAuthMessages() async throws {
        let (host, _) = try makeHost()
        defer { host.tearDown() }

        let prepareBody = json([
            "type": "auth.prepare",
            "id": "iso-1",
            "preferences": [["mode": "loopback", "host": "127.0.0.1", "path": "/cb"]],
        ])

        var subframe = top
        subframe.isMainFrame = false
        var wrongPort = top
        wrongPort.port = 52124
        var wrongHost = top
        wrongHost.host = "evil.example"
        var wrongView = top
        wrongView.isThisWebView = false

        for sender in [subframe, wrongPort, wrongHost, wrongView] {
            #expect(await host.handle(body: prepareBody, from: sender) == nil)
        }
    }
}
