// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Manages mute state for audio and video capture
@MainActor
@Observable
public final class MuteManager {
    /// Types of capture that can be muted
    public enum MuteType: String, CaseIterable, Sendable {
        case audio
        case video
    }

    /// Duration options for muting
    public enum MuteDuration: Sendable {
        case minutes(Int)
        case indefinite

        public var displayName: String {
            switch self {
            case .minutes(let mins):
                return "\(mins) min"
            case .indefinite:
                return "Until unmute"
            }
        }
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

    public private(set) var audioMute = MuteState()
    public private(set) var videoMute = MuteState()

    // MARK: - Timers

    private var audioTimer: Timer?
    private var videoTimer: Timer?

    // MARK: - Callbacks

    /// Called when mute state changes (for CaptureManager to pause/resume)
    public var onMuteStateChanged: (() -> Void)?

    // MARK: - Computed Properties

    /// True if both audio and video are muted
    public var isFullyMuted: Bool {
        audioMute.isMuted && videoMute.isMuted
    }

    /// True if either audio or video is muted
    public var isAnyMuted: Bool {
        audioMute.isMuted || videoMute.isMuted
    }

    // MARK: - Public Methods

    public init() {}

    /// Mute audio or video for a specified duration
    public func mute(_ type: MuteType, for duration: MuteDuration) {
        let expirationDate: Date?
        switch duration {
        case .minutes(let mins):
            expirationDate = Date().addingTimeInterval(TimeInterval(mins * 60))
        case .indefinite:
            expirationDate = nil
        }

        switch type {
        case .audio:
            audioMute = MuteState(isMuted: true, expirationDate: expirationDate)
            scheduleTimer(for: .audio, expiration: expirationDate)
        case .video:
            videoMute = MuteState(isMuted: true, expirationDate: expirationDate)
            scheduleTimer(for: .video, expiration: expirationDate)
        }

        // Persist mute state
        saveMuteState()

        onMuteStateChanged?()
    }

    /// Unmute audio or video
    public func unmute(_ type: MuteType) {
        switch type {
        case .audio:
            audioTimer?.invalidate()
            audioTimer = nil
            audioMute = MuteState()
        case .video:
            videoTimer?.invalidate()
            videoTimer = nil
            videoMute = MuteState()
        }

        saveMuteState()
        onMuteStateChanged?()
    }

    /// Unmute both audio and video
    public func unmuteAll() {
        audioTimer?.invalidate()
        audioTimer = nil
        videoTimer?.invalidate()
        videoTimer = nil

        audioMute = MuteState()
        videoMute = MuteState()

        saveMuteState()
        onMuteStateChanged?()
    }

    /// Restore mute state from UserDefaults (call on app launch)
    public func restoreMuteState() {
        let defaults = UserDefaults.standard

        // Restore audio mute
        if let audioExpiration = defaults.object(forKey: "audioMuteExpiration") as? Date {
            if audioExpiration > Date() {
                audioMute = MuteState(isMuted: true, expirationDate: audioExpiration)
                scheduleTimer(for: .audio, expiration: audioExpiration)
            }
        } else if defaults.bool(forKey: "audioMuteIndefinite") {
            audioMute = MuteState(isMuted: true, expirationDate: nil)
        }

        // Restore video mute
        if let videoExpiration = defaults.object(forKey: "videoMuteExpiration") as? Date {
            if videoExpiration > Date() {
                videoMute = MuteState(isMuted: true, expirationDate: videoExpiration)
                scheduleTimer(for: .video, expiration: videoExpiration)
            }
        } else if defaults.bool(forKey: "videoMuteIndefinite") {
            videoMute = MuteState(isMuted: true, expirationDate: nil)
        }

        if isAnyMuted {
            onMuteStateChanged?()
        }
    }

    /// Format remaining time as a human-readable string
    public func formatTimeRemaining(for type: MuteType) -> String? {
        let state = type == .audio ? audioMute : videoMute

        guard state.isMuted else { return nil }

        if state.isIndefinite {
            return "indefinitely"
        }

        guard let remaining = state.timeRemaining else { return nil }

        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60

        if mins > 0 {
            return String(format: "%d:%02d remaining", mins, secs)
        } else {
            return "\(secs)s remaining"
        }
    }

    // MARK: - Private Methods

    private func scheduleTimer(for type: MuteType, expiration: Date?) {
        guard let expiration = expiration else { return }

        let interval = expiration.timeIntervalSinceNow
        guard interval > 0 else {
            // Already expired, unmute immediately
            unmute(type)
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.unmute(type)
            }
        }

        switch type {
        case .audio:
            audioTimer?.invalidate()
            audioTimer = timer
        case .video:
            videoTimer?.invalidate()
            videoTimer = timer
        }
    }

    private func saveMuteState() {
        let defaults = UserDefaults.standard

        // Save audio state
        if audioMute.isMuted {
            if let expiration = audioMute.expirationDate {
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

        // Save video state
        if videoMute.isMuted {
            if let expiration = videoMute.expirationDate {
                defaults.set(expiration, forKey: "videoMuteExpiration")
                defaults.removeObject(forKey: "videoMuteIndefinite")
            } else {
                defaults.set(true, forKey: "videoMuteIndefinite")
                defaults.removeObject(forKey: "videoMuteExpiration")
            }
        } else {
            defaults.removeObject(forKey: "videoMuteExpiration")
            defaults.removeObject(forKey: "videoMuteIndefinite")
        }
    }
}
