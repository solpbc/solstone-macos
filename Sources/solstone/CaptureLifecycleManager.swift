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
    func lifecycleTransitionToError(message: String, error: Error, trigger: String)
    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool)
}

@MainActor
internal protocol RecoveryTimerToken: AnyObject {
    func invalidate()
}

internal typealias RecoveryScheduler = @MainActor (
    _ delay: TimeInterval,
    _ fire: @escaping @MainActor @Sendable () async -> Void
) -> any RecoveryTimerToken

@MainActor
private final class LiveRecoveryTimerToken: RecoveryTimerToken {
    private let timer: Timer

    init(_ timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

@MainActor
final class CaptureLifecycleManager {
    weak var delegate: (any CaptureLifecycleDelegate)?

    private var recoveryTimer: (any RecoveryTimerToken)?
    private static let retryDelays: [TimeInterval] = [5, 30, 60]
    private static let fallbackRecoveryDelay: TimeInterval = 300
    private let maxRetryCount = 20
    private var retryCount: Int = 0
    private var isRecovering: Bool = false
    private(set) var suspendedForRecovery: Bool = false
    private var unlockResumeTask: Task<Void, Never>?
    private let recoveryScheduler: RecoveryScheduler
    private let isScreenLockedProvider: @MainActor () -> Bool

    nonisolated(unsafe) private var willSleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didWakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenLockedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenUnlockedObserver: NSObjectProtocol?

    internal init(
        recoveryScheduler: @escaping RecoveryScheduler = CaptureLifecycleManager.liveRecoveryScheduler,
        isScreenLocked: @escaping @MainActor () -> Bool = CaptureLifecycleManager.defaultIsScreenLocked
    ) {
        self.recoveryScheduler = recoveryScheduler
        self.isScreenLockedProvider = isScreenLocked
    }

    private static func liveRecoveryScheduler(
        delay: TimeInterval,
        fire: @escaping @MainActor @Sendable () async -> Void
    ) -> any RecoveryTimerToken {
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                await fire()
            }
        }
        timer.tolerance = 5.0
        return LiveRecoveryTimerToken(timer)
    }

    internal static func recoveryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        guard retryCount >= 0 else { return retryDelays[0] }
        return retryCount < retryDelays.count ? retryDelays[retryCount] : fallbackRecoveryDelay
    }

    internal var retryCountForTesting: Int {
        retryCount
    }

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

        MainActor.assumeIsolated {
            recoveryTimer?.invalidate()
            unlockResumeTask?.cancel()
        }
    }

    func reset(stopRecovery: Bool) {
        suspendedForRecovery = false
        unlockResumeTask?.cancel()
        unlockResumeTask = nil
        if stopRecovery {
            stopRecoveryTimer()
        }
    }

    func startRecoveryIfNeeded(error: Error) {
        if isPermissionError(error) {
            Logger.capture.info("[Recovery] Skipping auto-recovery: permission error requires user action")
        } else {
            startRecoveryTimer()
        }
    }

    internal func noteDisplayChange() async {
        guard delegate?.lifecycleCurrentState.isError == true else { return }
        guard recoveryTimer != nil || retryCount > 0 || isRecovering else { return }

        recoveryTimer?.invalidate()
        recoveryTimer = nil
        retryCount = 0

        await attemptRecovery()
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

        // Use beginActivity to request time for remix commit before system suspends.
        // Fire async to avoid blocking MainActor during sleep transition.
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
                error: error,
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

        // Drain the remix queue so the locked segment is committed.
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
                    error: error,
                    trigger: "unlock_failed"
                )
                Logger.capture.error("Failed to resume capture after unlock: \(error, privacy: .public)")
            }
        }
    }

    private static func defaultIsScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool else {
            return false
        }
        return locked
    }

    private func isScreenLocked() -> Bool {
        isScreenLockedProvider()
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
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard retryCount < maxRetryCount else {
            Logger.capture.error("[Recovery] Giving up after \(self.maxRetryCount, privacy: .public) failed attempts")
            return
        }

        let delay = Self.recoveryDelay(forRetryCount: retryCount)
        Logger.capture.info("[Recovery] Scheduling attempt \(self.retryCount + 1, privacy: .public)/\(self.maxRetryCount, privacy: .public) in \(Int(delay), privacy: .public)s")

        recoveryTimer = recoveryScheduler(delay) { [weak self] in
            await self?.attemptRecovery()
        }
    }

    private func stopRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        retryCount = 0
        isRecovering = false
    }

    internal func attemptRecovery() async {
        guard delegate?.lifecycleCurrentState.isError == true else {
            stopRecoveryTimer()
            return
        }

        guard !isScreenLocked() else {
            Logger.capture.info("[Recovery] Screen is locked, deferring recovery")
            startRecoveryTimer()
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
                recoveryTimer?.invalidate()
                recoveryTimer = nil
                Logger.capture.error("[Recovery] Giving up after \(self.maxRetryCount, privacy: .public) failed attempts")
            } else {
                startRecoveryTimer()
            }
        }
    }
}
