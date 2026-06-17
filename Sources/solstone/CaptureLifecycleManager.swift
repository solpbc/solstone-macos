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
    private struct InFlightPause {
        let id: UInt64
        let trigger: String
        let task: Task<URL?, Never>
    }

    private struct PendingResume {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private enum PauseSettleResult {
        case settled
        case timedOut
        case notPaused(String)
    }

    weak var delegate: (any CaptureLifecycleDelegate)?

    private var recoveryTimer: (any RecoveryTimerToken)?
    private static let retryDelays: [TimeInterval] = [5, 30, 60]
    private static let fallbackRecoveryDelay: TimeInterval = 300
    private let maxRetryCount = 20
    private var retryCount: Int = 0
    private var isRecovering: Bool = false
    private(set) var suspendedForRecovery: Bool = false
    private var nextPauseID: UInt64 = 0
    private var inFlightPause: InFlightPause?
    private var nextResumeID: UInt64 = 0
    private var pendingResumeTask: PendingResume?
    private let recoveryScheduler: RecoveryScheduler
    private let isScreenLockedProvider: @MainActor () -> Bool
    private let unlockResumeDelay: @MainActor @Sendable () async throws -> Void
    private let pauseSettleTimeoutSeconds: TimeInterval

    nonisolated(unsafe) private var willSleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var didWakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenLockedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenUnlockedObserver: NSObjectProtocol?

    internal init(
        recoveryScheduler: @escaping RecoveryScheduler = CaptureLifecycleManager.liveRecoveryScheduler,
        isScreenLocked: @escaping @MainActor () -> Bool = CaptureLifecycleManager.defaultIsScreenLocked,
        unlockResumeDelay: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: 500_000_000)
        },
        pauseSettleTimeoutSeconds: TimeInterval = 30
    ) {
        self.recoveryScheduler = recoveryScheduler
        self.isScreenLockedProvider = isScreenLocked
        self.unlockResumeDelay = unlockResumeDelay
        self.pauseSettleTimeoutSeconds = pauseSettleTimeoutSeconds
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

    internal var hasInFlightPauseForTesting: Bool {
        inFlightPause != nil
    }

    internal var hasPendingResumeTaskForTesting: Bool {
        pendingResumeTask != nil
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
            pendingResumeTask?.task.cancel()
            pendingResumeTask = nil
            inFlightPause?.task.cancel()
            inFlightPause = nil
        }
    }

    func reset(stopRecovery: Bool) {
        suspendedForRecovery = false
        pendingResumeTask?.task.cancel()
        pendingResumeTask = nil
        inFlightPause?.task.cancel()
        inFlightPause = nil
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

    internal func handleWillSleep() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] willSleep (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        // Cancel any pending lifecycle resume; sleep supersedes it.
        pendingResumeTask?.task.cancel()
        pendingResumeTask = nil

        guard delegate?.lifecycleCurrentState.isRecording == true || inFlightPause != nil else { return }

        suspendedForRecovery = true

        let lease = beginOrJoinPause(trigger: "sleep", stopAudio: false)
        let completedURL = await lease.pause.task.value

        if inFlightPause?.id == lease.pause.id {
            inFlightPause = nil
        }

        // Use beginActivity to request time for remix commit before system suspends.
        // Fire async to avoid blocking MainActor during sleep transition.
        if lease.created, let url = completedURL {
            delegate?.lifecycleProcessSegment(url, useSleepActivity: true)
        }

        Logger.capture.info("Capture paused for sleep")
    }

    internal func handleDidWake() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] didWake (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }

        // If screen is locked, defer resume to unlock handler
        guard !isScreenLocked() else {
            Logger.capture.info("Screen is locked after wake, deferring to unlock handler")
            return
        }

        pendingResumeTask?.task.cancel()
        pendingResumeTask = nil

        let resume = schedulePendingResume(trigger: "wake", useDebounce: false)
        await resume.task.value
    }

    internal func handleScreenLocked() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] screenLocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        // Cancel any pending lifecycle resume; lock supersedes it.
        pendingResumeTask?.task.cancel()
        pendingResumeTask = nil

        guard delegate?.lifecycleCurrentState.isRecording == true || inFlightPause != nil else { return }

        suspendedForRecovery = true

        let lease = beginOrJoinPause(trigger: "lock", stopAudio: true)
        let completedURL = await lease.pause.task.value

        if inFlightPause?.id == lease.pause.id {
            inFlightPause = nil
        }

        // Drain the remix queue so the locked segment is committed.
        if lease.created, let url = completedURL {
            delegate?.lifecycleProcessSegment(url, useSleepActivity: false)
        }

        Logger.capture.info("Capture paused for screen lock")
    }

    internal func handleScreenUnlocked() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] screenUnlocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }

        // Replace any pending lifecycle resume with the latest unlock.
        pendingResumeTask?.task.cancel()
        pendingResumeTask = nil

        _ = schedulePendingResume(trigger: "unlock", useDebounce: true)
    }

    private func beginOrJoinPause(trigger: String, stopAudio: Bool) -> (pause: InFlightPause, created: Bool) {
        if let existing = inFlightPause {
            Logger.capture.info("[Event] \(trigger, privacy: .public): pause already in flight from \(existing.trigger, privacy: .public); coalescing")
            return (existing, false)
        }

        nextPauseID &+= 1
        let id = nextPauseID
        let task: Task<URL?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            return await self.delegate?.lifecyclePauseCapture(trigger: trigger, stopAudio: stopAudio)
        }
        let pause = InFlightPause(id: id, trigger: trigger, task: task)
        inFlightPause = pause
        return (pause, true)
    }

    private func schedulePendingResume(trigger: String, useDebounce: Bool) -> PendingResume {
        nextResumeID &+= 1
        let id = nextResumeID
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPendingResume(id: id, trigger: trigger, useDebounce: useDebounce)
        }
        let resume = PendingResume(id: id, task: task)
        pendingResumeTask = resume
        return resume
    }

    private func runPendingResume(id: UInt64, trigger: String, useDebounce: Bool) async {
        defer {
            if pendingResumeTask?.id == id {
                pendingResumeTask = nil
            }
        }

        if useDebounce {
            do {
                // Coalesce rapid unlock cycles before waiting for pause settlement.
                try await unlockResumeDelay()
                try Task.checkCancellation()
            } catch {
                return
            }
        }

        guard suspendedForRecovery else { return }

        let settle = await waitForPauseToSettle(trigger: trigger)
        guard case .settled = settle else { return }

        do {
            try Task.checkCancellation()
        } catch {
            return
        }

        guard suspendedForRecovery else { return }

        await waitForAudioDevices(timeout: 5.0)

        do {
            try Task.checkCancellation()
        } catch {
            return
        }

        guard suspendedForRecovery else { return }

        do {
            try await delegate?.lifecycleResumeCapture(trigger: trigger)
            suspendedForRecovery = false
            Logger.capture.info("Capture resumed after \(trigger, privacy: .public)")
        } catch {
            delegate?.lifecycleTransitionToError(
                message: "Failed to resume after \(trigger): \(error.localizedDescription)",
                error: error,
                trigger: "\(trigger)_failed"
            )
            Logger.capture.error("Failed to resume capture after \(trigger, privacy: .public): \(error, privacy: .public)")
        }
    }

    private func waitForPauseToSettle(trigger: String) async -> PauseSettleResult {
        if let pause = inFlightPause {
            do {
                _ = try await withTimeout(seconds: pauseSettleTimeoutSeconds) {
                    await pause.task.value
                }

                if inFlightPause?.id == pause.id {
                    inFlightPause = nil
                }
            } catch is TimeoutError {
                let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
                Logger.capture.warning("[Event] \(trigger, privacy: .public): timed out waiting \(self.pauseSettleTimeoutSeconds, privacy: .public)s for in-flight pause to settle; resume skipped (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")
                return .timedOut
            } catch {
                let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
                Logger.capture.warning("[Event] \(trigger, privacy: .public): pause settle wait failed; resume skipped (state: \(stateLabel, privacy: .public), error: \(error, privacy: .public))")
                return .timedOut
            }
        }

        guard delegate?.lifecycleCurrentState.isPaused == true else {
            let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
            Logger.capture.warning("[Event] \(trigger, privacy: .public): pause settled but state is \(stateLabel, privacy: .public); resume skipped")
            return .notPaused(stateLabel)
        }

        return .settled
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
