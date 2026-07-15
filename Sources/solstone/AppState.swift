// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SwiftUI
import ServiceManagement
import UserNotifications
import os
import JournalMarkKit
import SolstoneCore
import SPLTunnel

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

@MainActor
private final class AppStateBridgeTarget: @unchecked Sendable {
    weak var state: AppState?
}

/// Observable state for the entire application
@MainActor
@Observable
public final class AppState {

    /// Latest real heartbeat POST outcome — the direct-URL connection-health fact
    /// the "your journal" panel presents when no tunnel manages the connection.
    struct JournalHeartbeatOutcome: Equatable {
        let ok: Bool
        let at: Date
    }

    private(set) var journalHeartbeatLastOutcome: JournalHeartbeatOutcome?

    func noteJournalHeartbeatOutcome(_ ok: Bool, at: Date = Date()) {
        journalHeartbeatLastOutcome = JournalHeartbeatOutcome(ok: ok, at: at)
    }

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

    public let capture: CaptureCoordinator
    public let pauseManager: PauseManager
    public let storageManager: StorageManager
    public let audioDeviceMonitor: AudioDeviceMonitor
    public var captureManager: CaptureManager { capture.captureManager }
    public private(set) var uploadCoordinator: UploadCoordinator!
    internal private(set) var appQuitCoordinator: AppQuitCoordinator!
    public let heartbeatService: HeartbeatService
    public let recoveryCoordinator: IncompleteSegmentRecoveryCoordinator
    internal let solChatBridge: SolChatBridge
    internal let tunnelLifecycleOwner: TunnelLifecycleOwner
    internal let pairingCoordinator: PairingCoordinator
    private let homeBaseURLResolver: HomeBaseURLResolver
    private let observerRegister: @MainActor @Sendable (
        _ baseURL: String,
        _ descriptor: ObserverRegistrationDescriptor
    ) async -> Result<ObserverRegistration, ObserverRegistrationFailure>
    // Test seam for observing tunnel-connected sync nudges when UploadCoordinator short-circuits.
    private let triggerTunnelConnectedSync: @MainActor @Sendable (AppState) -> Void
    private let notifier: any SolChatNotifying
    private let loginService: any LoginItemService
    private let isSnapshot: Bool
    private let observerHealthSnapshotEnabled: Bool
    public private(set) var config: AppConfig
    private var debugAudioHolder: DebugSettingHolder!
    private var silenceMusicHolder: DebugSettingHolder!

    // MARK: - State

    public internal(set) var isRecording: Bool {
        get { capture.isRecording }
        set { capture.isRecording = newValue }
    }

    public internal(set) var isPaused: Bool {
        get { capture.isPaused }
        set { capture.isPaused = newValue }
    }

    public internal(set) var errorMessage: String?
    public internal(set) var audioReconciledCount: Int {
        get { capture.audioReconciledCount }
        set { capture.audioReconciledCount = newValue }
    }

    public internal(set) var captureQueuedForJournalReadiness: Bool {
        get { capture.captureQueuedForJournalReadiness }
        set { capture.captureQueuedForJournalReadiness = newValue }
    }

    public internal(set) var solChatPending: SolChatRequestSummary?
    public internal(set) var solChatStale = false
    public internal(set) var connectionTestState: ConnectionTestState = .idle
    public internal(set) var journalHandoffActive = false
    internal private(set) var confirmedMark: JournalMark?
    public private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Screen recording permission — polled periodically via SCShareableContent.
    public internal(set) var screenRecordingGranted: Bool {
        get { capture.screenRecordingGranted }
        set { capture.screenRecordingGranted = newValue }
    }

    /// Microphone permission — polled periodically.
    public internal(set) var microphoneGranted: Bool {
        get { capture.microphoneGranted }
        set { capture.microphoneGranted = newValue }
    }

    /// Set by SetupView to tell SettingsView which tab to open to
    public var pendingSettingsTab: String?

    /// Set to true after the first permission check completes, so startup UI knows real state
    public internal(set) var initialPermissionCheckComplete: Bool {
        get { capture.initialPermissionCheckComplete }
        set { capture.initialPermissionCheckComplete = newValue }
    }

    private var tunnelLifecycleObservationEnabled = false
    private var previousTunnelLifecycleState: TunnelLifecycleState?
    private var tunnelObserverRegistrationTask: Task<Void, Never>?
    private var notificationRequestTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    internal var terminationDrainer: any TerminationDraining = RemixQueue.shared
    internal var replacementLaunchRunner: @MainActor (ReplacementLaunchCommand) throws -> Void = ReplacementLaunchGate.runDetached

    // MARK: - Activation Policy

    public internal(set) var openSceneIds: Set<SolstoneSceneID> = []
    public internal(set) var dockMode: DockMode = .auto
    public internal(set) var currentPolicy: NSApplication.ActivationPolicy = .accessory
    public internal(set) var loginLaunchSuppressionExpires: Date = .distantPast
    public internal(set) var isTerminating: Bool = false
    public internal(set) var appKitTerminationBegan: Bool = false
    private var activationPolicyWorkItem: DispatchWorkItem?
    private let dockBehaviorDefaultsKey = "SolstoneDockBehavior"
    private let visitedSettingsTabsDefaultsKey = "SolstoneVisitedSettingsTabs"
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

    public var permissionsNeedAttention: Bool {
        initialPermissionCheckComplete && (!screenRecordingGranted || !microphoneGranted)
    }

    public var serviceNeedsAttention: Bool {
        config.serviceMode == .bundled || !config.isUploadConfigured
    }

    public var permissionsAreDone: Bool {
        screenRecordingGranted && microphoneGranted && initialPermissionCheckComplete
    }

    public var serviceIsDone: Bool {
        resolvedServiceMode(for: config) == .external && config.isUploadConfigured && !serviceNeedsAttention
    }

    public internal(set) var visitedSettingsTabs: Set<String> = []

    func markSettingsTabVisited(_ tab: SettingsView.Tab) {
        guard visitedSettingsTabs.insert(tab.rawValue).inserted else { return }
        UserDefaults.standard.set(Array(visitedSettingsTabs).sorted(), forKey: visitedSettingsTabsDefaultsKey)
    }

    private func makeAppQuitCoordinator(
        setCommitted: @escaping @MainActor (Bool) -> Void,
        terminate: @escaping @MainActor () -> Void,
        launchReplacement: @escaping @MainActor () -> Void
    ) -> AppQuitCoordinator {
        AppQuitCoordinator(
            dependencies: AppQuitCoordinator.Dependencies(
                setCommitted: setCommitted,
                writeMarker: { reason in
                    ExpectedExitMarker.markExpectedExit(reason: reason.markerString)
                },
                invalidateMarker: {
                    ExpectedExitMarker.invalidate()
                },
                prepareForQuit: { [weak self] in
                    await self?.performQuitPreparation()
                },
                prepareForUpdate: { [weak self] in
                    await self?.performUpdatePreparation()
                },
                // This scheduler must escape the current MainActor job before
                // entering AppKit termination.
                terminate: terminate,
                launchReplacement: launchReplacement
            )
        )
    }

    internal func launchReplacementForSettingsRestart() {
        let command = ReplacementLaunchGate.command(
            predecessorPID: getpid(),
            bundlePath: Bundle.main.bundlePath
        )
        do {
            try replacementLaunchRunner(command)
        } catch {
            Logger.setup.error("replacement launch failed to spawn: \(String(describing: error), privacy: .public)")
        }
    }

    internal func performQuitPreparation() async {
        await stopRecording(reason: .quit)
        await drainRemixQueueForTermination()
    }

    internal func performUpdatePreparation() async {
        await stopRecording(reason: .update)
        await drainRemixQueueForTermination()
    }

    private func drainRemixQueueForTermination() async {
        let drainer = terminationDrainer
        await drainer.setOnSegmentComplete(nil)
        do {
            try await withTimeout(seconds: 30) { await drainer.waitForCompletion() }
        } catch {
            Logger.general.warning("Timed out draining pending remix work during termination; leaving in-flight segment recoverable")
        }
    }

    // MARK: - Login Item

    public internal(set) var isLoginItemEnabled: Bool = false

    private func refreshLoginItemStatus() {
        isLoginItemEnabled = loginService.watchdogStatus == .enabled
    }

    public func setLoginItemEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try loginService.registerWatchdog()
            } else {
                try loginService.unregisterWatchdog()
            }
            refreshLoginItemStatus()
        } catch {
            Logger.general.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
            errorMessage = UICopy.ERROR_LOGIN_ITEM
            refreshLoginItemStatus()
        }
    }

    func migrateLoginItemToWatchdogIfNeeded(isTranslocated: Bool) {
        if isTranslocated { return }

        let watchdog = loginService.watchdogStatus
        let mainApp = loginService.mainAppStatus

        if watchdog == .enabled {
            if mainApp == .enabled || mainApp == .requiresApproval {
                Logger.general.info("Login item migration: unregistering legacy main app login item")
                do {
                    try loginService.unregisterMainApp()
                } catch {
                    try? loginService.unregisterWatchdog()
                    Logger.general.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
                    errorMessage = UICopy.ERROR_LOGIN_ITEM
                }
            }
            refreshLoginItemStatus()
            return
        }

        if mainApp == .enabled {
            do {
                try loginService.registerWatchdog()
            } catch {
                Logger.general.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
                errorMessage = UICopy.ERROR_LOGIN_ITEM
                refreshLoginItemStatus()
                return
            }

            guard loginService.watchdogStatus == .enabled else {
                Logger.general.error("Failed to update login item: watchdog agent did not become enabled")
                errorMessage = UICopy.ERROR_LOGIN_ITEM
                refreshLoginItemStatus()
                return
            }

            do {
                try loginService.unregisterMainApp()
            } catch {
                try? loginService.unregisterWatchdog()
                Logger.general.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
                errorMessage = UICopy.ERROR_LOGIN_ITEM
            }
            refreshLoginItemStatus()
            return
        }

        if mainApp == .notRegistered {
            refreshLoginItemStatus()
            return
        }

        if watchdog == .notRegistered {
            refreshLoginItemStatus()
            return
        }

        if watchdog == .notFound && mainApp == .notFound {
            do {
                try loginService.registerWatchdog()
                Logger.general.info("First launch: enabled login item via watchdog agent")
            } catch {
                Logger.general.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
                errorMessage = UICopy.ERROR_LOGIN_ITEM
            }
            refreshLoginItemStatus()
            return
        }

        refreshLoginItemStatus()
    }

    // MARK: - Configuration

    /// Update and save configuration
    public func updateConfig(_ newConfig: AppConfig) {
        let oldConfig = config
        config = newConfig
        uploadCoordinator.updateConfig(newConfig)
        if newConfig.isUploadConfigured,
           let serverKey = newConfig.serverKey {
            Task { [heartbeatService] in
                await heartbeatService.configure(serverKey: serverKey)
            }
            Task { [solChatBridge] in
                await solChatBridge.configure(serverKey: serverKey)
            }
        } else {
            Task { [heartbeatService] in
                await heartbeatService.stop()
            }
            Task { [solChatBridge] in
                await solChatBridge.stop()
            }
        }
        if oldConfig.solInitiatedChatNotificationsEnabled != newConfig.solInitiatedChatNotificationsEnabled {
            Task { [solChatBridge] in
                await solChatBridge.setNotificationsEnabled(newConfig.solInitiatedChatNotificationsEnabled)
            }
        }
        debugAudioHolder.value = newConfig.debugKeepRejectedAudio
        silenceMusicHolder.value = newConfig.silenceMusic

        // Update mic gain immediately if it changed
        if newConfig.microphoneGain != oldConfig.microphoneGain {
            capture.captureManager.setMicrophoneGain(newConfig.microphoneGain)
        }

        // Update window exclusions immediately if they changed
        if newConfig.excludedAppNames != oldConfig.excludedAppNames ||
           newConfig.excludePrivateBrowsing != oldConfig.excludePrivateBrowsing ||
           newConfig.excludedTitlePatterns != oldConfig.excludedTitlePatterns {
            capture.captureManager.updateWindowExclusions(
                excludedAppNames: newConfig.excludedAppNames,
                excludePrivateBrowsing: newConfig.excludePrivateBrowsing,
                excludedTitlePatterns: newConfig.excludedTitlePatterns
            )
        }

        do {
            try newConfig.save()
        } catch {
            Logger.general.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
            errorMessage = UICopy.ERROR_SAVE_CONFIG
        }
    }

    internal func observerHealthSnapshot() -> ObserverHealthSnapshot? {
        guard observerHealthSnapshotEnabled else { return nil }
        guard config.isUploadConfigured else { return nil }

        let trimmedName = config.observerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName?.isEmpty == false ? trimmedName : nil
        return ObserverHealthSnapshot(
            name: name,
            streamType: "desktop",
            version: AppVersion.short,
            uptimeSeconds: 0,
            lastSuccessfulSync: uploadCoordinator.lastSyncedAt,
            pendingQueueDepth: max(0, uploadCoordinator.pendingCount),
            recentErrorCount: uploadCoordinator.recentErrorCount,
            lastErrorReason: uploadCoordinator.lastErrorReason
        )
    }

    public func setSolChatNotificationPreference(_ enabled: Bool) {
        var newConfig = config
        newConfig.solInitiatedChatNotificationsEnabled = enabled
        updateConfig(newConfig)

        notificationRequestTask?.cancel()
        notificationRequestTask = Task { [weak self] in
            guard let self else { return }
            if enabled {
                await self.requestProvisionalNotificationAuthorizationIfNeeded()
            } else {
                await self.refreshNotificationAuthorizationStatus()
            }
        }
    }

    public func refreshNotificationAuthorizationStatus() async {
        notificationAuthorizationStatus = await notifier.currentAuthorizationStatus()
    }

    public func refreshNotificationAuthorizationStatusSoon() {
        Task { [weak self] in
            await self?.refreshNotificationAuthorizationStatus()
        }
    }

    public func bootstrapNotificationAuthorization() async {
        await requestProvisionalNotificationAuthorizationIfNeeded()
    }

    public func elevateNotifications() {
        NSApp.activate(ignoringOtherApps: true)
        notificationRequestTask?.cancel()
        notificationRequestTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.notifier.requestAuthorization(options: [.alert, .sound])
            guard !Task.isCancelled else { return }
            await self.refreshNotificationAuthorizationStatus()
        }
    }

    public func startObservingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshNotificationAuthorizationStatus()
            }
        }
    }

    private func requestProvisionalNotificationAuthorizationIfNeeded() async {
        await refreshNotificationAuthorizationStatus()
        guard !Task.isCancelled else { return }
        if notificationAuthorizationStatus == .notDetermined {
            _ = await notifier.requestAuthorization(options: [.alert, .sound, .provisional])
        }
        guard !Task.isCancelled else { return }
        await refreshNotificationAuthorizationStatus()
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
                Logger.general.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
                errorMessage = UICopy.ERROR_SAVE_CONFIG
            }
        }
    }

    // MARK: - Initialization

    private static func makeHomeBaseURLResolver(target: AppStateBridgeTarget) -> HomeBaseURLResolver {
        HomeBaseURLResolver { [target] in
            await MainActor.run {
                guard let state = target.state else {
                    return .held
                }
                let owner = state.tunnelLifecycleOwner
                if owner.isTunnelManaged {
                    guard let localPort = owner.localPort else {
                        return .held
                    }
                    return .url("http://127.0.0.1:\(localPort)")
                }
                guard let serverURL = state.config.serverURL else {
                    return .held
                }
                return .url(serverURL)
            }
        }
    }

    internal func resolveHomeBase() async -> ResolvedHomeBase {
        await homeBaseURLResolver.resolve()
    }

    internal func setConfirmedMark(_ mark: JournalMark) {
        confirmedMark = mark
    }

    internal func clearConfirmedMark() {
        confirmedMark = nil
    }

    public init(
        notifier: any SolChatNotifying = UNUserNotificationSolChatNotifier(),
        loginService: any LoginItemService = LiveLoginItemService(),
        observerRegister: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ descriptor: ObserverRegistrationDescriptor
        ) async -> Result<ObserverRegistration, ObserverRegistrationFailure> = { baseURL, descriptor in
            await ObserverRegistrationClient().register(baseURL: baseURL, descriptor: descriptor)
        },
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        }
    ) {
        // Load configuration
        let config = AppConfig.loadOrCreateDefault()
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let uploadClient = UploadClient()
        let solChatTarget = AppStateBridgeTarget()
        let heartbeatTarget = AppStateBridgeTarget()
        let captureTarget = AppStateBridgeTarget()
        let homeBaseURLTarget = AppStateBridgeTarget()
        let recoveryCoordinator = IncompleteSegmentRecoveryCoordinator.shared

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isSnapshot = false
        self.config = config
        self.observerRegister = observerRegister
        self.triggerTunnelConnectedSync = triggerTunnelConnectedSync
        self.notifier = notifier
        self.loginService = loginService
        self.observerHealthSnapshotEnabled = true
        self.recoveryCoordinator = recoveryCoordinator
        let tunnelLifecycleOwner = TunnelLifecycleOwner()
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.pairingCoordinator = PairingCoordinator(
            loadPairing: { try SPLKeychain.load() },
            savePairing: { try SPLKeychain.save($0) },
            deletePairing: { try SPLKeychain.delete() },
            reactivate: { [owner = tunnelLifecycleOwner] in
                await owner.reevaluatePairing()
            },
            ownerState: { [owner = tunnelLifecycleOwner] in
                owner.state
            }
        )
        let homeBaseURLResolver = Self.makeHomeBaseURLResolver(target: homeBaseURLTarget)
        self.homeBaseURLResolver = homeBaseURLResolver

        // Apply debug segments setting if enabled
        if config.debugSegments {
            SegmentWriter.segmentDuration = 60
            Logger.general.info("Debug segments enabled: using 60s duration")
        }

        // Create thread-safe holders for settings that are read at segment creation time
        let debugAudioHolder = DebugSettingHolder(value: config.debugKeepRejectedAudio)
        let silenceMusicHolder = DebugSettingHolder(value: config.silenceMusic)
        let captureManager = CaptureManager(
            storageManager: storageManager,
            debugKeepRejectedAudio: { debugAudioHolder.value },
            silenceMusic: { silenceMusicHolder.value },
            excludedAppNames: config.excludedAppNames,
            excludePrivateBrowsing: config.excludePrivateBrowsing,
            excludedTitlePatterns: config.excludedTitlePatterns,
            microphoneGain: config.microphoneGain,
            verbose: false,
            recoveryCoordinator: recoveryCoordinator
        )
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder
        let capture = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: pauseManager,
            audioDeviceMonitor: audioDeviceMonitor,
            isTerminating: { [captureTarget] in
                captureTarget.state?.isTerminating ?? true
            },
            configProvider: { [captureTarget, config] in
                let currentConfig = captureTarget.state?.config ?? config
                return (
                    disabled: currentConfig.disabledMicrophoneUIDs,
                    enabled: currentConfig.enabledMicrophoneUIDs
                )
            },
            bannerSink: { [captureTarget] message in
                captureTarget.state?.errorMessage = message
            }
        )
        self.capture = capture
        self.heartbeatService = HeartbeatService(
            resolver: homeBaseURLResolver,
            isPaused: capture.heartbeatIsPausedProvider(),
            healthProvider: { [heartbeatTarget] in
                heartbeatTarget.state?.observerHealthSnapshot()
            },
            postHeartbeat: { [uploadClient] url, key, paused, health in
                try await uploadClient.postObserverStatus(
                    serverURL: url,
                    serverKey: key,
                    paused: paused,
                    health: health
                )
            },
            outcomeSink: { [heartbeatTarget] ok in
                await MainActor.run {
                    heartbeatTarget.state?.noteJournalHeartbeatOutcome(ok)
                }
            }
        )
        self.solChatBridge = SolChatBridge(
            notificationsEnabled: config.solInitiatedChatNotificationsEnabled,
            resolver: homeBaseURLResolver,
            setPending: { [solChatTarget] pending in
                solChatTarget.state?.solChatPending = pending
            },
            setStale: { [solChatTarget] stale in
                solChatTarget.state?.solChatStale = stale
            },
            postOpenChat: { url in
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            },
            notifier: notifier
        )

        uploadCoordinator = UploadCoordinator(
            storageManager: storageManager,
            config: config,
            resolver: homeBaseURLResolver
        )
        appQuitCoordinator = makeAppQuitCoordinator(
            setCommitted: { [weak self] committed in
                self?.isTerminating = committed
            },
            terminate: {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            },
            launchReplacement: { [weak self] in
                guard let self else { return }
                self.launchReplacementForSettingsRestart()
            }
        )
        captureTarget.state = self

        // Single segment-completion nudge for rotation, recovery, stop/pause, sleep, and lock.
        Task {
            await RemixQueue.shared.setOnSegmentComplete { [weak self] _, reconciliation in
                await MainActor.run {
                    guard let self else { return }
                    switch reconciliation {
                    case .normal:
                        self.uploadCoordinator.triggerSync()
                    case .recovered:
                        self.audioReconciledCount += 1
                        self.uploadCoordinator.triggerSync()
                    case .failed(let message):
                        self.errorMessage = message
                    }
                }
            }
        }

        let connectedOptInOnlyUIDs = Set(audioDeviceMonitor.availableDevices
            .filter { $0.transportType.isOptInOnly }
            .map { $0.uid })
        self.config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: connectedOptInOnlyUIDs)

        // Sync microphone priority list with available devices
        syncMicrophonePriorityList()

        // Recover any incomplete segments from previous sessions
        recoveryCoordinator.scheduleDetached()

        configureJournalServicesIfNeeded()

        // Start polling permissions — auto-starts recording when ready
        capture.activate()

        // Listen for external defaults changes (e.g. `defaults write` from terminal)
        visitedSettingsTabs = Set(UserDefaults.standard.stringArray(forKey: visitedSettingsTabsDefaultsKey) ?? [])
        loadDockModeFromDefaults()
        loginLaunchSuppressionExpires = Date().addingTimeInterval(Self.loginLaunchSuppressionInterval)
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.handleExternalDefaultsChange()
                self?.handleDockModeDefaultsChange()
            }
        }

        // Set shared instance for app-wide access (e.g., termination handler)
        solChatTarget.state = self
        heartbeatTarget.state = self
        homeBaseURLTarget.state = self
        AppState.shared = self
    }

    deinit {
        MainActor.assumeIsolated {
            notificationRequestTask?.cancel()
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
            }
        }
    }

    // MARK: - Snapshot Construction

    /// Creates an AppState suitable for snapshot previews and testing.
    /// All managers are initialized but no hardware, network, or keychain activity is triggered.
    /// `AppState.shared` is NOT set.
    public static func forSnapshot(
        config: AppConfig = AppConfig(),
        notificationStatus: UNAuthorizationStatus = .authorized,
        notifier: (any SolChatNotifying)? = nil,
        initialTunnelPairing: StoredPairing? = nil,
        observerRegister: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ descriptor: ObserverRegistrationDescriptor
        ) async -> Result<ObserverRegistration, ObserverRegistrationFailure> = { baseURL, descriptor in
            await ObserverRegistrationClient().register(baseURL: baseURL, descriptor: descriptor)
        },
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        }
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(
            snapshotConfig: config,
            notificationStatus: notificationStatus,
            isSnapshot: true,
            notifier: notifier ?? NoopSolChatNotifier(),
            initialTunnelPairing: initialTunnelPairing,
            observerRegister: observerRegister,
            triggerTunnelConnectedSync: triggerTunnelConnectedSync
        )
    }

    /// Creates a side-effect-free AppState for login item migration tests.
    internal static func forLoginItemTest(
        config: AppConfig = AppConfig(),
        loginService: any LoginItemService
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(
            snapshotConfig: config,
            notificationStatus: .authorized,
            isSnapshot: false,
            notifier: NoopSolChatNotifier(),
            loginService: loginService
        )
    }

    /// Private designated init that creates all managers without activating hardware or side effects.
    private init(
        snapshotConfig config: AppConfig,
        notificationStatus: UNAuthorizationStatus,
        isSnapshot: Bool,
        notifier: any SolChatNotifying,
        initialTunnelPairing: StoredPairing? = nil,
        loginService: any LoginItemService = LiveLoginItemService(),
        observerRegister: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ descriptor: ObserverRegistrationDescriptor
        ) async -> Result<ObserverRegistration, ObserverRegistrationFailure> = { baseURL, descriptor in
            await ObserverRegistrationClient().register(baseURL: baseURL, descriptor: descriptor)
        },
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        }
    ) {
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let heartbeatTarget = AppStateBridgeTarget()
        let captureTarget = AppStateBridgeTarget()
        let snapshotResolver = HomeBaseURLResolver { [config] in
            guard let serverURL = config.serverURL else {
                return .held
            }
            return .url(serverURL)
        }
        self.homeBaseURLResolver = snapshotResolver

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isSnapshot = isSnapshot
        self.config = config
        self.observerRegister = observerRegister
        self.triggerTunnelConnectedSync = triggerTunnelConnectedSync
        self.notifier = notifier
        self.loginService = loginService
        self.observerHealthSnapshotEnabled = false
        self.notificationAuthorizationStatus = notificationStatus
        self.recoveryCoordinator = .shared
        let debugAudioHolder = DebugSettingHolder(value: false)
        let silenceMusicHolder = DebugSettingHolder(value: true)
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder
        let captureManager = CaptureManager(storageManager: storageManager)
        let capture = CaptureCoordinator(
            captureManager: captureManager,
            pauseManager: pauseManager,
            audioDeviceMonitor: audioDeviceMonitor,
            isTerminating: { [captureTarget] in
                captureTarget.state?.isTerminating ?? true
            },
            configProvider: { [captureTarget, config] in
                let currentConfig = captureTarget.state?.config ?? config
                return (
                    disabled: currentConfig.disabledMicrophoneUIDs,
                    enabled: currentConfig.enabledMicrophoneUIDs
                )
            },
            bannerSink: { [captureTarget] message in
                captureTarget.state?.errorMessage = message
            }
        )
        self.capture = capture
        self.heartbeatService = HeartbeatService(
            resolver: snapshotResolver,
            isPaused: capture.heartbeatIsPausedProvider(),
            healthProvider: { nil },
            postHeartbeat: { _, _, _, _ in }
        )
        self.solChatBridge = SolChatBridge(
            notificationsEnabled: config.solInitiatedChatNotificationsEnabled,
            resolver: snapshotResolver,
            setPending: { _ in },
            setStale: { _ in },
            postOpenChat: { _ in },
            notifier: notifier
        )
        let tunnelLifecycleOwner = initialTunnelPairing
            .map { pairing in TunnelLifecycleOwner.dormantForSnapshot(loadPairing: { pairing }) }
            ?? TunnelLifecycleOwner.dormantForSnapshot()
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.pairingCoordinator = PairingCoordinator(
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {},
            reactivate: { [owner = tunnelLifecycleOwner] in
                await owner.reevaluatePairing()
            },
            ownerState: { [owner = tunnelLifecycleOwner] in
                owner.state
            }
        )

        uploadCoordinator = UploadCoordinator(
            forSnapshot: storageManager,
            config: config,
            resolver: snapshotResolver
        )
        appQuitCoordinator = makeAppQuitCoordinator(
            setCommitted: { _ in },
            terminate: {},
            launchReplacement: {}
        )
        visitedSettingsTabs = Set(UserDefaults.standard.stringArray(forKey: visitedSettingsTabsDefaultsKey) ?? [])
        heartbeatTarget.state = self
        captureTarget.state = self

        // No callback wiring, no pause restore, no segment recovery,
        // no startRecording, no upload sync, no AppState.shared assignment.
    }

    // MARK: - Recording Control

    internal func startTunnelLifecycleOwner() {
        tunnelLifecycleOwner.start()
        startTunnelLifecycleObservation()
    }

    internal func stopTunnelLifecycleOwner() {
        tunnelLifecycleObservationEnabled = false
        previousTunnelLifecycleState = nil
        Task { [tunnelLifecycleOwner] in
            await tunnelLifecycleOwner.stop()
        }
    }

    private func startTunnelLifecycleObservation() {
        guard !tunnelLifecycleObservationEnabled else { return }
        tunnelLifecycleObservationEnabled = true
        previousTunnelLifecycleState = tunnelLifecycleOwner.state
        observeTunnelLifecycleState()
    }

    private func observeTunnelLifecycleState() {
        guard tunnelLifecycleObservationEnabled else { return }
        let current = withObservationTracking {
            tunnelLifecycleOwner.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeTunnelLifecycleState()
            }
        }
        handleTunnelLifecycleState(current)
    }

    internal func handleTunnelLifecycleState(_ newState: TunnelLifecycleState) {
        let previousState = previousTunnelLifecycleState
        previousTunnelLifecycleState = newState
        guard isConnected(newState), !isConnected(previousState) else { return }

        let registrationTask: Task<Void, Never>
        if let inFlight = tunnelObserverRegistrationTask {
            registrationTask = inFlight
        } else {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await performTunnelObserverRegistration(
                    appState: self,
                    isTunnelManaged: self.tunnelLifecycleOwner.isTunnelManaged,
                    resolveBase: { [weak self] in
                        guard let self else { return .held }
                        return await self.resolveHomeBase()
                    },
                    register: self.observerRegister
                )
                self.tunnelObserverRegistrationTask = nil
            }
            tunnelObserverRegistrationTask = task
            registrationTask = task
        }

        Task { @MainActor [weak self, registrationTask] in
            await registrationTask.value
            guard let self else { return }
            self.triggerTunnelConnectedSync(self)
        }
    }

    private func isConnected(_ state: TunnelLifecycleState?) -> Bool {
        guard let state else { return false }
        if case .connected = state {
            return true
        }
        return false
    }

    public func startRecording(reason: StartReason = .user) async {
        await capture.startRecording(reason: reason)
    }

    public func stopRecording(reason: StopReason = .user) async {
        await capture.stopRecording(reason: reason)
    }

    public func toggleRecording() async {
        await capture.toggleRecording()
    }

    private func configureJournalServicesIfNeeded() {
        captureQueuedForJournalReadiness = false
        scheduleStartupUploadSyncIfNeeded()
        if config.isUploadConfigured, let serverKey = config.serverKey {
            Task { [heartbeatService] in
                await heartbeatService.configure(serverKey: serverKey)
            }
            Task { [solChatBridge] in
                await solChatBridge.configure(serverKey: serverKey)
            }
        }
    }

    private func scheduleStartupUploadSyncIfNeeded() {
        guard config.serverURL != nil else { return }
        Task.detached { [uploadCoordinator] in
            await uploadCoordinator?.syncOnStartup()
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

    /// Reloads config when an external process writes journal connection settings to UserDefaults.
    /// Guards against feedback loops: updateConfig() -> save() -> notification -> load() -> same values -> return.
    private func handleExternalDefaultsChange() {
        let fresh = AppConfig.load()

        // Only react to journal connection changes — ignore unrelated defaults
        guard fresh.serverURL != config.serverURL ||
              fresh.serverKey != config.serverKey ||
              fresh.observerName != config.observerName ||
              fresh.serviceMode != config.serviceMode ||
              fresh.journalPath != config.journalPath else {
            return
        }

        Logger.general.info("External defaults change detected — reloading journal connection config")
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
