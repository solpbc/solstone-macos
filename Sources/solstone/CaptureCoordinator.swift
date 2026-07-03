// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Observation
import os
@preconcurrency import ScreenCaptureKit

@MainActor
@Observable
public final class CaptureCoordinator {
    public typealias MicUIDConfig = (disabled: Set<String>, enabled: Set<String>)
    public typealias IsTerminatingProvider = @MainActor () -> Bool
    public typealias MicUIDConfigProvider = @MainActor () -> MicUIDConfig
    public typealias BannerSink = @MainActor (String?) -> Void
    public typealias StartOperation = @MainActor (StartReason, MicUIDConfig) async -> TransitionOutcome

    public internal(set) var isRecording = false
    public internal(set) var isPaused = false
    public internal(set) var isUserPaused = false
    public internal(set) var captureError: String?
    public internal(set) var screenRecordingGranted = false
    public internal(set) var microphoneGranted = false
    public internal(set) var initialPermissionCheckComplete = false
    public internal(set) var captureQueuedForJournalReadiness = false
    public internal(set) var audioReconciledCount: Int = 0

    public let captureManager: CaptureManager
    public let pauseManager: PauseManager

    private let audioDeviceMonitor: AudioDeviceMonitor
    private let isTerminating: IsTerminatingProvider
    private let configProvider: MicUIDConfigProvider
    private let bannerSink: BannerSink
    private let startOperation: StartOperation

    private var permissionPollTimer: Timer?
    private var isCheckingPermissions = false

    public init(
        captureManager: CaptureManager,
        pauseManager: PauseManager,
        audioDeviceMonitor: AudioDeviceMonitor,
        isTerminating: @escaping IsTerminatingProvider,
        configProvider: @escaping MicUIDConfigProvider,
        bannerSink: @escaping BannerSink,
        startOperation: StartOperation? = nil
    ) {
        self.captureManager = captureManager
        self.pauseManager = pauseManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isTerminating = isTerminating
        self.configProvider = configProvider
        self.bannerSink = bannerSink
        self.startOperation = startOperation ?? { [captureManager] reason, config in
            await captureManager.enqueueTransition(
                .start(
                    reason: reason,
                    disabledMicUIDs: config.disabled,
                    enabledMicUIDs: config.enabled
                )
            )
        }
    }

    deinit {
        MainActor.assumeIsolated {
            permissionPollTimer?.invalidate()
        }
    }

    public func heartbeatIsPausedProvider() -> HeartbeatService.IsPausedProvider {
        {
            // Strong self is safe: CaptureCoordinator never holds a reference to HeartbeatService, so no retain cycle. Keep it that way.
            self.isPaused
        }
    }

    public func activate() {
        captureManager.onStateChanged = { [weak self] state in
            self?.handleCaptureStateChange(state)
        }

        audioDeviceMonitor.onDeviceChange = { [weak self] added, removed in
            Task { @MainActor in
                await self?.captureManager.handleDeviceChange(added: added, removed: removed)
            }
        }

        pauseManager.onPause = { [weak self] in
            _ = await self?.captureManager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        }
        pauseManager.onResume = { [weak self] in
            _ = await self?.captureManager.enqueueTransition(.resume(reason: .user))
        }

        pauseManager.restorePauseState()
        startPermissionPolling()
    }

    func handleCaptureStateChange(_ state: CaptureManager.State) {
        switch state {
        case .idle:
            isRecording = false
            isPaused = false
            isUserPaused = false
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        case .recording:
            isRecording = true
            isPaused = false
            isUserPaused = false
            captureError = nil
            bannerSink(nil)
            stopPermissionPolling()
        case .paused(let reasons):
            isRecording = true
            isPaused = true
            isUserPaused = reasons.contains(.user)
        case .error(let message):
            isRecording = false
            isPaused = false
            isUserPaused = false
            captureError = message
            bannerSink(message)
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        }
    }

    public func startRecording(reason: StartReason = .user) async {
        guard !isTerminating() else {
            Logger.general.info("startRecording() ignored because app is terminating")
            return
        }

        let wasUserPaused = isUserPaused
        let config = configProvider()
        let outcome = await startOperation(reason, config)
        switch outcome {
        case .committed:
            screenRecordingGranted = true
            if wasUserPaused {
                pauseManager.clearPolicyStateSilently()
            }
        case .threw(let failure):
            if failure.isPermissionError {
                Logger.general.info("[Permissions] Recording denied — screen recording permission not granted")
                screenRecordingGranted = false
            } else {
                Logger.general.error("Recording failed to start: \(failure.message, privacy: .public)")
                captureError = UICopy.ERROR_START_OBSERVING
                bannerSink(UICopy.ERROR_START_OBSERVING)
            }
        case .vetoed:
            Logger.general.info("startRecording() vetoed")
        case .dropped:
            Logger.general.info("startRecording() dropped")
        }
    }

    @discardableResult
    public func stopRecording(reason: StopReason = .user) async -> TransitionOutcome {
        let wasUserPaused = isUserPaused
        let outcome = await captureManager.enqueueTransition(.stop(reason: reason))
        if wasUserPaused, case .committed = outcome {
            pauseManager.clearPolicyStateSilently()
        }
        return outcome
    }

    public func toggleRecording() async {
        if isUserPaused {
            pauseManager.resume()
        } else if isRecording && !isPaused {
            await stopRecording(reason: .user)
        } else {
            await startRecording(reason: .user)
        }
    }

    private func startPermissionPolling() {
        Task { @MainActor in
            await self.checkPermissionsAndAutoStart()
        }

        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkPermissionsAndAutoStart()
            }
        }
        permissionPollTimer?.tolerance = 2.0
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func checkPermissionsAndAutoStart() async {
        guard !isCheckingPermissions else { return }
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }

        let checker = PermissionChecker()

        if checker.hasPromptedScreenRecording {
            // Gate on CGPreflightScreenCaptureAccess before touching SCShareableContent.
            // On macOS 26, SCShareableContent.current re-triggers the OS dialog when no TCC
            // entry exists — i.e. while the user has been prompted but hasn't granted yet.
            // CGPreflightScreenCaptureAccess returns true only when a valid TCC entry exists.
            if CGPreflightScreenCaptureAccess() {
                let granted = await PermissionChecker.checkScreenRecording()
                if !granted {
                    // Preflight passed but SCShareableContent failed — CDHash changed after
                    // reinstall. Reset prompted flag so user re-grants via the button.
                    PermissionChecker.resetPromptedFlag()
                    Logger.setup.info("[Permissions] Screen recording access lost (CDHash changed?) — resetting prompt flag")
                }
                screenRecordingGranted = granted
            }
            // else: no TCC entry yet — user hasn't granted in System Settings, wait silently
        }
        microphoneGranted = checker.microphoneGranted

        let allGranted = screenRecordingGranted && microphoneGranted

        // Auto-start if permissions are ready, not paused, and not already recording
        if allGranted && !isRecording && !isUserPaused {
            if isTerminating() {
                Logger.general.info("[Permissions] auto-start skipped because app is terminating")
            } else {
                Logger.general.info("[Permissions] all granted, auto-starting observation")
                await startRecording(reason: .autoStart)
            }
        }

        // Stop polling once recording is active — lifecycle manager handles recovery from there
        if isRecording {
            stopPermissionPolling()
        }

        initialPermissionCheckComplete = true
    }

    internal var isPermissionPollingActiveForTesting: Bool {
        permissionPollTimer != nil
    }
}
