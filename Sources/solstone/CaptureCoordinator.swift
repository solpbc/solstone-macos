// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Observation
import os
@preconcurrency import ScreenCaptureKit

internal enum ScreenRecordingPermissionEvidence: Equatable {
    case granted
    case notGranted
    case unavailable
}

private enum MicrophonePermissionEvidence: Equatable {
    case granted
    case notGranted
    case unavailable
}

private enum CaptureStateEvidence: Equatable {
    case on
    case paused
    case off
    case error
}

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
    private var storedScreenRecordingGranted = false
    public var screenRecordingGranted: Bool { storedScreenRecordingGranted }
    internal var microphoneAuthorizationCause: MicrophoneAuthorizationCause = .unknown
    public internal(set) var initialPermissionCheckComplete = false
    public internal(set) var captureQueuedForJournalReadiness = false
    public internal(set) var audioReconciledCount: Int = 0

    public var microphoneGranted: Bool {
        microphoneAuthorizationCause == .authorized
    }

    public let captureManager: CaptureManager
    public let pauseManager: PauseManager

    @ObservationIgnored
    internal var microphoneAuthorizationReader: @MainActor @Sendable () -> MicrophoneAuthorizationCause = {
        PermissionChecker().microphoneAuthorizationCause
    }

    private let audioDeviceMonitor: AudioDeviceMonitor
    private let isTerminating: IsTerminatingProvider
    private let configProvider: MicUIDConfigProvider
    private let bannerSink: BannerSink
    private let startOperation: StartOperation
    private let recorder: DiagnosticEvidenceRecorder
    private let screenPermissionProvider: ScreenRecordingPermissionProvider
    private let permissionPollScheduler: PermissionPollScheduler
    private let logAdapter: DiagnosticEvidenceLoggingAdapter

    private var permissionPollCancellation: PermissionPollScheduler.Cancellation?
    private var isCheckingPermissions = false
    private var lastScreenPermissionEvidence: ScreenRecordingPermissionEvidence?
    private var lastMicrophonePermissionEvidence: MicrophonePermissionEvidence?
    private var lastCaptureStateEvidence: CaptureStateEvidence?

    init(
        captureManager: CaptureManager,
        pauseManager: PauseManager,
        audioDeviceMonitor: AudioDeviceMonitor,
        isTerminating: @escaping IsTerminatingProvider,
        configProvider: @escaping MicUIDConfigProvider,
        bannerSink: @escaping BannerSink,
        startOperation: StartOperation? = nil,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        permissionPollScheduler: PermissionPollScheduler = .live(),
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live
    ) {
        self.captureManager = captureManager
        self.pauseManager = pauseManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isTerminating = isTerminating
        self.configProvider = configProvider
        self.bannerSink = bannerSink
        self.recorder = recorder
        self.screenPermissionProvider = screenPermissionProvider
        self.permissionPollScheduler = permissionPollScheduler
        self.logAdapter = logAdapter
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
            permissionPollCancellation?()
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

        pauseManager.clearPersistedPauseState()
        startPermissionPolling()
    }

    func handleCaptureStateChange(_ state: CaptureManager.State) {
        publishCaptureStateEvidence(for: state)

        switch state {
        case .idle:
            isRecording = false
            isPaused = false
            isUserPaused = false
            if permissionPollCancellation == nil {
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
            if permissionPollCancellation == nil {
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
            publishScreenRecordingPermission(.granted)
            if wasUserPaused {
                pauseManager.clearPolicyStateSilently()
            }
        case .threw(let failure):
            if failure.isPermissionError {
                Logger.general.info("[Permissions] Recording denied, screen recording permission not granted")
                publishScreenRecordingPermission(.notGranted)
            } else {
                Logger.general.error("Recording failed to start: \(failure.message, privacy: .public)")
                publishCaptureStateEvidence(for: .error(failure.message))
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

    internal func refreshMicrophoneAuthorization() {
        let cause = microphoneAuthorizationReader()
        microphoneAuthorizationCause = cause
        publishMicrophoneAuthorization(cause)
    }

    private func startPermissionPolling() {
        permissionPollCancellation?()
        permissionPollCancellation = permissionPollScheduler.armPolling { [weak self] in
            await self?.checkPermissionsAndAutoStart()
        }
    }

    private func stopPermissionPolling() {
        permissionPollCancellation?()
        permissionPollCancellation = nil
    }

    internal func checkPermissionsAndAutoStart() async {
        guard !isCheckingPermissions else { return }
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }

        if screenPermissionProvider.hasPrompted() {
            // Gate on CGPreflightScreenCaptureAccess before touching SCShareableContent.
            // On macOS 26, SCShareableContent.current re-triggers the OS dialog when no TCC
            // entry exists — i.e. while the user has been prompted but hasn't granted yet.
            // CGPreflightScreenCaptureAccess returns true only when a valid TCC entry exists.
            if screenPermissionProvider.preflight() {
                let granted = await screenPermissionProvider.checkScreenRecording()
                if granted {
                    publishScreenRecordingPermission(.granted)
                } else {
                    // Preflight passed but ScreenCaptureKit failed — a changed CDHash can leave
                    // the TCC record unusable. This recurring signal must precede unavailable.
                    screenPermissionProvider.resetPromptedFlag()
                    recorder.enqueue(.screenRecordingCDHashMismatch)
                    logAdapter.screenRecordingCDHashMismatch()
                    publishScreenRecordingPermission(.unavailable)
                }
            } else {
                publishScreenRecordingPermission(.notGranted)
            }
        } else {
            publishScreenRecordingPermission(.unavailable)
        }

        let microphoneCause = microphoneAuthorizationReader()
        microphoneAuthorizationCause = microphoneCause
        publishMicrophoneAuthorization(microphoneCause)

        let allGranted = screenRecordingGranted && microphoneGranted

        // Auto-start if permissions are ready, not paused, not already recording, and recovery is not scheduled
        if allGranted && !isRecording && !isUserPaused && !captureManager.isRecoveryScheduled {
            if isTerminating() {
                recorder.enqueue(.permissionAutoStartSkipped)
                logAdapter.permissionAutoStartSkipped()
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
        permissionPollCancellation != nil
    }

    internal func publishScreenRecordingPermission(_ evidence: ScreenRecordingPermissionEvidence) {
        storedScreenRecordingGranted = evidence == .granted
        guard lastScreenPermissionEvidence != evidence else { return }
        lastScreenPermissionEvidence = evidence

        switch evidence {
        case .granted:
            recorder.enqueue(.screenRecordingGranted)
        case .notGranted:
            recorder.enqueue(.screenRecordingNotGranted)
        case .unavailable:
            recorder.enqueue(.screenRecordingUnavailable)
        }
    }

    private func publishMicrophoneAuthorization(_ cause: MicrophoneAuthorizationCause) {
        let evidence: MicrophonePermissionEvidence
        switch cause {
        case .authorized:
            evidence = .granted
        case .notDetermined, .denied, .restricted:
            evidence = .notGranted
        case .unknown:
            evidence = .unavailable
        }

        guard lastMicrophonePermissionEvidence != evidence else { return }
        lastMicrophonePermissionEvidence = evidence

        switch evidence {
        case .granted:
            recorder.enqueue(.microphoneGranted)
        case .notGranted:
            recorder.enqueue(.microphoneNotGranted)
        case .unavailable:
            recorder.enqueue(.microphoneUnavailable)
        }
    }

    private func publishCaptureStateEvidence(for state: CaptureManager.State) {
        let evidence: CaptureStateEvidence
        switch state {
        case .recording:
            evidence = .on
        case .paused:
            evidence = .paused
        case .idle:
            evidence = .off
        case .error:
            evidence = .error
        }

        guard lastCaptureStateEvidence != evidence else { return }
        lastCaptureStateEvidence = evidence

        switch evidence {
        case .on:
            recorder.enqueue(.captureOn)
        case .paused:
            recorder.enqueue(.capturePaused)
        case .off:
            recorder.enqueue(.captureOff)
        case .error:
            recorder.enqueue(.captureError)
        }
    }
}
