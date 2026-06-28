// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public actor HeartbeatService {
    /// Scope name: HEARTBEAT_INTERVAL_SECONDS.
    public static let heartbeatIntervalSeconds: TimeInterval = 15

    public typealias PostHeartbeat =
        @Sendable (_ serverURL: String, _ serverKey: String, _ paused: Bool, _ health: ObserverHealthSnapshot?) async throws -> Void
    public typealias IsPausedProvider = @MainActor @Sendable () -> Bool
    public typealias HealthProvider = @MainActor @Sendable () -> ObserverHealthSnapshot?

    private let intervalSeconds: TimeInterval
    private let isPaused: IsPausedProvider
    private let healthProvider: HealthProvider
    private let postHeartbeat: PostHeartbeat
    private let clock: any MonotonicClock

    private var task: Task<Void, Never>?
    private var currentURL: String?
    private var currentKey: String?
    private var lastAuthStatus: Int?

    public init(
        intervalSeconds: TimeInterval = HeartbeatService.heartbeatIntervalSeconds,
        isPaused: @escaping IsPausedProvider,
        healthProvider: @escaping HealthProvider,
        postHeartbeat: @escaping PostHeartbeat
    ) {
        self.init(
            intervalSeconds: intervalSeconds,
            isPaused: isPaused,
            healthProvider: healthProvider,
            postHeartbeat: postHeartbeat,
            clock: SystemMonotonicClock()
        )
    }

    internal init(
        intervalSeconds: TimeInterval = HeartbeatService.heartbeatIntervalSeconds,
        isPaused: @escaping IsPausedProvider,
        healthProvider: @escaping HealthProvider,
        postHeartbeat: @escaping PostHeartbeat,
        clock: any MonotonicClock
    ) {
        self.intervalSeconds = intervalSeconds
        self.isPaused = isPaused
        self.healthProvider = healthProvider
        self.postHeartbeat = postHeartbeat
        self.clock = clock
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
        let startedAt = clock.now()

        if hadExistingTask {
            Logger.upload.info("Heartbeat reconfigured")
        } else {
            Logger.upload.info("Heartbeat started")
        }

        task = Task { [intervalSeconds, isPaused, healthProvider, postHeartbeat, clock] in
            while !Task.isCancelled {
                let paused = await isPaused()
                var health = await healthProvider()
                if health != nil {
                    health?.uptimeSeconds = Self.uptimeSeconds(clock: clock, startedAt: startedAt)
                }
                Logger.upload.debug("heartbeat tick paused=\(paused, privacy: .public)")

                do {
                    try await postHeartbeat(serverURL, serverKey, paused, health)
                    clearAuthFailureState()
                } catch {
                    handleHeartbeatError(error)
                }

                await clock.sleep(for: .seconds(intervalSeconds))
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

    internal func pausedForTesting() async -> Bool {
        await isPaused()
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

    private nonisolated static func uptimeSeconds(clock: any MonotonicClock, startedAt: Duration) -> Int {
        let elapsed = clock.now() - startedAt
        return max(0, Int(elapsed.components.seconds))
    }
}
