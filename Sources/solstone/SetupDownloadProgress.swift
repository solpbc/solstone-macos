// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import JournalMarkKit

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
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let read: @Sendable (String) async throws -> SetupDownloads
    @ObservationIgnored private let sleep: @Sendable () async throws -> Void

    init(
        read: @escaping @Sendable (String) async throws -> SetupDownloads = {
            try await SetupDownloadClient().read(baseURL: $0)
        },
        sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
    ) {
        self.read = read
        self.sleep = sleep
    }

    func start(admission: @escaping @MainActor () async -> SetupDownloadAdmission?) {
        guard task == nil else { return }
        let token = generation
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.generation == token else { return }
                await self?.refresh(admission: admission)
                do { try await sleep() } catch { return }
            }
        }
    }

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        downloads = nil
    }

    /// Admission is checked on both sides of the read, including resolver awaits.
    func refresh(admission: @MainActor () async -> SetupDownloadAdmission?) async {
        let token = generation
        let context = await admission()
        guard generation == token, !Task.isCancelled else { return }
        guard let context else { downloads = nil; return }
        do {
            let value = try await read(context.baseURL)
            let current = await admission()
            guard generation == token, !Task.isCancelled else { return }
            guard current == context else { downloads = nil; return }
            downloads = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            downloads = nil
        }
    }
}
