// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UserNotifications
@testable import solstone

private final class SolChatURLProtocolStore: @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var data: Data
        var error: URLError?
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String?] = []

    func reset() {
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
            requestBodies.removeAll()
        }
    }

    func enqueue(statusCode: Int = 200, body: String = "", error: URLError? = nil) {
        let response = Response(statusCode: statusCode, data: Data(body.utf8), error: error)
        lock.withLock {
            responses.append(response)
        }
    }

    func next(for request: URLRequest) -> Response {
        lock.withLock {
            requests.append(request)
            requestBodies.append(Self.bodyString(from: request))
            if responses.isEmpty {
                return Response(statusCode: 500, data: Data(), error: URLError(.badServerResponse))
            }
            return responses.removeFirst()
        }
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class SolChatURLProtocol: URLProtocol {
    static let store = SolChatURLProtocolStore()

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
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !next.data.isEmpty {
            client?.urlProtocol(self, didLoad: next.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor SolChatTestNotifier: SolChatNotifying {
    var authorizationResult = true
    var status: UNAuthorizationStatus = .authorized
    private(set) var requestedOptions: [UNAuthorizationOptions] = []
    private(set) var posts: [(identifier: String, title: String, body: String)] = []
    private(set) var removed: [String] = []

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        requestedOptions.append(options)
        return authorizationResult
    }

    func post(identifier: String, title: String, body: String) async {
        posts.append((identifier: identifier, title: title, body: body))
    }

    func removeDelivered(identifier: String) async {
        removed.append(identifier)
    }
}

@MainActor
private final class SolChatStateBox {
    var pendingValues: [SolChatRequestSummary?] = []
    var staleValues: [Bool] = []
    var openedURLs: [URL] = []

    var pending: SolChatRequestSummary? {
        pendingValues.last ?? nil
    }

    func setPending(_ value: SolChatRequestSummary?) {
        pendingValues.append(value)
    }

    func setStale(_ value: Bool) {
        staleValues.append(value)
    }
}

@Suite("SolChatBridge", .serialized)
@MainActor
struct SolChatBridgeTests {
    private func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SolChatURLProtocol.self]
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        return config
    }

    private func makeBridge(
        notificationsEnabled: Bool = false,
        state: SolChatStateBox,
        notifier: SolChatTestNotifier = SolChatTestNotifier(),
        staleThresholdSeconds: TimeInterval = 60,
        watchdogIntervalSeconds: TimeInterval = 5,
        backoffSeconds: [TimeInterval] = [1, 2, 4, 8, 16, 30],
        sleep: @escaping SolChatBridge.Sleeper = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) -> SolChatBridge {
        SolChatBridge(
            notificationsEnabled: notificationsEnabled,
            setPending: { [state] pending in state.setPending(pending) },
            setStale: { [state] stale in state.setStale(stale) },
            postOpenChat: { [state] url in
                await MainActor.run {
                    state.openedURLs.append(url)
                }
            },
            notifier: notifier,
            sessionConfiguration: makeConfiguration(),
            staleThresholdSeconds: staleThresholdSeconds,
            watchdogIntervalSeconds: watchdogIntervalSeconds,
            backoffSeconds: backoffSeconds,
            sleep: sleep
        )
    }

    private func requestFrame(
        id: String = "req-1",
        summary: String = "open the journal",
        day: String = "2026-05-09",
        eventIndex: Int = 42,
        isStale: Bool = false
    ) -> String {
        """
        data: {"kind":"sol_chat_request","request_id":"\(id)","summary":"\(summary)","day":"\(day)","event_index":\(eventIndex),"is_stale":\(isStale)}

        """
    }

    private func waitForPending(_ state: SolChatStateBox) async -> SolChatRequestSummary? {
        for _ in 0..<20 {
            if let pending = state.pending {
                return pending
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return state.pending
    }

    @Test func parserSingleLineDataFrameEmitsRequest() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame())
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state)

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-1")
        #expect(pending?.summary == "open the journal")
        let request = SolChatURLProtocol.store.requests.first
        #expect(request?.url?.absoluteString == "https://example.com/app/observer/callosum")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func parserMultiLineDataIsNewlineJoined() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: """
        data: {
        data: "kind":"sol_chat_request",
        data: "request_id":"req-2",
        data: "summary":"multi line",
        data: "day":"2026-05-09",
        data: "event_index":7
        data: }

        """)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state)

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-2")
        #expect(pending?.eventIndex == 7)
    }

    @Test func parserCommentLineIsSkippedAndFrameStillEmits() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: ": heartbeat\n\(requestFrame(id: "req-3"))")
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state)

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-3")
    }

    @Test func dispatchSupersededClearsKnownPendingAndNotification() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-4"))
        SolChatURLProtocol.store.enqueue(body: "data: {\"kind\":\"sol_chat_request_superseded\",\"request_id\":\"req-4\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        for _ in 0..<40 where !state.pendingValues.contains(where: { $0?.id == "req-4" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-4" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-4"))
    }

    @Test func dispatchOwnerChatOpenClearsPendingAndRemovesNotification() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-open"))
        SolChatURLProtocol.store.enqueue(body: "data: {\"kind\":\"owner_chat_open\",\"request_id\":\"req-open\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        for _ in 0..<40 where !state.pendingValues.contains(where: { $0?.id == "req-open" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-open" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-open"))
    }

    @Test func dispatchOwnerChatDismissedClearsPending() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-dismissed"))
        SolChatURLProtocol.store.enqueue(body: "data: {\"kind\":\"owner_chat_dismissed\",\"request_id\":\"req-dismissed\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        for _ in 0..<40 where !state.pendingValues.contains(where: { $0?.id == "req-dismissed" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-dismissed" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-dismissed"))
    }

    @Test func notificationsRespectOptInAndStaleFlags() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-5"))
        let enabledState = SolChatStateBox()
        let enabledNotifier = SolChatTestNotifier()
        let enabledBridge = makeBridge(notificationsEnabled: true, state: enabledState, notifier: enabledNotifier)

        await enabledBridge.configure(serverURL: "https://example.com", serverKey: "secret")
        _ = await waitForPending(enabledState)
        await enabledBridge.stop()
        #expect(await enabledNotifier.posts.count == 1)

        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-6", isStale: true))
        let staleState = SolChatStateBox()
        let staleNotifier = SolChatTestNotifier()
        let staleBridge = makeBridge(notificationsEnabled: true, state: staleState, notifier: staleNotifier)

        await staleBridge.configure(serverURL: "https://example.com", serverKey: "secret")
        try? await Task.sleep(for: .milliseconds(100))
        await staleBridge.stop()
        #expect(await staleNotifier.posts.isEmpty)
        #expect(staleState.pending == nil)

        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-7"))
        let disabledState = SolChatStateBox()
        let disabledNotifier = SolChatTestNotifier()
        let disabledBridge = makeBridge(notificationsEnabled: false, state: disabledState, notifier: disabledNotifier)

        await disabledBridge.configure(serverURL: "https://example.com", serverKey: "secret")
        _ = await waitForPending(disabledState)
        await disabledBridge.stop()
        #expect(await disabledNotifier.posts.isEmpty)
    }

    @Test func heartbeatStalenessFlipsAndNextFrameClears() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: "")
        let state = SolChatStateBox()
        let bridge = makeBridge(
            state: state,
            staleThresholdSeconds: 0.03,
            watchdogIntervalSeconds: 0.01,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        for _ in 0..<20 where !state.staleValues.contains(true) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        SolChatURLProtocol.store.enqueue(body: ": heartbeat\n\n")
        for _ in 0..<40 where state.staleValues.last != false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await bridge.stop()

        #expect(state.staleValues.contains(true))
        #expect(state.staleValues.contains(false))
    }

    @Test func reconnectTransportErrorUsesBackoffSequence() async {
        SolChatURLProtocol.store.reset()
        let state = SolChatStateBox()
        let sleepRecorder = SleepRecorder()
        let bridge = makeBridge(
            state: state,
            watchdogIntervalSeconds: 999,
            backoffSeconds: [1, 2, 4],
            sleep: { seconds in
                await sleepRecorder.record(seconds)
                try? await Task.sleep(for: .milliseconds(1))
            }
        )

        await bridge.configure(serverURL: "not a valid url", serverKey: "secret")
        for _ in 0..<80 where await sleepRecorder.values.filter({ $0 != 999 }).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let values = await sleepRecorder.values
        let backoffValues = values.filter { $0 != 999 }
        #expect(backoffValues.first == 1)
    }

    @Test func terminal401DoesNotRetry() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(statusCode: 401)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, backoffSeconds: [0.01])

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        #expect(SolChatURLProtocol.store.requests.count == 1)
    }

    @Test func terminal403DoesNotRetry() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(statusCode: 403)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, backoffSeconds: [0.01])

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        #expect(SolChatURLProtocol.store.requests.count == 1)
    }

    @Test func handleClickPostsOpensAndClearsPendingEvenOnServerError() async {
        SolChatURLProtocol.store.reset()
        SolChatURLProtocol.store.enqueue(body: requestFrame(id: "req-8", day: "2026-05-09", eventIndex: 99))
        SolChatURLProtocol.store.enqueue(statusCode: 500, body: "boom")
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state)

        await bridge.configure(serverURL: "https://example.com", serverKey: "secret")
        _ = await waitForPending(state)
        await bridge.handleClick(requestID: "req-8")
        await bridge.stop()

        #expect(state.openedURLs.last?.absoluteString == "https://example.com/app/chat/2026-05-09#event-99")
        #expect(state.pending == nil)
        let post = SolChatURLProtocol.store.requests.first { $0.httpMethod == "POST" }
        let postIndex = SolChatURLProtocol.store.requests.firstIndex { $0.httpMethod == "POST" }
        #expect(post?.url?.absoluteString == "https://example.com/api/chat/sol_chat_request/open")
        #expect(post?.httpMethod == "POST")
        #expect(post?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(postIndex.map { SolChatURLProtocol.store.requestBodies[$0] } == "{\"request_id\":\"req-8\"}")
    }
}

private actor SleepRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}
