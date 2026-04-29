// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import ServiceManagement
import os
import SolstoneCore

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

    public let pauseManager: PauseManager
    public let storageManager: StorageManager
    public let audioDeviceMonitor: AudioDeviceMonitor
    public private(set) var captureManager: CaptureManager!
    public private(set) var uploadCoordinator: UploadCoordinator!
    public let heartbeatService: HeartbeatService
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

    /// Set to true after the first permission check completes, so startup UI knows real state
    public internal(set) var initialPermissionCheckComplete = false

    /// Timer that polls permissions every few seconds until recording starts
    private var permissionPollTimer: Timer?
    /// Prevents concurrent permission check calls (poll interval < check duration)
    private var isCheckingPermissions = false

    // MARK: - Activation Policy

    public internal(set) var openSceneIds: Set<SolstoneSceneID> = []
    public internal(set) var dockMode: DockMode = .auto
    public internal(set) var currentPolicy: NSApplication.ActivationPolicy = .accessory
    public internal(set) var loginLaunchSuppressionExpires: Date = .distantPast
    public internal(set) var isTerminating: Bool = false
    private var activationPolicyWorkItem: DispatchWorkItem?
    private let dockBehaviorDefaultsKey = "SolstoneDockBehavior"
    private static let loginLaunchSuppressionInterval: TimeInterval = 2.0


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
        if newConfig.isUploadConfigured,
           let serverURL = newConfig.serverURL,
           let serverKey = newConfig.serverKey {
            Task { [heartbeatService] in
                await heartbeatService.configure(serverURL: serverURL, serverKey: serverKey)
            }
        } else {
            Task { [heartbeatService] in
                await heartbeatService.stop()
            }
        }
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

    public func reloadConfigFromDisk() {
        CFPreferencesAppSynchronize(SolMacIPCConstants.appBundleIdentifier as CFString)
        let reloaded = AppConfig.load()
        updateConfig(reloaded)
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
        let config = AppConfig.loadOrCreateDefault()
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let uploadClient = UploadClient()

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.config = config
        self.heartbeatService = HeartbeatService(
            isPaused: { [pauseManager] in
                pauseManager.isPaused
            },
            postHeartbeat: { [uploadClient] url, key, paused in
                try await uploadClient.postObserverStatus(
                    serverURL: url,
                    serverKey: key,
                    paused: paused
                )
            }
        )

        // Apply debug segments setting if enabled
        if config.debugSegments {
            SegmentWriter.segmentDuration = 60
            Logger.general.info("Debug segments enabled: using 60s duration")
        }

        // Enable login item on first launch.
        // Fresh install returns .notFound (never registered); .notRegistered means
        // user explicitly disabled it. Only auto-register on .notFound to respect opt-out.
        if SMAppService.mainApp.status == .notFound {
            try? SMAppService.mainApp.register()
            Logger.general.info("First launch: enabled login item")
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
        if config.isUploadConfigured, let serverURL = config.serverURL, let serverKey = config.serverKey {
            Task { [heartbeatService] in
                await heartbeatService.configure(serverURL: serverURL, serverKey: serverKey)
            }
        }

        // Start polling permissions — auto-starts recording when ready
        startPermissionPolling()

        // Listen for external defaults changes (e.g. `defaults write` from terminal)
        loadDockModeFromDefaults()
        loginLaunchSuppressionExpires = Date().addingTimeInterval(Self.loginLaunchSuppressionInterval)
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.handleExternalDefaultsChange()
                self?.handleDockModeDefaultsChange()
            }
        }

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
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.config = config
        self.heartbeatService = HeartbeatService(
            isPaused: { false },
            postHeartbeat: { _, _, _ in }
        )

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

    /// Polls permissions every 5 seconds. When both are granted, auto-starts recording and
    /// stops polling. Resumes polling if recording stops and permissions change.
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
            Logger.general.info("[Permissions] all granted, auto-starting observation")
            await startRecording()
        }

        // Stop polling once recording is active — lifecycle manager handles recovery from there
        if isRecording {
            stopPermissionPolling()
        }

        initialPermissionCheckComplete = true
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

    public func didOpenWindow(_ id: SolstoneSceneID) {
        openSceneIds.insert(id)
        reevaluateActivationPolicy(debounced: false)
    }

    func handleWindowWillClose(identifier: String?) {
        let rawID = identifier ?? ""
        let matchedSceneIDs = SolstoneSceneID.allCases.filter { rawID.contains($0.rawValue) }
        guard !matchedSceneIDs.isEmpty else { return }

        for sceneID in matchedSceneIDs {
            openSceneIds.remove(sceneID)
        }
        reevaluateActivationPolicy(debounced: true)
    }

    func reevaluateActivationPolicy(debounced: Bool = true) {
        activationPolicyWorkItem?.cancel()
        activationPolicyWorkItem = nil

        if debounced {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.reevaluateActivationPolicy(debounced: false)
                }
            }
            activationPolicyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
            return
        }

        let desiredPolicy = computeDesiredPolicy(now: Date())
        applyPolicy(desiredPolicy)
    }

    func computeDesiredPolicy(now: Date = Date()) -> NSApplication.ActivationPolicy {
        if isTerminating {
            return currentPolicy
        }
        if dockMode == .alwaysRegular {
            return .regular
        }
        if dockMode == .alwaysAccessory {
            return .accessory
        }
        if now < loginLaunchSuppressionExpires {
            return .accessory
        }
        return openSceneIds.isEmpty ? .accessory : .regular
    }

    private func applyPolicy(_ policy: NSApplication.ActivationPolicy) {
        if policy == currentPolicy {
            return
        }

        NSApp.setActivationPolicy(policy)
        currentPolicy = policy

        let name = policy == .regular ? "regular" : "accessory"
        let idsString = self.openSceneIds.map(\.rawValue).sorted().joined(separator: ",")
        Logger.general.info("Activation policy → \(name, privacy: .public) (openScenes=\(self.openSceneIds.count, privacy: .public), ids=[\(idsString, privacy: .public)])")

        if policy == .accessory {
            let hasVisibleTrackedWindow = NSApp.windows.contains { window in
                guard window.isVisible, let identifier = window.identifier?.rawValue else { return false }
                return identifier.contains(SolstoneSceneID.settings.rawValue) || identifier.contains(SolstoneSceneID.about.rawValue)
            }
            if hasVisibleTrackedWindow {
                Logger.general.warning("Activation policy drift: set to accessory but visible solstone window still in NSApp.windows")
            }
        }
    }

    /// Reloads config when an external process writes serverURL/serverKey to UserDefaults.
    /// Guards against feedback loops: updateConfig() -> save() -> notification -> load() -> same values -> return.
    private func handleExternalDefaultsChange() {
        let fresh = AppConfig.load()

        // Only react to server config changes — ignore unrelated defaults
        guard fresh.serverURL != config.serverURL || fresh.serverKey != config.serverKey else {
            return
        }

        Logger.general.info("External defaults change detected — reloading server config")
        updateConfig(fresh)

        if fresh.isUploadConfigured {
            Task.detached { [uploadCoordinator] in
                await uploadCoordinator?.syncOnStartup()
            }
        }
    }

    private func handleDockModeDefaultsChange() {
        let previous = dockMode
        loadDockModeFromDefaults()
        guard dockMode != previous else { return }
        reevaluateActivationPolicy(debounced: false)
    }

    private func loadDockModeFromDefaults() {
        guard let rawValue = UserDefaults.standard.string(forKey: dockBehaviorDefaultsKey) else {
            dockMode = .auto
            return
        }
        dockMode = DockMode(rawValue: rawValue) ?? .auto
    }

}
