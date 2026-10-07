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
import UpdateKit

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
    internal let credentialStore: PairingCredentialStore?
    #if SOLSTONE_BROWSER_INTAKE_PREVIEW
    @ObservationIgnored private var browserIntakeOwner: BrowserIntakeOwner?
    @ObservationIgnored private var browserHostListener: BrowserHostListener?
    @ObservationIgnored private var browserIntakeStartupScheduled = false
    @ObservationIgnored private var browserIntakeCredentialStore: PairingCredentialStore?
    @ObservationIgnored private var browserIntakeRouteState: BrowserIntakeRouteState?
    public private(set) var browserIntakeStore: BrowserIntakeStore?
    public private(set) var browserIntakeAuthority: BrowserIntakeAuthority?
    public let browserHostSnapshot = BrowserHostSnapshot()
    var browserPendingDiscard = BrowserPendingDiscardInteraction<BrowserPendingDiscardToken>()
    @ObservationIgnored private var browserPendingDiscardRefreshRevision: UInt64 = 0
    @ObservationIgnored private var browserPendingDiscardRefreshRunning = false
    @ObservationIgnored private var browserPendingDiscardCompletion:
        (request: BrowserPendingDiscardInteraction<BrowserPendingDiscardToken>.DiscardRequest,
         store: BrowserIntakeStore, durablyCompleted: Bool)?
#if DEBUG || SOLSTONE_TEST_SUPPORT
    @ObservationIgnored var browserPendingDiscardResultBarrier: @Sendable () async -> Void = {}
#endif
    @ObservationIgnored private let browserRepairValidity = BrowserRepairValidity()
    var browserRepair = BrowserRepairController() {
        didSet {
            if oldValue.attempt != browserRepair.attempt ||
               oldValue.destinationGeneration != browserRepair.destinationGeneration ||
               oldValue.lifecycleGeneration != browserRepair.lifecycleGeneration ||
               oldValue.viewGeneration != browserRepair.viewGeneration {
                browserRepairValidity.invalidate()
            }
        }
    }
    var browserStoreCatalog = BrowserStoreCatalog.preview
    var browserStoreOpener: @MainActor (URL, BrowserBrand) -> Bool = { url, brand in
        let bundleID: String
        switch brand {
        case .chrome: bundleID = "com.google.Chrome"
        case .edge: bundleID = "com.microsoft.edgemac"
        case .firefox: bundleID = "org.mozilla.firefox"
        }
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
            return true
        }
        return NSWorkspace.shared.open(url)
    }
    var browserStoreLaunch: [BrowserBrand: BrowserStoreLaunch] = [:]
    public private(set) var browserUploadGate: BrowserUploadGate?
    public private(set) var browserUploadPlanner: BrowserUploadPlanner?
    #endif
    private let homeBaseURLResolver: HomeBaseURLResolver
    private let ingestBaseURLResolver: HomeBaseURLResolver
    private let sameMachinePairStart: @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
    // Test seam for observing tunnel-connected sync nudges when UploadCoordinator short-circuits.
    private let triggerTunnelConnectedSync: @MainActor @Sendable (AppState) -> Void
    private let journalURLOpener: @MainActor @Sendable (URL) -> Bool
    private let notifier: any UserNotifying
    private let loginService: any LoginItemService
    private let loginItemRegistrationReconciler: LoginItemRegistrationReconciler
    private let lastContactStore: any LastSuccessfulJournalContactStoring
    private let journalMarkConfirmationStore: any JournalMarkConfirmationStoring
    private let recorder: DiagnosticEvidenceRecorder
    private let logAdapter: DiagnosticEvidenceLoggingAdapter
    private let isSnapshot: Bool
    private let automaticObservationPipelineEnabled: Bool
    public private(set) var config: AppConfig
    internal var privateWindowAccessibilityMonitor = PrivateWindowAccessibilityMonitor()
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
    internal var pendingPrivateWindowSettingsTarget: UUID?

    internal var privateWindowAccessibilityEnabled: Bool {
        config.excludePrivateBrowsing && config.excludePrivateBrowsingAccessibility
    }

    internal func requestPrivateWindowSettingsRecovery() {
        pendingSettingsTab = "privacy"
        pendingPrivateWindowSettingsTarget = UUID()
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    private func reconcilePrivateWindowAccessibility() {
        guard !isSnapshot else { return }
        privateWindowAccessibilityMonitor.setEnabled(privateWindowAccessibilityEnabled)
    }

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
    public internal(set) var isTerminating: Bool = false {
        didSet {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            if isTerminating != oldValue { browserRepairValidity.invalidate() }
#endif
        }
    }
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

    public var availableSelectedSources: CaptureSources {
        config.selectedSources.intersection(capture.permittedSources)
    }

    public var permissionsNeedAttention: Bool {
        initialPermissionCheckComplete && !isRecording && !isPaused &&
            !config.selectedSources.isEmpty && availableSelectedSources.isEmpty
    }

    var ownerPauseHeldIdle: Bool {
        pauseManager.isPaused && !isRecording && !capture.isPaused
    }

    public var captureSourcesStatusText: String {
        if isRecording || isPaused {
            guard !captureManager.activeSources.isEmpty else { return UICopy.SOURCES_UNAVAILABLE }
            return UICopy.sourceStatus(captureManager.activeSources, isPaused: isPaused)
        }
        if config.selectedSources.isEmpty { return UICopy.SOURCES_NONE }
        if availableSelectedSources.isEmpty { return UICopy.SOURCES_NONE_GRANTED }
        if ownerPauseHeldIdle {
            return UICopy.sourceStatus(availableSelectedSources, isPaused: true)
        }
        return UICopy.SOURCES_STARTING
    }

    public var captureSourceNotice: String? {
        let selected = config.selectedSources
        if selected.contains(.microphone), !microphoneGranted, captureManager.activeSources.contains(.screen) {
            return UICopy.SOURCES_MIC_DENIED
        }
        if selected.contains(.screen), !screenRecordingGranted, captureManager.activeSources.contains(.microphone) {
            return UICopy.SOURCES_SCREEN_DENIED
        }
        if isRecording, !isPaused, !captureManager.activeSources.isEmpty {
            if selected.contains(.microphone), !captureManager.activeSources.contains(.microphone) {
                return UICopy.SOURCES_MIC_UNAVAILABLE
            }
            if selected.contains(.screen), !captureManager.activeSources.contains(.screen) {
                return UICopy.SOURCES_SCREEN_UNAVAILABLE
            }
        }
        return nil
    }

    public var serviceNeedsAttention: Bool {
        !serviceIsDone || tunnelLifecycleOwner.connectionVerdict.failureCause != nil
    }

    /// Keep pairing recovery visible even when the saved identity cannot be read.
    internal var showsConfiguredJournal: Bool {
        tunnelLifecycleOwner.hasPersistedPairing || config.isUploadConfigured
            || tunnelLifecycleOwner.connectionVerdict.failureCause != nil
    }

    internal var canOpenJournal: Bool {
        tunnelLifecycleOwner.cachedPairingIdentity != nil || config.isUploadConfigured
    }

    public var permissionsAreDone: Bool {
        initialPermissionCheckComplete && (isRecording || isPaused || !capture.permittedSources.isEmpty)
    }

    public var serviceIsDone: Bool {
        tunnelLifecycleOwner.cachedPairingIdentity != nil
            || (resolvedServiceMode(for: config) == .external && config.isUploadConfigured
                && !tunnelLifecycleOwner.hasPersistedPairing)
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
                closeBrowserHost: { [weak self] reason, generation in
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                    self?.browserRepair.lifecycleGeneration += 1
                    self?.browserHostListener?.commitClose(reason: reason, generation: generation)
#endif
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
            recorder.enqueue(.terminationSettingsRelaunchSpawnFailed)
            logAdapter.terminationSettingsRelaunchSpawnFailed()
            Logger.setup.error("replacement launch failed to spawn: \(String(describing: error), privacy: .public)")
        }
    }

    internal func performQuitPreparation() async {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let generation = appQuitCoordinator.preparationGeneration
        await browserHostListener?.finishCommittedClose(generation: generation)
        guard appQuitCoordinator.preparationGeneration == generation else { return }
        browserIntakeOwner?.stop()
#endif
        await stopRecording(reason: .quit)
        await drainRemixQueueForTermination()
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        guard appQuitCoordinator.preparationGeneration == generation else { return }
        await browserHostListener?.finalizeCommittedClose(generation: generation)
#endif
    }

    internal func performUpdatePreparation() async {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let generation = appQuitCoordinator.preparationGeneration
        await browserHostListener?.finishCommittedClose(generation: generation)
        guard appQuitCoordinator.preparationGeneration == generation else { return }
        await browserIntakeOwner?.stopAndDrain()
        guard appQuitCoordinator.preparationGeneration == generation else { return }
#endif
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
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let browserIntakeChanged = oldConfig.isBrowserIntakeEnabled != newConfig.isBrowserIntakeEnabled
#endif
        config = newConfig
        reconcilePrivateWindowAccessibility()
        uploadCoordinator.updateConfig(newConfig)
        uploadCoordinator.updatePairedIngestIdentity(currentPairedIngestIdentity())
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if oldConfig.syncPaused && !newConfig.syncPaused, let owner = browserIntakeOwner {
            Task { await owner.scheduleDelivery() }
        }
#endif
        silenceMusicHolder.value = newConfig.silenceMusic

        if newConfig.disabledMicrophoneUIDs != oldConfig.disabledMicrophoneUIDs ||
           newConfig.enabledMicrophoneUIDs != oldConfig.enabledMicrophoneUIDs {
            capture.captureManager.updateMicrophoneSelection(
                disabled: newConfig.disabledMicrophoneUIDs, enabled: newConfig.enabledMicrophoneUIDs)
        }

        // Update mic gain immediately if it changed
        if newConfig.microphoneGain != oldConfig.microphoneGain {
            capture.captureManager.setMicrophoneGain(newConfig.microphoneGain)
        }

        // Update window exclusions immediately if they changed
        if newConfig.excludedAppNames != oldConfig.excludedAppNames ||
           newConfig.excludePrivateBrowsing != oldConfig.excludePrivateBrowsing ||
           newConfig.excludePrivateBrowsingAccessibility != oldConfig.excludePrivateBrowsingAccessibility ||
           newConfig.excludedTitlePatterns != oldConfig.excludedTitlePatterns {
            capture.captureManager.updateWindowExclusions(
                excludedAppNames: newConfig.excludedAppNames,
                excludePrivateBrowsing: newConfig.excludePrivateBrowsing,
                excludedTitlePatterns: newConfig.excludedTitlePatterns,
                excludePrivateBrowsingAccessibility: newConfig.excludePrivateBrowsingAccessibility
            )
        }

        do {
            try configSaver(newConfig)
        } catch {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            if browserIntakeChanged {
                config.isBrowserIntakeEnabled = oldConfig.isBrowserIntakeEnabled
                if let owner = browserIntakeOwner {
                    Task {
                        await owner.setIntakeEnabled(oldConfig.isBrowserIntakeEnabled)
                        await browserHostListener?.refreshSnapshot()
                    }
                }
            }
#endif
            Logger.general.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
            errorMessage = UICopy.ERROR_SAVE_CONFIG
            return
        }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if browserIntakeChanged, let owner = browserIntakeOwner {
            Task {
                await owner.setIntakeEnabled(newConfig.isBrowserIntakeEnabled)
                await browserHostListener?.refreshSnapshot()
            }
        }
#endif
    }

    @ObservationIgnored internal var configSaver: (AppConfig) throws -> Void = { try $0.save() }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    func refreshBrowserPendingDiscard() {
        browserPendingDiscardRefreshRevision &+= 1
        beginBrowserPendingDiscardRefreshIfNeeded()
    }

    private func beginBrowserPendingDiscardRefreshIfNeeded() {
        guard !browserPendingDiscardRefreshRunning else { return }
        guard let store = browserIntakeStore else {
            browserPendingDiscard.observe(.unknown)
            return
        }
        browserPendingDiscardRefreshRunning = true
        let revision = browserPendingDiscardRefreshRevision
        let window = browserPendingDiscard.viewRevision
        Task.detached(priority: .utility) { [weak self, store] in
            let inventory = store.pendingDiscardInventory()
            await MainActor.run {
                guard let self else { return }
                self.browserPendingDiscardRefreshRunning = false
                if self.browserIntakeStore === store,
                   revision == self.browserPendingDiscardRefreshRevision,
                   window == self.browserPendingDiscard.viewRevision {
                    self.browserPendingDiscard.observe(Self.browserPendingMaterial(inventory))
                    if let completion = self.browserPendingDiscardCompletion, completion.store === store {
                        self.browserPendingDiscardCompletion = nil
                        self.browserPendingDiscard.finishDiscard(completion.request,
                            durablyCompleted: completion.durablyCompleted,
                            inventory: Self.browserPendingMaterial(inventory))
                    }
                }
                if revision != self.browserPendingDiscardRefreshRevision {
                    self.beginBrowserPendingDiscardRefreshIfNeeded()
                }
            }
        }
    }

    private static func browserPendingMaterial(_ inventory: BrowserPendingDiscardInventory) -> BrowserPendingMaterial<BrowserPendingDiscardToken> {
        switch inventory {
        case .unavailable: return .unknown
        case .empty: return .empty
        case .present(let scope): return .present(scope)
        }
    }

    func confirmBrowserPendingDiscard() {
        guard let store = browserIntakeStore, let request = browserPendingDiscard.beginDiscard() else { return }
        browserPendingDiscardRefreshRevision &+= 1
#if DEBUG || SOLSTONE_TEST_SUPPORT
        let resultBarrier = browserPendingDiscardResultBarrier
#endif
        Task.detached(priority: .utility) { [weak self, store] in
            let observation = store.discardPendingPages(request.scope)
#if DEBUG || SOLSTONE_TEST_SUPPORT
            await resultBarrier()
#endif
            await MainActor.run {
                guard let self, self.browserIntakeStore === store else { return }
                self.browserPendingDiscardCompletion = (request, store, observation.durablyCompleted)
                self.refreshBrowserPendingDiscard()
            }
        }
    }

    public func setBrowserIntakeEnabled(_ enabled: Bool) {
        var newConfig = config
        newConfig.isBrowserIntakeEnabled = enabled
        updateConfig(newConfig)
    }

    func beginBrowserRepair() {
        guard let token = browserRepair.click() else { return }
        let listener = browserHostListener
        let validity = browserRepairValidity
        let revision = validity.value
        let store = browserIntakeOwner?.store
        let destination = store?.getDestinationGeneration()
        let isCurrent: @Sendable () -> Bool = {
            validity.matches(revision) && store?.getDestinationGeneration() == destination
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func isStale() -> Bool {
                if !isCurrent() || token.attempt != self.browserRepair.attempt ||
                   token.destinationGeneration != self.browserRepair.destinationGeneration ||
                   token.lifecycleGeneration != self.browserRepair.lifecycleGeneration ||
                   token.viewGeneration != self.browserRepair.viewGeneration {
                    self.browserRepair.inFlight = false
                    return true
                }
                return false
            }

            var holdsFence = await listener?.holdsEndpointFence ?? false
            if isStale() { return }

            var endpoint: BrowserHostEndpointDisposition?
            let root = NativeHostPaths.hostDirectory()
            if holdsFence {
                endpoint = nil
            } else if let listener {
                endpoint = await listener.repairStaleEndpoint(rootURL: root, isCurrent: isCurrent)
                if isStale() { return }
            } else {
                endpoint = (try? BrowserHostEndpointFence(rootURL: root).repairStaleEndpoint()) ?? .refused
            }

            if endpoint == .refused {
                self.browserRepair.inFlight = false
                self.browserRepair.lastFailureReason = "endpoint_collision"
                Logger.general.error("Browser host endpoint repair refused")
                return
            }

            let bundleURL = Bundle.main.bundleURL
            let prodReport: BrowserHostRegistrationReport
            let devReport: BrowserHostRegistrationReport?
            if let contractRoot = BrowserContractProjection.vendorRootURL(bundleURL: bundleURL) {
                let registration = BrowserHostRegistration(
                    contractRoot: contractRoot,
                    helperURL: bundleURL.appendingPathComponent("Contents/MacOS/solstone-browser-host")
                )
                _ = registration.repair(mode: .production)
                prodReport = registration.check(mode: .production)
                if NativeHostMode.enabledModes.contains(.development) {
                    _ = registration.repair(mode: .development)
                    devReport = registration.check(mode: .development)
                } else {
                    devReport = nil
                }
            } else {
                prodReport = BrowserHostRegistrationReport(outcomes: [:], changedAny: false)
                devReport = nil
            }

            if isStale() { return }

            if !holdsFence, let listener, (endpoint == .absent || endpoint == .removed) {
                await listener.startIfNeeded(rootURL: root, isCurrent: isCurrent)
                if isStale() { return }
                holdsFence = await listener.holdsEndpointFence
                if isStale() { return }
            }

            if isStale() { return }

            await listener?.noteRegistration(prodReport, isCurrent: isCurrent)
            if isStale() { return }

            self.browserRepair.complete(
                token: token,
                report: prodReport,
                devReport: devReport,
                listenerHoldsFence: holdsFence,
                endpoint: endpoint
            )
        }
    }

    func openBrowserStore(_ brand: BrowserBrand) {
        guard let url = browserStoreCatalog.url(for: brand) else {
            browserStoreLaunch[brand] = .disabled
            return
        }
        browserStoreLaunch[brand] = browserStoreOpener(url, brand) ? .opened : .failed
    }
#endif

    var browserRowPermitted: Bool {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserIntakeIsReady(browserHostSnapshot.value, now: Date()) && !pauseManager.isPaused
#else
        false
#endif
    }

    var browserPauseEnabled: Bool {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        config.isBrowserIntakeEnabled && !browserHostSnapshot.value.shutdown && !browserHostSnapshot.value.quiescence
#else
        false
#endif
    }

    var browserRowPaused: Bool {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        pauseManager.isPaused && config.isBrowserIntakeEnabled && !isRecording
#else
        false
#endif
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
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        browserRepair.destinationGeneration += 1
#endif
        await tunnelLifecycleOwner.reevaluatePairing()
        uploadCoordinator.refreshLastJournalDelivery()
    }

    internal func retryRevokedPairingRetirement() async {
        await tunnelLifecycleOwner.retryRevokedPairingRetirement()
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

        // The adoption asks no mark question, so it answers it: this is the journal the
        // owner was already sending to from this Mac.
        if case .pairingStarted = result {
            recordJournalMarkConfirmed()
        }

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
        if config.reseedBluetoothMicrophones(connectedBluetoothUIDs: Set(available.filter { $0.transportType == .bluetooth }.map(\.uid))) {
            configChanged = true
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
                return Self.homeBase(
                    tunnelManaged: owner.isTunnelManaged,
                    admissionReady: state.currentDurablePairingAdmissionIsReady,
                    routeRevoked: owner.ordinaryRouteRevoked,
                    localPort: owner.localPort,
                    configuredServerURL: state.config.serverURL
                )
            }
        }
    }

    internal static func homeBase(
        tunnelManaged: Bool,
        admissionReady: Bool,
        routeRevoked: Bool,
        localPort: Int?,
        configuredServerURL: String?
    ) -> ResolvedHomeBase {
        if tunnelManaged {
            guard admissionReady, !routeRevoked, let localPort else { return .held }
            return .url("http://127.0.0.1:\(localPort)")
        }
        guard let configuredServerURL else { return .held }
        return .url(configuredServerURL)
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
                    pairingIdentity: owner.cachedPairingIdentity,
                    journalMarkConfirmed: state.isJournalMarkConfirmed,
                    admissionReady: state.currentDurablePairingAdmissionIsReady
                )
            }
        }
    }

    internal static func ingestBaseURL(
        lifecycleState: TunnelLifecycleState,
        localPort: Int?,
        pairingIdentity: TunnelPairingIdentity?,
        journalMarkConfirmed: Bool,
        admissionReady: Bool = true
    ) -> ResolvedHomeBase {
        guard case .connected = lifecycleState,
              let localPort,
              pairingIdentity != nil,
              admissionReady,
              journalMarkConfirmed else {
            return .held
        }
        return .url("http://127.0.0.1:\(localPort)")
    }

    internal var isPairedIngestReady: Bool {
        let owner = tunnelLifecycleOwner
        guard case .connected = owner.state,
              owner.localPort != nil,
              owner.cachedPairingIdentity != nil,
              !owner.ordinaryRouteRevoked,
              currentDurablePairingAdmissionIsReady else {
            return false
        }
        return isJournalMarkConfirmed
    }

    /// Whether the owner has confirmed the paired journal's mark, or chose to continue
    /// when the check could not finish. Nothing captured here is sent until they have.
    internal var isJournalMarkConfirmed: Bool {
        access(keyPath: \.isJournalMarkConfirmed)
        guard let journal = tunnelLifecycleOwner.cachedJournalMarkIdentity else {
            return false
        }
        return journalMarkConfirmationStore.isConfirmed(journal)
    }

    /// A pairing whose mark question is still open: connected, so the mark can be fetched,
    /// and not yet answered. The automatic same-machine adoption never asks.
    internal var needsJournalMarkConfirmation: Bool {
        Self.needsJournalMarkConfirmation(
            tunnelManaged: tunnelLifecycleOwner.isTunnelManaged,
            lifecycleState: tunnelLifecycleOwner.state,
            adoptingAutomatically: isAdoptingSameMachineHomeAutomatically,
            journalIdentity: tunnelLifecycleOwner.cachedJournalMarkIdentity,
            journalMarkConfirmed: isJournalMarkConfirmed,
            admissionReady: currentDurablePairingAdmissionIsReady && !tunnelLifecycleOwner.ordinaryRouteRevoked
        )
    }

    internal static func needsJournalMarkConfirmation(
        tunnelManaged: Bool,
        lifecycleState: TunnelLifecycleState,
        adoptingAutomatically: Bool,
        journalIdentity: String?,
        journalMarkConfirmed: Bool,
        admissionReady: Bool = true
    ) -> Bool {
        guard tunnelManaged,
              case .connected = lifecycleState,
              !adoptingAutomatically,
              admissionReady else {
            return false
        }
        return journalIdentity != nil && !journalMarkConfirmed
    }

    /// Records the owner's answer for the paired journal and lets held work go.
    @discardableResult
    internal func recordJournalMarkConfirmed(
        mark: JournalMark? = nil,
        expectedRevision: PairingCredentialRevision? = nil
    ) -> Bool {
        guard let revision = currentDurablePairingRevision,
              expectedRevision == nil || (!tunnelLifecycleOwner.ordinaryRouteRevoked
                && Self.markAnswerRevisionMatches(
                    expected: expectedRevision,
                    current: revision,
                    activeAttempt: pendingMarkCredentialRevision
                )),
              let pairing = currentDurablePairing,
              PairingCredentialRevision(from: pairing) == revision,
              let journal = tunnelLifecycleOwner.cachedJournalMarkIdentity,
              journalMarkConfirmationIdentity(for: pairing) == journal else { return false }
        withMutation(keyPath: \.isJournalMarkConfirmed) {
            if let mark { confirmedMark = mark }
            journalMarkConfirmationStore.confirm(journal)
            uploadCoordinator.updatePairedIngestIdentity(currentPairedIngestIdentity())
            pairingCoordinator.refreshPendingActions(markConfirmed: true)
            guard isPairedIngestReady else { return }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            if let owner = browserIntakeOwner {
                Task { await owner.scheduleDelivery() }
            }
#endif
            guard automaticObservationPipelineEnabled else { return }
            triggerTunnelConnectedSync(self)
        }
        pendingMarkCredentialRevision = nil
        return true
    }

    /// A fetched answer must still name both the current durable credential and
    /// the active mark attempt before it can change confirmation state.
    internal static func markAnswerRevisionMatches(
        expected: PairingCredentialRevision?,
        current: PairingCredentialRevision,
        activeAttempt: PairingCredentialRevision?
    ) -> Bool {
        guard let expected else { return true }
        return expected == current && activeAttempt == expected
    }

    @ObservationIgnored private var pendingMarkCredentialRevision: PairingCredentialRevision?

    private var currentDurablePairingRevision: PairingCredentialRevision? {
        guard let pairing = currentDurablePairing else { return nil }
        if let credentialStore {
            let revision = PairingCredentialRevision(from: pairing)
            guard
                  credentialStore.markAnswerIsCurrent(revision),
                  let identity = tunnelLifecycleOwner.cachedPairingIdentity,
                  identity.instanceID == pairing.instanceID,
                  identity.fingerprint == pairing.fingerprint else { return nil }
            return revision
        }
        guard tunnelLifecycleOwner.carriedPairingAdmission == .ready else { return nil }
        return PairingCredentialRevision(from: pairing)
    }

    private var currentDurablePairing: StoredPairing? {
        if let credentialStore { return try? credentialStore.load() }
        return tunnelLifecycleOwner.currentStoredPairing()
    }

    internal func beginJournalMarkConfirmationAttempt() -> PairingCredentialRevision? {
        guard case .connected = tunnelLifecycleOwner.state,
              tunnelLifecycleOwner.localPort != nil,
              !tunnelLifecycleOwner.ordinaryRouteRevoked,
              let revision = currentDurablePairingRevision else { return nil }
        pendingMarkCredentialRevision = revision
        return revision
    }

    internal var currentJournalMarkAttemptRevision: PairingCredentialRevision? {
        pendingMarkCredentialRevision
    }

    internal func isCurrentJournalMarkAttempt(_ revision: PairingCredentialRevision) -> Bool {
        pendingMarkCredentialRevision == revision && currentDurablePairingRevision == revision &&
            !tunnelLifecycleOwner.ordinaryRouteRevoked
    }

    private func carriedPairingDidCommit(
        oldInstanceID: String,
        oldFingerprint: String,
        newPairing: StoredPairing
    ) {
        guard oldInstanceID == newPairing.instanceID else { return }
        let journal = journalMarkConfirmationIdentity(for: newPairing)
        if journalMarkConfirmationStore.confirmedJournal == journal {
            recordJournalMarkConfirmed()
        } else {
            uploadCoordinator.updatePairedIngestIdentity(nil)
        }
        pairingCoordinator.refreshPendingActions(markConfirmed: isJournalMarkConfirmed)
        let oldIdentity = TunnelPairingIdentity(instanceID: oldInstanceID, fingerprint: oldFingerprint)
        let newIdentity = TunnelPairingIdentity(instanceID: newPairing.instanceID, fingerprint: newPairing.fingerprint)
        uploadCoordinator.rebindLastJournalDelivery(from: oldIdentity, to: newIdentity)
    }

    internal func clearJournalMarkConfirmation() {
        withMutation(keyPath: \.isJournalMarkConfirmed) {
            journalMarkConfirmationStore.clear()
            uploadCoordinator?.updatePairedIngestIdentity(currentPairedIngestIdentity())
            pairingCoordinator.refreshPendingActions(markConfirmed: false)
        }
    }

    /// The sync identity is the paired journal whose mark the owner answered, not
    /// whether its carrier is up right now. A carrier that drops and returns must
    /// not reset upload hold-offs or discard an answer already received; while it
    /// is down, the home-base resolver holds sends.
    private func currentPairedIngestIdentity() -> TunnelPairingIdentity? {
        guard isJournalMarkConfirmed, currentDurablePairingAdmissionIsReady else { return nil }
        return tunnelLifecycleOwner.cachedPairingIdentity
    }

    internal var currentDurablePairingAdmissionIsReady: Bool {
        currentDurablePairingRevision != nil
    }

    internal func resolveHomeBase() async -> ResolvedHomeBase {
        await homeBaseURLResolver.resolve()
    }

    /// The journal window's base. The owner can type into a journal from there, so it waits
    /// for the mark answer like everything else that sends; the mark check itself uses
    /// `resolveHomeBase` and is never held by this.
    internal func resolveJournalWindowBase() async -> ResolvedHomeBase {
        Self.journalWindowBase(
            homeBase: await resolveHomeBase(),
            tunnelManaged: tunnelLifecycleOwner.isTunnelManaged,
            pairingHeld: tunnelLifecycleOwner.cachedJournalMarkIdentity != nil,
            journalMarkConfirmed: isJournalMarkConfirmed
        )
    }

    internal static func journalWindowBase(
        homeBase: ResolvedHomeBase,
        tunnelManaged: Bool,
        pairingHeld: Bool,
        journalMarkConfirmed: Bool
    ) -> ResolvedHomeBase {
        guard tunnelManaged, pairingHeld, !journalMarkConfirmed else {
            return homeBase
        }
        return .held
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
        journalURLOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
        recorder: DiagnosticEvidenceRecorder = .dormant,
        screenPermissionProvider: ScreenRecordingPermissionProvider = .live,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live
    ) {
        // Load configuration
        let config = AppConfig.loadOrCreateDefault()
        let pauseManager = PauseManager(defaults: .standard)
        let storageManager = StorageManager()
        let audioDeviceMonitor = AppState.makeAudioDeviceMonitor()
        let captureTarget = AppStateBridgeTarget()
        let homeBaseURLTarget = AppStateBridgeTarget()
        let fingerprintTarget = AppStateBridgeTarget()
        let recoveryCoordinator = IncompleteSegmentRecoveryCoordinator.shared
        let lastContactStore = UserDefaultsLastSuccessfulJournalContactStore()
        let journalMarkConfirmationStore = UserDefaultsJournalMarkConfirmationStore()
        self.journalMarkConfirmationStore = journalMarkConfirmationStore
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
        self.journalURLOpener = journalURLOpener
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
        let splCredentialStore = PairingCredentialStore(store: splKeychainStore)
        let tunnelLifecycleOwner = TunnelLifecycleOwner(
            credentialStore: splCredentialStore,
            clientInfo: splClientInfo,
            onCarriedPairingCommitted: { [fingerprintTarget] oldInstanceID, oldFingerprint, pairing in
                fingerprintTarget.state?.carriedPairingDidCommit(
                    oldInstanceID: oldInstanceID,
                    oldFingerprint: oldFingerprint,
                    newPairing: pairing
                )
            },
            // Write the refusal down where the owner can read it back. The
            // observer runs on the tunnel's own teardown path, so it hands off
            // to the main actor and returns rather than doing work there.
            onPeerStreamReset: { [recorder] reason in
                Task { @MainActor in
                    recorder.enqueue(diagnosticEvidenceCode(forPeerStreamReset: reason))
                }
            },
            recorder: recorder
        )
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.credentialStore = splCredentialStore
        self.pairingCoordinator = PairingCoordinator(
            clientInfo: splClientInfo,
            credentialStore: splCredentialStore,
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
            },
            clearJournalMarkConfirmation: { [fingerprintTarget, journalMarkConfirmationStore] in
                if let state = fingerprintTarget.state {
                    state.clearJournalMarkConfirmation()
                } else {
                    journalMarkConfirmationStore.clear()
                }
            },
            retireOwnCredential: { [owner = tunnelLifecycleOwner] pairing, operationID in
                await owner.retireInvalidatedPairing(pairing, operationID: operationID)
            },
            endSelfRetirement: { [owner = tunnelLifecycleOwner] in
                owner.endSelfRetirement()
            },
            fenceOrdinaryTraffic: { [owner = tunnelLifecycleOwner] pairing in
                await owner.fenceOrdinaryTraffic(for: pairing) {
                    if let state = fingerprintTarget.state {
                        await state.uploadCoordinator?.revokeOrdinaryTraffic()
                    }
                }
            },
            localPort: { [owner = tunnelLifecycleOwner] in
                owner.localPort
            },
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
        let silenceMusicHolder = DebugSettingHolder(value: config.silenceMusic)
        let captureManager = CaptureManager(
            storageManager: storageManager,
            silenceMusic: { silenceMusicHolder.value },
            excludedAppNames: config.excludedAppNames,
            excludePrivateBrowsing: config.excludePrivateBrowsing,
            excludedTitlePatterns: config.excludedTitlePatterns,
            excludePrivateBrowsingAccessibility: config.excludePrivateBrowsingAccessibility,
            microphoneGain: config.microphoneGain,
            verbose: false,
            recoveryCoordinator: recoveryCoordinator
        )
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
                    sources: currentConfig.selectedSources,
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
            ordinaryAdmission: { [splCredentialStore] in
                splCredentialStore.admission(for: splCredentialStore.currentPairing()) == .ready
            },
            pairingCredentialStore: splCredentialStore,
            recorder: recorder,
            logAdapter: logAdapter
        )
        appQuitCoordinator = makeAppQuitCoordinator(
            setCommitted: { [weak self] committed in
                self?.isTerminating = committed
            },
            terminate: {
                terminateFromMainRunLoop()
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
                        case .audioLoss:
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
        self.config.reseedCaptureSourcesOnIfNeeded()

        // Sync microphone priority list with available devices, now and as they connect
        capture.onMicrophonesChanged = { [weak self] in self?.syncMicrophonePriorityList() }
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
        reconcilePrivateWindowAccessibility()
    }

    deinit {
        MainActor.assumeIsolated {
            privateWindowAccessibilityMonitor.stop()
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
        journalURLOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
        lastContactStore: (any LastSuccessfulJournalContactStoring)? = nil,
        lastDeliveryStore: (any LastJournalDeliveryStoring)? = nil,
        journalMarkConfirmationStore: (any JournalMarkConfirmationStoring)? = nil,
        pairingLoad: PairingCoordinator.LoadPairing? = nil,
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
            journalURLOpener: journalURLOpener,
            lastContactStore: lastContactStore,
            lastDeliveryStore: lastDeliveryStore,
            journalMarkConfirmationStore: journalMarkConfirmationStore,
            pairingLoad: pairingLoad,
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
        pairingStoring: (any PairingStoring)? = nil,
        pairingOperation: PairingCoordinator.PairOperation? = nil,
        pairingLoad: PairingCoordinator.LoadPairing? = nil,
        pairingSave: PairingCoordinator.SavePairing? = nil
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
            pairingStoring: pairingStoring,
            pairingOperation: pairingOperation,
            pairingLoad: pairingLoad,
            pairingSave: pairingSave
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
        pairingStoring: (any PairingStoring)? = nil,
        triggerTunnelConnectedSync: @escaping @MainActor @Sendable (AppState) -> Void = {
            $0.uploadCoordinator.triggerSync()
        },
        journalURLOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) },
        lastContactStore providedLastContactStore: (any LastSuccessfulJournalContactStoring)? = nil,
        lastDeliveryStore providedLastDeliveryStore: (any LastJournalDeliveryStoring)? = nil,
        journalMarkConfirmationStore providedJournalMarkConfirmationStore: (any JournalMarkConfirmationStoring)? = nil,
        pairingOperation: PairingCoordinator.PairOperation? = nil,
        pairingLoad: PairingCoordinator.LoadPairing? = nil,
        pairingSave: PairingCoordinator.SavePairing? = nil,
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
        self.journalURLOpener = journalURLOpener
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
        let journalMarkConfirmationStore = providedJournalMarkConfirmationStore
            ?? InMemoryJournalMarkConfirmationStore(settled: false)
        self.journalMarkConfirmationStore = journalMarkConfirmationStore
        self.recorder = recorder
        self.logAdapter = logAdapter
        let lastDeliveryStore = providedLastDeliveryStore ?? InMemoryLastJournalDeliveryStore()
        self.notificationAuthorizationStatus = notificationStatus
        self.recoveryCoordinator = .shared
        let silenceMusicHolder = DebugSettingHolder(value: true)
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
                    sources: currentConfig.selectedSources,
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
        // Snapshots never open a keychain. The owner and the coordinator share one
        // memory-backed store seeded from the pairing this composition holds.
        let snapshotPairingStore: any PairingStoring = pairingStoring
            ?? InMemoryPairingStore(pairing: (try? tunnelPairingLoad()) ?? nil)
        let tunnelLifecycleOwner = TunnelLifecycleOwner.dormantForSnapshot(
            keychainStore: snapshotPairingStore,
            loadPairing: tunnelPairingLoad
        )
        self.tunnelLifecycleOwner = tunnelLifecycleOwner
        self.credentialStore = nil
        self.pairingCoordinator = PairingCoordinator(
            pair: pairingOperation,
            keychainStore: snapshotPairingStore,
            loadPairing: pairingLoad ?? { nil },
            savePairing: pairingSave ?? { _ in },
            reactivate: { [fingerprintTarget] in
                await fingerprintTarget.state?.reevaluateTunnelPairing()
            },
            ownerState: { [owner = tunnelLifecycleOwner] in
                owner.state
            },
            clearLastSuccessfulJournalContact: { [lastContactStore] in
                lastContactStore.clear()
            },
            clearJournalMarkConfirmation: { [fingerprintTarget, journalMarkConfirmationStore] in
                if let state = fingerprintTarget.state {
                    state.clearJournalMarkConfirmation()
                } else {
                    journalMarkConfirmationStore.clear()
                }
            },
            retireOwnCredential: { _, _ in true },
            endSelfRetirement: { [owner = tunnelLifecycleOwner] in
                owner.endSelfRetirement()
            },
            fenceOrdinaryTraffic: { _ in }
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
        pairingCoordinator.refreshPendingActions(markConfirmed: isJournalMarkConfirmed)
        tunnelLifecycleOwner.start()
        Task { await pairingCoordinator.recoverDurableInvalidation() }
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
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        if let owner = browserIntakeOwner {
            Task { await owner.scheduleDelivery() }
        }
#endif
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

    public func startRecording(reason: StartReason = .user, preservingPausePolicy: Bool = false) async {
        await capture.startRecording(reason: reason, preservingPausePolicy: preservingPausePolicy)
    }

    public func stopRecording(reason: StopReason = .user, preservingPausePolicy: Bool = false) async {
        await capture.stopRecording(reason: reason, preservingPausePolicy: preservingPausePolicy)
    }

    public func toggleRecording() async {
        await capture.toggleRecording()
    }

    /// Brings a running session in line with the owner's current source switches.
    ///
    /// A session freezes the sources it actually started with, so a switch flipped mid-session
    /// needs the session rebuilt to take effect. That rebuild is ours to do — the owner flipped
    /// a switch, they did not ask to stop and restart their capture.
    public func applySelectedSourcesToRunningSession() async {
        if pauseManager.isPaused && !isRecording {
            return
        }

        if !config.selectedSources.isEmpty {
            capture.clearExplicitStop()
        }

        let wasPaused = pauseManager.isPaused
        guard isRecording || wasPaused else {
            // Not running. Start now if a source is already usable; if the owner turned one on
            // but macOS hasn't granted it yet, the latch is clear above, so the permission poll
            // picks it up the moment the grant lands.
            if !availableSelectedSources.isEmpty {
                await startRecording(reason: .user)
            }
            return
        }

        let desired = availableSelectedSources
        guard desired != captureManager.activeSources else { return }

        await stopRecording(reason: .user, preservingPausePolicy: wasPaused)

        guard !desired.isEmpty else { return }

        await startRecording(reason: .user, preservingPausePolicy: wasPaused)
        if wasPaused {
            pauseManager.reapply()
        }
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
        if isSameMacJournalDoor(
            sameMachineStoredPairingState: tunnelLifecycleOwner.sameMachineStoredPairingState,
            serverURL: config.serverURL
        ) {
            openSameMacJournalInBrowser(destination)
            return
        }
        nextJournalOpenIntentID += 1
        journalOpenIntent = JournalOpenIntent(
            id: nextJournalOpenIntentID,
            destination: destination
        )
        NotificationCenter.default.post(name: .openJournalWindow, object: nil)
    }

    private func openSameMacJournalInBrowser(_ destination: JournalWindowDestination) {
        let conveyBase = "http://127.0.0.1:5015/"
        let url: URL
        if destination == .root {
            guard let conveyURL = URL(string: conveyBase) else { return }
            url = conveyURL
        } else if let command = JournalWindowComposition.composeLoadCommand(
            base: conveyBase,
            destination: destination,
            generation: 0
        ) {
            url = command.url
        } else {
            Logger.setup.error("same-Mac journal URL could not be composed")
            return
        }
        guard journalURLOpener(url) else {
            Logger.setup.error("open journal in browser failed: \(url.absoluteString, privacy: .public)")
            return
        }
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

        // Only react to journal connection or browser-intake changes.
        let journalConnectionChanged = fresh.serverURL != config.serverURL ||
            fresh.serverKey != config.serverKey ||
            fresh.observerName != config.observerName ||
            fresh.serviceMode != config.serviceMode ||
            fresh.journalPath != config.journalPath ||
            fresh.syncPaused != config.syncPaused
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let browserIntakeChanged = fresh.isBrowserIntakeEnabled != config.isBrowserIntakeEnabled
#else
        let browserIntakeChanged = false
#endif
        guard journalConnectionChanged || browserIntakeChanged else {
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

        if journalConnectionChanged, isPairedIngestReady {
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

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    public func configureBrowserIntake(
        owner: BrowserIntakeOwner,
        credentialStore: PairingCredentialStore
    ) async {
        let store = owner.store
        let authority = owner.authority
        let gate = owner.gate
        let planner = owner.planner
        self.browserIntakeOwner = owner
        self.browserIntakeCredentialStore = credentialStore
        if self.browserIntakeStore !== store {
            self.browserPendingDiscard = .init()
            self.browserPendingDiscardCompletion = nil
        }
        self.browserIntakeStore = store
        self.browserIntakeAuthority = authority
        self.browserUploadGate = gate
        self.browserUploadPlanner = planner
        let journalVersion = tunnelLifecycleOwner.journalVersion
        let routeState = tunnelLifecycleOwner.browserIntakeRouteState
        journalVersion.onAboutChanged = { [weak owner, weak journalVersion, routeState] factsAccepted in
            guard let journalVersion else { return }
            let routeEpoch = routeState.aboutEpoch()
            let snapshot = AboutPresentation.nativeSnapshot(journal: journalVersion)
            Task {
                await owner?.updateAboutSnapshot(snapshot, factsAccepted: factsAccepted, routeEpoch: routeEpoch)
            }
        }
        refreshBrowserPendingDiscard()

        owner.bindCredentials(credentialStore)
        await owner.setCarriedPairingAdmissionOpen { [credentialStore] in
            credentialStore.admission(for: credentialStore.currentPairing()) == .ready
        }
        await owner.setCarriedPairingAdmissionCommit { [credentialStore] route, operation in
            try credentialStore.withOrdinaryBrowserAdmission(
                generation: route.pairingGeneration,
                identityDigest: route.identityDigest,
                operation: operation
            ) ?? false
        }
        let routeEpoch = routeState.aboutEpoch()
        let snapshot = AboutPresentation.nativeSnapshot(journal: journalVersion)
        Task {
            await owner.updateAboutSnapshot(
                snapshot,
                factsAccepted: false,
                routeEpoch: routeEpoch
            )
        }
        authority.setPaused(pauseManager.isPaused)
        Task { await owner.setIntakeEnabled(config.isBrowserIntakeEnabled) }

        self.pauseManager.onPauseIntake = { [weak self, weak authority, weak store] in
            authority?.setPaused(true)
            store?.setPaused(true)
            if let listener = self?.browserHostListener {
                Task { await listener.refreshSnapshot() }
            }
        }
        self.pauseManager.onResumeIntake = { [weak self, weak authority, weak store] in
            authority?.setPaused(false)
            store?.setPaused(false)
            if let owner = self?.browserIntakeOwner {
                Task { await owner.scheduleDelivery() }
            }
            if let listener = self?.browserHostListener {
                Task { await listener.refreshSnapshot() }
            }
        }
    }

    public func startBrowserIntake(updateController: UpdateController? = nil) {
        guard !browserIntakeStartupScheduled, browserIntakeStore == nil,
              let credentialStore, !isTerminating else { return }
        browserIntakeStartupScheduled = true
        let bundleURL = Bundle.main.bundleURL
        let bridge = AppStateBridgeTarget()
        bridge.state = self
        let routeState = tunnelLifecycleOwner.browserIntakeRouteState
        let routeResolver = Self.makeIngestBaseURLResolver(target: bridge)
        let generation = appQuitCoordinator.preparationGeneration
        let updateGate = BrowserHostUpdateGate {
            updateController?.checkForUpdates()
        }
        let snapshot = browserHostSnapshot
        let state = self
        Task.detached(priority: .utility) { [weak state, credentialStore, bridge] in
            guard let vendorURL = BrowserContractProjection.vendorRootURL(bundleURL: bundleURL),
                  let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                Logger.storage.error("Browser intake left off: contract or spool path unavailable")
                return
            }
            let projection: BrowserContractProjection
            do {
                projection = try BrowserContractProjection(rootURL: vendorURL)
            } catch {
                Logger.storage.error("Browser intake left off: contract projection failed")
                return
            }
            let pairing: StoredPairing?
            do {
                pairing = try credentialStore.currentPairing() ?? credentialStore.load()
            } catch {
                pairing = nil
                Logger.storage.error("Browser intake credential load failed")
            }
            let owner: BrowserIntakeOwner
            do {
                owner = try BrowserIntakeOwner.start(
                    spoolRoot: appSupport.appendingPathComponent("Solstone/browser-intake"),
                    projection: projection,
                    credentialSnapshot: BrowserCredentialSnapshot(identityToken: pairing.map { PairingCredentialStore.identityToken(for: $0) }),
                    routeResolver: routeResolver,
                    syncPaused: { [bridge] in await MainActor.run { bridge.state?.config.syncPaused ?? false } },
                    routeState: routeState
                )
            } catch {
                Logger.storage.error("Browser intake left off: spool unavailable")
                return
            }

            guard let state, await MainActor.run(body: { !state.isTerminating && state.appQuitCoordinator.preparationGeneration == generation }) else {
                await owner.stopAndDrain()
                return
            }
            await MainActor.run { state.browserIntakeRouteState = routeState }
            await state.configureBrowserIntake(owner: owner, credentialStore: credentialStore)
            let currentEnabled = await MainActor.run { state.config.isBrowserIntakeEnabled }
            await owner.setIntakeEnabled(currentEnabled)
            await owner.start()

            let helperURL = bundleURL.appendingPathComponent("Contents/MacOS/solstone-browser-host")
            let registration = BrowserHostRegistration(contractRoot: projection.rootURL, helperURL: helperURL)
            if NativeHostMode.enabledModes.contains(.development) {
                _ = registration.repair(mode: .development)
            }
            let registrationReport = registration.repair(mode: .production)
            let listener = BrowserHostListener(
                limits: BrowserHostLimits(projection: projection),
                snapshot: snapshot,
                updateGate: updateGate
            )
            await MainActor.run {
                guard !state.isTerminating, state.appQuitCoordinator.preparationGeneration == generation else { return }
                state.browserHostListener = listener
            }
            guard await MainActor.run(body: { !state.isTerminating && state.appQuitCoordinator.preparationGeneration == generation }) else {
                await owner.stopAndDrain()
                return
            }
            await listener.start(
                rootURL: NativeHostPaths.hostDirectory(),
                owner: owner,
                projection: projection,
                registration: registrationReport,
                generation: generation,
                modes: NativeHostMode.enabledModes
            )
        }
    }

    public func stopBrowserIntake() {
        browserIntakeOwner?.stop()
    }
#endif

    internal func recoverAfterFailedUpdaterInstall() async {
        appQuitCoordinator.resetAfterFailedUpdaterInstall()
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let recoveryGeneration = appQuitCoordinator.preparationGeneration
        browserRepair.lifecycleGeneration += 1
        let revision = browserRepairValidity.value
        let validity = browserRepairValidity
        let current: @Sendable () -> Bool = { validity.matches(revision) }
        guard !isTerminating, let owner = browserIntakeOwner, let credentials = browserIntakeCredentialStore else { return }
        do {
            let pairing = try credentials.load()
            await owner.resumeAfterFailedUpdate(
                credentialSnapshot: BrowserCredentialSnapshot(identityToken: pairing.map { PairingCredentialStore.identityToken(for: $0) }),
                paused: pauseManager.isPaused
            )
            guard !isTerminating, appQuitCoordinator.preparationGeneration == recoveryGeneration, current() else { return }
            await browserHostListener?.resumeAfterFailedUpdaterInstall(generation: recoveryGeneration, isCurrent: current)
        } catch {
            Logger.storage.error("Browser intake update recovery failed: \(error.localizedDescription, privacy: .public)")
        }
#endif
    }

}
