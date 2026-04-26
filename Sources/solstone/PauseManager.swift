// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Manages user-initiated pause state for capture
@MainActor
@Observable
public final class PauseManager {
    /// Duration options for pausing capture
    public enum PauseDuration: Sendable {
        case minutes(Int)
        case seconds(Int)
        case indefinite

        /// Calculate the expiration date for this duration
        public var expirationDate: Date? {
            switch self {
            case .minutes(let minutes):
                return Date().addingTimeInterval(TimeInterval(minutes * 60))
            case .seconds(let seconds):
                return Date().addingTimeInterval(TimeInterval(seconds))
            case .indefinite:
                return nil
            }
        }
    }

    /// State of a pause
    public struct PauseState: Sendable {
        public var isPaused: Bool = false
        public var expirationDate: Date? = nil

        public var timeRemaining: TimeInterval? {
            guard isPaused, let expiration = expirationDate else { return nil }
            let remaining = expiration.timeIntervalSinceNow
            return remaining > 0 ? remaining : nil
        }

        public var isIndefinite: Bool {
            isPaused && expirationDate == nil
        }
    }

    // MARK: - Observable State

    public private(set) var pauseState = PauseState()
    public var onPause: (() async -> Void)?
    public var onResume: (() async -> Void)?

    /// Convenience property for checking pause status
    public var isPaused: Bool { pauseState.isPaused }

    // MARK: - Timers

    private var pauseTimer: Timer?
    private var uiRefreshTimer: Timer?

    /// Triggers UI refresh for time remaining display (incremented every second when paused)
    public private(set) var refreshTick: Int = 0

    // MARK: - Public Methods

    public init() {}

    /// Pause capture for a specified duration
    public func pause(for duration: PauseDuration) {
        let expirationDate = duration.expirationDate

        pauseState = PauseState(isPaused: true, expirationDate: expirationDate)
        scheduleTimer(expiration: expirationDate)
        updateUIRefreshTimer()

        if let onPause {
            Task { @MainActor in
                await onPause()
            }
        }
    }

    /// Resume capture
    public func resume() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pauseState = PauseState()

        updateUIRefreshTimer()

        if let onResume {
            Task { @MainActor in
                await onResume()
            }
        }
    }

    /// Clear any persisted pause state from previous sessions.
    /// Pause only applies to the running instance — on restart we always start fresh.
    public func restorePauseState() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: "audioMuteExpiration")
        defaults.removeObject(forKey: "audioMuteIndefinite")
        defaults.removeObject(forKey: "videoMuteExpiration")
        defaults.removeObject(forKey: "videoMuteIndefinite")
        defaults.removeObject(forKey: "pauseExpiration")
        defaults.removeObject(forKey: "pauseIndefinite")
    }

    /// Format remaining time as a human-readable string with natural units
    public func formatTimeRemaining() -> String? {
        guard pauseState.isPaused else { return nil }

        if pauseState.isIndefinite {
            return nil
        }

        guard let remaining = pauseState.timeRemaining else { return nil }

        let totalSeconds = Int(remaining)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60

        if hours > 0 {
            if mins > 30 {
                return "\(hours + 1) hrs"
            } else if hours == 1 && mins == 0 {
                return "1 hr"
            } else if mins > 0 {
                return "\(hours) hrs \(mins) mins"
            } else {
                return "\(hours) hrs"
            }
        } else if mins > 0 {
            return mins == 1 ? "1 min" : "\(mins) mins"
        } else {
            return "\(totalSeconds) secs"
        }
    }

    // MARK: - Private Methods

    private func startUIRefreshTimer() {
        guard uiRefreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTick += 1
            }
        }
        timer.tolerance = 0.5
        uiRefreshTimer = timer
    }

    private func stopUIRefreshTimer() {
        uiRefreshTimer?.invalidate()
        uiRefreshTimer = nil
    }

    private func updateUIRefreshTimer() {
        if isPaused {
            startUIRefreshTimer()
        } else {
            stopUIRefreshTimer()
        }
    }

    private func scheduleTimer(expiration: Date?) {
        guard let expiration = expiration else { return }

        let interval = expiration.timeIntervalSinceNow
        guard interval > 0 else {
            resume()
            return
        }

        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resume()
            }
        }
    }

}
