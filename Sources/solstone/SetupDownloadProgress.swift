// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import JournalMarkKit
import os

enum SetupDownloadState: String, Decodable, Sendable {
    case idle, downloading, complete, cancelled, error
}

struct SetupDownloadJob: Decodable, Equatable, Sendable {
    let state: SetupDownloadState
    let attemptID: String?
    let bytesDone: UInt64
    let bytesTotal: UInt64?
    let error: Failure?

    struct Failure: Decodable, Equatable, Sendable {
        let code: String
        let detail: String
    }

    enum CodingKeys: String, CodingKey {
        case state, error
        case attemptID = "attempt_id"
        case bytesDone = "bytes_done"
        case bytesTotal = "bytes_total"
    }

    var fraction: Double? {
        guard state == .downloading, let total = bytesTotal, total > 0 else { return nil }
        return min(1, Double(bytesDone) / Double(total))
    }
}

struct SetupDownloads: Decodable, Equatable, Sendable {
    let speech: SetupDownloadJob
    let thinking: SetupDownloadJob

    /// Local thinking stays idle unless the owner chose it, so an idle job is not pending.
    var showsThinking: Bool { thinking.state != .idle }

    var thinkingAction: SetupDownloadAction? {
        switch thinking.state {
        case .downloading:
            guard let attemptID = thinking.attemptID, !attemptID.isEmpty else { return nil }
            return .cancelThinking(attemptID: attemptID)
        case .error, .cancelled:
            return .startThinking
        case .idle, .complete:
            return nil
        }
    }

    /// A speech package that needs repair is never retried in place.
    var speechAction: SetupDownloadAction? {
        guard speech.state == .error, speech.error?.code != "speech_package_unavailable" else { return nil }
        return .retrySpeech
    }

    func offers(_ action: SetupDownloadAction) -> Bool {
        action == thinkingAction || action == speechAction
    }
}

/// The journal's setup actions for its downloads. A cancel names the attempt it was shown for.
enum SetupDownloadAction: Equatable, Sendable {
    case cancelThinking(attemptID: String)
    case startThinking
    case retrySpeech

    var body: [String: String] {
        switch self {
        case .cancelThinking(let attemptID):
            ["action": "cancel_thinking_download", "attempt_id": attemptID]
        case .startThinking:
            ["action": "start_thinking_download"]
        case .retrySpeech:
            ["action": "retry_speech_download"]
        }
    }
}

/// Setup actions are local-only on the journal, so they go to Journal.app's own
/// listener, never through the tunnel, and carry no loopback capability.
struct SetupActionClient: Sendable {
    static let endpoint = URL(string: "http://127.0.0.1:5015/init/api/action")!
    let session: URLSession

    init(session: URLSession = BoundedLoopbackClient.sharedSession) {
        self.session = session
    }

    static func request(for action: SetupDownloadAction) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.httpBody = try? JSONSerialization.data(withJSONObject: action.body, options: [.sortedKeys])
        return request
    }

    /// Every outcome, including a speech admission still pending, is reconciled by re-reading progress.
    func send(_ action: SetupDownloadAction) async {
        do {
            let result = try await BoundedLoopbackClient.execute(request: Self.request(for: action), session: session)
            guard (200..<300).contains(result.response.statusCode) else {
                let reason = (try? JSONDecoder().decode(Refusal.self, from: result.data))?.reasonCode ?? "unknown"
                Logger.setup.notice("setup download action refused: http \(result.response.statusCode, privacy: .public) \(reason, privacy: .public)")
                return
            }
        } catch {
            Logger.setup.notice("setup download action failed: \(String(describing: error), privacy: .public)")
        }
    }

    private struct Refusal: Decodable {
        let reasonCode: String?
        enum CodingKeys: String, CodingKey { case reasonCode = "reason_code" }
    }
}

enum SetupDownloadReadError: Error {
    case unavailable
}

struct SetupDownloadClient: Sendable {
    let session: URLSession

    init(session: URLSession = BoundedLoopbackClient.sharedSession) {
        self.session = session
    }

    func read(baseURL: String) async throws -> SetupDownloads {
        guard var parts = URLComponents(string: baseURL), parts.scheme == "http",
              parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw SetupDownloadReadError.unavailable }
        parts.path = "/app/home/api/first-minutes"
        guard let url = parts.url else { throw SetupDownloadReadError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.attachLoopbackCapability()
        let result = try await BoundedLoopbackClient.execute(request: request, session: session)
        guard result.response.statusCode == 200, result.response.url == url else {
            throw SetupDownloadReadError.unavailable
        }
        let response = try JSONDecoder().decode(Response.self, from: result.data)
        guard response.windowOpen, let downloads = response.setup?.downloads else {
            throw SetupDownloadReadError.unavailable
        }
        return downloads
    }

    private struct Response: Decodable {
        let windowOpen: Bool
        let setup: Setup?
        enum CodingKeys: String, CodingKey {
            case windowOpen = "window_open"
            case setup
        }
        struct Setup: Decodable {
            let downloads: SetupDownloads?
        }
    }
}

struct SetupDownloadAdmission: Equatable, Sendable {
    let handoffID: UUID
    let credential: PairingCredentialRevision
    let routeGeneration: UInt64
    let baseURL: String
}

/// The lifetime belongs to setup, rather than the currently visible Settings tab.
@MainActor
@Observable
final class SetupDownloadProgress {
    private(set) var downloads: SetupDownloads?
    /// A read was attempted and failed; nothing to say before the first read.
    private(set) var readFailed = false
    private(set) var actionInFlight = false
    /// The admission whose direct listener matched the tunnel's journal.
    private var verified: SetupDownloadAdmission?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let read: @Sendable (String) async throws -> SetupDownloads
    @ObservationIgnored private let send: @Sendable (SetupDownloadAction) async -> Void
    @ObservationIgnored private let sleep: @Sendable () async throws -> Void

    var actionsEnabled: Bool { verified != nil && !actionInFlight }

    init(
        read: @escaping @Sendable (String) async throws -> SetupDownloads = {
            try await SetupDownloadClient().read(baseURL: $0)
        },
        send: @escaping @Sendable (SetupDownloadAction) async -> Void = {
            await SetupActionClient().send($0)
        },
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
    ) {
        self.read = read
        self.send = send
        self.sleep = sleep
    }

    func start(
        admission: @escaping @MainActor () async -> SetupDownloadAdmission?,
        verifyDirect: @escaping @MainActor (SetupDownloadAdmission) async -> Bool
    ) {
        guard task == nil else { return }
        let token = generation
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.generation == token else { return }
                await self?.refresh(admission: admission, verifyDirect: verifyDirect)
                do { try await sleep() } catch { return }
            }
        }
    }

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        downloads = nil
        readFailed = false
        verified = nil
    }

    /// Admission is checked on both sides of the read, including resolver awaits.
    /// While a control is on offer, the direct listener is checked once per admission.
    func refresh(
        admission: @MainActor () async -> SetupDownloadAdmission?,
        verifyDirect: (@MainActor (SetupDownloadAdmission) async -> Bool)? = nil
    ) async {
        let token = generation
        let context = await admission()
        guard generation == token, !Task.isCancelled else { return }
        guard let context else { downloads = nil; verified = nil; return }
        do {
            let value = try await read(context.baseURL)
            let current = await admission()
            guard generation == token, !Task.isCancelled else { return }
            guard current == context else { downloads = nil; verified = nil; return }
            downloads = value
            readFailed = false
            if verified != context { verified = nil }
            guard let verifyDirect, verified == nil,
                  value.thinkingAction != nil || value.speechAction != nil else { return }
            let matches = await verifyDirect(context)
            let after = await admission()
            guard generation == token, !Task.isCancelled, after == context else { return }
            verified = matches ? context : nil
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            downloads = nil
            readFailed = true
        }
    }

    /// Sends only an action still on screen, after the direct listener matches again, then re-reads.
    func perform(
        _ action: SetupDownloadAction,
        admission: @MainActor () async -> SetupDownloadAdmission?,
        verifyDirect: @MainActor (SetupDownloadAdmission) async -> Bool
    ) async {
        guard !actionInFlight, verified != nil, downloads?.offers(action) == true else { return }
        let token = generation
        actionInFlight = true
        defer { actionInFlight = false }
        guard let context = await admission(), generation == token, context == verified else { return }
        let matches = await verifyDirect(context)
        let current = await admission()
        guard generation == token, !Task.isCancelled else { return }
        guard matches, current == context else { verified = nil; return }
        guard downloads?.offers(action) == true else { return }
        await send(action)
        guard generation == token, !Task.isCancelled else { return }
        await refresh(admission: admission)
    }
}
