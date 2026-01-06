// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import ServiceManagement
import SolstoneCaptureCore

/// Observable state for the entire application
@MainActor
@Observable
public final class AppState {
    // MARK: - Managers

    public let muteManager = MuteManager()
    public let storageManager = StorageManager()
    public let audioDeviceMonitor = AudioDeviceMonitor()
    public private(set) var captureManager: CaptureManager!
    public private(set) var uploadCoordinator: UploadCoordinator!
    public private(set) var config: AppConfig

    // MARK: - State

    public private(set) var isRecording = false
    public private(set) var isPaused = false
    public private(set) var errorMessage: String?

    /// Time remaining in current segment (updated by timer for UI refresh)
    public private(set) var segmentTimeRemaining: TimeInterval = 0

    /// Current segment index
    public private(set) var segmentIndex: Int = 0

    /// Timer for updating segment time display
    private var uiUpdateTimer: Timer?

    // MARK: - Computed Properties

    /// Status bar icon name based on current state
    public var statusIconName: String {
        if errorMessage != nil {
            return "exclamationmark.circle.fill"
        }
        if muteManager.isFullyMuted || isPaused {
            return "pause.circle.fill"
        }
        if muteManager.isAnyMuted {
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
        if muteManager.isFullyMuted {
            return "Muted"
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
        config = newConfig
        uploadCoordinator.updateConfig(newConfig)
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

        // Check current login item status
        isLoginItemEnabled = SMAppService.mainApp.status == .enabled

        captureManager = CaptureManager(
            storageManager: storageManager,
            excludedAppNames: config.excludedAppNames,
            excludePrivateBrowsing: config.excludePrivateBrowsing,
            verbose: false
        )

        uploadCoordinator = UploadCoordinator(storageManager: storageManager, config: config)

        // Wire up callbacks
        captureManager.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleCaptureStateChange(state)
            }
        }

        captureManager.onSegmentComplete = { [weak self] _ in
            self?.uploadCoordinator.triggerSync()
        }

        muteManager.onMuteStateChanged = { [weak self] in
            Task { @MainActor in
                await self?.handleMuteStateChange()
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

        // Auto-start recording on launch
        Task { @MainActor in
            await self.startRecording()
        }

        // Start upload sync in background
        Task.detached { [uploadCoordinator] in
            await uploadCoordinator?.syncOnStartup()
        }
    }

    // MARK: - Recording Control

    public func startRecording() async {
        do {
            try await captureManager.startRecording(disabledMicUIDs: config.disabledMicrophoneUIDs)
            isRecording = true
            isPaused = false
            errorMessage = nil
            startUIUpdateTimer()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func stopRecording() async {
        stopUIUpdateTimer()
        await captureManager.stopRecording()
        isRecording = false
        isPaused = false
    }

    // MARK: - UI Update Timer

    private func startUIUpdateTimer() {
        stopUIUpdateTimer()
        updateSegmentInfo()
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSegmentInfo()
            }
        }
    }

    private func stopUIUpdateTimer() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
        segmentTimeRemaining = 0
        segmentIndex = 0
    }

    private func updateSegmentInfo() {
        segmentTimeRemaining = captureManager.segmentTimeRemaining
        // Note: segmentIndex no longer tracked per-session, each segment is independent
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
            stopUIUpdateTimer()
            isRecording = false
            isPaused = false
        case .recording:
            isRecording = true
            isPaused = false
            errorMessage = nil
            startUIUpdateTimer()
        case .paused:
            stopUIUpdateTimer()
            isRecording = true
            isPaused = true
        case .error(let message):
            stopUIUpdateTimer()
            errorMessage = message
        }
    }

    private func handleMuteStateChange() async {
        if muteManager.isFullyMuted {
            // Both audio and video muted - pause capture
            if isRecording && !isPaused {
                await captureManager.pauseRecording()
            }
        } else if isPaused {
            // At least one is unmuted - resume capture
            do {
                try await captureManager.resumeRecording()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
