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
        var finishes: Bool
    }

    let serverKey = "secret-\(UUID().uuidString)"

    var authorizationHeader: String {
        "Bearer \(serverKey)"
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var stopLoadingEvents = 0
    private(set) var requests: [URLRequest] = []
    private(set) var requestBodies: [String?] = []

    var requestCount: Int {
        lock.withLock {
            requests.count
        }
    }

    var stopLoadingCount: Int {
        lock.withLock {
            stopLoadingEvents
        }
    }

    func enqueue(statusCode: Int = 200, body: String = "", error: URLError? = nil, finishes: Bool = true) {
        let response = Response(statusCode: statusCode, data: Data(body.utf8), error: error, finishes: finishes)
        lock.withLock {
            responses.append(response)
        }
    }

    func next(for request: URLRequest) -> Response {
        lock.withLock {
            requests.append(request)
            requestBodies.append(Self.bodyString(from: request))
            if responses.isEmpty {
                return Response(statusCode: 500, data: Data(), error: URLError(.badServerResponse), finishes: true)
            }
            return responses.removeFirst()
        }
    }

    func recordStopLoading() {
        lock.withLock {
            stopLoadingEvents += 1
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

private final class SolChatURLProtocolStoreRegistry: @unchecked Sendable {
    static let shared = SolChatURLProtocolStoreRegistry()

    private let lock = NSLock()
    private var stores: [String: SolChatURLProtocolStore] = [:]

    func register(_ store: SolChatURLProtocolStore) {
        // Keep entries for the process lifetime so late URLProtocol callbacks stay routed to their originating test.
        lock.withLock { stores[store.authorizationHeader] = store }
    }

    func store(for request: URLRequest) -> SolChatURLProtocolStore? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization") else {
            return nil
        }
        return lock.withLock { stores[authorization] }
    }
}

private final class SolChatURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let store = SolChatURLProtocolStoreRegistry.shared.store(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let next = store.next(for: request)
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
        if next.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        SolChatURLProtocolStoreRegistry.shared.store(for: request)?.recordStopLoading()
    }
}

private actor SolChatTestNotifier: SolChatNotifying {
    var authorizationResult = true
    var status: UNAuthorizationStatus = .authorized
    private(set) var requestedOptions: [UNAuthorizationOptions] = []
    private(set) var posts: [(identifier: String, title: String, body: String, sound: Bool)] = []
    private(set) var removed: [String] = []

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        requestedOptions.append(options)
        return authorizationResult
    }

    func post(identifier: String, title: String, body: String, sound: Bool) async {
        posts.append((identifier: identifier, title: title, body: body, sound: sound))
    }

    func removeDelivered(identifier: String) async {
        removed.append(identifier)
    }
}

@MainActor
private final class SolChatStateBox {
    var pendingValues: [SolChatRequestSummary?] = []
    var staleValues: [Bool] = []
    var openedDestinations: [JournalWindowDestination] = []

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
    private func makeConfiguration(store: SolChatURLProtocolStore) -> URLSessionConfiguration {
        SolChatURLProtocolStoreRegistry.shared.register(store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SolChatURLProtocol.self]
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        return config
    }

    private func makeBridge(
        notificationsEnabled: Bool = false,
        resolver: HomeBaseURLResolver = HomeBaseURLResolver { .url("https://example.com") },
        state: SolChatStateBox,
        store: SolChatURLProtocolStore,
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
            resolver: resolver,
            setPending: { [state] pending in state.setPending(pending) },
            setStale: { [state] stale in state.setStale(stale) },
            postOpenJournalDestination: { [state] destination in
                await MainActor.run {
                    state.openedDestinations.append(destination)
                }
            },
            notifier: notifier,
            sessionConfiguration: makeConfiguration(store: store),
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
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame())
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store)

        await bridge.configure(serverKey: store.serverKey)
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-1")
        #expect(pending?.summary == "open the journal")
        let request = store.requests.first
        #expect(request?.url?.absoluteString == "https://example.com/app/devices/callosum")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == store.authorizationHeader)
    }

    @Test func parserMultiLineDataIsNewlineJoined() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: """
        data: {
        data: "kind":"sol_chat_request",
        data: "request_id":"req-2",
        data: "summary":"multi line",
        data: "day":"2026-05-09",
        data: "event_index":7
        data: }

        """)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store)

        await bridge.configure(serverKey: store.serverKey)
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-2")
        #expect(pending?.eventIndex == 7)
    }

    @Test func parserCommentLineIsSkippedAndFrameStillEmits() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: ": heartbeat\n\(requestFrame(id: "req-3"))")
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store)

        await bridge.configure(serverKey: store.serverKey)
        let pending = await waitForPending(state)
        await bridge.stop()

        #expect(pending?.id == "req-3")
    }

    @Test func subscribeUsesResolverLoopbackTarget() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: "")
        let state = SolChatStateBox()
        let bridge = makeBridge(
            resolver: HomeBaseURLResolver { .url("http://127.0.0.1:24681") },
            state: state,
            store: store,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        try? await waitUntil(timeout: .seconds(2)) {
            store.requests.count >= 1
        }
        await bridge.stop()

        let request = store.requests.first
        #expect(request?.url?.host == "127.0.0.1")
        #expect(request?.url?.port == 24681)
        #expect(request?.url?.path == "/app/devices/callosum")
    }

    @Test func subscribeUsesResolverStaticTarget() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: "")
        let state = SolChatStateBox()
        let bridge = makeBridge(
            resolver: HomeBaseURLResolver { .url("https://journal.example:9443") },
            state: state,
            store: store,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        try? await waitUntil(timeout: .seconds(2)) {
            store.requests.count >= 1
        }
        await bridge.stop()

        let request = store.requests.first
        #expect(request?.url?.host == "journal.example")
        #expect(request?.url?.port == 9443)
        #expect(request?.url?.path == "/app/devices/callosum")
    }

    @Test func heldResolverBacksOffWithoutCallosumRequest() async {
        let store = SolChatURLProtocolStore()
        let state = SolChatStateBox()
        let sleepRecorder = SleepRecorder()
        let bridge = makeBridge(
            resolver: HomeBaseURLResolver { .held },
            state: state,
            store: store,
            watchdogIntervalSeconds: 999,
            backoffSeconds: [0.01],
            sleep: { seconds in
                await sleepRecorder.record(seconds)
                try? await Task.sleep(for: .milliseconds(1))
            }
        )

        await bridge.configure(serverKey: store.serverKey)
        try? await waitUntil(timeout: .seconds(2)) {
            await !sleepRecorder.values.isEmpty
        }
        await bridge.stop()

        #expect(store.requests.isEmpty)
    }

    @Test func dispatchSupersededClearsKnownPendingAndNotification() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame(id: "req-4"))
        store.enqueue(body: "data: {\"kind\":\"sol_chat_request_superseded\",\"request_id\":\"req-4\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            store: store,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        for _ in 0..<120 where !state.pendingValues.contains(where: { $0?.id == "req-4" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-4" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-4"))
    }

    @Test func dispatchOwnerChatOpenClearsPendingAndRemovesNotification() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame(id: "req-open"))
        store.enqueue(body: "data: {\"kind\":\"owner_chat_open\",\"request_id\":\"req-open\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            store: store,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        for _ in 0..<120 where !state.pendingValues.contains(where: { $0?.id == "req-open" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-open" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-open"))
    }

    @Test func dispatchOwnerChatDismissedClearsPending() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame(id: "req-dismissed"))
        store.enqueue(body: "data: {\"kind\":\"owner_chat_dismissed\",\"request_id\":\"req-dismissed\"}\n\n")
        let state = SolChatStateBox()
        let notifier = SolChatTestNotifier()
        let bridge = makeBridge(
            notificationsEnabled: true,
            state: state,
            store: store,
            notifier: notifier,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        for _ in 0..<120 where !state.pendingValues.contains(where: { $0?.id == "req-dismissed" }) || state.pending != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let removed = await notifier.removed
        #expect(state.pendingValues.contains { $0?.id == "req-dismissed" })
        #expect(state.pending == nil)
        #expect(removed.contains("req-dismissed"))
    }

    @Test func notificationsRespectOptInAndStaleFlags() async {
        let enabledStore = SolChatURLProtocolStore()
        enabledStore.enqueue(body: requestFrame(id: "req-5"))
        let enabledState = SolChatStateBox()
        let enabledNotifier = SolChatTestNotifier()
        let enabledBridge = makeBridge(
            notificationsEnabled: true,
            state: enabledState,
            store: enabledStore,
            notifier: enabledNotifier
        )

        await enabledBridge.configure(serverKey: enabledStore.serverKey)
        _ = await waitForPending(enabledState)
        await enabledBridge.stop()
        let enabledPosts = await enabledNotifier.posts
        #expect(enabledPosts.count == 1)
        #expect(enabledPosts.first?.sound == true)

        let staleStore = SolChatURLProtocolStore()
        staleStore.enqueue(body: requestFrame(id: "req-6", isStale: true))
        let staleState = SolChatStateBox()
        let staleNotifier = SolChatTestNotifier()
        let staleBridge = makeBridge(
            notificationsEnabled: true,
            state: staleState,
            store: staleStore,
            notifier: staleNotifier
        )

        await staleBridge.configure(serverKey: staleStore.serverKey)
        try? await Task.sleep(for: .milliseconds(100))
        await staleBridge.stop()
        #expect(await staleNotifier.posts.isEmpty)
        #expect(staleState.pending == nil)

        let disabledStore = SolChatURLProtocolStore()
        disabledStore.enqueue(body: requestFrame(id: "req-7"))
        let disabledState = SolChatStateBox()
        let disabledNotifier = SolChatTestNotifier()
        let disabledBridge = makeBridge(
            notificationsEnabled: false,
            state: disabledState,
            store: disabledStore,
            notifier: disabledNotifier
        )

        await disabledBridge.configure(serverKey: disabledStore.serverKey)
        _ = await waitForPending(disabledState)
        await disabledBridge.stop()
        #expect(await disabledNotifier.posts.isEmpty)
    }

    @Test func heartbeatStalenessFlipsAndNextFrameClears() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: "")
        let state = SolChatStateBox()
        let bridge = makeBridge(
            state: state,
            store: store,
            staleThresholdSeconds: 0.03,
            watchdogIntervalSeconds: 0.01,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        for _ in 0..<20 where !state.staleValues.contains(true) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        store.enqueue(body: ": heartbeat\n\n")
        for _ in 0..<40 where state.staleValues.last != false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await bridge.stop()

        #expect(state.staleValues.contains(true))
        #expect(state.staleValues.contains(false))
    }

    @Test func staleWatchdogRelaunchesWedgedSubscriptionOncePerEpisode() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: "", finishes: false)
        store.enqueue(body: ": heartbeat\n", finishes: false)
        store.enqueue(body: "", finishes: false)
        let state = SolChatStateBox()
        let bridge = makeBridge(
            state: state,
            store: store,
            staleThresholdSeconds: 0.03,
            watchdogIntervalSeconds: 0.01,
            backoffSeconds: [0.01]
        )

        await bridge.configure(serverKey: store.serverKey)
        try? await waitUntil(timeout: .seconds(2)) {
            let requestCount = store.requestCount
            let stopLoadingCount = store.stopLoadingCount
            let staleValues = await MainActor.run { state.staleValues }
            return requestCount >= 2
                && stopLoadingCount >= 1
                && staleValues.contains(true)
        }
        try? await waitUntil(timeout: .seconds(2)) {
            let requestCount = store.requestCount
            let stopLoadingCount = store.stopLoadingCount
            let staleValues = await MainActor.run { state.staleValues }
            return requestCount >= 3
                && stopLoadingCount >= 2
                && staleValues.contains(false)
                && staleValues.filter { $0 }.count >= 2
        }
        let requestCountAfterSecondEpisode = store.requestCount
        let stopLoadingCountAfterSecondEpisode = store.stopLoadingCount
        try? await Task.sleep(for: .milliseconds(120))
        let boundedRequestCount = store.requestCount
        let boundedStopLoadingCount = store.stopLoadingCount
        let staleValues = state.staleValues
        await bridge.stop()

        #expect(requestCountAfterSecondEpisode == 3)
        #expect(stopLoadingCountAfterSecondEpisode == 2)
        #expect(boundedRequestCount == requestCountAfterSecondEpisode)
        #expect(boundedStopLoadingCount == stopLoadingCountAfterSecondEpisode)
        #expect(staleValues.contains(true))
        #expect(staleValues.contains(false))
        #expect(staleValues.filter { $0 }.count == 2)
    }

    @Test func reconnectTransportErrorUsesBackoffSequence() async {
        let store = SolChatURLProtocolStore()
        let state = SolChatStateBox()
        let sleepRecorder = SleepRecorder()
        let bridge = makeBridge(
            resolver: HomeBaseURLResolver { .url("not a valid url") },
            state: state,
            store: store,
            watchdogIntervalSeconds: 999,
            backoffSeconds: [1, 2, 4],
            sleep: { seconds in
                await sleepRecorder.record(seconds)
                try? await Task.sleep(for: .milliseconds(1))
            }
        )

        await bridge.configure(serverKey: store.serverKey)
        for _ in 0..<80 where await sleepRecorder.values.filter({ $0 != 999 }).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await bridge.stop()

        let values = await sleepRecorder.values
        let backoffValues = values.filter { $0 != 999 }
        #expect(backoffValues.first == 1)
    }

    @Test func terminal401DoesNotRetry() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(statusCode: 401)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store, backoffSeconds: [0.01])

        await bridge.configure(serverKey: store.serverKey)
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        #expect(store.requests.count == 1)
    }

    @Test func terminal403DoesNotRetry() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(statusCode: 403)
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store, backoffSeconds: [0.01])

        await bridge.configure(serverKey: store.serverKey)
        try? await Task.sleep(for: .milliseconds(150))
        await bridge.stop()

        #expect(store.requests.count == 1)
    }

    @Test func handleClickPostsOpensAndClearsPendingEvenOnServerError() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame(id: "req-8", day: "2026-05-09", eventIndex: 99))
        store.enqueue(statusCode: 500, body: "boom")
        let state = SolChatStateBox()
        let bridge = makeBridge(state: state, store: store)

        await bridge.configure(serverKey: store.serverKey)
        _ = await waitForPending(state)
        await bridge.handleClick(requestID: "req-8")
        await bridge.stop()

        #expect(state.openedDestinations.last == .chat(day: "2026-05-09", eventIndex: 99))
        #expect(state.pending == nil)
        let post = store.requests.first { $0.httpMethod == "POST" }
        let postIndex = store.requests.firstIndex { $0.httpMethod == "POST" }
        #expect(post?.url?.absoluteString == "https://example.com/api/chat/sol_chat_request/open")
        #expect(post?.httpMethod == "POST")
        #expect(post?.value(forHTTPHeaderField: "Authorization") == store.authorizationHeader)
        #expect(postIndex.map { store.requestBodies[$0] } == "{\"request_id\":\"req-8\"}")
    }

    @Test func handleClickOnHeldBaseStillEmitsIntentAndClearsPendingWithoutOwnerOpenPost() async {
        let store = SolChatURLProtocolStore()
        store.enqueue(body: requestFrame(id: "req-held", day: "2026-05-11", eventIndex: 7))
        let state = SolChatStateBox()
        let resolver = SequencedHomeBaseResolver([.url("https://example.com"), .held])
        let bridge = makeBridge(
            resolver: HomeBaseURLResolver {
                await resolver.next()
            },
            state: state,
            store: store
        )

        await bridge.configure(serverKey: store.serverKey)
        _ = await waitForPending(state)
        await bridge.handleClick(requestID: "req-held")
        await bridge.stop()

        #expect(state.openedDestinations == [.chat(day: "2026-05-11", eventIndex: 7)])
        #expect(state.pending == nil)
        #expect(!store.requests.contains { $0.httpMethod == "POST" })
    }
}

private actor SleepRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        values.append(value)
    }
}

private actor SequencedHomeBaseResolver {
    private var values: [ResolvedHomeBase]

    init(_ values: [ResolvedHomeBase]) {
        self.values = values
    }

    func next() -> ResolvedHomeBase {
        if values.count > 1 {
            return values.removeFirst()
        }
        return values.first ?? .held
    }
}
