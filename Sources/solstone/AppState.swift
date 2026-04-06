// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import ServiceManagement
import os

/// Thread-safe holder for a debug setting value
/// Allows Sendable closures to read the current value
final class DebugSettingHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    init(value: Bool) {
        self._value = value
    }
}

/// Observable state for the entire application
@MainActor
@Observable
public final class AppState {
    /// Shared instance for app-wide access (set during init)
    nonisolated(unsafe) public static var shared: AppState?
    private static var snapshotAudioMonitorMode = false

    private static func makeAudioDeviceMonitor() -> AudioDeviceMonitor {
        if snapshotAudioMonitorMode {
            return AudioDeviceMonitor(startListening: false)
        }
        return AudioDeviceMonitor()
    }

    // MARK: - Managers

    public let pauseManager = PauseManager()
    public let storageManager = StorageManager()
    public let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
    public private(set) var captureManager: CaptureManager!
    public private(set) var uploadCoordinator: UploadCoordinator!
    public private(set) var config: AppConfig
    private var debugAudioHolder: DebugSettingHolder!
    private var silenceMusicHolder: DebugSettingHolder!

    // MARK: - State

    public internal(set) var isRecording = false
    public internal(set) var isPaused = false
    public internal(set) var errorMessage: String?

    /// Screen recording permission — polled periodically via SCShareableContent.
    public internal(set) var screenRecordingGranted = false

    /// Microphone permission — polled periodically.
    public internal(set) var microphoneGranted = false

    /// Set by SetupView to tell SettingsView which tab to open to
    public var pendingSettingsTab: String?

    /// Timer that polls permissions every few seconds until recording starts
    private var permissionPollTimer: Timer?


    // MARK: - Computed Properties

    /// Human-readable status text
    public var statusText: String {
        if let error = errorMessage {
            return "Error: \(error)"
        }
        if isPaused {
            return "Paused"
        }
        if isRecording {
            return "Recording"
        }
        return "Idle"
    }

    // MARK: - Login Item

    public internal(set) var isLoginItemEnabled: Bool = false

    private func refreshLoginItemStatus() {
        isLoginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    public func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLoginItemStatus()
        } catch {
            errorMessage = "Failed to update login item: \(error.localizedDescription)"
            refreshLoginItemStatus()
        }
    }

    // MARK: - Configuration

    /// Update and save configuration
    public func updateConfig(_ newConfig: AppConfig) {
        let oldConfig = config
        config = newConfig
        uploadCoordinator.updateConfig(newConfig)
        debugAudioHolder.value = newConfig.debugKeepRejectedAudio
        silenceMusicHolder.value = newConfig.silenceMusic

        // Update mic gain immediately if it changed
        if newConfig.microphoneGain != oldConfig.microphoneGain {
            captureManager.setMicrophoneGain(newConfig.microphoneGain)
        }

        // Update window exclusions immediately if they changed
        if newConfig.excludedAppNames != oldConfig.excludedAppNames ||
           newConfig.excludePrivateBrowsing != oldConfig.excludePrivateBrowsing ||
           newConfig.excludedTitlePatterns != oldConfig.excludedTitlePatterns {
            captureManager.updateWindowExclusions(
                excludedAppNames: newConfig.excludedAppNames,
                excludePrivateBrowsing: newConfig.excludePrivateBrowsing,
                excludedTitlePatterns: newConfig.excludedTitlePatterns
            )
        }

        do {
            try newConfig.save()
        } catch {
            errorMessage = "Failed to save config: \(error.localizedDescription)"
        }
    }

    /// Auto-adds any newly detected microphones to the priority list
    public func syncMicrophonePriorityList() {
        let available = audioDeviceMonitor.availableDevices
        var configChanged = false

        for device in available {
            if config.addMicrophone(device) {
                configChanged = true
            }
        }

        if configChanged {
            do {
                try config.save()
            } catch {
                errorMessage = "Failed to save config: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Initialization

    public init() {
        // Load configuration
        config = AppConfig.loadOrCreateDefault()

        // Apply debug segments setting if enabled
        if config.debugSegments {
            SegmentWriter.segmentDuration = 60
            Logger.general.info("Debug segments enabled: using 60s duration")
        }

        // Check current login item status
        isLoginItemEnabled = SMAppService.mainApp.status == .enabled

        // Create thread-safe holders for settings that are read at segment creation time
        let debugAudioHolder = DebugSettingHolder(value: config.debugKeepRejectedAudio)
        let silenceMusicHolder = DebugSettingHolder(value: config.silenceMusic)
        captureManager = CaptureManager(
            storageManager: storageManager,
            debugKeepRejectedAudio: { debugAudioHolder.value },
            silenceMusic: { silenceMusicHolder.value },
            excludedAppNames: config.excludedAppNames,
            excludePrivateBrowsing: config.excludePrivateBrowsing,
            excludedTitlePatterns: config.excludedTitlePatterns,
            microphoneGain: config.microphoneGain,
            verbose: false
        )
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder

        uploadCoordinator = UploadCoordinator(storageManager: storageManager, config: config)

        // Wire up callbacks
        captureManager.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleCaptureStateChange(state)
            }
        }

        // Direct segment completion (stop/pause/sleep) - triggers upload
        captureManager.onSegmentComplete = { [weak self] _ in
            self?.uploadCoordinator.triggerSync()
        }

        // Background remix completion (rotation) - triggers upload
        Task {
            await RemixQueue.shared.setOnSegmentComplete { [weak self] _ in
                await MainActor.run {
                    self?.uploadCoordinator.triggerSync()
                }
            }
        }

        // Wire up audio device change notifications
        audioDeviceMonitor.onDeviceChange = { [weak self] added, removed in
            Task { @MainActor in
                await self?.captureManager.handleDeviceChange(added: added, removed: removed)
            }
        }

        // Wire pause manager callbacks
        pauseManager.onPause = { [weak self] in
            await self?.stopRecording()
        }
        pauseManager.onResume = { [weak self] in
            await self?.startRecording()
        }

        // Clear any persisted pause state from previous sessions
        pauseManager.restorePauseState()

        // Sync microphone priority list with available devices
        syncMicrophonePriorityList()

        // Recover any incomplete segments from previous sessions
        Task.detached {
            let recovery = IncompleteSegmentRecovery(verbose: false)
            let recovered = await recovery.recoverAll()
            if recovered > 0 {
                Logger.general.info("Recovered \(recovered, privacy: .public) incomplete segment(s)")
            }
        }

        // Sync any pending uploads on startup
        if config.serverURL != nil {
            Task.detached { [uploadCoordinator] in
                await uploadCoordinator?.syncOnStartup()
            }
        }

        // Start polling permissions — auto-starts recording when ready
        startPermissionPolling()

        // Set shared instance for app-wide access (e.g., termination handler)
        AppState.shared = self
    }

    // MARK: - Snapshot Construction

    /// Creates an AppState suitable for snapshot previews and testing.
    /// All managers are initialized but no hardware, network, or keychain activity is triggered.
    /// `AppState.shared` is NOT set.
    public static func forSnapshot(config: AppConfig = AppConfig()) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(snapshotConfig: config)
    }

    /// Private designated init that creates all managers without activating hardware or side effects.
    private init(snapshotConfig config: AppConfig) {
        self.config = config

        let debugAudioHolder = DebugSettingHolder(value: false)
        let silenceMusicHolder = DebugSettingHolder(value: true)
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder

        captureManager = CaptureManager(storageManager: storageManager)
        uploadCoordinator = UploadCoordinator(forSnapshot: storageManager, config: config)

        // No callback wiring, no pause restore, no segment recovery,
        // no startRecording, no upload sync, no AppState.shared assignment.
    }

    // MARK: - Recording Control

    public func startRecording() async {
        do {
            try await captureManager.startRecording(disabledMicUIDs: config.disabledMicrophoneUIDs)
            screenRecordingGranted = true
        } catch let error as CaptureManager.CaptureError where error == .permissionDenied {
            Logger.general.info("[Permissions] Recording denied — screen recording permission not granted")
            screenRecordingGranted = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stopRecording() async {
        await captureManager.stopRecording()
    }

    public func toggleRecording() async {
        if isRecording && !isPaused {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    // MARK: - Permission Polling

    /// Polls permissions every 5 seconds. When both are granted and the app is configured,
    /// auto-starts recording and stops polling. Resumes polling if recording stops and
    /// permissions are still needed.
    private func startPermissionPolling() {
        // Check immediately, then poll
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
        let checker = PermissionChecker()

        // Only check screen recording via SCShareableContent if user has been prompted
        // (otherwise it triggers the OS dialog)
        if checker.hasPromptedScreenRecording || config.serverURL != nil {
            screenRecordingGranted = await PermissionChecker.checkScreenRecording()
        }
        microphoneGranted = checker.microphoneGranted

        let allGranted = screenRecordingGranted && microphoneGranted

        // Auto-start if permissions are ready, not paused, configured, and not already recording
        if allGranted && config.serverURL != nil && !pauseManager.isPaused && !isRecording {
            Logger.general.info("[Permissions] all granted, auto-starting recording")
            await startRecording()
        }

        // Stop polling once recording is active — lifecycle manager handles recovery from there
        if isRecording {
            stopPermissionPolling()
        }
    }

    // MARK: - Private Methods

    private func handleCaptureStateChange(_ state: CaptureManager.State) {
        switch state {
        case .idle:
            isRecording = false
            isPaused = false
            // Resume polling so we auto-start if user clicks "start recording" later
            // or permissions change
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        case .recording:
            isRecording = true
            isPaused = false
            errorMessage = nil
            stopPermissionPolling()
        case .paused:
            isRecording = true
            isPaused = true
        case .error(let message):
            isRecording = false
            isPaused = false
            errorMessage = message
            // Resume polling to retry when permissions are restored
            if permissionPollTimer == nil {
                startPermissionPolling()
            }
        }
    }

}
