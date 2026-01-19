// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import ServiceManagement
import SolstoneCaptureCore

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

    // MARK: - Managers

    public let muteManager = MuteManager()
    public let storageManager = StorageManager()
    public let audioDeviceMonitor = AudioDeviceMonitor()
    public private(set) var captureManager: CaptureManager!
    public private(set) var uploadCoordinator: UploadCoordinator!
    public private(set) var config: AppConfig
    private var debugAudioHolder: DebugSettingHolder!
    private var silenceMusicHolder: DebugSettingHolder!

    // MARK: - State

    public private(set) var isRecording = false
    public private(set) var isPaused = false
    public private(set) var errorMessage: String?


    // MARK: - Computed Properties

    /// Status bar icon name based on current state
    public var statusIconName: String {
        if errorMessage != nil {
            return "exclamationmark.circle.fill"
        }
        if isPaused {
            return "pause.circle.fill"
        }
        if muteManager.isMuted {
            return "circle.lefthalf.filled"
        }
        if isRecording {
            return "record.circle.fill"
        }
        return "circle"
    }

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

    public private(set) var isLoginItemEnabled: Bool = false

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
            Log.info("Debug segments enabled: using 60s duration")
        }

        // Check current login item status
        isLoginItemEnabled = SMAppService.mainApp.status == .enabled

        // Create thread-safe holders for settings that are read at segment creation time
        let debugAudioHolder = DebugSettingHolder(value: config.debugKeepRejectedAudio)
        let silenceMusicHolder = DebugSettingHolder(value: config.silenceMusic)
        captureManager = CaptureManager(
            storageManager: storageManager,
            isAudioMuted: { [muteManager] in muteManager.isAudioMuted },
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

        // Restore mute state from previous session
        muteManager.restoreMuteState()

        // Sync microphone priority list with available devices
        syncMicrophonePriorityList()

        // Recover any incomplete segments from previous sessions
        Task.detached {
            let recovery = IncompleteSegmentRecovery(verbose: false)
            let recovered = await recovery.recoverAll()
            if recovered > 0 {
                Log.info("Recovered \(recovered) incomplete segment(s)")
            }
        }

        // Auto-start recording on launch
        Task { @MainActor in
            await self.startRecording()
        }

        // Start upload sync in background
        Task.detached { [uploadCoordinator] in
            await uploadCoordinator?.syncOnStartup()
        }

        // Set shared instance for app-wide access (e.g., termination handler)
        AppState.shared = self
    }

    // MARK: - Recording Control

    public func startRecording() async {
        do {
            try await captureManager.startRecording(disabledMicUIDs: config.disabledMicrophoneUIDs)
            isRecording = true
            isPaused = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stopRecording() async {
        await captureManager.stopRecording()
        isRecording = false
        isPaused = false
    }

    public func toggleRecording() async {
        if isRecording && !isPaused {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    // MARK: - Private Methods

    private func handleCaptureStateChange(_ state: CaptureManager.State) {
        switch state {
        case .idle:
            isRecording = false
            isPaused = false
        case .recording:
            isRecording = true
            isPaused = false
            errorMessage = nil
        case .paused:
            isRecording = true
            isPaused = true
        case .error(let message):
            errorMessage = message
        }
    }

}
