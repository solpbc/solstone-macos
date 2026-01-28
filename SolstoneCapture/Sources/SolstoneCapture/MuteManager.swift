// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Manages audio mute state for capture
@MainActor
@Observable
public final class MuteManager {
    /// Duration options for muting
    public enum MuteDuration: Sendable {
        case until(Date)
        case untilTomorrowMorning
        case indefinite

        /// Calculate the expiration date for this duration
        public var expirationDate: Date? {
            switch self {
            case .until(let date):
                return date
            case .untilTomorrowMorning:
                let calendar = Calendar.current
                var components = calendar.dateComponents([.year, .month, .day], from: Date())
                components.day! += 1
                components.hour = 5
                components.minute = 0
                components.second = 0
                return calendar.date(from: components)
            case .indefinite:
                return nil
            }
        }
    }

    // MARK: - Quarter Hour Helpers

    /// Returns the next quarter hour (e.g., if now is 14:32, returns 14:45)
    public static func nextQuarterHour(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let nextQuarter = ((minute / 15) + 1) * 15

        var newComponents = components
        if nextQuarter >= 60 {
            newComponents.minute = 0
            newComponents.second = 0
            return calendar.date(from: newComponents)!.addingTimeInterval(3600)
        } else {
            newComponents.minute = nextQuarter
            newComponents.second = 0
            return calendar.date(from: newComponents)!
        }
    }

    /// Returns the second quarter hour from now
    public static func secondQuarterHour(after date: Date = Date()) -> Date {
        let first = nextQuarterHour(after: date)
        return nextQuarterHour(after: first)
    }

    /// Returns the next full hour after the second quarter hour
    /// (e.g., if now is 15:55, next quarter is 16:00, second is 16:15, so this returns 17:00)
    /// (e.g., if now is 15:32, next quarter is 15:45, second is 16:00, so this returns 17:00)
    public static func nextFullHour(after date: Date = Date()) -> Date {
        let secondQuarter = secondQuarterHour(after: date)
        let calendar = Calendar.current
        // Get the hour component and add 1 to get the next full hour after second quarter
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: secondQuarter)
        components.hour! += 1
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }

    /// Formats a time as HH:mm (e.g., "14:45")
    public static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// State of a mute
    public struct MuteState: Sendable {
        public var isMuted: Bool = false
        public var expirationDate: Date? = nil

        public var timeRemaining: TimeInterval? {
            guard isMuted, let expiration = expirationDate else { return nil }
            let remaining = expiration.timeIntervalSinceNow
            return remaining > 0 ? remaining : nil
        }

        public var isIndefinite: Bool {
            isMuted && expirationDate == nil
        }
    }

    // MARK: - Observable State

    public private(set) var muteState = MuteState() {
        didSet { _isAudioMuted = muteState.isMuted }
    }

    /// Thread-safe accessor for audio mute state (for audio capture closures)
    @ObservationIgnored nonisolated(unsafe) private var _isAudioMuted: Bool = false
    nonisolated public var isAudioMuted: Bool { _isAudioMuted }

    /// Convenience property for checking mute status
    public var isMuted: Bool { muteState.isMuted }

    // MARK: - Timers

    private var muteTimer: Timer?
    private var uiRefreshTimer: Timer?

    /// Triggers UI refresh for time remaining display (incremented every second when muted)
    public private(set) var refreshTick: Int = 0

    // MARK: - Public Methods

    public init() {}

    /// Mute audio for a specified duration
    public func mute(for duration: MuteDuration) {
        let expirationDate = duration.expirationDate

        muteState = MuteState(isMuted: true, expirationDate: expirationDate)
        scheduleTimer(expiration: expirationDate)

        // Persist mute state
        saveMuteState()
        updateUIRefreshTimer()
    }

    /// Unmute audio
    public func unmute() {
        muteTimer?.invalidate()
        muteTimer = nil
        muteState = MuteState()

        saveMuteState()
        updateUIRefreshTimer()
    }

    /// Restore mute state from UserDefaults (call on app launch)
    public func restoreMuteState() {
        let defaults = UserDefaults.standard

        // Restore audio mute
        if let audioExpiration = defaults.object(forKey: "audioMuteExpiration") as? Date {
            if audioExpiration > Date() {
                muteState = MuteState(isMuted: true, expirationDate: audioExpiration)
                scheduleTimer(expiration: audioExpiration)
            } else {
                // Expired - clear persisted state
                defaults.removeObject(forKey: "audioMuteExpiration")
            }
        } else if defaults.bool(forKey: "audioMuteIndefinite") {
            muteState = MuteState(isMuted: true, expirationDate: nil)
        }

        // Clean up any old video mute keys from previous versions
        defaults.removeObject(forKey: "videoMuteExpiration")
        defaults.removeObject(forKey: "videoMuteIndefinite")

        if isMuted {
            updateUIRefreshTimer()
        }
    }

    /// Format remaining time as a human-readable string with natural units
    public func formatTimeRemaining() -> String? {
        guard muteState.isMuted else { return nil }

        if muteState.isIndefinite {
            return nil  // No time to display for indefinite mute
        }

        guard let remaining = muteState.timeRemaining else { return nil }

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
        timer.tolerance = 0.5  // Allow coalescing to reduce energy impact
        uiRefreshTimer = timer
    }

    private func stopUIRefreshTimer() {
        uiRefreshTimer?.invalidate()
        uiRefreshTimer = nil
    }

    private func updateUIRefreshTimer() {
        if isMuted {
            startUIRefreshTimer()
        } else {
            stopUIRefreshTimer()
        }
    }

    private func scheduleTimer(expiration: Date?) {
        guard let expiration = expiration else { return }

        let interval = expiration.timeIntervalSinceNow
        guard interval > 0 else {
            // Already expired, unmute immediately
            unmute()
            return
        }

        muteTimer?.invalidate()
        muteTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.unmute()
            }
        }
    }

    private func saveMuteState() {
        let defaults = UserDefaults.standard

        if muteState.isMuted {
            if let expiration = muteState.expirationDate {
                defaults.set(expiration, forKey: "audioMuteExpiration")
                defaults.removeObject(forKey: "audioMuteIndefinite")
            } else {
                defaults.set(true, forKey: "audioMuteIndefinite")
                defaults.removeObject(forKey: "audioMuteExpiration")
            }
        } else {
            defaults.removeObject(forKey: "audioMuteExpiration")
            defaults.removeObject(forKey: "audioMuteIndefinite")
        }
    }
}
