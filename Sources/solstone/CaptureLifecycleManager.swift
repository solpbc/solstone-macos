// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@preconcurrency import ScreenCaptureKit

@MainActor
protocol CaptureLifecycleDelegate: AnyObject {
    var lifecycleCurrentState: CaptureManager.State { get }
    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL?
    func lifecycleResumeCapture(trigger: String) async throws
    func lifecycleTransitionToError(message: String, trigger: String)
    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool)
}

@MainActor
final class CaptureLifecycleManager {
    weak var delegate: (any CaptureLifecycleDelegate)?

    nonisolated(unsafe) private var retryTimer: Timer?
    private let retryDelays: [TimeInterval] = [5, 30, 60]
    private let maxRetryCount = 20
    private var retryCount: Int = 0
    private var isRecovering: Bool = false
    private(set) var suspendedForRecovery: Bool = false
    private var unlockResumeTask: Task<Void, Never>?

    nonisolated(unsafe) private var willSleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didWakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenLockedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenUnlockedObserver: NSObjectProtocol?

    init() {}

    func configure(delegate: any CaptureLifecycleDelegate) {
        guard willSleepObserver == nil else { return }
        self.delegate = delegate

        willSleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWillSleep()
            }
        }

        didWakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleDidWake()
            }
        }

        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreenLocked()
            }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreenUnlocked()
            }
        }
    }

    deinit {
        if let observer = willSleepObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = didWakeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        retryTimer?.invalidate()
        unlockResumeTask?.cancel()
    }

    func reset(stopRecovery: Bool) {
        suspendedForRecovery = false
        unlockResumeTask?.cancel()
        unlockResumeTask = nil
        if stopRecovery {
            stopRecoveryTimer()
        }
    }

    func startRecoveryIfNeeded(message: String) {
        if isPermissionError(message) {
            Logger.capture.info("[Recovery] Skipping auto-recovery: permission error requires user action")
        } else {
            startRecoveryTimer()
        }
    }

    private func handleWillSleep() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] willSleep (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        // Cancel any pending unlock resume — sleep supersedes it
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        guard delegate?.lifecycleCurrentState.isRecording == true else { return }

        suspendedForRecovery = true

        let completedURL = await delegate?.lifecyclePauseCapture(trigger: "sleep", stopAudio: false)

        // Use beginActivity to request time for upload before system suspends
        // Fire async to avoid blocking MainActor during sleep transition
        if let url = completedURL {
            delegate?.lifecycleProcessSegment(url, useSleepActivity: true)
        }

        Logger.capture.info("Capture paused for sleep")
    }

    private func handleDidWake() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] didWake (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }

        // Already recording (shouldn't happen, but guard against double-start)
        guard delegate?.lifecycleCurrentState.isRecording != true else {
            Logger.capture.warning("[Event] didWake: already recording, skipping resume")
            return
        }

        // If screen is locked, defer resume to unlock handler
        guard !isScreenLocked() else {
            Logger.capture.info("Screen is locked after wake, deferring to unlock handler")
            return
        }

        do {
            await waitForAudioDevices(timeout: 5.0)
            try await delegate?.lifecycleResumeCapture(trigger: "wake")
            suspendedForRecovery = false
            Logger.capture.info("Capture resumed after wake")
        } catch {
            delegate?.lifecycleTransitionToError(
                message: "Failed to resume after wake: \(error.localizedDescription)",
                trigger: "wake_failed"
            )
            Logger.capture.error("Failed to resume capture after wake: \(error, privacy: .public)")
        }
    }

    private func handleScreenLocked() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] screenLocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        // Cancel any pending unlock resume
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        guard delegate?.lifecycleCurrentState.isRecording == true else { return }

        suspendedForRecovery = true

        let completedURL = await delegate?.lifecyclePauseCapture(trigger: "lock", stopAudio: true)

        // Trigger upload callback
        if let url = completedURL {
            delegate?.lifecycleProcessSegment(url, useSleepActivity: false)
        }

        Logger.capture.info("Capture paused for screen lock")
    }

    private func handleScreenUnlocked() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] screenUnlocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }

        // Already recording (shouldn't happen, but guard against double-start)
        guard delegate?.lifecycleCurrentState.isRecording != true else {
            Logger.capture.warning("[Event] screenUnlocked: already recording, skipping resume")
            return
        }

        // Cancel any existing debounce task
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        // Debounce: wait 0.5s before resuming to handle rapid lock/unlock cycling
        unlockResumeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                // Task was cancelled (rapid re-lock)
                return
            }

            guard let self else { return }

            // Re-check state after debounce
            guard self.suspendedForRecovery,
                  self.delegate?.lifecycleCurrentState.isRecording != true else { return }

            do {
                await self.waitForAudioDevices(timeout: 5.0)
                try await self.delegate?.lifecycleResumeCapture(trigger: "unlock")
                self.suspendedForRecovery = false
                self.unlockResumeTask = nil
                Logger.capture.info("Capture resumed after unlock")
            } catch {
                self.delegate?.lifecycleTransitionToError(
                    message: "Failed to resume after unlock: \(error.localizedDescription)",
                    trigger: "unlock_failed"
                )
                Logger.capture.error("Failed to resume capture after unlock: \(error, privacy: .public)")
            }
        }
    }

    private func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool else {
            return false
        }
        return locked
    }

    private func waitForAudioDevices(timeout: TimeInterval) async {
        let startTime = Date()
        let pollInterval: UInt64 = 100_000_000 // 100ms in nanoseconds

        while Date().timeIntervalSince(startTime) < timeout {
            let devices = MicrophoneMonitor.listInputDevices()
            if !devices.isEmpty {
                Logger.capture.info("Audio devices available after \(String(format: "%.1f", Date().timeIntervalSince(startTime)), privacy: .public)s")
                return
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        // Timeout reached - log warning but don't fail
        // Recording can proceed without mic if needed
        Logger.capture.warning("Timeout waiting for audio devices after \(timeout, privacy: .public)s")
    }

    private func startRecoveryTimer() {
        retryTimer?.invalidate()

        guard retryCount < maxRetryCount else {
            Logger.capture.error("[Recovery] Giving up after \(self.maxRetryCount, privacy: .public) failed attempts")
            return
        }

        let delay = retryCount < retryDelays.count ? retryDelays[retryCount] : 300.0
        Logger.capture.info("[Recovery] Scheduling attempt \(self.retryCount + 1, privacy: .public)/\(self.maxRetryCount, privacy: .public) in \(Int(delay), privacy: .public)s")

        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.attemptRecovery()
            }
        }
        retryTimer?.tolerance = 5.0
    }

    private func stopRecoveryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        isRecovering = false
    }

    private func attemptRecovery() async {
        guard delegate?.lifecycleCurrentState.isError == true else {
            stopRecoveryTimer()
            return
        }

        guard !isScreenLocked() else {
            Logger.capture.info("[Recovery] Screen is locked, deferring recovery")
            startRecoveryTimer()
            return
        }

        // Don't attempt recovery without screen capture permission
        let hasAccess = CGPreflightScreenCaptureAccess()
        Logger.capture.warning("[Permissions] CaptureLifecycleManager.attemptRecovery: CGPreflightScreenCaptureAccess() = \(hasAccess, privacy: .public)")
        guard hasAccess else {
            Logger.capture.info("[Recovery] No screen capture permission, stopping recovery")
            stopRecoveryTimer()
            return
        }

        guard !isRecovering else {
            Logger.capture.info("[Recovery] Already in progress, skipping")
            return
        }

        isRecovering = true
        defer { isRecovering = false }

        let attempt = retryCount + 1
        Logger.capture.info("[Recovery] Attempting recovery \(attempt, privacy: .public)/\(self.maxRetryCount, privacy: .public)")

        do {
            try await delegate?.lifecycleResumeCapture(trigger: "recovery")
            stopRecoveryTimer()
            Logger.capture.info("[Recovery] Successfully recovered on attempt \(attempt, privacy: .public)")
        } catch {
            retryCount += 1
            Logger.capture.info("[Recovery] Attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")

            if isPermissionError(error) {
                Logger.capture.info("[Recovery] Permission error detected, stopping auto-recovery")
                stopRecoveryTimer()
            } else if retryCount >= maxRetryCount {
                Logger.capture.error("[Recovery] Giving up after \(self.maxRetryCount, privacy: .public) failed attempts")
            } else {
                startRecoveryTimer()
            }
        }
    }
}
