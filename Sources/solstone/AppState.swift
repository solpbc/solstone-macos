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
    internal static let terminationRemixDrainTimeoutSeconds: Double = 30

    /// Shared instance for app-wide access (registered by normal startup composition).
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
    public let recoveryCoordinator: IncompleteSegmentRecoveryCoordinator
    internal let tunnelLifecycleOwner: TunnelLifecycleOwner
    internal let pairingCoordinator: PairingCoordinator
    private let homeBaseURLResolver: HomeBaseURLResolver
    private let ingestBaseURLResolver: HomeBaseURLResolver
    private let sameMachinePairStart: @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
    // Test seam for observing tunnel-connected sync nudges when UploadCoordinator short-circuits.
    private let triggerTunnelConnectedSync: @MainActor @Sendable (AppState) -> Void
    private let notifier: any UserNotifying
    private let loginService: any LoginItemService
    private let loginItemRegistrationReconciler: LoginItemRegistrationReconciler
    private let lastContactStore: any LastSuccessfulJournalContactStoring
    private let recorder: DiagnosticEvidenceRecorder
    private let logAdapter: DiagnosticEvidenceLoggingAdapter
    private let isSnapshot: Bool
    private let automaticObservationPipelineEnabled: Bool
    public private(set) var config: AppConfig
    private var debugAudioHolder: DebugSettingHolder!
    private var silenceMusicHolder: DebugSettingHolder!
    private var didAttemptSameMachineMigration = false
    private static let sameMachineMigrationRetryDelays: [Duration] = [
        .zero,
        .seconds(1),
        .seconds(2),
        .seconds(7),
        .seconds(20),
    ]
    internal private(set) var sameMachineMigrationLastResult: SameMachineHomePairingResult?
    /// True only while the automatic same-machine adoption is driving the pairing ceremony.
    /// Owner-initiated pairing never sets it, so the journal-mark confirmation still runs there.
    /// Settable within the module so both branches can be exercised directly in tests.
    internal var isAdoptingSameMachineHomeAutomatically = false

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

    internal private(set) var journalOpenIntent: JournalOpenIntent?
    internal private(set) var journalHomeBaseChangeToken: UInt64 = 0
    public internal(set) var connectionTestState: ConnectionTestState = .idle
    public internal(set) var journalHandoffActive = false
    internal private(set) var confirmedMark: JournalMark?
    public private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Screen recording permission — polled periodically via SCShareableContent.
    public var screenRecordingGranted: Bool { capture.screenRecordingGranted }

    /// Microphone permission — derived from the current authorization cause.
    public var microphoneGranted: Bool {
        capture.microphoneGranted
    }

    internal var microphoneAuthorizationCause: MicrophoneAuthorizationCause {
        get { capture.microphoneAuthorizationCause }
        set { capture.microphoneAuthorizationCause = newValue }
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
    private var notificationRequestTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    internal var terminationDrainer: any TerminationDraining = RemixQueue.shared
    internal var terminationDrainRunner: @MainActor (@escaping @Sendable () async -> Void) async throws -> Void = { operation in
        try await withTimeout(
            seconds: AppState.terminationRemixDrainTimeoutSeconds,
            operation: operation
        )
    }
    internal var replacementLaunchRunner: @MainActor (ReplacementLaunchCommand) throws -> Void = ReplacementLaunchGate.runDetached

    // MARK: - Activation Policy

    public internal(set) var openSceneIds: Set<SolstoneSceneID> = []
    public internal(set) var dockMode: DockMode = .auto
    public internal(set) var currentPolicy: NSApplication.ActivationPolicy = .accessory
    public internal(set) var loginLaunchSuppressionExpires: Date = .distantPast
    public internal(set) var isTerminating: Bool = false
    public internal(set) var appKitTerminationBegan: Bool = false
    private var activationPolicyWorkItem: DispatchWorkItem?
    private var nextJournalOpenIntentID: UInt64 = 0
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
            return "on"
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
        launchReplacement: @escaping @MainActor () -> Void,
        recorder: DiagnosticEvidenceRecorder,
        logAdapter: DiagnosticEvidenceLoggingAdapter
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
            ),
            recorder: recorder,
            logAdapter: logAdapter
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
            try await terminationDrainRunner { await drainer.waitForCompletion() }
        } catch {
            if error is TimeoutError {
                recorder.enqueue(.terminationDrainTimeout)
                logAdapter.terminationDrainTimeout()
            }
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

    func migrateLoginItemToWatchdogIfNeeded() {
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

    internal func reconcileLoginItemRegistrationAfterUpdateIfNeeded() async {
        await loginItemRegistrationReconciler.reconcileIfNeeded()
        refreshLoginItemStatus()
    }

    // MARK: - Configuration

    /// Update and save configuration
    public func updateConfig(_ newConfig: AppConfig) {
        let oldConfig = config
        config = newConfig
        uploadCoordinator.updateConfig(newConfig)
        uploadCoordinator.updatePairedIngestIdentity(currentPairedIngestIdentity())
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

    internal func currentJournalIdentity() -> JournalIdentityRead {
        let pairing: TunnelPairingIdentity?
        switch tunnelLifecycleOwner.pairingIdentityRead {
        case .failed:
            return .failed
        case .found(let identity):
            pairing = identity
        case .absent:
            pairing = nil
        }
        let topology = classifySetupTopology(
            serviceMode: config.serviceMode,
            serverURL: config.serverURL,
            isTunnelManaged: tunnelLifecycleOwner.isTunnelManaged,
            isPairedHome: tunnelLifecycleOwner.isPairedHome
        )
        guard let fingerprint = journalConnectionFingerprint(
            config: config,
            topology: topology,
            isTunnelManaged: tunnelLifecycleOwner.isTunnelManaged,
            tunnelPairing: pairing
        ) else {
            return .absent
        }
        return .identified(fingerprint)
    }

    internal func reevaluateTunnelPairing() async {
        await tunnelLifecycleOwner.reevaluatePairing()
        uploadCoordinator.refreshLastJournalDelivery()
    }

    internal var isPairedHome: Bool {
        tunnelLifecycleOwner.isPairedHome
    }

    internal var sameMachineHomeMigrationComplete: Bool {
        isPairedHome
    }

    internal func triggerSameMachineMigrationIfEligible() {
        guard !didAttemptSameMachineMigration,
              isEligibleForSameMachineMigration()
        else {
            return
        }

        didAttemptSameMachineMigration = true
        Task { @MainActor [weak self] in
            guard let self else { return }

            for (attempt, delay) in Self.sameMachineMigrationRetryDelays.enumerated() {
                if attempt > 0 {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }

                guard self.isEligibleForSameMachineMigration() else { return }
                await self.runSameMachineHomeMigration()
                guard self.shouldRetrySameMachineMigration else { return }
            }
        }
    }

    internal func isEligibleForSameMachineMigration() -> Bool {
        guard !isSnapshot,
              BundledJournalEndpoint.isBundledServiceURL(config.serverURL),
              let serverKey = config.serverKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverKey.isEmpty,
              config.serviceMode == .external,
              config.isUploadConfigured,
              !isPairedHome
        else {
            return false
        }

        return tunnelLifecycleOwner.sameMachineStoredPairingState == .noneHeld
    }

    private var shouldRetrySameMachineMigration: Bool {
        guard case let .failed(.pairStart(failure)) = sameMachineMigrationLastResult else {
            return false
        }
        switch failure {
        case .transport, .httpStatus(503):
            return true
        case .invalidURL, .requestEncoding, .invalidResponse, .httpStatus(_), .decode, .emptyPairLink:
            return false
        }
    }

    private func runSameMachineHomeMigration() async {
        guard let baseURL = config.serverURL else {
            sameMachineMigrationLastResult = .notEligible
            return
        }

        // This adoption runs by itself for a journal the owner already had
        // linked on this same Mac. It re-uses the pairing ceremony to adopt the existing record
        // rather than re-mint one, and that ceremony ends by asking the owner to compare journal
        // marks. Left alone, merely taking an update therefore raises a security question the
        // owner never started and parks settings behind a modal until they answer it.
        //
        // No new trust decision is being made here: the journal is the one they were already
        // using, on this machine, over a link sol verified as direct with exactly one loopback
        // candidate. So suppress the mark for *this* ceremony only.
        //
        // ⛔ Scope this to the automatic adoption, never to same-machine pairing generally — an
        // owner-initiated link, including a fresh one to a journal on this same Mac, must still
        // confirm its mark, and the release gate asserts exactly that.
        // ⛔ Deliberately not cleared when this function returns. The ceremony's final state is
        // observed asynchronously, so the mark driver runs *after* the await below completes —
        // a `defer` here closes the window before the thing it is meant to cover ever happens,
        // which is exactly how the first attempt at this failed on the rig while passing tests.
        // The flag is cleared instead by the owner starting a pairing of their own.
        isAdoptingSameMachineHomeAutomatically = true

        let result = await performSameMachineHomePairing(
            baseURL: baseURL,
            existingPairing: tunnelLifecycleOwner.sameMachineStoredPairingState,
            startPairing: sameMachinePairStart,
            submitPairingLink: { [pairingCoordinator] exactPairLink in
                await pairingCoordinator.submitPairingLink(exactPairLink)
                return pairingCoordinator.state
            }
        )
        sameMachineMigrationLastResult = result

        if case .failed(let failure) = result {
            Logger.setup.debug("same-machine home migration did not complete: \(String(describing: failure), privacy: .public)")
        }
    }

    internal func clearLastSuccessfulJournalContact() {
        lastContactStore.clear()
        uploadCoordinator?.refreshLastSuccessfulJournalContact()
        uploadCoordinator?.refreshLastJournalDelivery()
    }

    internal func readDiagnosticEvidence() async -> DiagnosticEvidenceRead {
        await recorder.read()
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
                guard let self else { return }
                self.refreshMicrophoneAuthorization()
                await self.refreshNotificationAuthorizationStatus()
            }
        }
    }

    internal func refreshMicrophoneAuthorization() {
        capture.refreshMicrophoneAuthorization()
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

    /// Ingest never falls back to the configured external server. Journal v3 is
    /// available only over an established paired loopback tunnel.
    private static func makeIngestBaseURLResolver(target: AppStateBridgeTarget) -> HomeBaseURLResolver {
        HomeBaseURLResolver { [target] in
            await MainActor.run {
                guard let state = target.state else { return .held }
                let owner = state.tunnelLifecycleOwner
                return Self.ingestBaseURL(
                    lifecycleState: owner.state,
                    localPort: owner.localPort,
                    pairingIdentity: owner.cachedPairingIdentity
                )
            }
        }
    }

    internal static func ingestBaseURL(
        lifecycleState: TunnelLifecycleState,
        localPort: Int?,
        pairingIdentity: TunnelPairingIdentity?
    ) -> ResolvedHomeBase {
        guard case .connected = lifecycleState,
              let localPort,
              pairingIdentity != nil else {
            return .held
        }
        return .url("http://127.0.0.1:\(localPort)")
    }

    internal var isPairedIngestReady: Bool {
        let owner = tunnelLifecycleOwner
        guard case .connected = owner.state,
              owner.localPort != nil,
              owner.cachedPairingIdentity != nil else {
            return false
        }
        return true
    }

    private func currentPairedIngestIdentity() -> TunnelPairingIdentity? {
        guard isPairedIngestReady else { return nil }
        return tunnelLifecycleOwner.cachedPairingIdentity
    }

    internal func resolveHomeBase() async -> ResolvedHomeBase {
        await homeBaseURLResolver.resolve()
    }

    internal func resolveIngestBase() async -> ResolvedHomeBase {
        await ingestBaseURLResolver.resolve()
    }

    internal func setConfirmedMark(_ mark: JournalMark) {
        confirmedMark = mark
    }

    internal func clearConfirmedMark() {
        confirmedMark = nil
    }

    init(
        notifier: any UserNotifying = UNUserNotificationCenterNotifier(),
        loginService: any LoginItemService = LiveLoginItemService(),
        automaticObservationPipelineEnabled: Bool = true,
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        },
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live
    ) {
        // Load configuration
        let config = AppConfig.loadOrCreateDefault()
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let captureTarget = AppStateBridgeTarget()
        let homeBaseURLTarget = AppStateBridgeTarget()
        let fingerprintTarget = AppStateBridgeTarget()
        let recoveryCoordinator = IncompleteSegmentRecoveryCoordinator.shared
        let lastContactStore = UserDefaultsLastSuccessfulJournalContactStore()
        let lastDeliveryStore = UserDefaultsLastJournalDeliveryStore()

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isSnapshot = false
        self.automaticObservationPipelineEnabled = automaticObservationPipelineEnabled
        self.config = config
        self.sameMachinePairStart = { baseURL, deviceLabel in
            await SameMachinePairStartClient().start(baseURL: baseURL, deviceLabel: deviceLabel)
        }
        self.triggerTunnelConnectedSync = triggerTunnelConnectedSync
        self.notifier = notifier
        self.loginService = loginService
        self.loginItemRegistrationReconciler = LoginItemRegistrationReconciler(
            loginService: loginService,
            receiptStore: UserDefaultsLoginItemRegistrationReceiptStore(),
            stateStore: UserDefaultsLoginItemRegistrationReconciliationStateStore(),
            placementDecision: AppPlacementGate.evaluate(),
            runningBundleURL: Bundle.main.bundleURL,
            versionReader: SolstoneBundleVersionReader.read(fromBundleAt:)
        )
        self.lastContactStore = lastContactStore
        self.recorder = recorder
        self.logAdapter = logAdapter
        self.recoveryCoordinator = recoveryCoordinator
        let splClientInfo = SPLRuntime.clientInfo
        let splKeychainStore = SPLPairingKeychain.store()
        let tunnelLifecycleOwner = TunnelLifecycleOwner(
            keychainStore: splKeychainStore,
            clientInfo: splClientInfo
        )
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.pairingCoordinator = PairingCoordinator(
            clientInfo: splClientInfo,
            keychainStore: splKeychainStore,
            reactivate: { [fingerprintTarget] in
                await fingerprintTarget.state?.reevaluateTunnelPairing()
            },
            ownerState: { [owner = tunnelLifecycleOwner] in
                owner.state
            },
            clearLastSuccessfulJournalContact: { [fingerprintTarget, lastContactStore] in
                if let state = fingerprintTarget.state {
                    state.clearLastSuccessfulJournalContact()
                } else {
                    lastContactStore.clear()
                }
            }
        )
        let homeBaseURLResolver = Self.makeHomeBaseURLResolver(target: homeBaseURLTarget)
        self.homeBaseURLResolver = homeBaseURLResolver
        let ingestBaseURLResolver = Self.makeIngestBaseURLResolver(target: homeBaseURLTarget)
        self.ingestBaseURLResolver = ingestBaseURLResolver

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
            },
            recorder: recorder,
            screenPermissionProvider: screenPermissionProvider,
            logAdapter: logAdapter
        )
        self.capture = capture

        uploadCoordinator = UploadCoordinator(
            storageManager: storageManager,
            config: config,
            resolver: ingestBaseURLResolver,
            pairedIngestIdentity: nil,
            automaticSyncEnabled: automaticObservationPipelineEnabled,
            lastContactStore: lastContactStore,
            lastDeliveryStore: lastDeliveryStore,
            journalIdentityProvider: { [fingerprintTarget] in
                fingerprintTarget.state?.currentJournalIdentity() ?? .absent
            },
            recorder: recorder,
            logAdapter: logAdapter
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
            },
            recorder: recorder,
            logAdapter: logAdapter
        )
        captureTarget.state = self

        if automaticObservationPipelineEnabled {
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
        }

        let connectedOptInOnlyUIDs = Set(audioDeviceMonitor.availableDevices
            .filter { $0.isOptInOnlyMicrophone }
            .map { $0.uid })
        self.config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: connectedOptInOnlyUIDs)

        // Sync microphone priority list with available devices
        syncMicrophonePriorityList()

        if automaticObservationPipelineEnabled {
            // Recover any incomplete segments from previous sessions.
            recoveryCoordinator.scheduleDetached()
            configureJournalServicesIfNeeded()
        }

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

        // Complete manager bridge wiring. Normal startup composition registers AppState.shared.
        homeBaseURLTarget.state = self
        fingerprintTarget.state = self
        uploadCoordinator.updatePairedIngestIdentity(currentPairedIngestIdentity())
        uploadCoordinator.refreshLastSuccessfulJournalContact()
        uploadCoordinator.refreshLastJournalDelivery()
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
    static func forSnapshot(
        config: AppConfig = AppConfig(),
        notificationStatus: UNAuthorizationStatus = .authorized,
        notifier: (any UserNotifying)? = nil,
        initialTunnelPairing: StoredPairing? = nil,
        sameMachinePairStart: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ deviceLabel: String
        ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> = { baseURL, deviceLabel in
            await SameMachinePairStartClient().start(baseURL: baseURL, deviceLabel: deviceLabel)
        },
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        },
        lastContactStore: (any LastSuccessfulJournalContactStoring)? = nil,
        lastDeliveryStore: (any LastJournalDeliveryStoring)? = nil,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        permissionPollScheduler: PermissionPollScheduler = .live(),
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        captureStartOperation: CaptureCoordinator.StartOperation? = nil
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(
            snapshotConfig: config,
            notificationStatus: notificationStatus,
            isSnapshot: true,
            notifier: notifier ?? NoopUserNotifier(),
            initialTunnelPairing: initialTunnelPairing,
            sameMachinePairStart: sameMachinePairStart,
            triggerTunnelConnectedSync: triggerTunnelConnectedSync,
            lastContactStore: lastContactStore,
            lastDeliveryStore: lastDeliveryStore,
            recorder: recorder,
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: permissionPollScheduler,
            logAdapter: logAdapter,
            captureStartOperation: captureStartOperation
        )
    }

    /// Creates an AppState for login item tests.
    internal static func forLoginItemTest(
        config: AppConfig = AppConfig(),
        loginService: any LoginItemService,
        placementDecision: AppPlacementDecision = AppPlacementGate.evaluate(),
        receiptStore: any LoginItemRegistrationReceiptStoring = UserDefaultsLoginItemRegistrationReceiptStore(),
        stateStore: any LoginItemRegistrationReconciliationStateStoring = UserDefaultsLoginItemRegistrationReconciliationStateStore(),
        runningBundleURL: URL = Bundle.main.bundleURL,
        versionReader: @escaping (URL) throws -> SolstoneBundleVersion = SolstoneBundleVersionReader.read(fromBundleAt:),
        sameMachinePairStart: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ deviceLabel: String
        ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> = { baseURL, deviceLabel in
            await SameMachinePairStartClient().start(baseURL: baseURL, deviceLabel: deviceLabel)
        },
        pairingOperation: PairingCoordinator.PairOperation? = nil,
        pairingLoad: PairingCoordinator.LoadPairing? = nil,
        pairingSave: PairingCoordinator.SavePairing? = nil,
        pairingDelete: PairingCoordinator.DeletePairing? = nil
    ) -> AppState {
        snapshotAudioMonitorMode = true
        defer { snapshotAudioMonitorMode = false }
        return AppState(
            snapshotConfig: config,
            notificationStatus: .authorized,
            isSnapshot: false,
            notifier: NoopUserNotifier(),
            loginService: loginService,
            placementDecision: placementDecision,
            receiptStore: receiptStore,
            stateStore: stateStore,
            runningBundleURL: runningBundleURL,
            versionReader: versionReader,
            sameMachinePairStart: sameMachinePairStart,
            pairingOperation: pairingOperation,
            pairingLoad: pairingLoad,
            pairingSave: pairingSave,
            pairingDelete: pairingDelete
        )
    }

    /// Private designated init that creates all managers without activating hardware or side effects.
    private init(
        snapshotConfig config: AppConfig,
        notificationStatus: UNAuthorizationStatus,
        isSnapshot: Bool,
        notifier: any UserNotifying,
        initialTunnelPairing: StoredPairing? = nil,
        loginService: any LoginItemService = LiveLoginItemService(),
        placementDecision: AppPlacementDecision = AppPlacementGate.evaluate(),
        receiptStore: any LoginItemRegistrationReceiptStoring = UserDefaultsLoginItemRegistrationReceiptStore(),
        stateStore: any LoginItemRegistrationReconciliationStateStoring = UserDefaultsLoginItemRegistrationReconciliationStateStore(),
        runningBundleURL: URL = Bundle.main.bundleURL,
        versionReader: @escaping (URL) throws -> SolstoneBundleVersion = SolstoneBundleVersionReader.read(fromBundleAt:),
        sameMachinePairStart: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ deviceLabel: String
        ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> = { baseURL, deviceLabel in
            await SameMachinePairStartClient().start(baseURL: baseURL, deviceLabel: deviceLabel)
        },
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        },
        lastContactStore providedLastContactStore: (any LastSuccessfulJournalContactStoring)? = nil,
        lastDeliveryStore providedLastDeliveryStore: (any LastJournalDeliveryStoring)? = nil,
        pairingOperation: PairingCoordinator.PairOperation? = nil,
        pairingLoad: PairingCoordinator.LoadPairing? = nil,
        pairingSave: PairingCoordinator.SavePairing? = nil,
        pairingDelete: PairingCoordinator.DeletePairing? = nil,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        permissionPollScheduler: PermissionPollScheduler = .live(),
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        captureStartOperation: CaptureCoordinator.StartOperation? = nil
    ) {
        let pauseManager = PauseManager()
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let captureTarget = AppStateBridgeTarget()
        let fingerprintTarget = AppStateBridgeTarget()
        let snapshotResolver = HomeBaseURLResolver { [config] in
            guard let serverURL = config.serverURL else {
                return .held
            }
            return .url(serverURL)
        }
        self.homeBaseURLResolver = snapshotResolver
        let snapshotIngestResolver = HomeBaseURLResolver { .held }
        self.ingestBaseURLResolver = snapshotIngestResolver

        self.pauseManager = pauseManager
        self.storageManager = storageManager
        self.audioDeviceMonitor = audioDeviceMonitor
        self.isSnapshot = isSnapshot
        // Only the live-probe launch suppresses the automatic pipeline, and it
        // always comes through the designated initializer. This initializer
        // starts no capture, recovery, or startup sync of its own; normal
        // startup composition owns activation after it creates the state.
        self.automaticObservationPipelineEnabled = true
        self.config = config
        self.sameMachinePairStart = sameMachinePairStart
        self.triggerTunnelConnectedSync = triggerTunnelConnectedSync
        self.notifier = notifier
        self.loginService = loginService
        self.loginItemRegistrationReconciler = LoginItemRegistrationReconciler(
            loginService: loginService,
            receiptStore: receiptStore,
            stateStore: stateStore,
            placementDecision: placementDecision,
            runningBundleURL: runningBundleURL,
            versionReader: versionReader
        )
        let lastContactStore = providedLastContactStore ?? InMemoryLastSuccessfulJournalContactStore()
        self.lastContactStore = lastContactStore
        self.recorder = recorder
        self.logAdapter = logAdapter
        let lastDeliveryStore = providedLastDeliveryStore ?? InMemoryLastJournalDeliveryStore()
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
            },
            startOperation: captureStartOperation,
            recorder: recorder,
            screenPermissionProvider: screenPermissionProvider,
            permissionPollScheduler: permissionPollScheduler,
            logAdapter: logAdapter
        )
        self.capture = capture
        let tunnelPairingLoad: @Sendable () throws -> StoredPairing?
        if let pairingLoad {
            tunnelPairingLoad = pairingLoad
        } else if let initialTunnelPairing {
            tunnelPairingLoad = { initialTunnelPairing }
        } else {
            tunnelPairingLoad = { nil }
        }
        let tunnelLifecycleOwner = TunnelLifecycleOwner.dormantForSnapshot(loadPairing: tunnelPairingLoad)
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.pairingCoordinator = PairingCoordinator(
            pair: pairingOperation,
            loadPairing: pairingLoad ?? { nil },
            savePairing: pairingSave ?? { _ in },
            deletePairing: pairingDelete ?? {},
            reactivate: { [fingerprintTarget] in
                await fingerprintTarget.state?.reevaluateTunnelPairing()
            },
            ownerState: { [owner = tunnelLifecycleOwner] in
                owner.state
            },
            clearLastSuccessfulJournalContact: { [lastContactStore] in
                lastContactStore.clear()
            }
        )

        uploadCoordinator = UploadCoordinator(
            forSnapshot: storageManager,
            config: config,
            resolver: snapshotIngestResolver,
            lastContactStore: lastContactStore,
            lastDeliveryStore: lastDeliveryStore,
            journalIdentityProvider: { [fingerprintTarget] in
                fingerprintTarget.state?.currentJournalIdentity() ?? .absent
            },
            recorder: recorder,
            logAdapter: logAdapter
        )
        appQuitCoordinator = makeAppQuitCoordinator(
            setCommitted: { _ in },
            terminate: {},
            launchReplacement: {},
            recorder: recorder,
            logAdapter: logAdapter
        )
        visitedSettingsTabs = Set(UserDefaults.standard.stringArray(forKey: visitedSettingsTabsDefaultsKey) ?? [])
        captureTarget.state = self
        fingerprintTarget.state = self
        uploadCoordinator.refreshLastSuccessfulJournalContact()
        uploadCoordinator.refreshLastJournalDelivery()

        // No pause restore, no segment recovery,
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
        journalHomeBaseChangeToken += 1
        uploadCoordinator.updatePairedIngestIdentity(currentPairedIngestIdentity())
        guard isConnected(newState), !isConnected(previousState) else { return }
        guard automaticObservationPipelineEnabled else { return }
        triggerTunnelConnectedSync(self)
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
        triggerSameMachineMigrationIfEligible()
    }

    private func scheduleStartupUploadSyncIfNeeded() {
        guard isPairedIngestReady else { return }
        Task.detached { [uploadCoordinator] in
            await uploadCoordinator?.syncOnStartup()
        }
    }

    public func didOpenWindow(_ id: SolstoneSceneID) {
        openSceneIds.insert(id)
        reevaluateActivationPolicy(debounced: false)
    }

    public func requestOpenJournal(_ destination: JournalWindowDestination) {
        nextJournalOpenIntentID += 1
        journalOpenIntent = JournalOpenIntent(
            id: nextJournalOpenIntentID,
            destination: destination
        )
        NotificationCenter.default.post(name: .openJournalWindow, object: nil)
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
                return SolstoneSceneID.allCases.contains { identifier.contains($0.rawValue) }
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

        Logger.general.info("External defaults change detected, reloading journal connection config")
        let identityChanged = fresh.serverURL != config.serverURL ||
            fresh.serverKey != config.serverKey ||
            fresh.serviceMode != config.serviceMode ||
            fresh.journalPath != config.journalPath
        if identityChanged {
            clearLastSuccessfulJournalContact()
        }
        updateConfig(fresh)

        if isPairedIngestReady {
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
