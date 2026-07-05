// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
@preconcurrency import ScreenCaptureKit

@MainActor
protocol CaptureLifecycleDelegate: AnyObject {
    var lifecycleCurrentState: CaptureManager.State { get }
    func lifecycleStartCapture(
        reason: StartReason,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async throws -> StartResult
    func lifecycleResetForRestartFromError() async
    func lifecycleStartFromErrorFailed(_ failure: TransitionFailure)
    func lifecycleStopCapture(reason: StopReason) async
    func lifecycleRotateSegment(
        reason: RotateReason,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async -> RotationResult
    func lifecyclePauseCapture(reason: PauseReason, stopAudio: Bool) async -> URL?
    func lifecycleApplyResumeReason(_ reason: ResumeReason) -> ResumeResolution
    func lifecyclePrepareResume(trigger: String) async throws
    func lifecycleCommitResume(trigger: String)
    func lifecycleAbortPreparedResume(restore: Set<PauseReason>?, trigger: String) async
    func lifecycleTransitionToError(message: String, error: Error, trigger: String)
    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool)
}

enum ResumeResolution: Sendable {
    case stayedPaused
    case readyToResume(restore: Set<PauseReason>)
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
    private let recoveryScheduler: RecoveryScheduler
    private let isScreenLockedProvider: @MainActor () -> Bool
    private let executor: CaptureExecutor

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
        transitionTimeoutSeconds: TimeInterval = 30
    ) {
        self.recoveryScheduler = recoveryScheduler
        self.isScreenLockedProvider = isScreenLocked
        self.executor = CaptureExecutor(
            isScreenLocked: isScreenLocked,
            unlockResumeDelay: unlockResumeDelay,
            preResumeSettle: {
                await CaptureLifecycleManager.waitForAudioDevices(timeout: 5.0)
            },
            transitionTimeoutSeconds: transitionTimeoutSeconds
        )
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

    internal var isRecoveryScheduled: Bool {
        recoveryTimer != nil
    }

    internal var suspendedForRecovery: Bool {
        executor.suspendedForRecovery
    }

    internal var queuedIntentSnapshotForTesting: [IntentSnapshot] {
        executor.queuedIntentSnapshotForTesting
    }

    internal var queuedIntentCountForTesting: Int {
        executor.queuedIntentCountForTesting
    }

    internal var inFlightIntentForTesting: IntentSnapshot? {
        executor.inFlightIntentForTesting
    }

    internal var lastVetoReasonForTesting: VetoReason? {
        executor.lastVetoReasonForTesting
    }

    func configure(delegate: any CaptureLifecycleDelegate) {
        guard willSleepObserver == nil else { return }
        self.delegate = delegate
        executor.delegate = delegate

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
            executor.reset()
        }
    }

    func reset(stopRecovery: Bool) {
        executor.reset()
        if stopRecovery {
            stopRecoveryTimer()
        }
    }

    func resetLifecyclePendingState(stopRecovery: Bool) {
        executor.resetLifecyclePendingState()
        if stopRecovery {
            stopRecoveryTimer()
        }
    }

    @discardableResult
    func enqueue(_ intent: CaptureIntent) async -> TransitionOutcome {
        await executor.enqueue(intent)
    }

    func startRecoveryIfNeeded(error: Error) {
        if isPermissionError(error) {
            Logger.capture.info("[Recovery] Skipping auto-recovery: permission error requires user action")
        } else {
            startRecoveryTimer()
        }
    }

    func noteStartFromErrorFailed(isPermissionError: Bool) {
        guard delegate?.lifecycleCurrentState.isError == true else { return }

        recoveryTimer?.invalidate()
        recoveryTimer = nil

        if isPermissionError {
            Logger.capture.info("[Recovery] Skipping restart recovery: permission error requires permission polling")
            return
        }

        retryCount = 0
        startRecoveryTimer()
    }

    internal func noteDisplayChange() async {
        guard delegate?.lifecycleCurrentState.isError == true else { return }
        guard recoveryTimer != nil || retryCount > 0 else { return }

        recoveryTimer?.invalidate()
        recoveryTimer = nil
        retryCount = 0

        await attemptRecovery()
    }

    internal func handleWillSleep() async {
        let state = delegate?.lifecycleCurrentState
        let stateLabel = state?.label ?? "unknown"
        Logger.capture.info("[Event] willSleep (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard state?.isRecording == true || state?.isPaused == true else { return }
        executor.markSuspendedForRecovery()
        _ = await executor.enqueue(.pause(reason: .sleep, stopAudio: false))
        Logger.capture.info("Capture paused for sleep")
    }

    internal func handleDidWake() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] didWake (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }

        // If screen is locked, defer resume to unlock handler.
        guard !isScreenLocked() else {
            Logger.capture.info("Screen is locked after wake, deferring to unlock handler")
            return
        }

        _ = await executor.enqueue(.resume(reason: .wake))
    }

    internal func handleScreenLocked() async {
        let state = delegate?.lifecycleCurrentState
        let stateLabel = state?.label ?? "unknown"
        Logger.capture.info("[Event] screenLocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard state?.isRecording == true || state?.isPaused == true else { return }
        executor.markSuspendedForRecovery()
        _ = await executor.enqueue(.pause(reason: .lock, stopAudio: true))
        Logger.capture.info("Capture paused for screen lock")
    }

    internal func handleScreenUnlocked() async {
        let stateLabel = delegate?.lifecycleCurrentState.label ?? "unknown"
        Logger.capture.info("[Event] screenUnlocked (state: \(stateLabel, privacy: .public), suspended: \(self.suspendedForRecovery, privacy: .public))")

        guard suspendedForRecovery else { return }
        executor.scheduleUnlockResume()
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

    private static func waitForAudioDevices(timeout: TimeInterval) async {
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

        // Timeout reached - log warning but don't fail.
        // Recording can proceed without mic if needed.
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
    }

    internal func attemptRecovery() async {
        guard delegate?.lifecycleCurrentState.isError == true else {
            stopRecoveryTimer()
            return
        }

        let attempt = retryCount + 1
        Logger.capture.info("[Recovery] Attempting recovery \(attempt, privacy: .public)/\(self.maxRetryCount, privacy: .public)")

        let outcome = await executor.enqueue(.resume(reason: .recovery))
        switch outcome {
        case .committed:
            stopRecoveryTimer()
            Logger.capture.info("[Recovery] Successfully recovered on attempt \(attempt, privacy: .public)")
        case .vetoed:
            stopRecoveryTimer()
            Logger.capture.info("[Recovery] Recovery resume vetoed on attempt \(attempt, privacy: .public)")
        case .dropped:
            stopRecoveryTimer()
            Logger.capture.info("[Recovery] Recovery resume dropped on attempt \(attempt, privacy: .public)")
        case .threw(let failure):
            retryCount += 1
            Logger.capture.info("[Recovery] Attempt \(attempt, privacy: .public) failed: \(failure.message, privacy: .public)")

            if failure.isPermissionError {
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
