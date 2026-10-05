// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreFoundation

/// A handle to an armed pause-expiry timer that can be invalidated on resume.
public protocol PauseExpiryTimer: AnyObject {
    func invalidate()
}

extension Timer: PauseExpiryTimer {}

/// Arms a one-shot expiry timer; returns a handle the manager invalidates on resume.
public typealias PauseExpiryScheduler = (_ interval: TimeInterval, _ onExpire: @escaping @Sendable @MainActor () -> Void) -> PauseExpiryTimer

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
        public func expirationDate(at now: Date) -> Date? {
            switch self {
            case .minutes(let minutes):
                return now.addingTimeInterval(TimeInterval(minutes * 60))
            case .seconds(let seconds):
                return now.addingTimeInterval(TimeInterval(seconds))
            case .indefinite:
                return nil
            }
        }
    }

    /// State of a pause
    public struct PauseState: Sendable {
        public var isPaused: Bool = false
        public var expirationDate: Date? = nil

        public func timeRemaining(at now: Date) -> TimeInterval? {
            guard isPaused, let expiration = expirationDate else { return nil }
            let remaining = expiration.timeIntervalSince(now)
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
    public var onPauseIntake: (() -> Void)?
    public var onResumeIntake: (() -> Void)?

    /// Convenience property for checking pause status
    public var isPaused: Bool { pauseState.isPaused }

    // MARK: - Timers

    private var pauseTimer: (any PauseExpiryTimer)?
    private var uiRefreshTimer: Timer?
    private let defaults: UserDefaults?
    private let expiryScheduler: PauseExpiryScheduler
    private let now: @MainActor () -> Date
    private static let ownerPauseKey = "ownerPause"

    /// Triggers UI refresh for time remaining display (incremented every second when paused)
    public private(set) var refreshTick: Int = 0

    // MARK: - Public Methods

    public init(
        defaults: UserDefaults? = nil,
        expiryScheduler: @escaping PauseExpiryScheduler = { interval, onExpire in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
                Task { @MainActor in onExpire() }
            }
            return timer
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.expiryScheduler = expiryScheduler
        self.now = now

        if defaults != nil {
            removeObsoletePauseKeys()
            restorePauseState()
        }
    }

    /// Pause capture for a specified duration
    public func pause(for duration: PauseDuration) {
        let expirationDate = duration.expirationDate(at: now())

        pauseState = PauseState(isPaused: true, expirationDate: expirationDate)
        if let defaults {
            if let expirationDate {
                defaults.set(expirationDate.timeIntervalSince1970, forKey: Self.ownerPauseKey)
            } else {
                defaults.set("indefinite", forKey: Self.ownerPauseKey)
            }
        }

        scheduleTimer(expiration: expirationDate)
        updateUIRefreshTimer()

        onPauseIntake?()

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
        defaults?.removeObject(forKey: Self.ownerPauseKey)

        updateUIRefreshTimer()

        onResumeIntake?()

        if let onResume {
            Task { @MainActor in
                await onResume()
            }
        }
    }

    /// Reapplies pause effects without changing the existing deadline or timer.
    public func reapply() {
        guard pauseState.isPaused else { return }
        onPauseIntake?()
        if let onPause {
            Task { @MainActor in
                await onPause()
            }
        }
    }

    /// Remove obsolete capture-pause keys. An owner's pause stays until the owner resumes or its deadline passes.
    public func removeObsoletePauseKeys() {
        guard let defaults else { return }
        defaults.removeObject(forKey: "audioMuteExpiration")
        defaults.removeObject(forKey: "audioMuteIndefinite")
        defaults.removeObject(forKey: "videoMuteExpiration")
        defaults.removeObject(forKey: "videoMuteIndefinite")
        defaults.removeObject(forKey: "pauseExpiration")
        defaults.removeObject(forKey: "pauseIndefinite")
    }

    private func restorePauseState() {
        guard let defaults, let storedValue = defaults.object(forKey: Self.ownerPauseKey) else { return }

        if storedValue is String {
            restoreIndefinitePause()
            return
        }

        guard let number = storedValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              String(cString: number.objCType) == "d",
              number.doubleValue.isFinite else {
            restoreIndefinitePause()
            return
        }

        let expiration = Date(timeIntervalSince1970: number.doubleValue)
        guard expiration > now() else {
            defaults.removeObject(forKey: Self.ownerPauseKey)
            return
        }

        pauseState = PauseState(isPaused: true, expirationDate: expiration)
        scheduleTimer(expiration: expiration)
        updateUIRefreshTimer()
    }

    private func restoreIndefinitePause() {
        pauseState = PauseState(isPaused: true, expirationDate: nil)
        updateUIRefreshTimer()
    }

    /// Format remaining time as a human-readable string with natural units
    public func formatTimeRemaining() -> String? {
        guard pauseState.isPaused else { return nil }

        if pauseState.isIndefinite {
            return nil
        }

        guard let remaining = pauseState.timeRemaining(at: now()) else { return nil }

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

        let interval = expiration.timeIntervalSince(now())
        guard interval > 0 else {
            resume()
            return
        }

        pauseTimer?.invalidate()
        pauseTimer = expiryScheduler(interval) { [weak self] in
            self?.resume()
        }
    }

    var expirySchedulerForTesting: PauseExpiryScheduler { expiryScheduler }

}
