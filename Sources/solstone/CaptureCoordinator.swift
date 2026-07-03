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
    public typealias StartOperation = @MainActor (MicUIDConfig) async throws -> Void

    public internal(set) var isRecording = false
    public internal(set) var capturePaused = false
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

    // interim guard; a later phase replaces this with a transition queue
    private var startTask: Task<Void, Never>?
    private var permissionPollTimer: Timer?
    private var isCheckingPermissions = false

    public var isPausedIncludingUserPause: Bool {
        pauseManager.isPaused || capturePaused
    }

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
        self.startOperation = startOperation ?? { [captureManager] config in
            try await captureManager.startRecording(
                disabledMicUIDs: config.disabled,
                enabledMicUIDs: config.enabled
            )
        }
    }

    deinit {
        MainActor.assumeIsolated {
            permissionPollTimer?.invalidate()
            startTask?.cancel()
        }
    }

    public func heartbeatIsPausedProvider() -> HeartbeatService.IsPausedProvider {
        {
            // Strong self is safe: CaptureCoordinator never holds a reference to HeartbeatService, so no retain cycle. Keep it that way.
            self.isPausedIncludingUserPause
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
            await self?.stopRecording()
        }
        pauseManager.onResume = { [weak self] in
            await self?.startRecording()
        }

        pauseManager.restorePauseState()
        startPermissionPolling()
    }

    public func handleCaptureStateChange(_ state: CaptureManager.State) {
        switch state {
        case .idle:
            isRecording = false
            capturePaused = false
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        case .recording:
            isRecording = true
            capturePaused = false
            captureError = nil
            bannerSink(nil)
            stopPermissionPolling()
        case .paused:
            isRecording = true
            capturePaused = true
        case .error(let message):
            isRecording = false
            capturePaused = false
            captureError = message
            bannerSink(message)
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        }
    }

    public func startRecording() async {
        if let startTask {
            await startTask.value
            return
        }

        let task = Task { @MainActor in
            defer { self.startTask = nil }

            guard !self.isTerminating() else {
                Logger.general.info("startRecording() ignored because app is terminating")
                return
            }

            do {
                let config = self.configProvider()
                try await self.startOperation(config)
                self.screenRecordingGranted = true
            } catch CaptureManager.CaptureError.permissionDenied {
                Logger.general.info("[Permissions] Recording denied — screen recording permission not granted")
                self.screenRecordingGranted = false
            } catch {
                Logger.general.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                self.captureError = UICopy.ERROR_START_OBSERVING
                self.bannerSink(UICopy.ERROR_START_OBSERVING)
            }
        }
        startTask = task
        await task.value
    }

    public func stopRecording() async {
        await captureManager.stopRecording()
    }

    public func toggleRecording() async {
        if isRecording && !capturePaused {
            await stopRecording()
        } else {
            await startRecording()
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
        if allGranted && !pauseManager.isPaused && !isRecording {
            if isTerminating() {
                Logger.general.info("[Permissions] auto-start skipped because app is terminating")
            } else {
                Logger.general.info("[Permissions] all granted, auto-starting observation")
                await startRecording()
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
