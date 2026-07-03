// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SwiftUI
import ServiceManagement
import UserNotifications
import os
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
    private enum JournalRestartRequestOutcome {
        case success
        case failure
        case modeChanged
        case binaryMissing
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

    public let pauseManager: PauseManager
    public let storageManager: StorageManager
    public let audioDeviceMonitor: AudioDeviceMonitor
    public private(set) var captureManager: CaptureManager!
    public private(set) var uploadCoordinator: UploadCoordinator!
    internal private(set) var appQuitCoordinator: AppQuitCoordinator!
    public let installer: SolstoneInstaller
    public let heartbeatService: HeartbeatService
    public let recoveryCoordinator: IncompleteSegmentRecoveryCoordinator
    internal let solChatBridge: SolChatBridge
    internal let tunnelLifecycleOwner: TunnelLifecycleOwner
    internal let pairingCoordinator: PairingCoordinator
    private let homeBaseURLResolver: HomeBaseURLResolver
    private let notifier: any SolChatNotifying
    private let loginService: any LoginItemService
    private let isSnapshot: Bool
    private let observerHealthSnapshotEnabled: Bool
    public private(set) var config: AppConfig
    private var debugAudioHolder: DebugSettingHolder!
    private var silenceMusicHolder: DebugSettingHolder!

    // MARK: - State

    public internal(set) var isRecording = false
    public internal(set) var isPaused = false
    public internal(set) var errorMessage: String?
    public internal(set) var audioReconciledCount: Int = 0
    public internal(set) var journalRuntimeStatus: JournalRuntimeStatus = .running
    public internal(set) var captureQueuedForJournalReadiness: Bool = false
    public internal(set) var restartRequiredBannerVisible: Bool = false
    private var restartRequiredGeneration: UInt64 = 0
    public internal(set) var solChatPending: SolChatRequestSummary?
    public internal(set) var solChatStale = false
    public internal(set) var connectionTestState: ConnectionTestState = .idle
    internal private(set) var confirmedMark: JournalMark?
    public private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

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
    private var hasStartedBundledJournalDetection = false
    private var journalRestartTask: Task<Void, Never>?
    private var journalStopTask: Task<Void, Never>?
    private var journalStartTask: Task<Void, Never>?
    private var bundledJournalStartupTask: Task<Void, Never>?
    private var tunnelLifecycleObservationEnabled = false
    private var previousTunnelLifecycleState: TunnelLifecycleState?
    private struct InFlightBundledStart {
        let journalRoot: URL
        let generation: UInt64
        let task: Task<Bool, Never>
    }
    private enum JournalModeTransitionOutcome: Equatable {
        case none
        case started
        case alreadyReadyNoStart
    }
    private var activeJournalRoot: URL?
    private var bundledStartGeneration: UInt64 = 0
    private var inFlightBundledStart: InFlightBundledStart?
    internal private(set) var journalDependentServicesReady = false
    private var currentMaterializedRuntime: MaterializedRuntime?
    private var notificationRequestTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var preRestartErrorMessage: String?
    internal var journalRestartLogSink: (@Sendable (JournalRestartLogEvent) -> Void)?
    internal var journalBinaryProvider: @Sendable () -> URL? = { nil }
    internal var journalRuntimeFileExists: @Sendable (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }
    internal var journalRuntimeProbeRunner: SubprocessRunning = SubprocessRunner()
    internal var bundledJournalDetectionRunner: (() async -> Bool)?
    internal var journalRestartRunnerFactory: ((
        URL,
        (@Sendable (JournalRestartLogEvent) -> Void)?
    ) -> JournalRestartRunner)?
    internal var journalOwnershipResolver: @Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership = SolOwnership.defaultResolver()
    internal var runtimeMaterializer: any RuntimeMaterializing
    internal var supervisedJournalRunner: any SupervisedChildRunning
    internal var singleSupervisorGate: any SingleSupervisorGating
    internal var journalReadinessGate: any JournalReadinessChecking
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
        guard let serviceMode = config.serviceMode else { return true }
        switch serviceMode {
        case .external:
            return connectionTestState != .success
        case .bundled:
            if case .failure = installer.postInstallAutoTest {
                return true
            }
            switch bundledJournalCardState {
            case .absent, .upgradeFailed, .failed, .runtimeFailed:
                return true
            case .installedCurrent,
                 .installedUnknown,
                 .externallyManaged,
                 .done,
                 .installedPlaceholder,
                 .detecting,
                 .installing,
                 .runtimeStarting,
                 .runtimeUnconfirmed,
                 .runtimeStoppedByUser:
                return false
            }
        }
    }

    public var permissionsAreDone: Bool {
        screenRecordingGranted && microphoneGranted && initialPermissionCheckComplete
    }

    public var serviceIsDone: Bool {
        guard let serviceMode = config.serviceMode else { return false }
        switch serviceMode {
        case .external:
            return !serviceNeedsAttention
        case .bundled:
            switch bundledJournalCardState {
            case .installedCurrent, .done, .externallyManaged, .runtimeStoppedByUser:
                return true
            case .detecting,
                 .absent,
                 .installing,
                 .installedPlaceholder,
                 .installedUnknown,
                 .upgradeFailed,
                 .failed,
                 .runtimeStarting,
                 .runtimeFailed,
                 .runtimeUnconfirmed:
                return false
            }
        }
    }

    private func isInstalledJournalCardState(_ state: InstallerCardState) -> Bool {
        switch state {
        case .installedPlaceholder,
             .done,
             .installedCurrent,
             .installedUnknown,
             .runtimeStarting,
             .runtimeFailed,
             .runtimeUnconfirmed,
             .runtimeStoppedByUser:
            return true
        case .detecting,
             .absent,
             .installing,
             .externallyManaged,
             .upgradeFailed,
             .failed:
            return false
        }
    }

    public internal(set) var visitedSettingsTabs: Set<String> = []

    func markSettingsTabVisited(_ tab: SettingsView.Tab) {
        guard visitedSettingsTabs.insert(tab.rawValue).inserted else { return }
        UserDefaults.standard.set(Array(visitedSettingsTabs).sorted(), forKey: visitedSettingsTabsDefaultsKey)
    }

    internal var bundledRuntimeStartInFlight: Bool {
        inFlightBundledStart != nil
    }

    internal var bundledRuntimeConfirmedAtPin: Bool {
        currentMaterializedRuntime != nil && journalRuntimeStatus == .running
    }

    internal var bundledJournalCardState: InstallerCardState {
        solstone.bundledJournalCardState(
            main: installer.main,
            failureRecord: installer.upgradeFailureRecord,
            runtimeStatus: journalRuntimeStatus,
            startInFlight: bundledRuntimeStartInFlight,
            confirmedAtPin: bundledRuntimeConfirmedAtPin
        )
    }

    internal var bundledJournalStatusAvailable: Bool {
        guard config.serviceMode == .bundled else {
            return false
        }
        return isInstalledJournalCardState(bundledJournalCardState)
    }

    /// Time the app last handled a successful segment upload into the active bundled journal,
    /// or nil when the bundled status surface is unavailable. Forwarded from UploadCoordinator.
    public var bundledJournalLastIngestAt: Date? {
        uploadCoordinator.bundledJournalLastIngestAt
    }

    /// In bundled mode the localhost serverURL isn't owner-meaningful — the bundled
    /// journal IS the journal — so the address row is suppressed in favor of the
    /// runtime-status row. External and unconfigured modes keep showing the address.
    var showsExternalJournalAddressRow: Bool { !bundledJournalStatusAvailable }

    internal var bundledJournalRestartAvailable: Bool {
        bundledJournalStatusAvailable && !journalRuntimeStatus.isSetupNeeded && !bundledRuntimeStartInFlight
    }

    private var journalLifecycleBusy: Bool {
        journalRestartTask != nil || journalStopTask != nil || journalStartTask != nil || inFlightBundledStart != nil
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
        if isRecording {
            await stopRecording()
        }
        await stopSupervisedJournalForTermination()
        await drainRemixQueueForTermination()
    }

    internal func performUpdatePreparation() async {
        if isRecording {
            await stopRecording()
        }
        await stopSupervisedJournalForUpdate()
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
        let transition = handleJournalModeTransition(from: oldConfig.serviceMode, to: newConfig.serviceMode)
        uploadCoordinator.updateConfig(newConfig)
        if transition == .alreadyReadyNoStart, newConfig.isUploadConfigured {
            scheduleStartupUploadSyncIfNeeded()
        }
        let canConfigureJournalServices = newConfig.serviceMode != .bundled || journalDependentServicesReady
        if canConfigureJournalServices,
           newConfig.isUploadConfigured,
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
        loginService: any LoginItemService = LiveLoginItemService()
    ) {
        // Load configuration
        let config = AppConfig.loadOrCreateDefault()
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let uploadClient = UploadClient()
        let solChatTarget = AppStateBridgeTarget()
        let journalStatusTarget = AppStateBridgeTarget()
        let heartbeatTarget = AppStateBridgeTarget()
        let homeBaseURLTarget = AppStateBridgeTarget()

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isSnapshot = false
        self.config = config
        self.notifier = notifier
        self.loginService = loginService
        self.observerHealthSnapshotEnabled = true
        self.installer = SolstoneInstaller()
        self.runtimeMaterializer = RuntimeMaterializer()
        self.supervisedJournalRunner = SupervisedJournalRunner(
            statusSink: { status in
                Task { @MainActor [journalStatusTarget] in
                    journalStatusTarget.state?.journalRuntimeStatus = status
                }
            }
        )
        self.singleSupervisorGate = SingleSupervisorGate()
        self.journalReadinessGate = JournalReadinessGate()
        self.recoveryCoordinator = .shared
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
        self.heartbeatService = HeartbeatService(
            resolver: homeBaseURLResolver,
            isPaused: { [pauseManager, heartbeatTarget] in
                pauseManager.isPaused || (heartbeatTarget.state?.isPaused ?? false)
            },
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

        // Apply debug segments setting if enabled
        if config.debugSegments {
            SegmentWriter.segmentDuration = 60
            Logger.general.info("Debug segments enabled: using 60s duration")
        }

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
            verbose: false,
            recoveryCoordinator: recoveryCoordinator
        )
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder

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
        uploadCoordinator.bundledAvailabilityProvider = { [weak self] in
            self?.bundledJournalStatusAvailable ?? false
        }

        // Wire up callbacks
        captureManager.onStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleCaptureStateChange(state)
            }
        }

        // Single segment-completion nudge for rotation, recovery, stop/pause, sleep, and lock.
        Task {
            await RemixQueue.shared.setOnSegmentComplete { [weak self] _, reconciliation in
                await MainActor.run {
                    guard let self else { return }
                    switch reconciliation {
                    case .normal:
                        self.markCaptureQueuedIfJournalNotReady()
                        self.uploadCoordinator.triggerSync()
                    case .recovered:
                        self.audioReconciledCount += 1
                        self.markCaptureQueuedIfJournalNotReady()
                        self.uploadCoordinator.triggerSync()
                    case .failed(let message):
                        self.errorMessage = message
                    }
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

        let connectedOptInOnlyUIDs = Set(audioDeviceMonitor.availableDevices
            .filter { $0.transportType.isOptInOnly }
            .map { $0.uid })
        self.config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: connectedOptInOnlyUIDs)

        // Sync microphone priority list with available devices
        syncMicrophonePriorityList()

        // Recover any incomplete segments from previous sessions
        recoveryCoordinator.scheduleDetached()

        if config.serviceMode == .bundled {
            startBundledJournalStartup()
        } else {
            configureJournalDependentServices()
        }

        // Start polling permissions — auto-starts recording when ready
        startPermissionPolling()

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
        installer.attach(appState: self)
        solChatTarget.state = self
        journalStatusTarget.state = self
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
            permissionPollTimer?.invalidate()
            journalRestartTask?.cancel()
            journalStopTask?.cancel()
            journalStartTask?.cancel()
            bundledJournalStartupTask?.cancel()
            inFlightBundledStart?.task.cancel()
        }
    }

    // MARK: - Snapshot Construction

    /// Creates an AppState suitable for snapshot previews and testing.
    /// All managers are initialized but no hardware, network, or keychain activity is triggered.
    /// `AppState.shared` is NOT set.
    public static func forSnapshot(
        config: AppConfig = AppConfig(),
        notificationStatus: UNAuthorizationStatus = .authorized,
        notifier: (any SolChatNotifying)? = nil
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(
            snapshotConfig: config,
            notificationStatus: notificationStatus,
            isSnapshot: true,
            notifier: notifier ?? NoopSolChatNotifier()
        )
    }

    /// Creates a side-effect-free AppState that is not snapshot-gated for
    /// testing explicit launch detection behavior.
    internal static func forLaunchDetectionTest(
        config: AppConfig = AppConfig(),
        detectionRunner: @escaping () async -> Bool
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        let state = AppState(
            snapshotConfig: config,
            notificationStatus: .authorized,
            isSnapshot: false,
            notifier: NoopSolChatNotifier()
        )
        state.bundledJournalDetectionRunner = detectionRunner
        return state
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
        loginService: any LoginItemService = LiveLoginItemService()
    ) {
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let heartbeatTarget = AppStateBridgeTarget()
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
        self.notifier = notifier
        self.loginService = loginService
        self.observerHealthSnapshotEnabled = false
        self.notificationAuthorizationStatus = notificationStatus
        self.installer = SolstoneInstaller(
            subprocessRunner: SubprocessRunner(),
            failureRecordStore: InMemoryUpgradeFailureRecordStore()
        )
        self.runtimeMaterializer = RuntimeMaterializer()
        self.supervisedJournalRunner = SupervisedJournalRunner(statusSink: { _ in })
        self.singleSupervisorGate = SingleSupervisorGate()
        self.journalReadinessGate = JournalReadinessGate()
        self.recoveryCoordinator = .shared
        self.heartbeatService = HeartbeatService(
            resolver: snapshotResolver,
            isPaused: { [pauseManager, heartbeatTarget] in
                pauseManager.isPaused || (heartbeatTarget.state?.isPaused ?? false)
            },
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
        let tunnelLifecycleOwner = TunnelLifecycleOwner.dormantForSnapshot()
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

        let debugAudioHolder = DebugSettingHolder(value: false)
        let silenceMusicHolder = DebugSettingHolder(value: true)
        self.debugAudioHolder = debugAudioHolder
        self.silenceMusicHolder = silenceMusicHolder

        captureManager = CaptureManager(storageManager: storageManager)
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

    private func handleTunnelLifecycleState(_ newState: TunnelLifecycleState) {
        let previousState = previousTunnelLifecycleState
        previousTunnelLifecycleState = newState
        guard isConnected(newState), !isConnected(previousState) else { return }
        uploadCoordinator.triggerSync()
    }

    private func isConnected(_ state: TunnelLifecycleState?) -> Bool {
        guard let state else { return false }
        if case .connected = state {
            return true
        }
        return false
    }

    public func startRecording() async {
        guard !isTerminating else {
            Logger.general.info("startRecording() ignored because app is terminating")
            return
        }

        do {
            try await captureManager.startRecording(
                disabledMicUIDs: config.disabledMicrophoneUIDs,
                enabledMicUIDs: config.enabledMicrophoneUIDs
            )
            screenRecordingGranted = true
        } catch let error as CaptureManager.CaptureError where error == .permissionDenied {
            Logger.general.info("[Permissions] Recording denied — screen recording permission not granted")
            screenRecordingGranted = false
        } catch {
            Logger.general.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            errorMessage = UICopy.ERROR_START_OBSERVING
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
            if isTerminating {
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

    // MARK: - Bundled Journal Startup

    private func startBundledJournalStartup() {
        guard !isSnapshot, config.serviceMode == .bundled else { return }
        let root = configuredJournalRoot()
        let hadPriorStartupTask = bundledJournalStartupTask != nil
        Logger.setup.notice("journal-lifecycle: startup-task-scheduled cancelledPrior=\(hadPriorStartupTask, privacy: .public) journalRoot=\(root.path, privacy: .public)")
        bundledJournalStartupTask?.cancel()
        bundledJournalStartupTask = Task { @MainActor [weak self] in
            _ = await self?.coordinateBundledJournalStart(journalRoot: root).value
        }
    }

    internal func ensureBundledJournalRuntime(journalRoot: URL) async -> Bool {
        if config.journalPath != journalRoot.path {
            var next = config
            next.journalPath = journalRoot.path
            config = next
            try? next.save()
        }
        return await coordinateBundledJournalStart(journalRoot: journalRoot).value
    }

    private func coordinateBundledJournalStart(journalRoot rawJournalRoot: URL) -> Task<Bool, Never> {
        guard !isTerminating else {
            Logger.setup.notice("journal-lifecycle: coordinate-start branch=noop reason=terminating")
            return Task { false }
        }

        let journalRoot = rawJournalRoot.standardizedFileURL
        if bundledJournalAlreadyReady(for: journalRoot) {
            Logger.setup.notice("journal-lifecycle: coordinate-start branch=already-ready journalRoot=\(journalRoot.path, privacy: .public)")
            return Task { true }
        }
        if let inFlightBundledStart,
           journalRootsMatch(inFlightBundledStart.journalRoot, journalRoot) {
            Logger.setup.notice("journal-lifecycle: coordinate-start branch=coalesced generation=\(inFlightBundledStart.generation, privacy: .public) journalRoot=\(journalRoot.path, privacy: .public)")
            return inFlightBundledStart.task
        }

        bundledStartGeneration &+= 1
        let generation = bundledStartGeneration
        Logger.setup.notice("journal-lifecycle: coordinate-start branch=new generation=\(generation, privacy: .public) journalRoot=\(journalRoot.path, privacy: .public)")
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let ready = await self.runBundledJournalStartup(journalRoot: journalRoot, generation: generation)
            if self.inFlightBundledStart?.generation == generation {
                self.inFlightBundledStart = nil
            }
            return ready
        }
        inFlightBundledStart = InFlightBundledStart(
            journalRoot: journalRoot,
            generation: generation,
            task: task
        )
        return task
    }

    private func bundledJournalAlreadyReady(for journalRoot: URL) -> Bool {
        guard journalDependentServicesReady,
              let activeJournalRoot,
              journalRootsMatch(activeJournalRoot, journalRoot),
              case .running = journalRuntimeStatus else {
            return false
        }
        return true
    }

    private func journalRootsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private func runBundledJournalStartup(journalRoot: URL, generation: UInt64) async -> Bool {
        let journalRoot = journalRoot.standardizedFileURL
        let ownership = await journalOwnershipResolver(hasLocalJournalCreds())
        switch ownership {
        case .externallyManaged:
            configureJournalDependentServices()
            Logger.setup.notice("journal-lifecycle: bundled-start outcome=external-managed generation=\(generation, privacy: .public)")
            return true
        case .appManaged, .absent:
            break
        }

        let runtime: MaterializedRuntime
        do {
            let liveKey = await supervisedJournalRunner.currentRuntimeKey()
            runtime = try await runtimeMaterializer.materialize(excludingLiveKey: liveKey)
            currentMaterializedRuntime = runtime
            journalBinaryProvider = { runtime.layout.journalBinary }
            Logger.setup.notice("journal-lifecycle: runtime-materialized generation=\(generation, privacy: .public) key=\(runtime.key, privacy: .public)")
        } catch {
            journalRuntimeStatus = .unknown(JournalDiagnostic(
                commandLabel: "journal runtime materialize",
                outputExcerpt: diagnosticMessage(
                    ownerMessage: UICopy.JOURNAL_MATERIALIZE_FAILED,
                    detail: error.localizedDescription
                )
            ))
            Logger.setup.error("journal-lifecycle: runtime-materialize branch=failed generation=\(generation, privacy: .public)")
            return false
        }

        switch await singleSupervisorGate.prepareForSpawn(journalRoot: journalRoot) {
        case .success:
            Logger.setup.notice("journal-lifecycle: prepare-for-spawn result=success generation=\(generation, privacy: .public)")
            break
        case .blocked(let blockage):
            let diagnostic = blockage.diagnostic
            journalRuntimeStatus = .stopped(attentionDiagnostic(
                commandLabel: diagnostic.commandLabel,
                ownerMessage: blockage.ownerMessage,
                diagnostic: diagnostic
            ))
            Logger.setup.warning("journal-lifecycle: prepare-for-spawn result=blocked generation=\(generation, privacy: .public)")
            return false
        }

        do {
            try await supervisedJournalRunner.start(
                runtime: runtime,
                journalRoot: journalRoot,
                port: 5015
            )
        } catch {
            journalRuntimeStatus = .stopped(JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: diagnosticMessage(
                    ownerMessage: UICopy.JOURNAL_SPAWN_FAILED,
                    detail: error.localizedDescription
                )
            ))
            Logger.setup.error("journal-lifecycle: spawn branch=failed generation=\(generation, privacy: .public)")
            return false
        }

        switch await journalReadinessGate.waitUntilReady(
            journalRoot: journalRoot,
            runtime: runtime,
            timeout: .seconds(120),
            terminalCheck: { [supervisedJournalRunner] in
                await supervisedJournalRunner.terminalReason()
            }
        ) {
        case .ready:
            guard generation == bundledStartGeneration else {
                Logger.setup.notice("journal-lifecycle: start-superseded phase=ready-check generation=\(generation, privacy: .public) current=\(self.bundledStartGeneration, privacy: .public)")
                return true
            }
            await supervisedJournalRunner.markReady()
            journalRuntimeStatus = .running
            activeJournalRoot = journalRoot
            configureJournalDependentServices()
            Logger.setup.notice("journal-lifecycle: bundled-start outcome=ready generation=\(generation, privacy: .public)")
            return true
        case .failed(let diagnostic):
            guard generation == bundledStartGeneration else {
                Logger.setup.notice("journal-lifecycle: start-superseded phase=ready-failed generation=\(generation, privacy: .public) current=\(self.bundledStartGeneration, privacy: .public)")
                return false
            }
            if let terminalDiagnostic = await supervisedJournalRunner.terminalReason() {
                await supervisedJournalRunner.stop()
                activeJournalRoot = nil
                journalRuntimeStatus = .stopped(terminalDiagnostic)
                Logger.setup.warning("journal-lifecycle: bundled-start outcome=readiness-terminal-failed generation=\(generation, privacy: .public)")
                return false
            }
            await supervisedJournalRunner.stop()
            activeJournalRoot = nil
            journalRuntimeStatus = .unknown(attentionDiagnostic(
                commandLabel: diagnostic.commandLabel,
                ownerMessage: UICopy.JOURNAL_READINESS_TIMEOUT,
                diagnostic: diagnostic
            ))
            Logger.setup.warning("journal-lifecycle: bundled-start outcome=readiness-failed generation=\(generation, privacy: .public)")
            return false
        case .failedTerminal(let diagnostic):
            guard generation == bundledStartGeneration else {
                Logger.setup.notice("journal-lifecycle: start-superseded phase=ready-terminal-failed generation=\(generation, privacy: .public) current=\(self.bundledStartGeneration, privacy: .public)")
                return false
            }
            await supervisedJournalRunner.stop()
            activeJournalRoot = nil
            journalRuntimeStatus = .stopped(diagnostic)
            Logger.setup.warning("journal-lifecycle: bundled-start outcome=readiness-terminal-failed generation=\(generation, privacy: .public)")
            return false
        }
    }

    private func configuredJournalRoot() -> URL {
        if let journalPath = config.journalPath, !journalPath.isEmpty {
            return URL(fileURLWithPath: journalPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("journal", isDirectory: true)
    }

    private func hasLocalJournalCreds() -> Bool {
        guard BundledJournalEndpoint.isBundledServiceURL(config.serverURL),
              let key = config.serverKey,
              !key.isEmpty else {
            return false
        }
        return true
    }

    private func markCaptureQueuedIfJournalNotReady() {
        guard config.serviceMode == .bundled, !journalDependentServicesReady else { return }
        captureQueuedForJournalReadiness = true
    }

    private func configureJournalDependentServices() {
        journalDependentServicesReady = true
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

    private func attentionDiagnostic(
        commandLabel: String,
        ownerMessage: String,
        diagnostic: JournalDiagnostic
    ) -> JournalDiagnostic {
        JournalDiagnostic(
            commandLabel: commandLabel,
            timedOut: diagnostic.timedOut,
            exitCode: diagnostic.exitCode,
            outputExcerpt: diagnosticMessage(
                ownerMessage: ownerMessage,
                detail: diagnostic.outputExcerpt
            )
        )
    }

    private func diagnosticMessage(ownerMessage: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return ownerMessage }
        return "\(ownerMessage)\n\(detail)"
    }

    // MARK: - Journal Runtime Probing

    internal func startBundledJournalDetectionIfNeeded() async {
        guard !isSnapshot,
              config.serviceMode == .bundled,
              !hasStartedBundledJournalDetection else { return }
        hasStartedBundledJournalDetection = true
        if let bundledJournalDetectionRunner {
            _ = await bundledJournalDetectionRunner()
        } else {
            _ = await installer.detect()
        }
    }

    private func clearJournalProbeState() {
        journalRuntimeStatus = .running
    }

    internal func notifyUpgradeStarted() {
        clearJournalProbeState()
    }

    private func handleJournalModeTransition(
        from oldMode: ServiceMode?,
        to newMode: ServiceMode?
    ) -> JournalModeTransitionOutcome {
        if newMode != .bundled {
            clearJournalProbeState()
            Logger.setup.notice("journal-lifecycle: mode-transition outcome=none reason=not-bundled from=\(String(describing: oldMode), privacy: .public) to=\(String(describing: newMode), privacy: .public)")
            return .none
        }
        if oldMode != .bundled {
            let root = configuredJournalRoot()
            if bundledJournalAlreadyReady(for: root) {
                Logger.setup.notice("journal-lifecycle: mode-transition outcome=already-ready from=\(String(describing: oldMode), privacy: .public) to=\(String(describing: newMode), privacy: .public)")
                return .alreadyReadyNoStart
            }
            journalDependentServicesReady = false
            startBundledJournalStartup()
            Logger.setup.notice("journal-lifecycle: mode-transition outcome=started from=\(String(describing: oldMode), privacy: .public) to=\(String(describing: newMode), privacy: .public)")
            return .started
        }
        Logger.setup.notice("journal-lifecycle: mode-transition outcome=none reason=stable from=\(String(describing: oldMode), privacy: .public) to=\(String(describing: newMode), privacy: .public)")
        return .none
    }

    public func requestJournalRestart() {
        guard !isTerminating else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "terminating")
            return
        }

        if config.serviceMode == .bundled {
            guard !journalRuntimeStatus.isSetupNeeded else { return }
            guard !journalLifecycleBusy else {
                emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "already-running")
                return
            }
            journalRestartTask = Task { @MainActor [weak self] in
                await self?.runSupervisedJournalRestart()
            }
            return
        }
        guard !journalLifecycleBusy else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "already-running")
            return
        }
        journalRestartTask = Task { @MainActor [weak self] in
            await self?.runJournalRestart()
        }
    }

    public func requestJournalStop() {
        guard config.serviceMode == .bundled else { return }
        guard case .running = journalRuntimeStatus else { return }
        guard !journalLifecycleBusy else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "already-running")
            return
        }
        journalStopTask = Task { @MainActor [weak self] in
            await self?.runJournalStop()
        }
    }

    private func runJournalStop() async {
        defer { journalStopTask = nil }
        guard config.serviceMode == .bundled else { return }
        Logger.setup.notice("journal-lifecycle: user-stop begin")
        await supervisedJournalRunner.stop()
        activeJournalRoot = nil
        journalRuntimeStatus = .stoppedByUser
        Logger.setup.notice("journal-lifecycle: user-stop complete")
    }

    public func requestJournalStart() {
        guard !isTerminating else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "terminating")
            return
        }

        guard config.serviceMode == .bundled else { return }
        guard journalRuntimeStatus.isStoppedByUser else { return }
        guard !journalLifecycleBusy else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "already-running")
            return
        }
        journalStartTask = Task { @MainActor [weak self] in
            await self?.runJournalStart()
        }
    }

    internal func requestBundledJournalRuntimeStart() {
        guard !isTerminating else {
            Logger.setup.notice("journal-lifecycle: runtime-start outcome=noop detail=terminating")
            return
        }

        guard config.serviceMode == .bundled else { return }
        guard !bundledRuntimeStartInFlight else { return }
        _ = coordinateBundledJournalStart(journalRoot: configuredJournalRoot())
    }

    private func runJournalStart() async {
        defer { journalStartTask = nil }
        guard config.serviceMode == .bundled else { return }
        Logger.setup.notice("journal-lifecycle: user-start begin")
        let preStartError = errorMessage
        let ready = await coordinateBundledJournalStart(journalRoot: configuredJournalRoot()).value
        if ready {
            journalRuntimeStatus = .running
            errorMessage = preStartError
            Logger.setup.notice("journal-lifecycle: user-start outcome=ready")
        } else {
            Logger.setup.warning("journal-lifecycle: user-start outcome=failed")
            if errorMessage == nil {
                errorMessage = "start failed — journal didn't come back"
            }
        }
    }

    // TODO(v1.1): remove once the first production '.bundled'-mode restart-required Settings UI lands (e.g. provider-API-key field).
    internal func notifyRestartRequiredSettingSaved() {
        guard config.serviceMode == .bundled else {
            Logger.setup.info("restart-required banner suppressed: serviceMode is not bundled")
            return
        }
        guard bundledJournalRestartAvailable || journalRestartTask != nil else {
            Logger.setup.info("restart-required banner suppressed: bundled journal restart not available")
            return
        }
        restartRequiredGeneration &+= 1
        restartRequiredBannerVisible = true
    }

    private func runJournalRestart() async {
        preRestartErrorMessage = errorMessage
        journalRuntimeStatus = .restarting
        let restartStartGeneration = restartRequiredGeneration
        var restartOutcome: JournalRestartRequestOutcome = .modeChanged
        defer {
            if case .restarting = journalRuntimeStatus {
                journalRuntimeStatus = .running
            }
            journalRestartTask = nil
            preRestartErrorMessage = nil
        }

        guard let journalBinary = journalBinaryProvider(),
              journalRuntimeFileExists(journalBinary.path) else {
            clearJournalProbeState()
            journalRuntimeStatus = .setupNeeded
            restartOutcome = .binaryMissing
            let message = "restart failed — journal setup needed"
            emitJournalRestartLog(step: .resolveJournal, outcome: "error", detail: "binary-missing")
            if config.serviceMode == .bundled {
                errorMessage = message
            }
            return
        }

        let logSink = journalRestartLogSink
        let probeRunner = journalRuntimeProbeRunner
        let fileExists = journalRuntimeFileExists
        let runner = journalRestartRunnerFactory?(journalBinary, logSink) ?? JournalRestartRunner(
            reprobe: {
                await JournalRuntimeProbe.run(
                    journalBinary: journalBinary,
                    runner: probeRunner,
                    fileExists: fileExists
                )
            },
            logSink: logSink,
            journalBinary: journalBinary
        )

        switch await runner.run() {
        case .success:
            clearJournalProbeState()
            restartOutcome = .success
            errorMessage = preRestartErrorMessage
        case .failure(let failure):
            restartOutcome = .failure
            errorMessage = failure.ownerMessage
            journalRuntimeStatus = .stopped(failure.diagnostic)
        }
        if restartOutcome == .success && restartStartGeneration == restartRequiredGeneration {
            restartRequiredBannerVisible = false
        }
    }

    private func runSupervisedJournalRestart() async {
        Logger.setup.notice("journal-lifecycle: supervised-restart begin")
        preRestartErrorMessage = errorMessage
        journalRuntimeStatus = .restarting
        let restartStartGeneration = restartRequiredGeneration
        defer {
            journalRestartTask = nil
            preRestartErrorMessage = nil
        }

        guard config.serviceMode == .bundled else {
            emitJournalRestartLog(step: .serviceRestart, outcome: "noop", detail: "not-bundled")
            journalRuntimeStatus = .running
            return
        }
        guard let runtime = currentMaterializedRuntime else {
            Logger.setup.notice("journal-lifecycle: supervised-restart branch=cold-start")
            let ready = await coordinateBundledJournalStart(journalRoot: configuredJournalRoot()).value
            if ready {
                errorMessage = preRestartErrorMessage
                if restartStartGeneration == restartRequiredGeneration {
                    restartRequiredBannerVisible = false
                }
            } else if errorMessage == nil {
                errorMessage = "restart failed — journal did not come back"
            }
            return
        }

        do {
            try await supervisedJournalRunner.restart()
        } catch {
            journalRuntimeStatus = .stopped(JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: diagnosticMessage(
                    ownerMessage: UICopy.JOURNAL_SPAWN_FAILED,
                    detail: error.localizedDescription
                )
            ))
            Logger.setup.error("journal-lifecycle: supervised-restart branch=spawn-failed")
            errorMessage = UICopy.JOURNAL_SPAWN_FAILED
            return
        }

        switch await journalReadinessGate.waitUntilReady(
            journalRoot: configuredJournalRoot(),
            runtime: runtime,
            timeout: .seconds(120),
            terminalCheck: { [supervisedJournalRunner] in
                await supervisedJournalRunner.terminalReason()
            }
        ) {
        case .ready:
            await supervisedJournalRunner.markReady()
            configureJournalDependentServices()
            Logger.setup.notice("journal-lifecycle: supervised-restart outcome=ready")
            errorMessage = preRestartErrorMessage
            if restartStartGeneration == restartRequiredGeneration {
                restartRequiredBannerVisible = false
            }
        case .failed(let diagnostic):
            if let terminalDiagnostic = await supervisedJournalRunner.terminalReason() {
                await supervisedJournalRunner.stop()
                activeJournalRoot = nil
                journalRuntimeStatus = .stopped(terminalDiagnostic)
                Logger.setup.warning("journal-lifecycle: supervised-restart outcome=readiness-terminal-failed")
                errorMessage = terminalDiagnostic.outputExcerpt ?? UICopy.JOURNAL_SPAWN_FAILED
                return
            }
            journalRuntimeStatus = .unknown(attentionDiagnostic(
                commandLabel: diagnostic.commandLabel,
                ownerMessage: UICopy.JOURNAL_READINESS_TIMEOUT,
                diagnostic: diagnostic
            ))
            Logger.setup.warning("journal-lifecycle: supervised-restart outcome=readiness-failed")
            errorMessage = UICopy.JOURNAL_READINESS_TIMEOUT
        case .failedTerminal(let diagnostic):
            await supervisedJournalRunner.stop()
            activeJournalRoot = nil
            journalRuntimeStatus = .stopped(diagnostic)
            Logger.setup.warning("journal-lifecycle: supervised-restart outcome=readiness-terminal-failed")
            errorMessage = diagnostic.outputExcerpt ?? UICopy.JOURNAL_SPAWN_FAILED
        }
    }

    public func stopSupervisedJournalForTermination() async {
        guard config.serviceMode == .bundled else { return }
        await supervisedJournalRunner.stopForTermination()
        activeJournalRoot = nil
    }

    public func stopSupervisedJournalForUpdate() async {
        guard config.serviceMode == .bundled else { return }
        await supervisedJournalRunner.stop()
        activeJournalRoot = nil
    }

    public func reestablishSupervisedJournalAfterFailedUpdate() async {
        guard config.serviceMode == .bundled else { return }
        _ = await coordinateBundledJournalStart(journalRoot: configuredJournalRoot()).value
    }

    private func emitJournalRestartLog(step: JournalRestartStep, outcome: String, detail: String?) {
        let event = JournalRestartLogEvent(step: step, outcome: outcome, detail: detail)
        let detailSuffix = detail.map { " detail=\($0)" } ?? ""
        if outcome == "error" {
            Logger.setup.warning("journal-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        } else {
            Logger.setup.info("journal-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        }
        journalRestartLogSink?(event)
    }

    // MARK: - Private Methods

    private func handleCaptureStateChange(_ state: CaptureManager.State) {
        switch state {
        case .idle:
            isRecording = false
            isPaused = false
            // Resume polling so automatic retry and IPC .start can begin again
            // when permissions or runtime readiness change.
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

    /// Reloads config when an external process writes observer upload identity to UserDefaults.
    /// Guards against feedback loops: updateConfig() -> save() -> notification -> load() -> same values -> return.
    private func handleExternalDefaultsChange() {
        let fresh = AppConfig.load()

        // Only react to observer identity changes — ignore unrelated defaults
        guard fresh.serverURL != config.serverURL ||
              fresh.serverKey != config.serverKey ||
              fresh.observerName != config.observerName else {
            return
        }

        Logger.general.info("External defaults change detected — reloading observer upload config")
        updateConfig(fresh)

        if fresh.isUploadConfigured,
           (fresh.serviceMode != .bundled || journalDependentServicesReady) {
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
