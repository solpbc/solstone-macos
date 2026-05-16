// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import UserNotifications
import AppKit
import os
import SolstoneCore

enum SolChatLiterals {
    // MIRRORED FROM solstone/convey/sol_initiated/copy.py
    static let solChatRequest = "sol_chat_request"
    static let solChatRequestSuperseded = "sol_chat_request_superseded"
    static let ownerChatOpen = "owner_chat_open"
    static let ownerChatDismissed = "owner_chat_dismissed"
    static let notificationTitle = "sol"
    static let surface = "macos"
    static let unreachableTooltip = "sol can't reach this device"
    static let openEndpointPath = "/api/chat/sol_chat_request/open"
    static let callosumPathComponent = "callosum"
}

public struct SolChatRequestSummary: Sendable, Equatable, Codable {
    public let id: String
    public let summary: String
    public let day: String
    public let eventIndex: Int
    public let receivedAt: Date

    public init(
        id: String,
        summary: String,
        day: String,
        eventIndex: Int,
        receivedAt: Date
    ) {
        self.id = id
        self.summary = summary
        self.day = day
        self.eventIndex = eventIndex
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
        case summary
        case day
        case eventIndex = "event_index"
        case receivedAt = "received_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .requestID)
            ?? container.decode(String.self, forKey: .id)
        summary = try container.decode(String.self, forKey: .summary)
        day = try container.decode(String.self, forKey: .day)
        eventIndex = try container.decode(Int.self, forKey: .eventIndex)
        receivedAt = Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .requestID)
        try container.encode(summary, forKey: .summary)
        try container.encode(day, forKey: .day)
        try container.encode(eventIndex, forKey: .eventIndex)
        try container.encode(receivedAt, forKey: .receivedAt)
    }
}

public protocol SolChatNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func post(identifier: String, title: String, body: String) async
    func removeDelivered(identifier: String) async
}

public final class UNUserNotificationSolChatNotifier: SolChatNotifying, @unchecked Sendable {
    public init() {}

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            Logger.callosum.info("Notification authorization failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    public func post(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Logger.callosum.info("Notification post failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    public func removeDelivered(identifier: String) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

struct NoopSolChatNotifier: SolChatNotifying {
    func requestAuthorization() async -> Bool { true }
    func post(identifier: String, title: String, body: String) async {}
    func removeDelivered(identifier: String) async {}
}

enum SolChatEvent: Decodable {
    case request(SolChatRequestSummary, isStale: Bool)
    case superseded(requestID: String)
    case open(requestID: String)
    case dismissed(requestID: String)
    case heartbeat
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case requestID = "request_id"
        case isStale = "is_stale"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        switch kind {
        case SolChatLiterals.solChatRequest:
            let summary = try SolChatRequestSummary(from: decoder)
            let isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
            self = .request(summary, isStale: isStale)
        case SolChatLiterals.solChatRequestSuperseded:
            self = .superseded(requestID: try Self.decodeRequestID(from: container))
        case SolChatLiterals.ownerChatOpen:
            self = .open(requestID: try Self.decodeRequestID(from: container))
        case SolChatLiterals.ownerChatDismissed:
            self = .dismissed(requestID: try Self.decodeRequestID(from: container))
        case "heartbeat":
            self = .heartbeat
        default:
            self = .unknown
        }
    }

    private static func decodeRequestID(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        try container.decodeIfPresent(String.self, forKey: .requestID)
            ?? container.decode(String.self, forKey: .id)
    }
}

public actor SolChatBridge {
    public typealias PostOpenChat = @Sendable (URL) async -> Void
    public typealias SetPending = @MainActor @Sendable (SolChatRequestSummary?) -> Void
    public typealias SetStale = @MainActor @Sendable (Bool) -> Void
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    private enum BridgeError: Error {
        case invalidURL
        case invalidResponse
        case httpStatus(Int)
        case authStatus(Int)
    }

    private let backoffSeconds: [TimeInterval]
    private let staleThresholdSeconds: TimeInterval
    private let watchdogIntervalSeconds: TimeInterval
    private let setPending: SetPending
    private let setStale: SetStale
    private let postOpenChat: PostOpenChat
    private let notifier: any SolChatNotifying
    private let session: URLSession
    private let sleep: Sleeper

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var currentURL: String?
    private var currentKey: String?
    private var lastAuthStatus: Int?
    private var lastHeartbeatAt: Date?
    private var notificationsEnabled: Bool
    private var pendingByID: [String: SolChatRequestSummary] = [:]
    private var staleFlag = false
    private var reconnectIndex = 0

    public init(
        notificationsEnabled: Bool,
        setPending: @escaping SetPending,
        setStale: @escaping SetStale,
        postOpenChat: @escaping PostOpenChat,
        notifier: any SolChatNotifying = UNUserNotificationSolChatNotifier(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        staleThresholdSeconds: TimeInterval = 60,
        watchdogIntervalSeconds: TimeInterval = 5,
        backoffSeconds: [TimeInterval] = [1, 2, 4, 8, 16, 30],
        sleep: @escaping Sleeper = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.setPending = setPending
        self.setStale = setStale
        self.postOpenChat = postOpenChat
        self.notifier = notifier
        self.staleThresholdSeconds = staleThresholdSeconds
        self.watchdogIntervalSeconds = watchdogIntervalSeconds
        self.backoffSeconds = backoffSeconds
        self.sleep = sleep

        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = .default
            config.timeoutIntervalForRequest = 0
            config.timeoutIntervalForResource = 0
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        self.session = URLSession(configuration: config)
    }

    public func configure(serverURL: String, serverKey: String) async {
        guard !serverURL.isEmpty, !serverKey.isEmpty else {
            await stop()
            return
        }

        guard currentURL != serverURL || currentKey != serverKey || task == nil else {
            return
        }

        let hadExistingTask = task != nil
        let hadExistingState = task != nil || watchdog != nil || currentURL != nil || currentKey != nil
            || !pendingByID.isEmpty || staleFlag
        await teardownState(clearConnection: false, publishClear: hadExistingState)
        lastHeartbeatAt = Date()
        currentURL = serverURL
        currentKey = serverKey

        if hadExistingTask {
            Logger.callosum.info("Callosum reconfigured")
        } else {
            Logger.callosum.info("Callosum started")
        }

        watchdog = Task { [weak self] in
            await self?.watchdogLoop()
        }
        task = Task { [weak self] in
            await self?.subscribeLoop(serverURL: serverURL, serverKey: serverKey)
        }
    }

    public func stop() async {
        let hadTask = task != nil || watchdog != nil || currentURL != nil || currentKey != nil
        await teardownState(clearConnection: true)

        if hadTask {
            Logger.callosum.info("Callosum stopped")
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    public func handleClick(requestID: String) async {
        let summary = pendingByID[requestID]
        await postOpenChatIfConfigured(summary: summary)
        await postOwnerChatOpen(requestID: requestID)
        pendingByID.removeValue(forKey: requestID)
        await notifier.removeDelivered(identifier: requestID)
        await publishMostRecentPending()
    }

    private func subscribeLoop(serverURL: String, serverKey: String) async {
        while !Task.isCancelled {
            do {
                try await subscribe(serverURL: serverURL, serverKey: serverKey)
            } catch BridgeError.authStatus(let statusCode) {
                handleAuthFailure(statusCode: statusCode)
                await teardownState(clearConnection: true, joinSubscribeTask: false)
                return
            } catch {
                if Task.isCancelled { return }
                logTransient(error)
            }

            if Task.isCancelled { return }
            let delay = backoffSeconds[min(reconnectIndex, backoffSeconds.count - 1)]
            reconnectIndex = min(reconnectIndex + 1, backoffSeconds.count - 1)
            await sleep(delay)
        }
    }

    private func subscribe(serverURL: String, serverKey: String) async throws {
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(baseURL)/app/observer/\(serverKey)/\(SolChatLiterals.callosumPathComponent)"
        guard let url = URL(string: urlString) else {
            throw BridgeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw BridgeError.authStatus(httpResponse.statusCode)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw BridgeError.httpStatus(httpResponse.statusCode)
        }

        var dataLines: [String] = []
        for try await line in bytes.lines {
            if Task.isCancelled { return }
            try await processSSELine(line, dataLines: &dataLines)
        }

        if !dataLines.isEmpty {
            try await processSSEDataLines(&dataLines)
        }

        if !Task.isCancelled {
            throw URLError(.networkConnectionLost)
        }
    }

    private func processSSELine(_ line: String, dataLines: inout [String]) async throws {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return }
            try await processSSEDataLines(&dataLines)
            return
        }

        if line.hasPrefix(":") {
            await markFrameReceived()
            return
        }

        if line.hasPrefix("data:") {
            var value = String(line.dropFirst("data:".count))
            if value.first == " " {
                value.removeFirst()
            }
            dataLines.append(value)
            return
        }

        if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") {
            return
        }
    }

    private func processSSEDataLines(_ dataLines: inout [String]) async throws {
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        await markFrameReceived()
        do {
            let event = try JSONDecoder().decode(SolChatEvent.self, from: Data(data.utf8))
            await dispatch(event)
        } catch {
            Logger.callosum.debug("dropped malformed event: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func dispatch(_ event: SolChatEvent) async {
        Logger.callosum.debug("dispatch event=\(self.eventKindLabel(event), privacy: .public)")

        switch event {
        case .request(let summary, let isStale):
            guard !isStale else { return }
            pendingByID[summary.id] = summary
            await setPending(summary)
            if notificationsEnabled && !staleFlag {
                await notifier.post(
                    identifier: summary.id,
                    title: SolChatLiterals.notificationTitle,
                    body: summary.summary
                )
            }
        case .superseded(let requestID), .open(let requestID), .dismissed(let requestID):
            pendingByID.removeValue(forKey: requestID)
            await notifier.removeDelivered(identifier: requestID)
            await publishMostRecentPending()
        case .heartbeat:
            break
        case .unknown:
            Logger.callosum.debug("dropped unknown event")
        }
    }

    private func markFrameReceived() async {
        lastHeartbeatAt = Date()
        lastAuthStatus = nil
        reconnectIndex = 0
        if staleFlag {
            staleFlag = false
            await setStale(false)
        }
    }

    private func watchdogLoop() async {
        while !Task.isCancelled {
            await sleep(watchdogIntervalSeconds)
            if Task.isCancelled { return }

            let last = lastHeartbeatAt ?? Date()
            guard Date().timeIntervalSince(last) > staleThresholdSeconds else {
                continue
            }
            guard !staleFlag else {
                continue
            }

            staleFlag = true
            Logger.callosum.info("Callosum heartbeat stale")
            await setStale(true)
        }
    }

    private func publishMostRecentPending() async {
        let mostRecent = pendingByID.values.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }.first
        await setPending(mostRecent)
    }

    private func teardownState(
        clearConnection: Bool,
        publishClear: Bool = true,
        joinSubscribeTask: Bool = true
    ) async {
        let pendingTask = task
        let pendingWatchdog = watchdog
        pendingTask?.cancel()
        pendingWatchdog?.cancel()
        task = nil
        watchdog = nil

        if clearConnection {
            currentURL = nil
            currentKey = nil
        }
        lastAuthStatus = nil
        lastHeartbeatAt = nil
        reconnectIndex = 0
        staleFlag = false
        pendingByID.removeAll()

        if publishClear {
            Task { @MainActor [setPending, setStale] in
                setPending(nil)
                setStale(false)
            }
        }

        if joinSubscribeTask {
            await pendingTask?.value
        }
        await pendingWatchdog?.value
    }

    private func eventKindLabel(_ event: SolChatEvent) -> String {
        switch event {
        case .request:
            SolChatLiterals.solChatRequest
        case .superseded:
            SolChatLiterals.solChatRequestSuperseded
        case .open:
            SolChatLiterals.ownerChatOpen
        case .dismissed:
            SolChatLiterals.ownerChatDismissed
        case .heartbeat:
            "heartbeat"
        case .unknown:
            "unknown"
        }
    }

    private func postOwnerChatOpen(requestID: String) async {
        guard let serverURL = currentURL, let serverKey = currentKey else {
            return
        }
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: baseURL + SolChatLiterals.openEndpointPath) else {
            Logger.callosum.info("Open chat request skipped: invalid URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["request_id": requestID])

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.callosum.info("Open chat request failed: invalid response")
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let message = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                Logger.callosum.info("Open chat request HTTP \(httpResponse.statusCode, privacy: .public): \(message, privacy: .private)")
                return
            }
        } catch {
            Logger.callosum.info("Open chat request failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func postOpenChatIfConfigured(summary: SolChatRequestSummary?) async {
        guard let serverURL = currentURL else {
            return
        }
        let baseURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resolvedDay = summary?.day ?? Self.todayString()
        let resolvedIndex = summary?.eventIndex ?? 0
        guard let url = URL(string: "\(baseURL)/app/chat/\(resolvedDay)#event-\(resolvedIndex)") else {
            Logger.callosum.info("open chat skipped: invalid URL")
            return
        }
        await postOpenChat(url)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func handleAuthFailure(statusCode: Int) {
        if lastAuthStatus != statusCode {
            Logger.callosum.info("Callosum auth failed with HTTP \(statusCode, privacy: .public)")
            lastAuthStatus = statusCode
        } else {
            Logger.callosum.debug("Callosum auth failure repeated with HTTP \(statusCode, privacy: .public)")
        }
    }

    private func logTransient(_ error: Error) {
        if case BridgeError.httpStatus(let statusCode) = error {
            Logger.callosum.debug("Callosum HTTP \(statusCode, privacy: .public)")
            return
        }
        if let urlError = error as? URLError {
            Logger.callosum.debug("Callosum URLError \(urlError.code.rawValue, privacy: .public)")
            return
        }
        Logger.callosum.debug("Callosum failed: \(String(describing: type(of: error)), privacy: .public)")
    }
}

private final class SolChatNotificationCompletion: @unchecked Sendable {
    private let completionHandler: () -> Void

    init(_ completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
    }

    func call() {
        completionHandler()
    }
}

final class SolChatNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        let completion = SolChatNotificationCompletion(completionHandler)
        Task { @MainActor in
            await AppState.shared?.solChatBridge.handleClick(requestID: id)
            completion.call()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
