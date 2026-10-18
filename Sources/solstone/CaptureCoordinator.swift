// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Foundation
import Observation
import os
@preconcurrency import ScreenCaptureKit
import SolstoneCore

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
    public typealias CaptureConfig = (sources: CaptureSources, disabled: Set<String>, enabled: Set<String>)
    public typealias IsTerminatingProvider = @MainActor () -> Bool
    public typealias CaptureConfigProvider = @MainActor () -> CaptureConfig
    public typealias BannerSink = @MainActor (String?) -> Void
    public typealias StartOperation = @MainActor (StartReason, CaptureSources, MicUIDConfig) async -> TransitionOutcome

    public internal(set) var isRecording = false
    public internal(set) var isPaused = false
    public internal(set) var isUserPaused = false
    public internal(set) var isExplicitlyStopped = false
    public internal(set) var isUserStopped = false
    public internal(set) var captureError: String?
    public internal(set) var screenFailure: ScreenFailureKind?
    internal func setSnapshotScreenFailure(_ failure: ScreenFailureKind?) {
        screenFailure = failure
    }
    /// Which audio source isn't coming through, or dropped out and is back. Shown as a plain line.
    public internal(set) var audioHealthNote: String?
    internal var screenRecordingNeedsRestart = false
    private var storedScreenRecordingGranted = false
    public var screenRecordingGranted: Bool { storedScreenRecordingGranted }
    internal var microphoneAuthorizationCause: MicrophoneAuthorizationCause = .unknown
    public internal(set) var initialPermissionCheckComplete = false
    public internal(set) var captureQueuedForJournalReadiness = false
    public internal(set) var audioReconciledCount: Int = 0
    public internal(set) var isStartDeferredForProtectedVideo = false

    public var microphoneGranted: Bool {
        microphoneAuthorizationCause == .authorized
    }

    public var permittedSources: CaptureSources {
        var sources: CaptureSources = []
        if screenRecordingGranted {
            sources.insert(.screen)
        }
        if microphoneGranted {
            sources.insert(.microphone)
        }
        return sources
    }

    public let captureManager: CaptureManager
    public let pauseManager: PauseManager

    @ObservationIgnored
    internal var microphoneAuthorizationReader: @MainActor @Sendable () -> MicrophoneAuthorizationCause = {
        PermissionChecker().microphoneAuthorizationCause
    }

    private let audioDeviceMonitor: AudioDeviceMonitor
    private let isTerminating: IsTerminatingProvider
    private let configProvider: CaptureConfigProvider
    /// Lets the app add newly connected microphones to its list before capture reconciles.
    var onMicrophonesChanged: (@MainActor () -> Void)?
    var onCaptureStateChanged: (@MainActor (CaptureManager.State) -> Void)?
    var onPauseTriggered: (@MainActor () -> Void)?
    private let bannerSink: BannerSink
    private let setAsideSink: @MainActor (String) -> Void
    private let startOperation: StartOperation
    private let recorder: DiagnosticEvidenceRecorder
    private let screenPermissionProvider: ScreenRecordingPermissionProvider
    private let permissionPollScheduler: PermissionPollScheduler
    private let logAdapter: DiagnosticEvidenceLoggingAdapter
    private let classifiedLog: any ClassifiedLogSinking
    private let now: @MainActor () -> Date
    private let screenProbeFastWindow: TimeInterval
    private let screenProbeSlowInterval: TimeInterval
    private var screenProbeEpoch: Date
    private var screenProbeLastCounted: Date?
    private var screenProbeTask: Task<ScreenCaptureProbeResult, Never>?
    private var lastProbeLogSignature: String?
    private var activationObserver: (any NSObjectProtocol)?

    private var permissionPollCancellation: PermissionPollScheduler.Cancellation?
    private var isCheckingPermissions = false
    private var permissionStartReason: StartReason = .autoStart
    private var lastScreenPermissionEvidence: ScreenRecordingPermissionEvidence?
    private var lastMicrophonePermissionEvidence: MicrophonePermissionEvidence?
    private var lastCaptureStateEvidence: CaptureStateEvidence?

    init(
        captureManager: CaptureManager,
        pauseManager: PauseManager,
        audioDeviceMonitor: AudioDeviceMonitor,
        isTerminating: @escaping IsTerminatingProvider,
        configProvider: @escaping CaptureConfigProvider,
        bannerSink: @escaping BannerSink,
        setAsideSink: @escaping @MainActor (String) -> Void = { _ in },
        startOperation: StartOperation? = nil,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        permissionPollScheduler: PermissionPollScheduler = .live(),
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink.general,
        now: @escaping @MainActor () -> Date = Date.init,
        screenProbeFastWindow: TimeInterval = 120,
        screenProbeSlowInterval: TimeInterval = 15
    ) {
        self.captureManager = captureManager
        self.pauseManager = pauseManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isTerminating = isTerminating
        self.configProvider = configProvider
        self.bannerSink = bannerSink
        self.setAsideSink = setAsideSink
        self.recorder = recorder
        self.screenPermissionProvider = screenPermissionProvider
        self.permissionPollScheduler = permissionPollScheduler
        self.logAdapter = logAdapter
        self.classifiedLog = classifiedLog
        self.now = now
        self.screenProbeFastWindow = screenProbeFastWindow
        self.screenProbeSlowInterval = screenProbeSlowInterval
        self.screenProbeEpoch = now()
        self.screenProbeLastCounted = nil
        self.screenProbeTask = nil
        self.lastProbeLogSignature = nil
        self.startOperation = startOperation ?? { [captureManager] reason, sources, config in
            await captureManager.enqueueTransition(
                .start(
                    reason: reason,
                    sources: sources,
                    disabledMicUIDs: config.disabled,
                    enabledMicUIDs: config.enabled
                )
            )
        }
        self.captureManager.microphoneSelectionProvider = {
            let current = configProvider()
            return (disabled: current.disabled, enabled: current.enabled)
        }
        self.captureManager.configuredSourcesIncludeScreen = { [configProvider] in
            configProvider().sources.contains(.screen)
        }
        self.captureManager.onTerminalStreamStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecording(reason: .userStopped)
            }
        }
        self.activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteApplicationDidBecomeActive()
            }
        }
    }

    public func protectedVideoBlocksAutomaticScreenCaptureRead() -> Bool {
        let config = configProvider()
        guard config.sources.contains(.screen) else { return false }
        return captureManager.protectedVideoOnScreen(sourcesIncludeScreen: true)
    }

    deinit {
        MainActor.assumeIsolated {
            permissionPollCancellation?()
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
            }
        }
    }

    public func activate() {
        captureManager.onAudioCaptureIssue = { [weak self] message in self?.bannerSink(message) }
        captureManager.onSegmentSetAside = setAsideSink
        captureManager.onAudioHealthNote = { [weak self] note in self?.audioHealthNote = note }
        captureManager.onScreenFailureChanged = { [weak self] failure in self?.screenFailure = failure }
        captureManager.onStateChanged = { [weak self] state in
            self?.handleCaptureStateChange(state)
        }

        captureManager.onTerminalStreamStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecording(reason: .userStopped)
            }
        }

        audioDeviceMonitor.onDeviceChange = { [weak self] added, removed in
            Task { @MainActor in
                self?.onMicrophonesChanged?()
                await self?.captureManager.handleDeviceChange(added: added, removed: removed)
            }
        }

        pauseManager.onPause = { [weak self] in
            self?.onPauseTriggered?()
            _ = await self?.captureManager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        }
        pauseManager.onResume = { [weak self] cause in
            guard let self else { return }
            if self.captureManager.state.isPaused {
                _ = await self.captureManager.enqueueTransition(.resume(reason: cause == .explicit ? .user : .pauseDeadline))
            } else if !self.isRecording {
                await self.checkPermissionsAndAutoStart(startReason: cause == .explicit ? .user : .autoStart)
            }
        }

        captureManager.lifecycleManager.ownerPauseIsHeld = { [weak self] in
            self?.pauseManager.isPaused ?? false
        }
        startPermissionPolling()
    }

    func handleCaptureStateChange(_ state: CaptureManager.State) {
        publishCaptureStateEvidence(for: state)
        onCaptureStateChanged?(state)

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
            bannerSink(captureManager.currentAudioCaptureIssue)
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

    public func startRecording(reason: StartReason = .user, preservingPausePolicy: Bool = false) async {
        guard !isTerminating() else {
            Logger.general.info("startRecording() ignored because app is terminating")
            return
        }

        if pauseManager.isPaused, !preservingPausePolicy {
            Logger.general.info("startRecording() ignored because the owner pause is held")
            return
        }

        if reason == .user {
            clearOwnerStop()
        }

        let config = configProvider()
        if config.sources.contains(.screen),
           screenPermissionProvider.preflight(),
           captureManager.protectedVideoOnScreen(sourcesIncludeScreen: true) {
            isStartDeferredForProtectedVideo = true
            return
        }

        let admissionSet = config.sources.intersection(permittedSources)
        guard !admissionSet.isEmpty else {
            if config.sources.isEmpty {
                classifiedLog.emit(
                    ClassifiedLogEmission(
                        level: .notice,
                        classification: "capture-not-running",
                        publicFields: ["reason": "no-sources"]
                    )
                )
            } else {
                classifiedLog.emit(
                    ClassifiedLogEmission(
                        level: .notice,
                        classification: "capture-not-running",
                        publicFields: ["reason": "not-permitted"]
                    )
                )
            }
            return
        }

        let outcome = await startOperation(reason, admissionSet, (disabled: config.disabled, enabled: config.enabled))
        switch outcome {
        case .committed:
            isStartDeferredForProtectedVideo = false
            if captureManager.activeSources.contains(.screen) {
                publishScreenRecordingPermission(.granted)
            }
        case .heldForProtectedVideo:
            isStartDeferredForProtectedVideo = true
            return
        case .threw(let failure):
            if failure.isPermissionError {
                classifiedLog.emit(
                    ClassifiedLogEmission(
                        level: .notice,
                        classification: "permission-refused",
                        publicFields: [:]
                    )
                )
                if admissionSet.contains(.screen) {
                    publishScreenRecordingPermission(.notGranted)
                }
            } else {
                classifiedLog.emit(
                    ClassifiedLogEmission(
                        level: .error,
                        classification: "capture-not-running",
                        publicFields: ["reason": "start-failed"]
                    )
                )
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
    public func stopRecording(reason: StopReason = .user, preservingPausePolicy: Bool = false) async -> TransitionOutcome {
        if reason == .user {
            isExplicitlyStopped = true
        } else if reason == .userStopped {
            isUserStopped = true
        }
        let outcome = await captureManager.enqueueTransition(.stop(reason: reason))
        return outcome
    }

    /// Turning a source back on is the owner asking for capture, so it clears an explicit
    /// stop even when nothing can start yet — otherwise granting the permission afterwards
    /// leaves the poll refusing to auto-start, with no owner-facing way back.
    /// An explicit turn-on action authorizes the next start, including after a held pause.
    internal func clearOwnerStop() {
        isExplicitlyStopped = false
        isUserStopped = false
    }

    public func clearExplicitStop() {
        isExplicitlyStopped = false
    }

    public func toggleRecording() async {
        if pauseManager.isPaused {
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

    internal func checkPermissionsAndAutoStart(startReason: StartReason = .autoStart) async {
        // An explicit resume can arrive while the current permission check is suspended.
        // Keep its cause within that check; automatic polling never upgrades it.
        if startReason == .user { permissionStartReason = .user }
        guard !isCheckingPermissions else { return }
        isCheckingPermissions = true
        defer {
            isCheckingPermissions = false
            permissionStartReason = .autoStart
        }

        if screenPermissionProvider.hasPrompted() {
            // Gate on CGPreflightScreenCaptureAccess before touching SCShareableContent.
            // On macOS 26, SCShareableContent.current re-triggers the OS dialog when no TCC
            // entry exists — i.e. while the user has been prompted but hasn't granted yet.
            // CGPreflightScreenCaptureAccess returns true only when a valid TCC entry exists.
            if screenPermissionProvider.preflight() {
                if configProvider().sources.contains(.screen) && protectedVideoBlocksAutomaticScreenCaptureRead() {
                    isStartDeferredForProtectedVideo = true
                } else {
                    isStartDeferredForProtectedVideo = false
                    let granted = configProvider().sources.contains(.screen)
                        ? await screenPermissionProvider.checkScreenRecording()
                        : true
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

        let admissionSet = configProvider().sources.intersection(permittedSources)

        // Auto-start if admitted sources exist, not explicitly stopped, not user stopped, not paused, not already recording, and recovery is not scheduled
        if !isUserStopped && !isExplicitlyStopped && !isStartDeferredForProtectedVideo && !admissionSet.isEmpty && !isRecording && !isUserPaused && !pauseManager.isPaused && !captureManager.isRecoveryScheduled {
            if isTerminating() {
                recorder.enqueue(.permissionAutoStartSkipped)
                logAdapter.permissionAutoStartSkipped()
            } else {
                Logger.general.info("[Permissions] admitted sources [\(admissionSet.logDescription, privacy: .public)], auto-starting observation")
                await startRecording(reason: permissionStartReason)
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

    internal func noteApplicationDidBecomeActive() {
        screenProbeEpoch = now()
    }

    internal func probeScreenRecordingGrantIfWaiting() async {
        guard screenPermissionProvider.hasPrompted(),
              !screenPermissionProvider.preflight(),
              !screenRecordingNeedsRestart else {
            return
        }

        let currentTime = now()
        let inFastWindow = currentTime < screenProbeEpoch.addingTimeInterval(screenProbeFastWindow)
        if !inFastWindow {
            if let lastCounted = screenProbeLastCounted,
               currentTime < lastCounted.addingTimeInterval(screenProbeSlowInterval) {
                return
            }
        }

        guard screenProbeTask == nil else { return }

        let probeTask = Task { await screenPermissionProvider.probe() }
        screenProbeTask = probeTask
        let result = await withTaskCancellationHandler {
            await probeTask.value
        } onCancel: {
            probeTask.cancel()
        }
        screenProbeTask = nil

        guard !Task.isCancelled, result != .unavailable(.cancelled) else { return }

        if result == .granted && !screenPermissionProvider.preflight() {
            screenRecordingNeedsRestart = true
        }

        switch result {
        case .denied:
            screenProbeLastCounted = now()
        case .unavailable(let reason):
            if reason != .cancelled {
                screenProbeLastCounted = now()
            }
        case .granted:
            break
        }

        let signature: String
        let publicFields: [String: String]
        switch result {
        case .granted:
            signature = "granted"
            publicFields = ["result": "granted"]
        case .denied:
            signature = "denied"
            publicFields = ["result": "denied"]
        case .unavailable(let reason):
            signature = "unavailable-\(reason.rawValue)"
            publicFields = ["result": "unavailable", "reason": reason.rawValue]
        }

        if signature != lastProbeLogSignature {
            lastProbeLogSignature = signature
            classifiedLog.emit(
                ClassifiedLogEmission(
                    level: .notice,
                    classification: "screen-capture-probe",
                    publicFields: publicFields
                )
            )
        }
    }

    internal func screenRecordingHasPrompted() -> Bool {
        screenPermissionProvider.hasPrompted()
    }

    internal func runInstalledScreenRecordingProbe() async -> ScreenCaptureProbeResult {
        await screenPermissionProvider.probe()
    }
}
