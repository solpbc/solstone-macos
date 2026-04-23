// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public actor HeartbeatService {
    /// Scope name: HEARTBEAT_INTERVAL_SECONDS.
    public static let heartbeatIntervalSeconds: TimeInterval = 15

    public typealias PostHeartbeat =
        @Sendable (_ serverURL: String, _ serverKey: String, _ paused: Bool) async throws -> Void
    public typealias IsPausedProvider = @MainActor @Sendable () -> Bool

    private let intervalSeconds: TimeInterval
    private let isPaused: IsPausedProvider
    private let postHeartbeat: PostHeartbeat

    private var task: Task<Void, Never>?
    private var currentURL: String?
    private var currentKey: String?
    private var lastAuthStatus: Int?

    public init(
        intervalSeconds: TimeInterval = HeartbeatService.heartbeatIntervalSeconds,
        isPaused: @escaping IsPausedProvider,
        postHeartbeat: @escaping PostHeartbeat
    ) {
        self.intervalSeconds = intervalSeconds
        self.isPaused = isPaused
        self.postHeartbeat = postHeartbeat
    }

    public func configure(serverURL: String, serverKey: String) {
        guard !serverURL.isEmpty, !serverKey.isEmpty else {
            stop()
            return
        }

        guard currentURL != serverURL || currentKey != serverKey || task == nil else {
            return
        }

        let hadExistingTask = task != nil
        task?.cancel()
        task = nil
        lastAuthStatus = nil
        currentURL = serverURL
        currentKey = serverKey

        if hadExistingTask {
            Logger.upload.info("Heartbeat reconfigured")
        } else {
            Logger.upload.info("Heartbeat started")
        }

        task = Task { [intervalSeconds, isPaused, postHeartbeat] in
            while !Task.isCancelled {
                let paused = await isPaused()
                Logger.upload.debug("heartbeat tick paused=\(paused, privacy: .public)")

                do {
                    try await postHeartbeat(serverURL, serverKey, paused)
                    clearAuthFailureState()
                } catch {
                    handleHeartbeatError(error)
                }

                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    public func stop() {
        let hadTask = task != nil || currentURL != nil || currentKey != nil
        task?.cancel()
        task = nil
        currentURL = nil
        currentKey = nil
        lastAuthStatus = nil

        if hadTask {
            Logger.upload.info("Heartbeat stopped")
        }
    }

    private func clearAuthFailureState() {
        lastAuthStatus = nil
    }

    private func handleHeartbeatError(_ error: Error) {
        if let statusCode = authStatusCode(from: error) {
            if lastAuthStatus != statusCode {
                Logger.upload.info("Heartbeat auth failed with HTTP \(statusCode, privacy: .public)")
                lastAuthStatus = statusCode
            } else {
                Logger.upload.debug("Heartbeat auth failure repeated with HTTP \(statusCode, privacy: .public)")
            }
            return
        }

        if case let UploadError.serverError(statusCode, _) = error {
            Logger.upload.debug("Heartbeat HTTP \(statusCode, privacy: .public)")
            return
        }

        if let urlError = error as? URLError {
            Logger.upload.debug("Heartbeat URLError \(urlError.code.rawValue, privacy: .public)")
            return
        }

        let errorType = String(describing: type(of: error))
        Logger.upload.debug("Heartbeat failed: \(errorType, privacy: .public)")
    }

    private func authStatusCode(from error: Error) -> Int? {
        guard case let UploadError.serverError(statusCode, _) = error else {
            return nil
        }

        switch statusCode {
        case 401, 403:
            return statusCode
        default:
            return nil
        }
    }
}
