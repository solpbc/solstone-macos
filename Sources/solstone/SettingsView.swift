// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import JournalMarkKit
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os
import SolstoneCore
import UpdateKit

/// Display entry for microphone priority list
struct MicrophoneDisplayEntry: Identifiable {
    let id: String
    let uid: String
    let name: String
    let isConnected: Bool
    let isDisabled: Bool
    let mode: MicrophoneEntry.Mode
    /// Bluetooth microphones can follow other apps instead of being always on or off.
    let offersFollowing: Bool
    let interfaceState: MicrophoneInterfaceState
    let layout: MicrophoneMonitor.MicrophoneLayout?
    let choice: MicrophoneChoice?

    init(
        from entry: MicrophoneEntry,
        isConnected: Bool,
        isBluetooth: Bool = false,
        interfaceState: MicrophoneInterfaceState = .admitted,
        layout: MicrophoneMonitor.MicrophoneLayout? = nil
    ) {
        self.id = entry.uid
        self.uid = entry.uid
        self.name = entry.name
        self.isConnected = isConnected
        self.isDisabled = entry.isDisabled
        self.mode = entry.mode
        self.offersFollowing = isBluetooth || entry.followsOtherApps
            || (!isConnected && AppConfig.knownBluetoothMicrophoneUIDs.contains(entry.uid))
        self.interfaceState = interfaceState
        self.layout = layout
        self.choice = entry.choice
    }

    /// Always holds a Bluetooth headset in its call profile, which degrades its playback everywhere.
    var showsCallModeNote: Bool { offersFollowing && mode == .always }
}

func isConnectButtonDisabled(observerURL: String, observerKey: String, connectionTestState: ConnectionTestState) -> Bool {
    observerURL.isEmpty || observerKey.isEmpty || connectionTestState != .success
}

func shouldApplyConnectionTestCompletion(inFlightTestID: UUID?, testGeneration: UUID) -> Bool {
    inFlightTestID == testGeneration
}

func isSameMacJournalDoor(
    sameMachineStoredPairingState: SameMachineStoredPairingState,
    serverURL: String?
) -> Bool {
    sameMachineStoredPairingState == .pairedHome
        || BundledJournalEndpoint.isBundledServiceURL(serverURL)
}

/// The journal line of the agent instructions: the paired address first, the
/// legacy server URL otherwise.
func agentInstructionsJournalValue(pairedAddresses: [String], serverURL: String?) -> String {
    if let first = pairedAddresses.first {
        return first
    }
    if let serverURL, !serverURL.isEmpty {
        return serverURL
    }
    return "not configured"
}

func journalLocationLabel(isSameMacJournalDoor: Bool) -> String {
    isSameMacJournalDoor
        ? UICopy.JOURNAL_MODE_THIS_MAC_LABEL
        : UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL
}

func pairingResultText(
    for state: PairingFlowState,
    isPairedHome: Bool,
    sameMachineHomeMigrationComplete: Bool
) -> String? {
    switch state {
    case .paired:
        guard !isPairedHome || sameMachineHomeMigrationComplete else { return nil }
        return "paired ✓"
    case .alreadyConnected:
        guard !isPairedHome || sameMachineHomeMigrationComplete else { return nil }
        return "already paired ✓"
    case .switched:
        return "switched ✓"
    case .idle, .pairing, .switchConfirmPending, .switchMarkPending, .switchDeclined, .saveFailed, .failed:
        return nil
    }
}

enum JournalConnectionRecoveryAction: Equatable {
    case none
    case reevaluatePairing
    case coalescedReconnect
    case paidPlan
    case retryRevokedRetirement
    case mismatchFreshLinkAndSupport
}

func journalConnectionRecoveryAction(for cause: JournalConnectionFailureCause?) -> JournalConnectionRecoveryAction {
    guard let cause else { return .none }
    switch cause {
    case .keychainUnavailable, .noRoute:
        return .reevaluatePairing
    case .unreachable, .loopbackUnavailable:
        return .coalescedReconnect
    case .notEntitled:
        return .paidPlan
    case .revoked:
        return .retryRevokedRetirement
    case .mismatch:
        return .mismatchFreshLinkAndSupport
    case .notServing:
        return .none
    }
}

func shouldShowPairingRetry(for state: TunnelLifecycleState, failureCause: JournalConnectionFailureCause? = nil) -> Bool {
    if let failureCause {
        switch failureCause {
        case .keychainUnavailable, .noRoute, .unreachable, .loopbackUnavailable, .revoked:
            return true
        case .notEntitled, .mismatch, .notServing:
            return false
        }
    }
    switch state {
    case .error(.keychainUnavailable), .error(.loopbackUnavailable), .error(.revoked), .error(.refusalsExhausted):
        return true
    default:
        return false
    }
}

private struct SettingsPaneScrollEdgeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

func healthActionEffect(_ action: StatusHealthAction) -> (tab: SettingsView.Tab, postsReask: Bool) {
    (SettingsView.Tab(rawValue: action.settingsTab) ?? .status, action.reasksJournalMark)
}

/// Settings window for configuring server upload
struct SettingsView: View {
    /// The window's places, by their legacy names: routes, visited marks and tests use these.
    /// The sidebar shows `ShelfRow`; the source-shaped names open a pane beside the deck.
    enum Tab: String, Hashable, CaseIterable {
        case home = "home"
        case permissions = "permissions"
        case sources = "sources"
        case observer = "observer"
        case service = "service"
        case microphones = "microphones"
        case privacy = "privacy"
        case status = "status"
        case updates = "updates"
        case help = "help"
    }

    enum SidebarBadgeState: CaseIterable {
        case done, attention, blank
    }

    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @State var shelf: ShelfRow = .home
    @State var homePane: HomePane?
    @FocusState var focusedTile: DeckSource?
    @Environment(\.dismiss) private var dismiss

    @State var storageUsedMB: Int?
    @State var tryAgainInFlight = false
    @State var setupProbeSnapshot = SetupProbeSnapshot.checking

    // Help diagnostics are read only after the owner opens the disclosure.
    @State var diagnosticsExpanded = false
    @State var diagnosticsLoading = false
    @State var diagnosticLoadGeneration: UInt = 0
    @State var diagnosticReport: DiagnosticReport?
    @State var diagnosticCopyFeedback: DiagnosticCopyFeedback?

    @State var logExportGeneration: UInt = 0
    @State var logExportLoading = false
    @State var logExportDocument: LogExportDocument?
    @State var logExportTask: Task<Void, Never>?
    @State var logExportWriteFeedback: LogExportWriteFeedback?

    // Permissions tab state
    @State var screenRecordingPrompted = false
    @State var screenRestartPending = false

    // Privacy tab state
    @State var newTitlePattern = ""
    @State var newProtectedVideoPattern = ""
    @State var newExcludedApp = ""
    @State var newWebsite = ""
    @State var websiteError: String? = nil
    @FocusState var privateWindowKeyboardFocused: Bool
    @AccessibilityFocusState var privateWindowAccessibilityFocused: Bool
    @State var privateWindowAnnouncements = PrivateWindowAccessibilityAnnouncementPolicy()

    // Service tab state
    @State var observerURL = ""
    @State var observerKey = ""
    @State var pairingLink = ""
    @State var inFlightTestID: UUID?
    @State var disconnectConfirmPending = false
    @State var journalMarkDriver = JournalMarkConfirmationDriver()
    @State var journalHandoffOrchestrator: JournalHandoffOrchestrator
    @State var freshFlow: FreshJournalFlow
    @State var onDiskJournalAdoptionFlow: OnDiskJournalAdoptionFlow
    @State var pairingMismatch = false
    @State var journalMarkRederiveEligible = false
    @State var journalMarkRederiveStarted = false
    @State var journalMarkRederiveTask: Task<Void, Never>?
    @State var localJournalMark: JournalMark?
    @State var localOnDiskDiscoveryPath: String?
    @State var localOnDiskAdoptionAction: OnDiskJournalAdoptionAction = .install
    @State var localDiscoveryCompleted = false
    @State var localDiscoveryTask: Task<Void, Never>?
    @State var localDiscoveryInFlight = false
    @State var lastProbeFinishedAt: Date?
    @State var localLinkInProgress = false
    @State var localLinkError: String?
    @State var localLinkNotice: String?
    @State var localJournalIsNotYours = false
    /// Re-link found this Mac set to send somewhere a same-machine link can't reach.
    @State var relinkNeedsPairingLink = false
    @State var showPairingFlow = false
    @State var replacementConfirmationPresented = false
    @State var entitlementOpenFailed = false
    @State var supportOpenFailed = false

    let localIdentityFetch: @MainActor @Sendable (String) async -> JournalIdentityResolution
    let onDiskJournalDiscovery: @MainActor @Sendable () async -> OnDiskJournalDiscovery
    let sameMachinePairStart: @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
    let runningJournalController: any RunningJournalController
    let diagnosticClipboardWrite: @MainActor (String) -> Bool
    let diagnosticAnnouncement: @MainActor (String) -> Void
    let openURL: @MainActor (URL) -> Bool
    let logExportSource: any LogExportEntrySourcing
    let logExportWriter: any LogExportFileWriting
    let logExportChooseSaveURL: @MainActor (LogExportDocument) -> URL?

    init(
        appState: AppState,
        updateController: UpdateController,
        selectedTab: Tab = .home,
        initialHomePane: HomePane? = nil,
        initialStorageUsedMB: Int? = nil,
        initialLocalJournalMark: JournalMark? = nil,
        initialLocalOnDiskDiscoveryPath: String? = nil,
        initialLocalDiscoveryCompleted: Bool = false,
        initialShowPairingFlow: Bool = false,
        journalHandoffOrchestrator: JournalHandoffOrchestrator = JournalHandoffOrchestrator(),
        freshFlow: FreshJournalFlow = FreshJournalFlow(dependencies: .live()),
        onDiskJournalAdoptionFlow: OnDiskJournalAdoptionFlow = OnDiskJournalAdoptionFlow(),
        localIdentityFetch: @escaping @MainActor @Sendable (String) async -> JournalIdentityResolution = { _ in
            await OwnJournalAccess.resolveIdentity()
        },
        onDiskJournalDiscovery: @escaping @MainActor @Sendable () async -> OnDiskJournalDiscovery = {
            await discoverOnDiskJournal()
        },
        sameMachinePairStart: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ deviceLabel: String
        ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> = { baseURL, deviceLabel in
            await OwnJournalAccess.startPairing(deviceLabel: deviceLabel)
        },
        runningJournalController: any RunningJournalController = LiveRunningJournalController(),
        initialSetupProbeSnapshot: SetupProbeSnapshot = .checking,
        initialDiagnosticsExpanded: Bool = false,
        initialDiagnosticReport: DiagnosticReport? = nil,
        diagnosticClipboardWrite: @escaping @MainActor (String) -> Bool = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        },
        diagnosticAnnouncement: @escaping @MainActor (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        },
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        logExportSource: any LogExportEntrySourcing = HostLocalLogExportSource(),
        logExportWriter: any LogExportFileWriting = LogExportAtomicWriter(),
        logExportChooseSaveURL: @escaping @MainActor (LogExportDocument) -> URL? = { _ in
            presentLogExportSavePanel()
        },
        initialEntitlementOpenFailed: Bool = false,
        initialSupportOpenFailed: Bool = false,
        initialPairingMismatch: Bool = false
    ) {
        self.appState = appState
        self.updateController = updateController
        self.localIdentityFetch = localIdentityFetch
        self.onDiskJournalDiscovery = onDiskJournalDiscovery
        self.sameMachinePairStart = sameMachinePairStart
        self.runningJournalController = runningJournalController
        self.diagnosticClipboardWrite = diagnosticClipboardWrite
        self.diagnosticAnnouncement = diagnosticAnnouncement
        self.openURL = openURL
        self.logExportSource = logExportSource
        self.logExportWriter = logExportWriter
        self.logExportChooseSaveURL = logExportChooseSaveURL
        let route = ShellRoute(tab: selectedTab, appState: appState)
        self._shelf = State(initialValue: route.shelf)
        self._homePane = State(initialValue: initialHomePane ?? route.pane)
        self._storageUsedMB = State(initialValue: initialStorageUsedMB)
        self._setupProbeSnapshot = State(initialValue: initialSetupProbeSnapshot)
        self._diagnosticsExpanded = State(initialValue: initialDiagnosticsExpanded)
        self._diagnosticReport = State(initialValue: initialDiagnosticReport)
        self._journalHandoffOrchestrator = State(initialValue: journalHandoffOrchestrator)
        self._freshFlow = State(initialValue: freshFlow)
        self._onDiskJournalAdoptionFlow = State(initialValue: onDiskJournalAdoptionFlow)
        self._localJournalMark = State(initialValue: initialLocalJournalMark)
        self._localOnDiskDiscoveryPath = State(initialValue: initialLocalOnDiskDiscoveryPath)
        self._localDiscoveryCompleted = State(initialValue: initialLocalDiscoveryCompleted)
        self._showPairingFlow = State(initialValue: initialShowPairingFlow)
        self._entitlementOpenFailed = State(initialValue: initialEntitlementOpenFailed)
        self._supportOpenFailed = State(initialValue: initialSupportOpenFailed)
        self._pairingMismatch = State(initialValue: initialPairingMismatch)
    }

    var preserveSyncedSegmentsBinding: Binding<Bool> {
        Binding(
            get: { appState.config.preserveSyncedSegments },
            set: { newValue in
                var config = appState.config
                config.preserveSyncedSegments = newValue
                appState.updateConfig(config)
            }
        )
    }

    var body: some View {
        settingsContent
        .background(SetupSettingsWindowInstaller(setupShowing: appState.setupModel.phase != nil))
        .alert(appState.setupModel.handoffRefusalMessage ?? "", isPresented: Binding(
            get: { appState.setupModel.handoffRefusal != nil },
            set: { if !$0 { appState.setupModel.dismissHandoffRefusal() } }
        )) {
            Button("ok", role: .cancel) { appState.setupModel.dismissHandoffRefusal() }
        }
    }

    var settingsContent: some View {
        Group {
            if appState.setupModel.phase != nil {
                SetupView(model: appState.setupModel, appState: appState, journalMarkDriver: journalMarkDriver)
            } else {
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    List(selection: $shelf) {
                        shelfLabel("home", row: .home, systemImage: "house")
                        shelfLabel(
                            "your journal",
                            row: .service,
                            systemImage: "book.closed",
                            badge: appState.serviceIsDone ? .done : (appState.serviceNeedsAttention ? .attention : .blank)
                        )
                        shelfLabel("this mac", row: .observer, systemImage: "laptopcomputer")
                        shelfLabel(
                            UpdatesCopy(provider: .solstone).tabTitle,
                            row: .updates,
                            systemImage: "arrow.down.circle",
                            badge: updatesSidebarBadge(for: updateController.durableUpdateStatus),
                            doneAccessibilityLabel: UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y
                        )
                        shelfLabel("help", row: .help, systemImage: "questionmark.circle")
                    }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .modifier(SettingsPaneScrollEdgeModifier())
        } detail: {
            ScrollViewReader { proxy in
                if shelf == .home {
                    deskHome(scrollProxy: proxy)
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = appState.configSaveError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier(AXID.Settings.configSaveError)
                        }
                        detailContent(scrollProxy: proxy)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .modifier(SettingsPaneScrollEdgeModifier())
                }
            }
        }
        }
        }
        .frame(
            minWidth: appState.setupModel.phase != nil ? 880 : 860,
            minHeight: appState.setupModel.phase != nil ? 580 : 600
        )

        .task {
            if storageUsedMB == nil {
                let bytes = await appState.storageManager.calculateStorageUsed()
                storageUsedMB = Int(bytes / (1024 * 1024))
            }
        }
        .onAppear {
            appState.syncMicrophonePriorityList()
            applyPendingSettingsTab()
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            appState.browserPendingDiscard.openSettings()
            appState.refreshBrowserPendingDiscard()
#endif
            journalMarkRederiveEligible = appState.confirmedMark == nil && appState.tunnelLifecycleOwner.isTunnelManaged
            startJournalMarkRederiveIfNeeded()
            if appState.sameComputerLinkAwaitsVerification, !localLinkInProgress {
                confirmLocalJournalLink()
            }
            if !appState.setupModel.isPeerSupportingSetup {
                // A ceremony that finished while settings was closed asks now.
                if appState.pairingCoordinator.state == .switchMarkPending {
                    journalMarkDriver.startIfNeeded(for: .switchMarkPending, appState: appState)
                }
                journalMarkDriver.startIfUnconfirmed(appState: appState)
            }
        }
        .onChange(of: appState.pairingCoordinator.state) { _, newValue in
            handlePairingStateChange(newValue)
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            appState.refreshBrowserPendingDiscard()
#endif
        }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        .onChange(of: appState.browserHostSnapshot.value) { _, _ in
            appState.refreshBrowserPendingDiscard()
        }
#endif
        .onChange(of: appState.pairingCoordinator.tunnelState) { _, newValue in
            startJournalMarkRederiveIfNeeded()
            // A same-computer link that ran out of time before the tunnel came up finishes now.
            if case .connected = newValue, appState.sameComputerLinkAwaitsVerification, !localLinkInProgress {
                confirmLocalJournalLink()
            }
            if !appState.setupModel.isPeerSupportingSetup {
                journalMarkDriver.startIfUnconfirmed(appState: appState)
            }
        }
        .onChange(of: homePane) { _, newValue in
            if shelf != .home || !Self.paneHoldsLeftOut(newValue) {
                appState.pendingPrivateWindowSettingsTarget = nil
                appState.pendingWebsiteSettingsTarget = nil
            }
        }
        .onChange(of: shelf) { _, newValue in
            if newValue != .home {
                appState.pendingPrivateWindowSettingsTarget = nil
                appState.pendingWebsiteSettingsTarget = nil
            }
        }
        .onChange(of: appState.initialPermissionCheckComplete) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.screenRecordingGranted) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.config.serverURL) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.config.serverKey) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.config.serviceMode) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.config.journalPath) { _, _ in
            refreshSetupProbes()
        }
        .onChange(of: appState.tunnelLifecycleOwner.isTunnelManaged) { _, _ in
            refreshSetupProbes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
            applyPendingSettingsTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            privateWindowAnnouncements.reset(to: privateWindowAccessibilityState)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            privateWindowAnnouncements.reset(to: privateWindowAccessibilityState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reaskJournalMark)) { _ in
            navigate(.service)
            journalMarkDriver.reaskUnconfirmed(appState: appState)
        }
        .sheet(isPresented: Binding(
            get: { journalMarkDriver.isPresented },
            set: { newValue in
                if !newValue {
                    journalMarkDriver.closeQuestion(appState: appState)
                }
            }
        ), onDismiss: {
            journalMarkDriver.sheetDismissed()
        }) {
            journalMarkSheet
                .allowsAppQuitWhilePresented()
        }
        .onDisappear {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            appState.browserPendingDiscard.closeSettings()
#endif
            journalMarkDriver.closeQuestion(appState: appState)
            appState.pairingCoordinator.clearSwitchDeclined()
            journalMarkRederiveTask?.cancel()
            journalMarkRederiveTask = nil
        }
        .onExitCommand {
            if shelf == .home, homePane != nil {
                homePane = nil
            } else {
                dismiss()
            }
        }
    }

    @ViewBuilder
    func detailContent(scrollProxy: ScrollViewProxy) -> some View {
        switch shelf {
        case .home:
            EmptyView()
        case .observer:
            VStack(alignment: .leading, spacing: 20) {
                observerTab
                permissionsReviewRow
            }
            .onAppear { appState.markSettingsTabVisited(.observer) }
        case .service:
            serviceTab.onAppear { appState.markSettingsTabVisited(.service) }
        case .updates:
            VStack(alignment: .leading, spacing: 16) {
                JournalUpdateDestinationView(owner: appState.tunnelLifecycleOwner)
                Divider()
                UpdatesTabView(controller: updateController, copy: UpdatesCopy(provider: .solstone))
            }
            .onAppear { appState.markSettingsTabVisited(.updates) }
        case .help:
            helpTab
                .onAppear { appState.markSettingsTabVisited(.help) }
                .onDisappear { cancelLogExportRead() }
        }
    }

    func applyPendingSettingsTab() {
        if let pendingLink = appState.takePendingPairingLink(forSetup: false) {
            pairingLink = pendingLink
            showPairingFlow = true
        }
        if let pending = appState.pendingSettingsTab {
            if pending.hasPrefix("source:"), let source = DeckSource(rawValue: String(pending.dropFirst("source:".count))) {
                shelf = .home
                homePane = .source(source)
            } else if let tab = SettingsView.Tab(legacyRoute: pending) {
                navigate(tab)
            }
            appState.pendingSettingsTab = nil
        }
    }

    var journalMarkSheet: some View {
        JournalMarkSheetContent(
            phase: journalMarkDriver.phase,
            onMismatch: rejectJournalMark,
            onConfirm: confirmJournalMark,
            onCancelPairing: cancelUnverifiedPairing,
            onContinueAnyway: continueUnverifiedMark
        )
    }

    func handlePairingStateChange(_ state: PairingFlowState) {
        if !appState.setupModel.isPeerSupportingSetup {
            journalMarkDriver.startIfNeeded(for: state, appState: appState)
        }
        switch state {
        case .paired, .alreadyConnected, .switched:
            showPairingFlow = false
            relinkNeedsPairingLink = false
            pairingLink = ""
        default:
            break
        }
    }

    func confirmJournalMark() {
        _ = journalMarkDriver.confirm(appState: appState)
        pairingMismatch = false
    }

    func continueUnverifiedMark() {
        _ = journalMarkDriver.continueAnyway(appState: appState)
        pairingMismatch = false
    }

    func cancelUnverifiedPairing() {
        Task { @MainActor in
            guard await journalMarkDriver.cancelPairing(appState: appState) else { return }
            pairingMismatch = false
            journalMarkRederiveEligible = false
            journalMarkRederiveStarted = false
        }
    }

    func rejectJournalMark() {
        Task { @MainActor in
            await journalMarkDriver.reject(appState: appState) {
                pairingMismatch = true
                journalMarkRederiveEligible = false
                journalMarkRederiveStarted = false
            }
        }
    }

    func startJournalMarkRederiveIfNeeded() {
        guard journalMarkRederiveEligible,
              !journalMarkRederiveStarted,
              appState.confirmedMark == nil,
              appState.isJournalMarkConfirmed,
              appState.tunnelLifecycleOwner.isTunnelManaged
        else {
            return
        }

        journalMarkRederiveStarted = true
        journalMarkRederiveTask?.cancel()
        journalMarkRederiveTask = Task { @MainActor in
            await appState.deriveConfirmedMark()
        }
    }

    @ViewBuilder
    func sidebarPlainLabel(_ title: String, tab: Tab, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityIdentifier(AXID.Settings.Sidebar.tab(tab))
            .overlay(alignment: .topLeading) {
                AXStateCompanion(
                    id: AXID.Settings.Sidebar.tabState(tab),
                    value: SidebarBadgeState.blank.axToken
                )
            }
    }

    @ViewBuilder
    func sidebarLabel(
        _ title: String,
        tab: Tab,
        systemImage: String,
        badge: SidebarBadgeState,
        doneAccessibilityLabel: String = UICopy.SETTINGS_TAB_DONE_A11Y
    ) -> some View {
        let label = Label(title, systemImage: systemImage)
        switch badge {
        case .blank:
            label
                .accessibilityIdentifier(AXID.Settings.Sidebar.tab(tab))
                .overlay(alignment: .topLeading) {
                    sidebarBadgeStateCompanion(tab: tab, badge: badge)
                }
        case .attention:
            HStack {
                label
                Spacer()
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(SolstoneColors.solOrange)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(UICopy.SETTINGS_TAB_ATTENTION_A11Y)")
            .accessibilityIdentifier(AXID.Settings.Sidebar.tab(tab))
            .overlay(alignment: .topLeading) {
                sidebarBadgeStateCompanion(tab: tab, badge: badge)
            }
        case .done:
            HStack {
                label
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(doneAccessibilityLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(doneAccessibilityLabel)")
            .accessibilityIdentifier(AXID.Settings.Sidebar.tab(tab))
            .overlay(alignment: .topLeading) {
                sidebarBadgeStateCompanion(tab: tab, badge: badge)
            }
        }
    }

    func sidebarBadgeStateCompanion(tab: Tab, badge: SidebarBadgeState) -> some View {
        AXStateCompanion(
            id: AXID.Settings.Sidebar.tabState(tab),
            value: badge.axToken
        )
    }

    // MARK: - Sources Tab

    func setCaptureSource(_ source: CaptureSources, enabled: Bool) {
        var config = appState.config
        if source.contains(.microphone) {
            config.isMicrophoneCaptureEnabled = enabled
        }
        if source.contains(.screen) {
            config.isScreenCaptureEnabled = enabled
        }
        appState.updateConfig(config)
        // A source switch takes effect now. Making the owner stop a session to change what
        // it takes in is the all-or-nothing gate this feature exists to retire, relocated.
        Task { await appState.applySelectedSourcesToRunningSession() }
    }

    var activityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("activity", isOn: Binding(
                get: { appState.config.isActivityEnabled },
                set: { enabled in
                    var config = appState.config
                    config.isActivityEnabled = enabled
                    appState.updateConfig(config)
                }
            ))
            Text("adds app names, window titles and active or idle time to your journal, and browser addresses if you allow accessibility. it starts and pauses with screen and system audio.")
                .font(.subheadline).foregroundStyle(.secondary)
            if appState.config.isActivityEnabled {
                Toggle("keep activity on while paused", isOn: Binding(
                    get: { appState.config.activityContinuesThroughPause },
                    set: { value in
                        var config = appState.config; config.activityContinuesThroughPause = value
                        appState.updateConfig(config)
                    }
                ))
                Text("activity keeps going when you pause, and when screen and system audio are off.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("window titles", isOn: Binding(
                    get: { appState.config.activityTitlesEnabled },
                    set: { value in
                        var config = appState.config; config.activityTitlesEnabled = value
                        appState.updateConfig(config)
                    }
                ))
                Toggle("browser addresses", isOn: Binding(
                    get: { appState.config.activityURLsEnabled },
                    set: { value in
                        var config = appState.config; config.activityURLsEnabled = value
                        appState.updateConfig(config)
                    }
                ))
                Text("addresses include the site and path, without query strings or fragments.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Toggle("allow accessibility for activity", isOn: Binding(
                    get: { appState.config.activityAccessibilityEnabled && !appState.activityAccessibilityOffInMacOS },
                    set: { enabled in
                        if enabled && appState.activityAccessibilityOffInMacOS {
                            appState.askForAccessibility()
                            return
                        }
                        var config = appState.config; config.activityAccessibilityEnabled = enabled
                        appState.updateConfig(config)
                        if enabled {
                            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                ))
                .accessibilityIdentifier(AXID.Settings.Sources.activityAccessibility)
                Text(UICopy.Websites.ACTIVITY_ACCESSIBILITY_HELP)
                    .font(.subheadline).foregroundStyle(.secondary)
                if appState.activityAccessibilityOffInMacOS {
                    Text(UICopy.Websites.activityAccessibilityOffInMacOS(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
                        .font(.subheadline)
                        .accessibilityIdentifier(AXID.Settings.Sources.activityAccessibilityOff)
                    Button(UICopy.Websites.OPEN_SYSTEM_SETTINGS) { appState.askForAccessibility() }
                        .accessibilityIdentifier(AXID.Settings.Sources.activityAccessibilityOpenSettings)
                }
                Text("activity follows your exclusions. it continues while screen and audio step aside for protected video. a title does not mean you watched or read it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let activity = appState.activitySource, activity.enabled, !activity.failed {
                if activity.titleUnavailable { Text("window titles are unavailable").foregroundStyle(.secondary) }
                if activity.urlUnavailable { Text("browser addresses are unavailable").foregroundStyle(.secondary) }
            }
        }
    }


#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    var sourcesLead: BrowserOwnerStatusLead {
        browserOwnerStatusLead(
            mediaSourcesEmpty: appState.config.selectedSources.isEmpty,
            mediaRecording: appState.isRecording,
            mediaPaused: appState.isPaused,
            snapshot: appState.browserHostSnapshot.value,
            now: Date()
        )
    }

    var browserSourcesGroup: some View {
        let snapshot = appState.browserHostSnapshot.value
        let rows = browserBrandRows(snapshot, now: Date())
        let verdict = browserOwnerVerdict(mediaSourcesEmpty: appState.config.selectedSources.isEmpty,
            mediaRecording: appState.isRecording, mediaPaused: appState.isPaused, snapshot: snapshot, now: Date())
        let hasAnyHistory = rows.contains { $0.lastSeen != nil }
        let offered = offeredBrowserStoreBrands(catalog: appState.browserStoreCatalog, rows: rows)

        return VStack(alignment: .leading, spacing: 8) {
            Text(UICopy.SOURCES_BROWSERS_GROUP_TITLE)
                .font(.headline)
                .accessibilityIdentifier(AXID.Settings.Sources.browsersGroup)

            if !hasAnyHistory {
                Text(UICopy.SOURCES_BROWSERS_NO_HISTORY)
                    .foregroundStyle(.secondary)
                Text(UICopy.SOURCES_BROWSERS_STORES_CONFIGURED)
                    .foregroundStyle(.secondary)
            }

            ForEach(rows, id: \.brand) { row in
                HStack {
                    Text(UICopy.sourcesBrowserRowLabel(browser: row.brand.displayName, profileCount: row.connectedCount))
                    Spacer()
                    Text(browserRowStatusText(row))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(browserBrandAXID(row.brand))
                .accessibilityValue(row.state.axToken)

                if row.connectedCount > 0 && (row.needsAppUpdate || row.needsExtensionUpdate) {
                    Text(UICopy.SOURCES_BROWSER_CONNECTED_NOW).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(UICopy.SOURCES_BROWSER_REPAIR_ACTION) {
                    appState.beginBrowserRepair()
                }
                .disabled(appState.browserRepair.inFlight)
                .accessibilityIdentifier(AXID.Settings.Sources.browserRepair)
                .accessibilityValue(browserRepairValue.axToken)

                if appState.browserRepair.repaired {
                    Text(UICopy.SOURCES_BROWSER_REPAIRED)
                        .foregroundStyle(.secondary)
                } else if let failure = appState.browserRepair.lastFailureReason {
                    Text(UICopy.sourcesBrowserRepairFailed(reason: UICopy.browserSetupReason(failure)))
                        .foregroundStyle(.red)
                }
            }

            ForEach(BrowserBrand.allCases.filter(offered.contains), id: \.self) { brand in
                VStack(alignment: .leading, spacing: 2) {
                    Button(UICopy.sourcesBrowserAddAction(browser: brand.displayName)) {
                        appState.openBrowserStore(brand)
                    }
                    .accessibilityIdentifier(browserStoreAXID(brand))
                    .accessibilityValue(browserStoreValue(brand).axToken)

                    if appState.browserStoreLaunch[brand] == .failed {
                        Text(UICopy.sourcesBrowserLaunchFailure(browser: brand.displayName))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            safariExtensionRow

            Text(UICopy.SOURCES_BROWSER_FOOTNOTE)
                .font(.caption)
                .foregroundStyle(.secondary)
            if rows.contains(where: { $0.needsAppUpdate }) { Text(UICopy.SOURCES_BROWSER_NEWER_EXTENSION) }
            if verdict.fullSecondary { Text(UICopy.SOURCES_BROWSER_FULL) }
            if verdict.stale { Text(UICopy.SOURCES_BROWSER_STALE) }
            browserPendingDiscardLine
            if verdict.showsDeliveryLine { Text(UICopy.SOURCES_BROWSER_DELIVERY_FAILED) }
            if snapshot.registration.values.contains(where: { $0.state == .refused }) {
                Text(UICopy.SOURCES_BROWSER_REGISTRATION_BROKEN)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    var browserPendingDiscardLine: some View {
        let custody = appState.browserPendingDiscard
        VStack(alignment: .leading, spacing: 6) {
            if custody.showsDiscarded {
                Text(UICopy.SOURCES_BROWSER_DISCARDED)
            }
            if custody.showsNotice {
                if custody.confirmation != nil {
                    Text(UICopy.SOURCES_BROWSER_DISCARD_CONFIRM)
                    HStack {
                        Button(UICopy.SOURCES_BROWSER_DISCARD_COMMIT) {
                            appState.confirmBrowserPendingDiscard()
                        }
                        .disabled(custody.isDiscarding || !custody.canRequestDiscard)
                        .accessibilityIdentifier(AXID.Settings.Sources.browserWaitingConfirm)
                        Button("cancel") { appState.browserPendingDiscard.cancelDiscard() }
                            .disabled(custody.isDiscarding)
                            .accessibilityIdentifier(AXID.Settings.Sources.browserWaitingCancel)
                    }
                } else {
                    Button(UICopy.SOURCES_BROWSER_DISCARD) {
                        appState.refreshBrowserPendingDiscard()
                        appState.browserPendingDiscard.requestDiscard()
                    }
                    .disabled(!custody.canRequestDiscard)
                    .accessibilityIdentifier(AXID.Settings.Sources.browserWaitingDiscard)
                }
            }
            if custody.showsFailure {
                Text(UICopy.SOURCES_BROWSER_DISCARD_FAILED)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AXID.Settings.Sources.browserWaitingFailure)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Settings.Sources.browserWaitingState)
        .accessibilityValue(browserPendingAXState.axToken)
    }

    var browserPendingAXState: BrowserRetiredAXState {
        let custody = appState.browserPendingDiscard
        if custody.isDiscarding { return .discarding }
        if custody.showsDiscarded { return .discarded }
        if custody.showsFailure { return .failed }
        if custody.confirmation != nil { return .confirming }
        switch custody.inventory {
        case .unknown: return .unknown
        case .empty: return .empty
        case .present: return .held
        }
    }


    var browserRepairValue: BrowserRepairAXState {
        if appState.browserRepair.inFlight { return .inFlight }
        if appState.browserRepair.repaired { return .repaired }
        if appState.browserRepair.lastFailureReason != nil { return .failed }
        return .idle
    }

    func browserStoreValue(_ brand: BrowserBrand) -> BrowserStoreLaunchAXState {
        switch appState.browserStoreLaunch[brand] ?? .disabled {
        case .disabled: return .disabled
        case .opened: return .opened
        case .failed: return .failed
        }
    }

    func browserBrandAXID(_ brand: BrowserBrand) -> String {
        switch brand {
        case .chrome: return AXID.Settings.Sources.browserChrome
        case .edge: return AXID.Settings.Sources.browserEdge
        case .firefox: return AXID.Settings.Sources.browserFirefox
        case .safari: return AXID.Settings.Sources.browserSafari
        }
    }

    func browserStoreAXID(_ brand: BrowserBrand) -> String {
        switch brand {
        case .chrome: return AXID.Settings.Sources.browserStoreChrome
        case .edge: return AXID.Settings.Sources.browserStoreEdge
        case .firefox: return AXID.Settings.Sources.browserStoreFirefox
        case .safari: return AXID.Settings.Sources.browserSafariSettings
        }
    }

    /// Safari's extension ships inside this app: the owner turns it on in
    /// Safari's own settings, which this opens, and the row says whether it's on.
    var safariExtensionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(UICopy.SOURCES_BROWSER_SAFARI_SETTINGS_ACTION) {
                    appState.openSafariExtensionSettings()
                }
                .accessibilityIdentifier(AXID.Settings.Sources.browserSafariSettings)
                .accessibilityValue(appState.safariExtensionState.axToken)

                switch appState.safariExtensionState {
                case .on: Text(UICopy.SOURCES_BROWSER_SAFARI_ON).foregroundStyle(.secondary)
                case .off: Text(UICopy.SOURCES_BROWSER_SAFARI_OFF).foregroundStyle(.secondary)
                case .unknown:
                    if appState.safariExtensionNeedsAttention {
                        Text(UICopy.SOURCES_BROWSER_SAFARI_UNAVAILABLE).foregroundStyle(.orange)
                    }
                }
            }
            if appState.safariSettingsLaunch == .failed {
                Text(UICopy.SOURCES_BROWSER_SAFARI_SETTINGS_FAILED)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { appState.refreshSafariExtensionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshSafariExtensionState()
        }
    }
#endif

    // MARK: - Permissions Tab

    var screenRecordingWaiting: Bool {
        (screenRecordingPrompted || appState.capture.screenRecordingHasPrompted()) && !appState.screenRecordingGranted
    }

    internal var screenRecordingPermissionAXState: AXPermissionState {
        if appState.screenRecordingGranted {
            return .granted
        }
        return screenRecordingWaiting ? .waiting : .denied
    }

    var microphonePermissionAXState: AXPermissionState {
        appState.microphoneAuthorizationCause.permissionAXState
    }

    @ViewBuilder
    func permissionSourceLiveRow(source: CaptureSources) -> some View {
        PermissionSourceLiveRowView(
            source: source,
            appState: appState,
            onOpenSources: { navigate(.sources) },
            onCheckStatus: { navigate(.status) }
        )
    }

    var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            screenRecordingPermissionCard
            microphonePermissionCard
            permissionsReviewRow
            Spacer()
        }
    }

    var screenRecordingPermissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("screen recording")
                    .font(.headline)
                AXStateCompanion(
                    id: AXID.Settings.Permissions.screenRecordingState,
                    value: screenRecordingPermissionAXState.axToken
                )
                if appState.screenRecordingGranted {
                    if screenRestartPending {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(SolstoneColors.solOrange)
                            Text(UICopy.SOURCES_RESTART_READY)
                            Spacer()
                            Button(UICopy.SOURCES_RESTART) { relaunchApp() }
                                .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingRestartNow)
                        }
                        AXStateCompanion(
                            id: AXID.Settings.Permissions.screenRecordingRestartPending,
                            value: "pending"
                        )
                    } else {
                        permissionSourceLiveRow(source: .screen)
                    }
                } else if appState.capture.screenRecordingNeedsRestart {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(SolstoneColors.solOrange)
                        Text(UICopy.SOURCES_RESTART_READY)
                        Spacer()
                        Button(UICopy.SOURCES_RESTART) { relaunchApp() }
                            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingRestartNow)
                    }
                    AXStateCompanion(
                        id: AXID.Settings.Permissions.screenRecordingRestartPending,
                        value: "pending"
                    )
                } else {
                    Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_EXPLAINER)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if shouldShowScreenRecordingResetHint(
                        hasPromptedScreenRecording: setupProbeSnapshot.hasPromptedScreenRecording,
                        sckFailedAfterPositivePreflight: setupProbeSnapshot.screenDiagnostic?.sckFailedAfterPositivePreflight ?? false,
                        restartCountdown: nil
                    ) {
                        Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingResetHint)
                    }
                    HStack {
                        if screenRecordingWaiting {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_WAITING)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                HStack {
                                    Button(UICopy.SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS) {
                                        // Asking again puts solstone back in the list if its entry was removed there.
                                        PermissionChecker().promptScreenRecording()
                                        NSWorkspace.shared.open(
                                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                                        )
                                    }
                                    .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingOpenSystemSettings)
                                    Button(UICopy.SETTINGS_PERMISSIONS_SCREEN_REOPEN) { relaunchApp() }
                                        .buttonStyle(.link)
                                        .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingReopen)
                                }
                            }
                        } else {
                            Spacer()
                            Button(UICopy.SETTINGS_PERMISSIONS_ENABLE_SCREEN_RECORDING) {
                                Logger.setup.info("Button tapped: enable screen recording")
                                PermissionChecker().promptScreenRecording()
                                screenRecordingPrompted = true
                            }
                            .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingEnable)
                        }
                    }
                }
                Text(UICopy.SETTINGS_PERMISSIONS_SCREEN_RECORDING_BREADCRUMB)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    var microphonePermissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("microphone")
                    .font(.headline)
                AXStateCompanion(
                    id: AXID.Settings.Permissions.microphoneState,
                    value: microphonePermissionAXState.axToken
                )
                if appState.microphoneGranted {
                    permissionSourceLiveRow(source: .microphone)
                } else {
                    Text(UICopy.SETTINGS_PERMISSIONS_MIC_EXPLAINER)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        switch appState.microphoneAuthorizationCause {
                        case .authorized:
                            EmptyView()
                        case .denied:
                            microphoneSettingsButton(message: UICopy.SETTINGS_PERMISSIONS_MIC_DENIED)
                        case .restricted:
                            microphoneSettingsButton(message: UICopy.SETTINGS_PERMISSIONS_MIC_RESTRICTED)
                        case .notDetermined:
                            Button(UICopy.SETTINGS_PERMISSIONS_ENABLE_MICROPHONE) {
                                Task {
                                    await PermissionChecker().requestMicrophone()
                                    appState.refreshMicrophoneAuthorization()
                                }
                            }
                            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneGrantAccess)
                        case .unknown:
                            microphoneSettingsButton(message: UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK)
                        }
                    }
                }
                Text(UICopy.SETTINGS_PERMISSIONS_MICROPHONE_BREADCRUMB)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    var permissionsReviewRow: some View {
        HStack(spacing: 4) {
            Text("you can review or revoke these anytime in")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("System Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
            }
            .font(.caption)
            .buttonStyle(.link)
            .accessibilityIdentifier(AXID.Settings.Permissions.systemSettingsOpen)
        }
    }

    /// Watches for a screen recording grant while the screen page shows the card.
    func screenRecordingGrantWatcher<Content: View>(_ content: Content) -> some View {
        content
        .task(id: screenRecordingWaiting) {
            guard screenRecordingWaiting else { return }
            while !Task.isCancelled {
                // Gate on CGPreflightScreenCaptureAccess before calling SCShareableContent.
                // On macOS 26, SCShareableContent.current re-triggers the OS dialog every call
                // when no TCC entry exists yet — i.e. while the user hasn't granted yet.
                if CGPreflightScreenCaptureAccess() {
                    if !appState.capture.protectedVideoBlocksAutomaticScreenCaptureRead() {
                        if await PermissionChecker.checkScreenRecording() {
                            screenRestartPending = true
                            appState.capture.publishScreenRecordingPermission(.granted)
                            return
                        }
                    }
                    // else: permission not yet granted
                }
                await appState.capture.probeScreenRecordingGrantIfWaiting()
                try? await Task.sleep(for: .seconds(1.5))
            }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        appState.capture.noteApplicationDidBecomeActive()
        Task { await appState.capture.probeScreenRecordingGrantIfWaiting() }
    }
    }


    func relaunchApp() {
        appState.appQuitCoordinator.requestSettingsRestart()
    }

    func microphoneSettingsButton(message: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(UICopy.SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS) {
                openMicrophoneSettings()
            }
            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneGrantAccess)
        }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        )
    }

    func refreshSetupProbes() {
        Task { @MainActor in
            let permissionChecker = PermissionChecker()
            let screenDiagnostic: ScreenRecordingPermissionDiagnostic?
            if appState.capture.protectedVideoBlocksAutomaticScreenCaptureRead() {
                screenDiagnostic = nil
            } else {
                screenDiagnostic = await PermissionChecker.screenRecordingDiagnostic()
            }
            setupProbeSnapshot = SetupProbeSnapshot(
                solAppPlacement: solAppPlacementOutcome(),
                journalAppInstalled: runningJournalController.installedURL() == nil ? .needsAttention : .ready,
                hasPromptedScreenRecording: permissionChecker.hasPromptedScreenRecording,
                screenDiagnostic: screenDiagnostic
            )
        }
    }

    func solAppPlacementOutcome() -> SetupProbeOutcome {
        switch AppPlacementGate.evaluate() {
        case .allowed(.canonical), .allowed(.stableLocation), .allowed(.developerBypass):
            return .ready
        case .repair:
            return .needsAttention
        }
    }

    // MARK: - Observer Tab

    var observerTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("general") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("start at login", isOn: Binding(
                        get: { appState.isLoginItemEnabled },
                        set: { appState.setLoginItemEnabled($0) }
                    ))
                    .accessibilityIdentifier(AXID.Settings.Observer.startAtLogin)
                    .padding(.vertical, 4)
                    if let error = appState.loginItemError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(AXID.Settings.Observer.startAtLoginError)
                    }

                    Divider()

                    shortcutSettingsView
                }
            }

            GroupBox("notifications") {
                VStack(alignment: .leading, spacing: 6) {
                    notificationAuthorizationDetails
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            appState.refreshNotificationAuthorizationStatusSoon()
        }
    }

    @ViewBuilder
    var shortcutSettingsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(UICopy.SHORTCUT_SECTION_TITLE)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(UICopy.SHORTCUT_SECTION_DESCRIPTION)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if appState.shortcutController.isCapturing {
                    Button(UICopy.SHORTCUT_PRESS) {}
                        .disabled(true)
                        .accessibilityIdentifier(AXID.Settings.Observer.shortcutSet)
                    Button(UICopy.SHORTCUT_CANCEL) {
                        appState.shortcutController.cancelCapture()
                    }
                    .accessibilityIdentifier(AXID.Settings.Observer.shortcutCancel)
                } else {
                    if let chord = appState.shortcutController.state.chord {
                        Button(chord.displayString) {
                            appState.shortcutController.beginCapture()
                        }
                        .accessibilityIdentifier(AXID.Settings.Observer.shortcutSet)
                        Button(UICopy.SHORTCUT_CLEAR) {
                            appState.shortcutController.clear()
                        }
                        .accessibilityIdentifier(AXID.Settings.Observer.shortcutClear)
                    } else {
                        Button(UICopy.SHORTCUT_SET) {
                            appState.shortcutController.beginCapture()
                        }
                        .accessibilityIdentifier(AXID.Settings.Observer.shortcutSet)
                        Text(UICopy.SHORTCUT_OFF)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            if let err = appState.shortcutController.captureErrorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AXID.Settings.Observer.shortcutStatus)
            } else if case .conflict = appState.shortcutController.state {
                Text(UICopy.SHORTCUT_ERROR_CONFLICT)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AXID.Settings.Observer.shortcutStatus)
            } else if case .unavailable = appState.shortcutController.state {
                Text(UICopy.SHORTCUT_ERROR_UNAVAILABLE)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AXID.Settings.Observer.shortcutStatus)
            }

            Text(UICopy.SHORTCUT_PERMISSION_NOTE)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AXID.Settings.Observer.shortcutPermission)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Settings.Observer.shortcut)
    }

    @ViewBuilder
    var notificationAuthorizationDetails: some View {
        if appState.notificationAuthorizationStatus == .provisional {
            VStack(alignment: .leading, spacing: 6) {
                Text("want solstone's notes to show up with a banner and sound?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("turn on banners") {
                    appState.elevateNotifications()
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        } else if appState.notificationAuthorizationStatus == .denied {
            VStack(alignment: .leading, spacing: 4) {
                Text("notifications are turned off for solstone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("macOS is blocking these. you can turn them back on anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("open notification settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.solstone.observer") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
                Text("System Settings → Notifications → solstone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AXID.Settings.Observer.notificationDeniedState)
            .accessibilityValue(String(appState.notificationAuthorizationStatus == .denied))
        }
    }

    // MARK: - Service Tab

    var serviceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            serviceSection
            Spacer()
            if appState.serviceIsDone && !appState.visitedSettingsTabs.contains(Tab.status.rawValue) {
                navRow(UICopy.SETTINGS_NEXT_CHECK_STATUS) {
                    navigate(.status)
                }
                .accessibilityIdentifier(AXID.Settings.Service.nextCheckStatus)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            _ = appState.pairingCoordinator.refreshPendingActions(markConfirmed: appState.isJournalMarkConfirmed)
        }
        .onChange(of: appState.isJournalMarkConfirmed) { _, confirmed in
            _ = appState.pairingCoordinator.refreshPendingActions(markConfirmed: confirmed)
        }
        .sheet(isPresented: Binding(
            get: {
                // The offer waits until the mark question is off screen.
                (appState.pairingCoordinator.replacementOfferVisible && !journalMarkDriver.isPresented)
                    || appState.pairingCoordinator.replacementPickerVisible
            },
            set: { presented in
                if !presented { appState.pairingCoordinator.dismissReplacementPicker() }
            }
        )) {
            replacementFlowSheet
                .allowsAppQuitWhilePresented()
        }
        .onDisappear {
            if appState.pairingCoordinator.replacementOfferVisible
                || appState.pairingCoordinator.replacementPickerVisible {
                appState.pairingCoordinator.dismissReplacementPicker()
            }
        }
        .onAppear {
            if observerURL.isEmpty { observerURL = appState.config.serverURL ?? "" }
            if observerKey.isEmpty { observerKey = appState.config.serverKey ?? "" }
            refreshLocalJournalDiscoveryIfNeeded()
            freshFlow.armWaitingProbe()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reprobeLocalJournalOnReturn()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
            else {
                return
            }
            reprobeLocalJournalOnReturn()
        }
        .onChange(of: freshFlow.state) { _, newState in
            if newState == .waitingForJournal {
                freshFlow.armWaitingProbe()
            } else {
                freshFlow.cancelWaitingProbe()
            }
        }
        .onChange(of: freshFlow.discoveredJournalMark) { _, mark in
            guard let mark else { return }
            localJournalMark = mark
            localDiscoveryCompleted = true
        }
        .onChange(of: appState.config.serverURL) { _, _ in
            observerURL = appState.config.serverURL ?? ""
            refreshLocalJournalDiscoveryIfNeeded()
        }
        .onChange(of: appState.config.serverKey) { _, _ in
            observerKey = appState.config.serverKey ?? ""
            refreshLocalJournalDiscoveryIfNeeded()
        }
        .onChange(of: appState.tunnelLifecycleOwner.isTunnelManaged) { _, _ in
            refreshLocalJournalDiscoveryIfNeeded()
        }
        .onChange(of: appState.config.journalPath) { _, _ in
            refreshLocalJournalDiscoveryIfNeeded()
        }
        .onDisappear {
            localDiscoveryTask?.cancel()
            localDiscoveryInFlight = false
            freshFlow.cancelWaitingProbe()
        }
    }

    var journalPathIsValid: Bool {
        isJournalPathValid(appState.config.journalPath)
    }

    @ViewBuilder
    var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if appState.permissionsNeedAttention {
                attentionRow(UICopy.SETTINGS_PREREQ_PERMISSIONS) {
                    navigate(.permissions)
                }
                .accessibilityIdentifier(AXID.Settings.Service.prereqPermissions)
            }

            AXStateCompanion(
                id: AXID.Settings.Service.pairingFlowState,
                value: appState.pairingCoordinator.state.axToken
            )

            Text("your journal")
                .font(.title2)
                .fontWeight(.semibold)

            if !appState.tunnelLifecycleOwner.hasPersistedPairing {
                healthSummaryCard(showsAction: false)
            }

            if appState.config.serviceMode == .bundled {
                journalMigrationBanner
            }

            if appState.showsConfiguredJournal {
                configuredJournalPanel
            } else {
                unconfiguredJournalPanel
            }
        }
    }

    @ViewBuilder
    var configuredJournalPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("journal") {
                    Text(resolvedJournalName)
                        .accessibilityIdentifier(AXID.Settings.Service.journalNameState)
                        .accessibilityValue(resolvedJournalName)
                }

                if appState.isJournalMarkConfirmed {
                    if let mark = appState.confirmedMark {
                        JournalMarkView(mark: mark, isConfirmed: appState.isJournalMarkCompared)
                        AXStateCompanion(
                            id: AXID.Settings.Service.journalMarkState,
                            value: mark.words.joined(separator: " ")
                        )
                    } else {
                        JournalMarkUnavailableView()
                        AXStateCompanion(
                            id: AXID.Settings.Service.journalMarkState,
                            value: JournalMarkUnavailable.slot
                        )
                    }
                } else {
                    AXStateCompanion(
                        id: AXID.Settings.Service.journalMarkState,
                        value: ""
                    )
                }

                LabeledContent("where") {
                    Text(journalLocationLabel)
                }

                journalAddressRows

                if pairingMismatch {
                    pairingMismatchPane
                } else {
                    let presentation = journalConnectionPresentation
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("connection") {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(presentation.severity.color)
                                    .frame(width: 8, height: 8)
                                Text(presentation.message)
                                    .foregroundStyle(presentation.severity.color)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(AXID.Settings.Service.journalConnectionState)
                            .accessibilityValue(presentation.axToken)
                        }
                        if let caption = presentation.caption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        configuredJournalRecoveryRow(for: presentation.failureCause)
                    }
                }

                unknownJournalNotices

                carriedPairingMigrationPane

                if Self.journalMarkHeldLineVisible(
                    needsJournalMarkConfirmation: appState.needsJournalMarkConfirmation,
                    markSheetPresented: journalMarkDriver.isPresented
                ) {
                    Text(UICopy.JOURNAL_MARK_HELD)
                        .accessibilityIdentifier(AXID.Settings.Service.journalMarkHeld)
                    Text(UICopy.JOURNAL_MARK_HELD_CAPTION)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let affordances = journalPanelAffordancesForPresentation

                if affordances.showRelink && !pairingCanUnpair {
                    HStack {
                        Button("re-link") {
                            relinkJournal()
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.journalRelink)
                        .disabled(localLinkInProgress || pairingIsBusy)

                        if localLinkInProgress {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                }

                if appState.canOpenJournal || affordances.showOpenJournal {
                    Button(UICopy.SETTINGS_JOURNAL_OPEN) {
                        appState.requestOpenJournal(.root)
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.journalOpen)
                }

                if let localLinkError {
                    Text(localLinkError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let localLinkNotice {
                    Text(localLinkNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if pairingCanUnpair {
                    Button("pair to another journal") {
                        showPairingFlow.toggle()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairJournalAnotherDevice)
                    .disabled(pairingIsBusy)
                    pairingDisconnectControls
                }
                if showPairingFlow {
                    pairingSection
                }

            }
            .padding(.vertical, 4)
        }

        if !appState.tunnelLifecycleOwner.hasPersistedPairing {
            DisclosureGroup("advanced") {
                externalServiceSection
            }
        }

        externalJournalSyncSection
        externalJournalStorageSection
    }

    static func journalMarkHeldLineVisible(
        needsJournalMarkConfirmation: Bool,
        markSheetPresented: Bool
    ) -> Bool {
        needsJournalMarkConfirmation && !markSheetPresented
    }

    @ViewBuilder
    var journalAddressRows: some View {
        let owner = appState.tunnelLifecycleOwner
        let addresses = owner.pairedAddresses
        if !addresses.isEmpty {
            LabeledContent(UICopy.JOURNAL_ADDRESSES_LABEL) {
                Text(addresses.joined(separator: "\n"))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        if owner.cachedPairingIdentity != nil {
            LabeledContent(UICopy.JOURNAL_RELAY_LABEL) {
                Text(journalRelayValue(dialableRelayHost: owner.dialableRelayHost))
                    .textSelection(.enabled)
            }
        }
        if let connectedThrough = owner.connectedThrough {
            LabeledContent(UICopy.JOURNAL_CONNECTED_THROUGH_LABEL) {
                Text(connectedThrough.text)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    var unconfiguredJournalPanel: some View {
        if appState.tunnelLifecycleOwner.hasPersistedPairing {
            pairingSection
        } else {
            localJournalDiscoveryPanel
        }

        DisclosureGroup("advanced") {
            externalServiceSection
        }
    }

    @ViewBuilder
    var localJournalDiscoveryPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if !localDiscoveryCompleted {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("looking for your journal on this mac")
                            .foregroundStyle(.secondary)
                    }
                    AXStateCompanion(
                        id: AXID.Settings.Service.localJournalDiscoveryState,
                        value: LocalJournalDiscoveryAXState.searching.axToken
                    )
                    AXStateCompanion(
                        id: AXID.Settings.Service.localJournalDiscoveryPathState,
                        value: ""
                    )
                } else {
                    switch localJournalDiscoveryPanelModel {
                    case .foundRunning(let mark):
                        Text("found your journal on this mac")
                            .font(.headline)
                        JournalMarkView(mark: mark)
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryState,
                            value: LocalJournalDiscoveryAXState.foundRunning.axToken
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryPathState,
                            value: ""
                        )
                        HStack {
                            Button(UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL) {
                                confirmLocalJournalLink()
                            }
                            .accessibilityIdentifier(AXID.Settings.Service.localJournalConfirm)
                            .disabled(localLinkInProgress)

                            if localLinkInProgress {
                                ProgressView()
                                    .scaleEffect(0.5)
                            }
                        }

                    case .foundOnDisk(let path):
                        Text(UICopy.SETTINGS_LOCAL_JOURNAL_FOUND_EXISTING)
                            .font(.headline)
                        Text(path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryState,
                            value: LocalJournalDiscoveryAXState.foundOnDisk.axToken
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryPathState,
                            value: path
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.createJournalState,
                            value: onDiskJournalAdoptionFlow.state.axState.axToken
                        )
                        // A journal is here but its mark can't be read until it runs: the generic
                        // mark, spoken as not read yet rather than as not set up.
                        JournalMarkView(mark: nil, isReadPending: true)
                        Button(localOnDiskAdoptionAction.buttonTitle) {
                            onDiskJournalAdoptionFlow.start(
                                discoveredPath: path,
                                observerName: appState.config.observerName,
                                action: localOnDiskAdoptionAction
                            )
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.createJournalThisMac)
                        .disabled(onDiskJournalAdoptionFlow.state.isBusy)

                        if onDiskJournalAdoptionFlow.state != .idle {
                            Text(onDiskJournalAdoptionFlow.state.ownerStatusMessage)
                                .font(.caption)
                                .foregroundStyle(freshJournalStatusColor(for: onDiskJournalAdoptionFlow.state))
                            if onDiskJournalAdoptionFlow.state.offersJournalAppDownload {
                                JournalAppDownloadLink()
                            }
                        }

                        localJournalPairButton

                    case .uncommitted:
                        Text(UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP)
                            .font(.headline)
                        JournalMarkView(mark: nil)
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryState,
                            value: LocalJournalDiscoveryAXState.notFound.axToken
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryPathState,
                            value: ""
                        )
                        localJournalPairButton

                    case .notOwnJournal:
                        Text(UICopy.LOCAL_JOURNAL_NOT_YOURS)
                            .font(.headline)
                        JournalMarkView(mark: nil)
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryState,
                            value: LocalJournalDiscoveryAXState.notFound.axToken
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryPathState,
                            value: ""
                        )
                        localJournalPairButton

                    case .none:
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryState,
                            value: LocalJournalDiscoveryAXState.notFound.axToken
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.localJournalDiscoveryPathState,
                            value: ""
                        )
                        AXStateCompanion(
                            id: AXID.Settings.Service.createJournalState,
                            value: freshFlow.state.axState.axToken
                        )
                        // journal-mark.md section 4.3 — the org-wide "no journal identity yet"
                        // treatment. Never an empty box, never hidden.
                        JournalMarkView(mark: nil)
                        Button(UICopy.CREATE_JOURNAL_ON_THIS_MAC) {
                            freshFlow.start()
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.createJournalThisMac)
                        .disabled(freshFlow.state.isBusy)

                        if freshFlow.state != .idle {
                            Text(freshFlow.state.ownerStatusMessage)
                                .font(.caption)
                                .foregroundStyle(freshJournalStatusColor(for: freshFlow.state))
                            if freshFlow.state.offersJournalAppDownload {
                                JournalAppDownloadLink()
                            }
                        }

                        localJournalPairButton
                    }
                }

                if let localLinkError {
                    Text(localLinkError)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let localLinkNotice {
                    Text(localLinkNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        if showPairingFlow {
            pairingSection
        }
    }

    var localJournalDiscoveryPanelModel: LocalJournalDiscoveryPanelModel {
        if let localJournalMark {
            return .foundRunning(localJournalMark)
        }
        if let localOnDiskDiscoveryPath {
            return .foundOnDisk(path: localOnDiskDiscoveryPath)
        }
        if localLinkNotice == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP {
            return .uncommitted
        }
        if localJournalIsNotYours {
            return .notOwnJournal
        }
        return .none
    }

    var localJournalPairButton: some View {
        Button("pair to a journal on another device") {
            showPairingFlow = true
        }
        .accessibilityIdentifier(AXID.Settings.Service.pairJournalAnotherDevice)
    }

    var journalMigrationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: appState.journalHandoffActive ? "arrow.triangle.2.circlepath" : "book.closed.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("your journal is getting its own app")
                    .font(.headline)
                Text("nothing moved. your journal was always here. you know it by its mark.")
                    .font(.callout)
                Text("segments are kept on this mac until your journal is back")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if journalHandoffOrchestrator.step != .idle || appState.journalHandoffActive {
                    Text(journalHandoffOrchestrator.step.ownerStatusMessage)
                        .font(.caption)
                        .foregroundStyle(journalHandoffStatusColor)
                    if journalHandoffOrchestrator.step.offersJournalAppDownload {
                        JournalAppDownloadLink()
                    }
                }
                AXStateCompanion(
                    id: AXID.Settings.Service.journalHandoffState,
                    value: journalHandoffOrchestrator.step.axState.axToken
                )
            }
            Spacer(minLength: 0)
            Button {
                journalHandoffOrchestrator.start(appState: appState)
            } label: {
                Label("start", systemImage: "arrow.right.circle")
            }
            .disabled(appState.journalHandoffActive)
            .accessibilityIdentifier(AXID.Settings.Service.journalHandoffStart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Settings.Service.journalHandoffBanner)
    }

    var journalHandoffStatusColor: Color {
        switch journalHandoffOrchestrator.step {
        case .failed, .aborted:
            return .red
        case .completed:
            return .green
        default:
            return .secondary
        }
    }

    func freshJournalStatusColor(for state: FreshJournalState) -> Color {
        switch state {
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    var resolvedJournalName: String {
        resolvedJournalDisplayName(
            isConfirmed: appState.isJournalMarkConfirmed,
            mark: appState.confirmedMark
        )
    }

    var journalLocationLabel: String {
        solstone.journalLocationLabel(
            isSameMacJournalDoor: isSameMacJournalDoor(
                sameMachineStoredPairingState: appState.tunnelLifecycleOwner.sameMachineStoredPairingState,
                serverURL: appState.config.serverURL
            )
        )
    }

    var journalConnectionPresentation: JournalConnectionVerdict {
        journalConnectionVerdictPresentation(
            tunnel: appState.tunnelLifecycleOwner.connectionVerdict,
            pairingMismatch: pairingMismatch
        )
    }

    var journalPanelAffordancesForPresentation: JournalPanelAffordances {
        let presentation = journalConnectionPresentation
        return journalPanelAffordances(
            for: journalPanelRemedy(
                failureCause: presentation.failureCause,
                axToken: presentation.axToken
            )
        )
    }

    var externalJournalSyncSection: some View {
        GroupBox("sync") {
            VStack(alignment: .leading, spacing: 8) {
                uploadStatusView
                Toggle("pause sync", isOn: Binding(
                    get: { appState.config.syncPaused },
                    set: { newValue in
                        var config = appState.config
                        config.syncPaused = newValue
                        appState.updateConfig(config)
                    }
                ))
                .help("keeps solstone running locally but stops sending to your journal")
                .accessibilityIdentifier(AXID.Settings.Status.pauseSync)
                lastDeliveryDetailRow
                if let error = appState.uploadCoordinator.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Status.lastErrorState)
                        .accessibilityValue(appState.uploadCoordinator.lastErrorReason ?? "")
                }
                Button("resync all") {
                    appState.uploadCoordinator.forceFullSync()
                }
                .help("re-check all days, including previously synced ones")
                .accessibilityIdentifier(AXID.Settings.Status.resyncAll)
                .disabled(!appState.isPairedIngestReady || appState.config.syncPaused)
            }
            .padding(.vertical, 4)
        }
    }

    var lastDeliveryDetailRow: some View {
        let outcome = appState.uploadCoordinator.lastJournalDeliveryOutcome
        return VStack(alignment: .leading, spacing: 2) {
            LabeledContent(UICopy.SETTINGS_LAST_DELIVERY_LABEL) {
                Text(diagnosticDeliveryValue(outcome, now: Date()))
                    .foregroundStyle(.secondary)
            }
            AXStateCompanion(
                id: AXID.Settings.Status.lastDeliveryState,
                value: outcome.diagnosticAXState.axToken
            )
            if case .delivered(let date) = outcome {
                AXStateCompanion(
                    id: AXID.Settings.Status.lastDeliveryTimestamp,
                    value: axIntegerString(Int(date.timeIntervalSince1970))
                )
            }
        }
    }

    var externalJournalStorageSection: some View {
        GroupBox("kept on this mac") {
            VStack(alignment: .leading) {
                 LabeledContent("currently using") {
                     if let used = storageUsedMB {
                         Text("\(used) MB")
                     } else {
                         ProgressView()
                             .scaleEffect(0.5)
                     }
                     AXStateCompanion(
                         id: AXID.Settings.Observer.storageUsedState,
                         value: storageUsedMB.map(axIntegerString) ?? ""
                     )
                 }
                 .padding(.vertical, 4)

                 LabeledContent("storage folder") {
                     Button("open in Finder") {
                         NSWorkspace.shared.open(appState.storageManager.baseDirectory)
                     }
                     .accessibilityIdentifier(AXID.Settings.Observer.cacheFolderOpen)
                 }
                 .padding(.vertical, 4)

                 Toggle("keep confirmed segments for debugging", isOn: preserveSyncedSegmentsBinding)
                     .accessibilityIdentifier(AXID.Settings.Observer.preserveSyncedSegments)
                     .padding(.vertical, 4)

                 Text("when on, segments your journal has confirmed are moved to a separate folder on this mac instead of being removed. they build up until you delete them yourself.")
                     .font(.caption)
                     .foregroundStyle(.secondary)

                 if appState.config.preserveSyncedSegments {
                     LabeledContent("preserved segments") {
                         Button("open in Finder") {
                             let folder = SyncService.preservedSegmentsDirectory(for: appState.storageManager)
                             try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                             NSWorkspace.shared.open(folder)
                         }
                         .accessibilityIdentifier(AXID.Settings.Observer.preservedFolderOpen)
                     }
                     .padding(.vertical, 4)
                 }
            }
        }
    }

    func navRow(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    func attentionRow(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(SolstoneColors.solOrange)
                    .accessibilityHidden(true)
                Text(text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SolstoneColors.solOrange.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    var pairingSection: some View {
        GroupBox("pairing") {
            VStack(alignment: .leading, spacing: 12) {
                if relinkNeedsPairingLink {
                    Text(UICopy.relinkNeedsPairingLink(address: journalAddressForOwner(appState.config.serverURL)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("pairing link").font(.caption).foregroundStyle(.secondary)
                    TextField(UICopy.PAIRING_LINK_PLACEHOLDER, text: $pairingLink)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AXID.Settings.Service.pairingLink)
                    if let error = appState.pendingPairingLinkError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    Button("pair") {
                        submitPairingLink()
                    }
                    .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingIsBusy)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingConnect)

                    if pairingIsBusy {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }

                pairingResultView

                if pairingMismatch {
                    if !appState.showsConfiguredJournal {
                        pairingMismatchPane
                    }
                } else if !appState.showsConfiguredJournal {
                    pairingConnectionTruthRow
                }

                if !appState.showsConfiguredJournal {
                    unknownJournalNotices
                }

                if !appState.showsConfiguredJournal {
                    pairingDisconnectControls
                }

                if case .switchConfirmPending = appState.pairingCoordinator.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pairingSwitchConfirmText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("switch") {
                                Task {
                                    await appState.pairingCoordinator.confirmSwitch()
                                }
                            }
                            .accessibilityIdentifier(AXID.Settings.Service.pairingSwitchConfirm)

                            Button("cancel") {
                                appState.pairingCoordinator.cancelSwitch()
                            }
                            .accessibilityIdentifier(AXID.Settings.Service.pairingSwitchCancel)
                        }
                    }
                }

                if appState.pairingCoordinator.state == .switchDeclined {
                    PairingSwitchNotChangedPane()
                }

                pairingFailureRow

                if !appState.showsConfiguredJournal {
                    tunnelErrorRetryRow
                }

            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    var carriedPairingMigrationPane: some View {
        if appState.pairingCoordinator.pendingMigrationDecision != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    migrationDecisionNotice
                }
            }
            .accessibilityIdentifier(AXID.Settings.Service.migrationChoiceRow)
        }
    }

    @ViewBuilder
    var migrationDecisionNotice: some View {
        switch appState.pairingCoordinator.migrationDecisionState ?? "decision_unknown" {
        case "deciding":
            Text(UICopy.Migration.decidingTitle)
        case "decision_refused":
            VStack(alignment: .leading, spacing: 6) {
                Text(UICopy.Migration.decisionRefusedTitle)
                Text(UICopy.Migration.decisionRefusedBody)
                Button(UICopy.Migration.technicalDetails) { openMigrationTechnicalDetails() }
            }
        case "storage_unavailable":
            VStack(alignment: .leading, spacing: 6) {
                Text(UICopy.Migration.storageUnavailableTitle)
                Text(UICopy.Migration.storageUnavailableBody)
                Button(UICopy.Migration.technicalDetails) { openMigrationTechnicalDetails() }
            }
        case "offline":
            VStack(alignment: .leading, spacing: 6) {
                Text(UICopy.Migration.offlineTitle)
                Text(UICopy.Migration.offlineBody)
                Button(UICopy.Migration.tryAgain) {
                    Task { await appState.pairingCoordinator.checkPendingMigrationDecision() }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text(UICopy.Migration.decisionUnknownTitle)
                Text(UICopy.Migration.decisionUnknownBody)
                Button(UICopy.Migration.checkAgain) {
                    Task { await appState.pairingCoordinator.checkPendingMigrationDecision() }
                }
                .accessibilityIdentifier(AXID.Settings.Service.migrationDecisionCheck)
            }
        }
    }

    @ViewBuilder
    var replacementFlowSheet: some View {
        if appState.pairingCoordinator.replacementPickerVisible {
            VStack(alignment: .leading, spacing: 12) {
                Text(UICopy.Migration.pickerTitle)
                    .font(.headline)
                if appState.pairingCoordinator.replacementListUnavailable {
                    Text(UICopy.Migration.listUnavailableTitle)
                    Text(UICopy.Migration.listUnavailableBody)
                    Button(UICopy.Migration.tryAgain) {
                        Task { await appState.pairingCoordinator.chooseAnotherReplacementDevice() }
                    }
                } else if appState.pairingCoordinator.replacementTargetMissing {
                    Text(UICopy.Migration.targetMissingTitle)
                    Text(UICopy.Migration.targetMissingBody)
                    Button(UICopy.Migration.chooseDevice) {
                        Task { await appState.pairingCoordinator.chooseAnotherReplacementDevice() }
                    }
                } else if appState.pairingCoordinator.replacementTargets.isEmpty {
                    Text(UICopy.Migration.pickerEmpty)
                } else {
                    ForEach(appState.pairingCoordinator.replacementTargets, id: \.cid) { target in
                        Button {
                            appState.pairingCoordinator.selectReplacementTarget(cid: target.cid)
                        } label: {
                            HStack {
                                Text(target.displayLabel)
                                Spacer()
                                if appState.pairingCoordinator.selectedReplacementCID == target.cid {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityValue(target.cid)
                    }
                    Button(UICopy.Migration.chooseDevice) {
                        replacementConfirmationPresented = true
                    }
                    .disabled(appState.pairingCoordinator.selectedReplacementCID == nil)
                    .accessibilityIdentifier(AXID.Settings.Service.migrationChooseDevice)
                    .confirmationDialog(
                        replacementConfirmationTitle,
                        isPresented: $replacementConfirmationPresented,
                        titleVisibility: .visible
                    ) {
                        Button(UICopy.Migration.replaceDevice, role: .destructive) {
                            Task { await appState.pairingCoordinator.confirmReplacement() }
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.migrationReplacementConfirm)
                        Button(UICopy.Migration.cancel, role: .cancel) {}
                    } message: {
                        Text(UICopy.Migration.replaceConfirmBody)
                    }
                }
                Button(UICopy.Migration.cancel) {
                    appState.pairingCoordinator.dismissReplacementPicker()
                }
                .accessibilityIdentifier(AXID.Settings.Service.pairingSwitchCancel)
            }
            .padding(24)
            .frame(minWidth: 360)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AXID.Settings.Service.migrationPicker)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(UICopy.Migration.replaceOfferTitle)
                    .font(.headline)
                Text(UICopy.Migration.replaceOfferBody)
                Button(UICopy.Migration.keepBoth) {
                    Task { await appState.pairingCoordinator.keepBothDevices() }
                }
                .accessibilityIdentifier(AXID.Settings.Service.migrationKeepBoth)
                Button(UICopy.Migration.chooseDevice) {
                    Task { await appState.pairingCoordinator.openReplacementPicker() }
                }
                .accessibilityIdentifier(AXID.Settings.Service.migrationChooseDevice)
                if appState.pairingCoordinator.replacementListUnavailable {
                    Text(UICopy.Migration.listUnavailableTitle)
                    Text(UICopy.Migration.listUnavailableBody)
                    Button(UICopy.Migration.tryAgain) {
                        Task { await appState.pairingCoordinator.openReplacementPicker() }
                    }
                }
                Button(UICopy.Migration.deferChoice) {
                    appState.pairingCoordinator.deferReplacementOffer()
                }
                .accessibilityIdentifier(AXID.Settings.Service.migrationChoiceDefer)
            }
            .padding(24)
            .frame(minWidth: 360)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AXID.Settings.Service.migrationReplacementOffer)
            .onAppear { appState.pairingCoordinator.markReplacementOfferShown() }
        }
    }

    var replacementConfirmationTitle: String {
        let label = appState.pairingCoordinator.replacementTargets.first {
            $0.cid == appState.pairingCoordinator.selectedReplacementCID
        }?.displayLabel
        guard let label, !label.isEmpty else { return UICopy.Migration.replaceConfirmTitleFallback }
        return UICopy.Migration.replaceConfirmTitle.replacingOccurrences(
            of: "{selected_device_label}",
            with: label
        )
    }

    func openMigrationTechnicalDetails() {
        navigate(.help)
        diagnosticsExpanded = true
    }

    @ViewBuilder
    var pairingDisconnectControls: some View {
        if pairingCanUnpair {
            if disconnectConfirmPending {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pairingDisconnectConfirmText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("disconnect", role: .destructive) {
                            disconnectPairing()
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.pairingDisconnectConfirm)

                        Button("cancel") {
                            disconnectConfirmPending = false
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.pairingDisconnectCancel)
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("disconnect") {
                        disconnectConfirmPending = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingUnpair)
                    .disabled(pairingIsBusy)
                }
            }
        }
    }

    @ViewBuilder
    var pairingResultView: some View {
        if let mark = appState.confirmedMark, pairingCanUnpair {
            JournalMarkView(mark: mark, isConfirmed: appState.isJournalMarkCompared)
        } else if let result = pairingResultText {
            LabeledContent("pairing") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.primary)
                    Text(result)
                }
            }
        }
    }

    @discardableResult
    func openEntitlementURL() -> Bool {
        guard let url = URL(string: "https://link.solstone.app") else {
            entitlementOpenFailed = true
            return false
        }
        if openURL(url) {
            entitlementOpenFailed = false
            return true
        } else {
            entitlementOpenFailed = true
            return false
        }
    }

    @discardableResult
    func openSupportMailto() -> Bool {
        guard let url = URL(string: "mailto:support@solstone.app") else {
            supportOpenFailed = true
            return false
        }
        if openURL(url) {
            supportOpenFailed = false
            return true
        } else {
            supportOpenFailed = true
            return false
        }
    }

    @ViewBuilder
    func configuredJournalRecoveryRow(for cause: JournalConnectionFailureCause?) -> some View {
        let action = journalConnectionRecoveryAction(for: cause)
        switch action {
        case .none, .mismatchFreshLinkAndSupport:
            EmptyView()
        case .reevaluatePairing:
            Button("retry") {
                Task {
                    await appState.reevaluateTunnelPairing()
                }
            }
            .disabled(pairingIsBusy)
            .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
        case .coalescedReconnect:
            Button("retry") {
                Task {
                    await appState.tunnelLifecycleOwner.requestCoalescedReconnect()
                }
            }
            .disabled(pairingIsBusy)
            .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
        case .retryRevokedRetirement:
            Button("retry") {
                Task {
                    await appState.retryRevokedPairingRetirement()
                }
            }
            .disabled(pairingIsBusy)
            .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
        case .paidPlan:
            Button("set up the paid plan ↗") {
                openEntitlementURL()
            }
            .font(.caption)
            .accessibilityIdentifier(AXID.Settings.Service.pairingPaidPlanLink)

            if entitlementOpenFailed {
                Text("https://link.solstone.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    var unknownJournalNotices: some View {
        UnknownJournalNoticeList(
            notices: appState.tunnelLifecycleOwner.unknownJournals.notices,
            yourJournal: appState.tunnelLifecycleOwner.unknownJournals.yourJournal,
            pairAgainDisabled: localLinkInProgress || pairingIsBusy,
            onPairAgain: openPastedLinkFlow
        )
    }

    var pairingMismatchPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UICopy.JOURNAL_MARK_MISMATCH_TITLE)
                .font(.headline)
            Text(UICopy.JOURNAL_MARK_MISMATCH_BODY)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(UICopy.JOURNAL_MARK_MISMATCH_FRESH_LINK) {
                    pairingMismatch = false
                    pairingLink = ""
                }
                .accessibilityIdentifier(AXID.Settings.Service.pairingMismatchFreshLink)

                Button(UICopy.JOURNAL_MARK_MISMATCH_SUPPORT) {
                    openSupportMailto()
                }
                .accessibilityIdentifier(AXID.Settings.Service.pairingMismatchSupport)
            }
            if supportOpenFailed {
                Text("support@solstone.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.Settings.Service.journalConnectionState)
        .accessibilityValue(PairingConnectionAXState.mismatch.axToken)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    var pairingConnectionTruthRow: some View {
        let presentation = journalConnectionPresentation
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("connection") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(presentation.severity.color)
                        .frame(width: 8, height: 8)
                    Text(presentation.message)
                        .foregroundStyle(presentation.severity.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.Settings.Service.journalConnectionState)
                .accessibilityValue(presentation.axToken)
            }
            if let caption = presentation.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if presentation.failureCause == .notEntitled {
                Button("set up the paid plan ↗") {
                    openEntitlementURL()
                }
                .font(.caption)
                .accessibilityIdentifier(AXID.Settings.Service.pairingPaidPlanLink)

                if entitlementOpenFailed {
                    Text("https://link.solstone.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    var pairingDisconnectConfirmText: String {
        if let mark = appState.confirmedMark {
            return "disconnect this mac from \(JournalMarkSlot.join(mark.words))? your journal keeps everything. you can pair again anytime."
        }
        return UICopy.PAIRING_DISCONNECT_CONFIRM
    }

    var pairingSwitchConfirmText: String {
        "this link is for a different journal. switch to it?"
    }

    @ViewBuilder
    var pairingFailureRow: some View {
        switch appState.pairingCoordinator.state {
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.message(address: appState.pairingCoordinator.failedAddress))
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("retry") {
                    submitPairingLink()
                }
                .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingIsBusy)
                .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
                AXStateCompanion(
                    id: AXID.Settings.Service.pairingFailureState,
                    value: failure.axToken
                )
            }
        case .saveFailed:
            VStack(alignment: .leading, spacing: 8) {
                Text(UICopy.PAIRING_SAVE_FAILED)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("retry") {
                    submitPairingLink()
                }
                .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingIsBusy)
                .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
            }
        case .idle, .pairing, .switchConfirmPending, .switchMarkPending, .switchDeclined, .paired, .alreadyConnected, .switched:
            EmptyView()
        }
    }

    @ViewBuilder
    var tunnelErrorRetryRow: some View {
        let failureCause = journalConnectionPresentation.failureCause
        let action = journalConnectionRecoveryAction(for: failureCause)
        if shouldShowPairingRetry(
            for: appState.pairingCoordinator.tunnelState,
            failureCause: failureCause
        ), !coordinatorShowsPairingRetry {
            HStack {
                Button("retry") {
                    Task {
                        switch action {
                        case .reevaluatePairing:
                            await appState.reevaluateTunnelPairing()
                        case .coalescedReconnect:
                            await appState.tunnelLifecycleOwner.requestCoalescedReconnect()
                        case .retryRevokedRetirement:
                            await appState.retryRevokedPairingRetirement()
                        default:
                            await appState.reevaluateTunnelPairing()
                        }
                    }
                }
                .disabled(pairingIsBusy)
                .accessibilityIdentifier(AXID.Settings.Service.pairingRetry)
            }
        }
    }

    var coordinatorShowsPairingRetry: Bool {
        switch appState.pairingCoordinator.state {
        case .failed, .saveFailed:
            return true
        default:
            return false
        }
    }

    var pairingResultText: String? {
        solstone.pairingResultText(
            for: appState.pairingCoordinator.state,
            isPairedHome: appState.isPairedHome,
            sameMachineHomeMigrationComplete: appState.sameMachineHomeMigrationComplete
        )
    }

    var pairingIsBusy: Bool {
        if case .pairing = appState.pairingCoordinator.state {
            return true
        }
        return false
    }

    var pairingCanUnpair: Bool {
        appState.tunnelLifecycleOwner.hasPersistedPairing || pairingResultText != nil
    }

    func submitPairingLink() {
        appState.pendingPairingLinkError = nil
        pairingMismatch = false
        journalMarkRederiveEligible = false
        journalMarkRederiveStarted = false
        relinkNeedsPairingLink = false
        journalMarkDriver.resetForNewPairAttempt()
        appState.recordDiagnosticEvidence(.pairingLinkSubmitted)
        Task { @MainActor in
            _ = await appState.submitPairingInput(pairingLink)
            if let code = pairingLinkEvidence(for: appState.pairingCoordinator.state) {
                appState.recordDiagnosticEvidence(code)
            }
        }
    }

    func disconnectPairing() {
        disconnectConfirmPending = false
        Task { @MainActor in
            let removed = await appState.pairingCoordinator.unpair()
            if removed {
                appState.clearConfirmedMark()
                pairingMismatch = false
                journalMarkRederiveEligible = false
                journalMarkRederiveStarted = false
                journalMarkDriver.resetForNewPairAttempt()
            }
        }
    }

    @ViewBuilder
    var externalServiceSection: some View {
        GroupBox("connection") {
            VStack(alignment: .leading, spacing: 12) {
                Link("setup guide: solstone.app/install", destination: URL(string: "https://solstone.app/install")!)
                    .font(.callout)
                    .accessibilityIdentifier(AXID.Settings.Service.externalSetupGuide)

                VStack(alignment: .leading, spacing: 4) {
                    Text("address").font(.caption).foregroundStyle(.secondary)
                    TextField("local address, name:port, or https://...", text: $observerURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AXID.Settings.Service.externalAddress)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("key").font(.caption).foregroundStyle(.secondary)
                    TextField("paste key from your journal", text: $observerKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AXID.Settings.Service.externalKey)
                }

                HStack {
                    Button("test connection") {
                        testServiceConnection()
                    }
                    .disabled(!appState.isPairedIngestReady || appState.connectionTestState == .testing)
                    .accessibilityIdentifier(AXID.Settings.Service.externalTestConnection)

                    Button("connect") {
                        let url = normalizeServerURL(observerURL)
                        saveService(url: url, key: observerKey, mode: .external)
                    }
                    .disabled(isConnectButtonDisabled(
                        observerURL: observerURL,
                        observerKey: observerKey,
                        connectionTestState: appState.connectionTestState
                    ))
                    .accessibilityIdentifier(AXID.Settings.Service.externalConnect)

                    if appState.connectionTestState == .testing {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        connectionTestIcon
                    }

                    AXStateCompanion(
                        id: AXID.Settings.Service.externalConnectionTestState,
                        value: appState.connectionTestState.axToken
                    )
                }

                if appState.connectionTestState == .success {
                    Button("view status →") {
                        navigate(.status)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AXID.Settings.Service.externalViewStatus)
                }
            }
            .padding(.vertical, 4)
        }
        Text("your memories are sent only to your configured journal. nothing else, nowhere else.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .onChange(of: observerURL) { _, _ in invalidateConnectionTestState() }
            .onChange(of: observerKey) { _, _ in invalidateConnectionTestState() }
    }

    /// Normalizes flexible journal address input to a full URL.
    /// Accepts: local names, name:port pairs, https:// addresses, and full URLs.
    func normalizeServerURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed.contains(":") ? trimmed : "\(trimmed):5015")"
    }

    // MARK: - Service Connection Logic

    func testServiceConnection() {
        let testGeneration = UUID()
        inFlightTestID = testGeneration
        appState.connectionTestState = .testing
        Task {
            let error = await appState.uploadCoordinator.testPairedIngestConnection()
            await MainActor.run {
                guard shouldApplyConnectionTestCompletion(
                    inFlightTestID: inFlightTestID,
                    testGeneration: testGeneration
                ) else {
                    return
                }
                inFlightTestID = nil
                if let error {
                    appState.connectionTestState = .failure(error)
                } else {
                    appState.connectionTestState = .success
                }
            }
        }
    }

    func invalidateConnectionTestState() {
        inFlightTestID = nil
        appState.connectionTestState = .idle
    }

    func saveService(url: String, key: String, mode: ServiceMode) {
        var config = appState.config
        config.serverURL = url
        config.serverKey = key
        config.serviceMode = mode
        appState.clearLastSuccessfulJournalContact()
        appState.updateConfig(config)
        Task {
            await appState.capture.checkPermissionsAndAutoStart()
            Task.detached { await appState.uploadCoordinator?.syncOnStartup() }
        }
    }

    func refreshLocalJournalDiscoveryIfNeeded() {
        guard shouldProbeLocalJournal(
            isUploadConfigured: appState.config.isUploadConfigured,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            localDiscoveryCompleted: localDiscoveryCompleted,
            journalPathIsValid: journalPathIsValid
        ) else {
            if appState.tunnelLifecycleOwner.hasPersistedPairing {
                localDiscoveryTask?.cancel()
                localDiscoveryTask = nil
                localDiscoveryInFlight = false
                localJournalMark = nil
                localOnDiskDiscoveryPath = nil
                localOnDiskAdoptionAction = .install
                localDiscoveryCompleted = false
            }
            return
        }
        localDiscoveryTask?.cancel()
        localDiscoveryCompleted = false
        localJournalMark = nil
        localOnDiskDiscoveryPath = nil
        localOnDiskAdoptionAction = .install
        localLinkError = nil
        localJournalIsNotYours = false
        localDiscoveryInFlight = true
        localDiscoveryTask = Task { @MainActor in
            let model = await discoverLocalJournalPanelModel(
                fetchIdentity: localIdentityFetch,
                onDiskDiscovery: onDiskJournalDiscovery
            )
            guard !Task.isCancelled else { return }
            switch model {
            case .foundRunning(let mark):
                localJournalMark = mark
            case .uncommitted:
                localLinkNotice = UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
                localJournalMark = nil
                localOnDiskDiscoveryPath = nil
            case .notOwnJournal:
                localJournalIsNotYours = true
                localJournalMark = nil
                localOnDiskDiscoveryPath = nil
            case .foundOnDisk(let path):
                let action = await onDiskJournalAdoptionFlow.resolveOfferAction()
                guard !Task.isCancelled else { return }
                localOnDiskDiscoveryPath = path
                localOnDiskAdoptionAction = action
            case .none:
                break
            }
            localDiscoveryCompleted = true
            localDiscoveryInFlight = false
            lastProbeFinishedAt = Date()
        }
    }

    func reprobeLocalJournalOnReturn() {
        guard shouldReprobeLocalJournalOnReturn(
            showsConfiguredJournal: appState.showsConfiguredJournal,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            runningJournalFound: localJournalMark != nil,
            localLinkInProgress: localLinkInProgress,
            freshJournalWaiting: freshFlow.state == .waitingForJournal,
            discoveryInFlight: localDiscoveryInFlight,
            lastProbeFinishedAt: lastProbeFinishedAt,
            now: Date()
        ) else {
            return
        }

        localDiscoveryTask?.cancel()
        localDiscoveryInFlight = true
        localDiscoveryTask = Task { @MainActor in
            let probeResult = await discoverLocalJournalPanelModel(
                fetchIdentity: localIdentityFetch,
                onDiskDiscovery: onDiskJournalDiscovery
            )
            guard !Task.isCancelled else { return }

            let nextModel = reprobedLocalJournalPanelModel(
                current: localJournalDiscoveryPanelModel,
                probeResult: probeResult
            )
            switch nextModel {
            case .foundRunning(let mark):
                localJournalMark = mark
                localOnDiskDiscoveryPath = nil
                localOnDiskAdoptionAction = .install
            case .uncommitted:
                localLinkNotice = UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP
                localJournalMark = nil
                localOnDiskDiscoveryPath = nil
            case .notOwnJournal:
                localJournalIsNotYours = true
                localJournalMark = nil
                localOnDiskDiscoveryPath = nil
            case .foundOnDisk(let path):
                let action = await onDiskJournalAdoptionFlow.resolveOfferAction()
                guard !Task.isCancelled else { return }
                if localOnDiskDiscoveryPath != path {
                    localOnDiskDiscoveryPath = path
                }
                if localOnDiskAdoptionAction != action {
                    localOnDiskAdoptionAction = action
                }
            case .none:
                localJournalIsNotYours = false
            }
            localDiscoveryInFlight = false
            lastProbeFinishedAt = Date()
        }
    }

    func relinkJournal() {
        resetForJournalRelink(appState: appState, journalMarkDriver: journalMarkDriver)
        appState.recordDiagnosticEvidence(.pairingRelinkStarted)
        localLinkError = nil
        localLinkNotice = nil
        if BundledJournalEndpoint.isBundledServiceURL(appState.config.serverURL) ||
            appState.config.serviceMode == .bundled {
            confirmLocalJournalLink()
        } else {
            openPastedLinkFlow()
        }
    }

    /// Asks for a pasted link and changes nothing else, so the pairing in use and its mark stand
    /// until a link actually lands.
    func openPastedLinkFlow() {
        appState.recordDiagnosticEvidence(.pairingRelinkNeedsPairingLink)
        localLinkError = nil
        localLinkNotice = nil
        relinkNeedsPairingLink = true
        showPairingFlow = true
    }

    func confirmLocalJournalLink() {
        localLinkInProgress = true
        localLinkError = nil
        localLinkNotice = nil
        relinkNeedsPairingLink = false

        Task { @MainActor in
            let outcome = await runSettingsSameComputerLink(
                appState: appState,
                journalMarkDriver: journalMarkDriver,
                startPairing: sameMachinePairStart,
                localIdentity: localIdentityFetch
            )
            localLinkInProgress = false
            showPairingFlow = outcome.offersPairingLink
            switch outcome.tone {
            case .notice:
                localLinkNotice = outcome.message
                localDiscoveryCompleted = true
            case .error:
                localLinkError = outcome.message
            }
        }
    }

    // MARK: - Microphone Tab

    var microphoneDisplayEntries: [MicrophoneDisplayEntry] {
        let _ = appState.audioDeviceMonitor.layoutRefreshGeneration
        let available = appState.audioDeviceMonitor.availableDevices
        let availableByUID = Dictionary(uniqueKeysWithValues: available.map { ($0.uid, $0) })
        let bluetoothUIDs = Set(available.filter { $0.transportType == .bluetooth }.map { $0.uid })
        return appState.config.microphonePriority.map { entry in
            let device = availableByUID[entry.uid]
            let isConnected = device != nil
            let layoutResult = device.map { MicrophoneMonitor.readLayout(deviceID: $0.id) }
            let interfaceState: MicrophoneInterfaceState
            let layout: MicrophoneMonitor.MicrophoneLayout?
            if let device, let layoutResult {
                interfaceState = classifyMicrophone(device: device, choice: entry.choice, layoutResult: layoutResult)
                if case .available(let l) = layoutResult {
                    layout = l
                } else {
                    layout = nil
                }
            } else {
                interfaceState = .admitted
                layout = nil
            }
            return MicrophoneDisplayEntry(
                from: entry,
                isConnected: isConnected,
                isBluetooth: bluetoothUIDs.contains(entry.uid),
                interfaceState: interfaceState,
                layout: layout
            )
        }
    }

    var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("microphone priority") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UICopy.MICROPHONES_LIST_CAPTION)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if microphoneDisplayEntries.isEmpty {
                        emptyMicrophoneView(
                            classifyMicrophoneEmptyState(
                                authorizationCause: appState.microphoneAuthorizationCause
                            )
                        )
                    } else {
                        List {
                            ForEach(microphoneDisplayEntries) { entry in
                                MicrophoneRow(
                                    entry: entry,
                                    onDelete: { deleteMicrophone(uid: entry.uid) },
                                    onToggleDisabled: { toggleMicrophoneDisabled(uid: entry.uid) },
                                    onSelectMode: { setMicrophoneMode(uid: entry.uid, mode: $0) },
                                    onSelectChoice: { selectMicrophoneChoice(uid: entry.uid, choice: $0) },
                                    onRetry: { retryMicrophoneLayout(uid: entry.uid) }
                                )
                            }
                            .onMove { from, to in
                                moveMicrophones(from: from, to: to)
                            }
                        }
                        .listStyle(.bordered)
                        .accessibilityIdentifier(AXID.Settings.Microphones.priorityList)
                        .frame(minHeight: 120, maxHeight: 200)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("microphone gain") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("boost microphone input level. changes take effect immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("gain", selection: microphoneGainBinding) {
                        ForEach([1, 2, 4, 8], id: \.self) { value in
                            Text("\(value)x").tag(Float(value))
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(AXID.Settings.Microphones.gainPicker)
                    AXStateCompanion(
                        id: AXID.Settings.Microphones.gainState,
                        value: axIntegerString(Int(snapGain(appState.config.microphoneGain).rounded()))
                    )
                    Text("stronger boost can pick up more background noise in quiet rooms.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .onAppear {
            refreshMicrophoneEmptyState()
        }
    }

    var audioProcessingGroup: some View {
        GroupBox("audio processing") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("silence music in system audio", isOn: silenceMusicBinding)
                    .help("silences background music when nobody's talking")
                    .accessibilityIdentifier(AXID.Settings.Microphones.silenceMusic)

                Text("silences portions of system audio where music is detected but no speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }


    func refreshMicrophoneEmptyState() {
        if microphoneDisplayEntries.isEmpty && appState.audioDeviceMonitor.availableDevices.count > 0 {
            appState.syncMicrophonePriorityList()
        }
    }

    @ViewBuilder
    func emptyMicrophoneView(_ emptyState: MicrophoneEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch emptyState {
            case .access:
                Text(UICopy.MICROPHONES_EMPTY_ACCESS_DESCRIPTION)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(UICopy.MICROPHONES_EMPTY_OPEN_PERMISSIONS) {
                    navigate(.permissions)
                    openMicrophoneSettings()
                }
                .accessibilityIdentifier(AXID.Settings.Microphones.emptyPermissions)
            case .connect:
                Text(UICopy.MICROPHONES_EMPTY_TITLE)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(UICopy.MICROPHONES_EMPTY_CONNECT_DESCRIPTION)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(UICopy.MICROPHONES_EMPTY_OPEN_SOUND) {
                    NSWorkspace.shared.open(MicrophoneEmptyState.soundSettingsURL)
                }
                .accessibilityIdentifier(AXID.Settings.Microphones.emptySound)
            case .couldNotCheck:
                Text(UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Settings.Microphones.empty)
    }

    func snapGain(_ value: Float) -> Float {
        let stops: [Float] = [1, 2, 4, 8]
        var best = stops[0]
        var bestDistance = abs(value - best)

        for stop in stops.dropFirst() {
            let distance = abs(value - stop)
            if distance < bestDistance || (distance == bestDistance && stop > best) {
                best = stop
                bestDistance = distance
            }
        }

        return best
    }

    var microphoneGainBinding: Binding<Float> {
        Binding(
            get: { snapGain(appState.config.microphoneGain) },
            set: { newValue in
                var config = appState.config
                config.microphoneGain = snapGain(newValue)
                appState.updateConfig(config)
            }
        )
    }

    var silenceMusicBinding: Binding<Bool> {
        Binding(
            get: { appState.config.silenceMusic },
            set: { newValue in
                var config = appState.config
                config.silenceMusic = newValue
                appState.updateConfig(config)
            }
        )
    }

    func moveMicrophones(from: IndexSet, to: Int) {
        var newConfig = appState.config
        newConfig.reorderMicrophones(fromOffsets: from, toOffset: to)
        appState.updateConfig(newConfig)
    }

    func deleteMicrophone(uid: String) {
        var newConfig = appState.config
        _ = newConfig.removeMicrophone(uid: uid)
        appState.updateConfig(newConfig)
    }

    func toggleMicrophoneDisabled(uid: String) {
        var newConfig = appState.config
        newConfig.toggleMicrophoneDisabled(uid: uid)
        appState.updateConfig(newConfig)
    }

    func setMicrophoneMode(uid: String, mode: MicrophoneEntry.Mode) {
        var newConfig = appState.config
        newConfig.setMicrophoneMode(uid: uid, mode: mode)
        appState.updateConfig(newConfig)
    }

    func selectMicrophoneChoice(uid: String, choice: MicrophoneChoice) {
        var config = appState.config
        if config.setMicrophoneChoice(uid: uid, choice: choice) {
            appState.updateConfig(config)
        }
    }

    func retryMicrophoneLayout(uid: String) {
        appState.retryMicrophoneLayout(uid: uid)
    }

    // MARK: - Privacy Tab

    func privacyTab(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            excludedAppsGroup
            titlePatternsGroup
            websitesGroup(scrollProxy: scrollProxy)
            protectedVideoGroup
            privateBrowsingGroup(scrollProxy: scrollProxy)
        }
        .padding(.vertical, 4)
    }

    var excludedAppsGroup: some View {
        GroupBox("excluded apps") {
            VStack(alignment: .leading, spacing: 8) {
                Text("windows from these apps are always excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.config.excludedApps.isEmpty {
                    Text("no apps excluded")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(appState.config.excludedApps.enumerated()), id: \.offset) { index, app in
                            HStack {
                                Text(app.name)
                                Spacer()
                                Button(action: { deleteExcludedApp(at: index) }) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("remove app")
                                .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppRemove(app.name))
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier(AXID.Settings.Privacy.excludedApp(app.name))
                            .accessibilityValue(app.name)
                        }
                    }
                    .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppsList)
                }

                let pickerEvaluation = ExcludedAppPicker.evaluate(
                    screenRecordingGranted: appState.screenRecordingGranted,
                    records: OnScreenWindowList.onScreenLayer0Windows(),
                    alreadyExcludedNames: appState.config.excludedApps.map(\.name)
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("currently open apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    switch pickerEvaluation.availability {
                    case .needsScreenRecording:
                        Text("grant access to see open apps")
                            .foregroundStyle(.secondary)
                    case .nothingAvailable:
                        Text("nothing available right now")
                            .foregroundStyle(.secondary)
                    case .ready:
                        Picker("", selection: Binding<String?>(
                            get: { nil },
                            set: { if let app = $0 { addExcludedApp(name: app) } }
                        )) {
                            Text("choose an open app…").tag(String?.none)
                            ForEach(pickerEvaluation.candidateNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppsPicker)
                    }

                    AXStateCompanion(
                        id: AXID.Settings.Privacy.excludedAppsPickerState,
                        value: pickerEvaluation.availability.axToken
                    )
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("exact window-server name", text: $newExcludedApp)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExcludedApp() }
                            .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppField)
                        Button("add") { addExcludedApp() }
                            .disabled(newExcludedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppAdd)
                    }
                    Text("typed names only take effect if they exactly match the name the app reports while running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        }
    }

    var titlePatternsGroup: some View {
        GroupBox("title patterns") {
            VStack(alignment: .leading, spacing: 8) {
                Text("hide windows whose title contains these keywords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.config.excludedTitlePatterns.isEmpty {
                    Text("no patterns added")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(appState.config.excludedTitlePatterns.enumerated()), id: \.offset) { index, pattern in
                            HStack {
                                Text(pattern)
                                Spacer()
                                Button(action: { deleteTitlePattern(at: index) }) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("remove pattern")
                                .accessibilityIdentifier(AXID.Settings.Privacy.titlePatternRemove(pattern))
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier(AXID.Settings.Privacy.titlePattern(pattern))
                            .accessibilityValue(pattern)
                        }
                    }
                    .accessibilityIdentifier(AXID.Settings.Privacy.titlePatternsList)
                }

                HStack {
                    TextField("reddit, facebook, etc.", text: $newTitlePattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTitlePattern() }
                        .accessibilityIdentifier(AXID.Settings.Privacy.titlePatternField)
                    Button("add") { addTitlePattern() }
                        .disabled(newTitlePattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier(AXID.Settings.Privacy.titlePatternAdd)
                }
            }
            .padding(.vertical, 4)
        }
    }

    func websitesGroup(scrollProxy: ScrollViewProxy) -> some View {
        GroupBox("websites you leave out") {
            VStack(alignment: .leading, spacing: 8) {
                Text(UICopy.Websites.DESCRIPTION_PARAGRAPH_1)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.siteAccessibilityCaution {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(UICopy.Websites.accessibilityCaution(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(UICopy.Websites.OPEN_SYSTEM_SETTINGS) {
                            appState.askForAccessibility()
                        }
                        .accessibilityIdentifier(AXID.Settings.Privacy.websiteAllowAccessibility)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AXID.Settings.Privacy.websiteAccessibilityCaution)
                }

                if appState.siteSafariCaution {
                    Text(UICopy.Websites.browserCaution(browser: "Safari"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Privacy.websiteBrowserCaution)
                }

                if appState.config.excludedSites.isEmpty {
                    Text("no websites left out")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(appState.config.excludedSites.enumerated()), id: \.offset) { index, site in
                            HStack {
                                Text(site)
                                Spacer()
                                Button(action: { appState.removeExcludedSite(site) }) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("stop leaving out")
                                .accessibilityIdentifier(AXID.Settings.Privacy.websiteRemove(site))
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier(AXID.Settings.Privacy.websiteSite(site))
                            .accessibilityValue(site)
                        }
                    }
                    .accessibilityIdentifier(AXID.Settings.Privacy.websitesList)
                }

                HStack {
                    TextField("bank.com", text: $newWebsite)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addWebsite() }
                        .onChange(of: newWebsite) { websiteError = nil }
                        .accessibilityIdentifier(AXID.Settings.Privacy.websiteField)
                    Button("leave out") { addWebsite() }
                        .disabled(newWebsite.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier(AXID.Settings.Privacy.websiteAdd)
                }

                if let websiteError {
                    Text(websiteError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(AXID.Settings.Privacy.websiteFieldError)
                }

                DisclosureGroup(UICopy.Websites.HOW_THIS_WORKS) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UICopy.Websites.DESCRIPTION_PARAGRAPH_2)
                        Text(UICopy.Websites.LIMITS_DISCLOSURE)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier(AXID.Settings.Privacy.websiteLimits)
            }
            .padding(.vertical, 4)
        }
        .id(AXID.Settings.Privacy.websitesList + ".group")
        .task(id: appState.pendingWebsiteSettingsTarget) {
            guard appState.pendingWebsiteSettingsTarget != nil else { return }
            await Task.yield()
            guard !Task.isCancelled, leftOutShowing else { return }
            scrollProxy.scrollTo(AXID.Settings.Privacy.websitesList + ".group", anchor: .top)
            appState.pendingWebsiteSettingsTarget = nil
        }
    }

    var protectedVideoGroup: some View {
        GroupBox("protected video") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("pause intake while protected video is on screen", isOn: pauseProtectedVideoBinding)
                    .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideo)
                Text("pauses screen and audio intake while supported streaming video apps or websites are visible, so the video doesn't go black. a short note of the service and window title goes into your journal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.config.protectedVideoTitlePatterns.isEmpty {
                    Text("no patterns added")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(appState.config.protectedVideoTitlePatterns.enumerated()), id: \.offset) { index, pattern in
                            HStack {
                                Text(pattern)
                                Spacer()
                                Button(action: { deleteProtectedVideoPattern(at: index) }) {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("remove pattern")
                                .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideoPatternRemove(pattern))
                            }
                            .padding(.vertical, 2)
                            .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideoPattern(pattern))
                            .accessibilityValue(pattern)
                        }
                    }
                    .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideoPatternsList)
                }

                HStack {
                    TextField("mubi", text: $newProtectedVideoPattern)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProtectedVideoPattern() }
                        .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideoPatternField)
                    Button("add") { addProtectedVideoPattern() }
                        .disabled(newProtectedVideoPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier(AXID.Settings.Privacy.protectedVideoPatternAdd)
                }
            }
            .padding(.vertical, 4)
        }
    }

    func privateBrowsingGroup(scrollProxy: ScrollViewProxy) -> some View {
        GroupBox("private browsing") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("keep private windows out of your journal: Firefox set to English", isOn: excludePrivateBrowsingBinding)
                    .help("reads the window title and matches private windows in Firefox set to English. Safari, Chrome, Edge and Brave don't show private mode in that title; the option below checks them another way. other browsers are not matched, so their private windows reach your journal. to keep every window of a browser out of your journal, add that browser to the excluded apps.")
                    .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsing)
                Text("this reads the window title and keeps Firefox private windows out of your journal. a new Firefox window is kept out of your journal for a moment while it is checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("details") {
                    Text("checked on Firefox 157 set to English; a browser update or another language can change a title, and then a private window there may reach your journal. a web page can end its own title the way Firefox marks a private window, and then an ordinary Firefox window showing it is kept out too. Safari, Chrome, Edge and Brave don't show private mode in that title; the option below checks them another way. other browsers are not matched, so their private windows reach your journal. to keep every window of a browser out of your journal, add that browser to the excluded apps above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("also check Safari, Chrome, Edge and Brave", isOn: excludePrivateBrowsingAccessibilityBinding)
                        .disabled(!appState.config.excludePrivateBrowsing)
                        .focused($privateWindowKeyboardFocused)
                        .accessibilityFocused($privateWindowAccessibilityFocused)
                        .accessibilityHint("turning this on asks for Accessibility access. solstone uses it to read these browsers' window titles and to check that the access works. allowing it also lets activity add browser addresses to your journal, unless you turn that off under activity.")
                        .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsingAccessibility)
                    Text(Self.privateWindowAccessibilityExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("details") {
                        Text("checked on Safari 27, Chrome 154, Edge 154 and Brave 1.96 set to English; a browser update or another language can change a title, and then a private window there may reach your journal. a new window from these browsers is kept out of your journal for a moment while it is checked. turning this off stops the reads; to remove the access too, turn solstone off in System Settings, under Privacy & Security, in Accessibility (Device Control and Data Access on macOS 27).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)

                    if privateWindowAccessibilityState != .off {
                        privateWindowAccessibilityStatus
                    }
                    AXStateCompanion(
                        id: AXID.Settings.Privacy.privateBrowsingAccessibilityState,
                        value: privateWindowAccessibilityState.axToken
                    )
                }
                .padding(.leading, 20)
                .padding(.top, 8)
                .id(AXID.Settings.Privacy.privateBrowsingAccessibility)
                .task(id: appState.pendingPrivateWindowSettingsTarget) {
                    guard let target = appState.pendingPrivateWindowSettingsTarget else { return }
                    await Task.yield()
                    guard !Task.isCancelled, leftOutShowing,
                          appState.pendingPrivateWindowSettingsTarget == target else { return }
                    scrollProxy.scrollTo(AXID.Settings.Privacy.privateBrowsingAccessibility, anchor: .center)
                    privateWindowKeyboardFocused = true
                    privateWindowAccessibilityFocused = true
                    appState.pendingPrivateWindowSettingsTarget = nil
                }
            }
            .padding(.vertical, 4)
            .onChange(of: privateWindowAccessibilityState) { _, state in
                if let message = privateWindowAnnouncements.observe(state, isVisible: privateWindowPrivacyIsVisible) {
                    diagnosticAnnouncement(message)
                }
            }
        }
    }


    static let privateWindowAccessibilityExplanation = "this needs Accessibility access (called Device Control and Data Access on macOS 27). solstone uses it to read the window titles these browsers give to accessibility tools, and to check that the access works. allowing it also lets activity add browser addresses to your journal, unless you turn that off under activity. turning this on asks for it."

    @ViewBuilder
    var privateWindowAccessibilityStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch privateWindowAccessibilityState {
            case .checking:
                Label(UICopy.PRIVATE_WINDOWS_CHECKING, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .waiting:
                if appState.privateWindowAccessibilityMonitor.needsAttention {
                    Text(UICopy.SETTINGS_ATTENTION_PRIVATE_WINDOWS)
                        .font(.caption)
                }
                Label {
                    Text("waiting for Accessibility access. allow solstone in System Settings; it asks for your mac's password. until then, private windows in Safari, Chrome, Edge and Brave reach your journal.")
                } icon: {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    Button("open System Settings") { AccessibilityTitleReader.openSystemSettings() }
                        .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsingAccessibilityOpenSettings)
                    Button("already allowed? reopen solstone") { relaunchApp() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsingAccessibilityReopen)
                }
            case .working:
                Label {
                    Text("on: solstone can read these browsers' window titles, so their private windows are kept out of your journal.")
                } icon: {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
                .font(.caption)
            case .notWorking:
                Label {
                    Text(UICopy.SETTINGS_ATTENTION_PRIVATE_WINDOWS)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.caption)
                Text("their private windows reach your journal.")
                    .font(.caption)
                HStack {
                    Button("open System Settings") { AccessibilityTitleReader.openSystemSettings() }
                        .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsingAccessibilityOpenSettings)
                    Button("already allowed? reopen solstone") { relaunchApp() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsingAccessibilityReopen)
                }
                Text("if solstone is on in System Settings and reopening doesn't help, remove solstone from that list with the minus button, then turn this option off and on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .off:
                EmptyView()
            }
        }
        .padding(.top, 2)
    }

    internal var privateWindowAccessibilityState: PrivateWindowAccessibilityState {
        appState.privateWindowAccessibilityEnabled ? appState.privateWindowAccessibilityMonitor.state : .off
    }

    var privateWindowPrivacyIsVisible: Bool {
        leftOutShowing && !NSApp.isHidden && NSApp.windows.contains {
            $0.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
                && $0.isVisible && !$0.isMiniaturized
        }
    }

    internal var excludePrivateBrowsingAccessibilityBinding: Binding<Bool> {
        Binding(
            get: { appState.config.excludePrivateBrowsing && appState.config.excludePrivateBrowsingAccessibility },
            set: { newValue in
                let shouldAsk = newValue && !appState.privateWindowAccessibilityEnabled
                if shouldAsk { appState.privateWindowAccessibilityMonitor.prepareForOwnerEnable() }
                var config = appState.config
                config.excludePrivateBrowsingAccessibility = newValue
                appState.updateConfig(config)
                // The only place solstone ever asks for Accessibility access: the owner turning this on.
                if shouldAsk {
                    appState.requestPrivateWindowAccessibility()
                }
            }
        )
    }

    var excludePrivateBrowsingBinding: Binding<Bool> {
        Binding(
            get: { appState.config.excludePrivateBrowsing },
            set: { newValue in
                var config = appState.config
                config.excludePrivateBrowsing = newValue
                appState.updateConfig(config)
            }
        )
    }

    func addTitlePattern() {
        let pattern = newTitlePattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }

        var config = appState.config
        if !config.excludedTitlePatterns.contains(where: { $0.lowercased() == pattern.lowercased() }) {
            config.excludedTitlePatterns.append(pattern)
            appState.updateConfig(config)
        }
        newTitlePattern = ""
    }

    func deleteTitlePattern(at index: Int) {
        var config = appState.config
        config.excludedTitlePatterns.remove(at: index)
        appState.updateConfig(config)
    }

    func addWebsite() {
        let input = newWebsite.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        Task { @MainActor in
            if let error = await appState.addExcludedSite(input) {
                websiteError = error
            } else {
                websiteError = nil
                newWebsite = ""
            }
        }
    }

    var pauseProtectedVideoBinding: Binding<Bool> {
        Binding(
            get: { appState.config.pauseForProtectedVideo },
            set: { newValue in
                var config = appState.config
                config.pauseForProtectedVideo = newValue
                appState.updateConfig(config)
            }
        )
    }

    func addProtectedVideoPattern() {
        let pattern = newProtectedVideoPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        appState.addProtectedVideoTitlePattern(pattern)
        newProtectedVideoPattern = ""
    }

    func deleteProtectedVideoPattern(at index: Int) {
        guard index >= 0, index < appState.config.protectedVideoTitlePatterns.count else { return }
        let pattern = appState.config.protectedVideoTitlePatterns[index]
        appState.removeProtectedVideoTitlePattern(pattern)
    }

    func addExcludedApp(name: String? = nil) {
        let rawName = name ?? newExcludedApp
        let updated = ExcludedAppPicker.appending(rawName, to: appState.config.excludedApps)
        if updated.count != appState.config.excludedApps.count {
            var config = appState.config
            config.excludedApps = updated
            appState.updateConfig(config)
        }
        newExcludedApp = ""
    }

    func deleteExcludedApp(at index: Int) {
        var config = appState.config
        config.excludedApps.remove(at: index)
        appState.updateConfig(config)
    }

    // MARK: - Status Tab

    /// True when the health card above has already claimed the source state as its verdict and
    /// this group would render an empty box under its own heading.
    var statusGroupIsFullyClaimedByVerdict: Bool {
        guard !appState.isRecording, !appState.isPaused, appState.config.selectedSources.isEmpty,
              appState.obsidianSource?.isOn != true else {
            return false
        }
        return observationRecoveryPresentation(
            observationRowState: appState.observationRowState,
            errorMessage: appState.errorMessage,
            tryAgainInFlight: tryAgainInFlight,
            uploadStatus: appState.uploadCoordinator.status
        ) == nil
    }

    var renderedObservationAXState: SettingsObservationAXState {
        SettingsObservationAXState(appState.observationRowState)
    }

    var renderedObservationText: String {
        if renderedObservationAXState == .protectedVideo {
            return UICopy.SETTINGS_OBSERVATION_PROTECTED_VIDEO
        }
        if appState.isRecording || appState.isPaused || appState.errorMessage == nil {
            return appState.captureSourcesStatusText
        }
        return renderedObservationAXState.headline
    }

    var storageGlanceText: String {
        if let storageUsedMB {
            return "\(storageUsedMB) MB"
        }
        return "calculating"
    }

    var statusFooterText: String {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        sourcesFooter(media: appState.captureSourcesStatusText, lead: sourcesLead)
#else
        appState.captureSourcesStatusText
#endif
    }

    var setupTopology: SetupTopology {
        classifySetupTopology(
            serviceMode: appState.config.serviceMode,
            serverURL: appState.config.serverURL,
            isTunnelManaged: appState.tunnelLifecycleOwner.isTunnelManaged,
            isPairedHome: appState.isPairedHome
        )
    }

    var setupSnapshotPresentation: SetupSnapshotPresentation {
        let screenOutcome = PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            screenRecordingGranted: appState.screenRecordingGranted,
            hasPromptedScreenRecording: setupProbeSnapshot.hasPromptedScreenRecording,
            preflightSucceeded: setupProbeSnapshot.screenDiagnostic?.preflightSucceeded,
            sckFailedAfterPositivePreflight: setupProbeSnapshot.screenDiagnostic?.sckFailedAfterPositivePreflight ?? false
        )
        let microphoneOutcome = PermissionOutcome.microphone(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            cause: appState.microphoneAuthorizationCause
        )
        return buildSetupSnapshot(SetupSnapshotInput(
            topology: setupTopology,
            solAppPlacement: setupProbeSnapshot.solAppPlacement,
            journalAppInstalled: setupProbeSnapshot.journalAppInstalled,
            serviceIsDone: appState.serviceIsDone,
            screenRecording: screenOutcome,
            microphone: microphoneOutcome,
            lastDeliveryOutcome: primaryLastDeliveryOutcome,
            now: Date(),
            selectedSources: appState.config.selectedSources,
            activeSources: appState.isRecording || appState.isPaused ? appState.captureManager.activeSources : []
        ))
    }

    var primaryLastDeliveryOutcome: LastJournalDeliveryOutcome {
        appState.serviceIsDone ? appState.uploadCoordinator.lastJournalDeliveryOutcome : .notLinked
    }

    var statusHealthSummary: StatusHealthSummary {
        let setupPresentation = setupSnapshotPresentation
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        return StatusHealthSummary.makeIncludingBrowser(
            serviceMode: appState.config.serviceMode,
            isRecording: appState.isRecording || appState.nonMediaIntakeState == .active,
            isPaused: appState.isPaused || (appState.config.selectedSources.isEmpty && appState.nonMediaIntakeState == .paused),
            ownerPauseHeldIdle: appState.ownerPauseHeldIdle,
            held: appState.needsJournalMarkConfirmation,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: appState.uploadCoordinator.presentedStatus,
            pendingCount: appState.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: statusPrimaryDelivery(
                media: appState.uploadCoordinator.lastJournalDeliveryOutcome,
                browserDelivery: appState.browserHostSnapshot.value.delivery
            ),
            journalSlot: resolvedJournalName,
            now: Date(),
            selectedSources: appState.config.selectedSources,
            otherSourceOn: appState.nonMediaIntakeState != .off,
            permittedSources: appState.capture.permittedSources,
            errorMessage: appState.errorMessage,
            setupVerdict: setupPresentation.verdict,
            lastHealthReason: appState.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: appState.isPairedIngestReady,
            presentedConnection: appState.tunnelLifecycleOwner.presentedConnection,
            startDeferredForProtectedVideo: appState.capture.isStartDeferredForProtectedVideo,
            screenFailure: appState.screenFailure,
            snapshot: appState.browserHostSnapshot.value
        )
#else
        return StatusHealthSummary.make(
            serviceMode: appState.config.serviceMode,
            isRecording: appState.isRecording || appState.nonMediaIntakeState == .active,
            isPaused: appState.isPaused || (appState.config.selectedSources.isEmpty && appState.nonMediaIntakeState == .paused),
            ownerPauseHeldIdle: appState.ownerPauseHeldIdle,
            held: appState.needsJournalMarkConfirmation,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: appState.uploadCoordinator.presentedStatus,
            pendingCount: appState.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: appState.uploadCoordinator.lastJournalDeliveryOutcome,
            journalSlot: resolvedJournalName,
            now: Date(),
            selectedSources: appState.config.selectedSources,
            otherSourceOn: appState.nonMediaIntakeState != .off,
            permittedSources: appState.capture.permittedSources,
            errorMessage: appState.errorMessage,
            setupVerdict: setupPresentation.verdict,
            lastHealthReason: appState.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: appState.isPairedIngestReady,
            presentedConnection: appState.tunnelLifecycleOwner.presentedConnection,
            startDeferredForProtectedVideo: appState.capture.isStartDeferredForProtectedVideo,
            screenFailure: appState.screenFailure
        )
#endif
    }

    @ViewBuilder
    func healthSummaryCard(showsAction: Bool = true) -> some View {
        let summary = statusHealthSummary
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(summary.severity.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.callout)
                if let subtitle = summary.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if showsAction, let action = summary.action {
                    Button(action.label) {
                        let effect = healthActionEffect(action)
                        navigate(effect.tab)
                        if effect.postsReask {
                            NotificationCenter.default.post(name: .reaskJournalMark, object: nil)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier(AXID.Settings.Status.healthSummaryAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        )
        .accessibilityIdentifier(AXID.Settings.Status.healthSummary)
        .accessibilityValue(summary.axValue)
    }

    var aboutBlock: String {
        AboutPresentation.captureBlock(journal: appState.tunnelLifecycleOwner.journalVersion)
    }

    var setupGroup: some View {
        let presentation = setupSnapshotPresentation
        let displayedAbout = aboutBlock
        return GroupBox(UICopy.SETTINGS_SETUP_GROUP_TITLE) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: setupVerdictSystemImage(presentation.verdict))
                        .foregroundStyle(setupVerdictColor(presentation.verdict))
                    Text(presentation.verdict.text)
                        .font(.callout)
                    Spacer(minLength: 0)
                }
                AXStateCompanion(
                    id: AXID.Settings.Status.setupVerdictState,
                    value: presentation.verdict.axState.axToken
                )

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presentation.rows) { row in
                        setupCheckRow(row)
                    }
                }

                Divider()

                HStack(alignment: .top) {
                    Text(displayedAbout)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AXID.Settings.Status.setupAboutState)
                        .accessibilityValue(displayedAbout)
                    Spacer(minLength: 8)
                    Button(UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION) {
                        navigate(.service)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AXID.Settings.Status.setupManageJournal)
                }
            }
            .padding(.vertical, 4)
        }
    }

    func setupCheckRow(_ row: SetupCheckRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                HStack(spacing: 8) {
                    Image(systemName: row.systemImage)
                        .foregroundStyle(setupRowColor(row.state))
                    Text(row.value)
                        .foregroundStyle(.secondary)
                    if let action = row.action,
                       let actionLabel = row.actionLabel,
                       let actionID = setupActionAXID(for: row.id) {
                        Button(actionLabel) {
                            performSetupAction(action)
                        }
                        .controlSize(.regular)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(actionID)
                    }
                }
            } label: {
                Text(row.label)
            }
            if row.id == .lastDelivery {
                let outcome = primaryLastDeliveryOutcome
                AXStateCompanion(
                    id: AXID.Settings.Status.setupLastDeliveryState,
                    value: outcome.diagnosticAXState.axToken
                )
                if case .delivered(let date) = outcome {
                    AXStateCompanion(
                        id: AXID.Settings.Status.setupLastDeliveryTimestamp,
                        value: axIntegerString(Int(date.timeIntervalSince1970))
                    )
                }
            } else {
                AXStateCompanion(
                    id: setupStateAXID(for: row.id),
                    value: row.state.axToken
                )
            }
        }
    }

    func setupStateAXID(for rowID: SetupCheckRowID) -> String {
        switch rowID {
        case .solApp:
            return AXID.Settings.Status.setupSolAppState
        case .journalApp:
            return AXID.Settings.Status.setupJournalAppState
        case .journalLink:
            return AXID.Settings.Status.setupJournalLinkState
        case .screenRecording:
            return AXID.Settings.Status.setupScreenRecordingState
        case .microphone:
            return AXID.Settings.Status.setupMicrophoneState
        case .lastDelivery:
            return AXID.Settings.Status.setupLastDeliveryState
        }
    }

    func setupActionAXID(for rowID: SetupCheckRowID) -> String? {
        switch rowID {
        case .solApp:
            return AXID.Settings.Status.setupSolAppAction
        case .journalApp:
            return AXID.Settings.Status.setupJournalAppAction
        case .journalLink:
            return AXID.Settings.Status.setupJournalLinkAction
        case .screenRecording:
            return AXID.Settings.Status.setupScreenRecordingAction
        case .microphone:
            return AXID.Settings.Status.setupMicrophoneAction
        case .lastDelivery:
            return nil
        }
    }

    func performSetupAction(_ action: SetupCheckAction) {
        switch action {
        case .openApplications:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .openJournalSettings, .connectJournal:
            navigate(.service)
        case .grantPermission:
            navigate(.permissions)
        }
    }

    func setupRowColor(_ state: SetupCheckRowAXState) -> Color {
        switch state {
        case .ready:
            return .green
        case .needsAttention, .unavailable:
            return .red
        case .notRequired, .checking:
            return .secondary
        }
    }

    func setupVerdictColor(_ verdict: SetupGroupVerdict) -> Color {
        verdict.severity.color
    }

    func setupVerdictSystemImage(_ verdict: SetupGroupVerdict) -> String {
        switch verdict {
        case .ready:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .someUnavailable:
            return "questionmark.circle.fill"
        }
    }

    var statusTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            healthSummaryCard()

            setupGroup

            // Promoting a state into the verdict card REMOVES it from here rather than showing
            // it twice. When the owner has turned every source off, the card above says so and
            // carries the way back, and this group has nothing left of its own to say.
            if !statusGroupIsFullyClaimedByVerdict {
            GroupBox("solstone") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(renderedObservationText)
                        .font(.title2)
                        .accessibilityIdentifier(AXID.Settings.Status.observingState)
                        .accessibilityValue(renderedObservationAXState.axToken)

                    if appState.isRecording && !appState.isPaused {
                        // TimelineView only updates when visible, avoiding background timer
                        TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                            let remaining = appState.captureManager.segmentTimeRemaining
                            let mins = Int(remaining) / 60
                            let secs = Int(remaining) % 60
                            Text(String(format: "next save in %d:%02d", mins, secs))
                                .foregroundStyle(.secondary)
                            AXStateCompanion(
                                id: AXID.Settings.Status.nextSegmentSeconds,
                                value: axIntegerString(Int(remaining))
                            )
                        }
                    }

                    if let recovery = observationRecoveryPresentation(
                        observationRowState: appState.observationRowState,
                        errorMessage: appState.errorMessage,
                        tryAgainInFlight: tryAgainInFlight,
                        uploadStatus: appState.uploadCoordinator.status
                    ) {
                        Text(recovery.reason)
                            .font(.caption)
                            .foregroundStyle(.red)

                        Button(recovery.buttonLabel) {
                            tryAgainInFlight = true
                            Task {
                                await appState.startRecording(reason: .user)
                                tryAgainInFlight = false
                            }
                        }
                        .disabled(recovery.buttonDisabled)
                        .accessibilityIdentifier(AXID.Settings.Status.tryAgain)
                    }
                }
                .padding(.vertical, 4)
            }
            }

            if resolvedServiceMode(for: appState.config) == .external {
                GroupBox("kept on this mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(storageGlanceText)
                        Text("unsynced segments are never deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("storage settings →") {
                            navigate(.service)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                        .accessibilityIdentifier(AXID.Settings.Status.storageSettings)
                    }
                    .padding(.vertical, 4)
                }
            }

            // Same rule as the group above: the verdict card owns this state, so the quiet
            // footer does not restate it a third time.
            if !statusGroupIsFullyClaimedByVerdict {
                Text(statusFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            GroupBox("debug") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("1-minute segments", isOn: debugSegmentsBinding)
                        .help("use 1-minute segments instead of 5-minute for testing")
                        .accessibilityIdentifier(AXID.Settings.Status.debugOneMinuteSegments)
                }
                .padding(.vertical, 4)
            }
            #endif

            Spacer()
        }
    }

    #if DEBUG
    var debugSegmentsBinding: Binding<Bool> {
        Binding(
            get: { appState.config.debugSegments },
            set: { newValue in
                var config = appState.config
                config.debugSegments = newValue
                appState.updateConfig(config)

                Task {
                    await appState.captureManager.setDebugSegments(newValue)
                }
            }
        )
    }

    #endif

    // MARK: - Upload Status

    @ViewBuilder
    var uploadStatusView: some View {
        let status = appState.uploadCoordinator.status
        let pending = appState.uploadCoordinator.pendingCount
        let symbol = journalSyncStatusSymbol(
            status,
            paused: appState.config.syncPaused,
            ready: appState.isPairedIngestReady,
            held: appState.needsJournalMarkConfirmation
        )

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if symbol.usesSecondaryStyle {
                    Image(systemName: symbol.systemName)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: symbol.systemName)
                        .foregroundStyle(uploadStatusColor(for: status))
                }
                Text(journalSyncStatusText(
                    status,
                    paused: appState.config.syncPaused,
                    ready: appState.isPairedIngestReady,
                    held: appState.needsJournalMarkConfirmation
                ))
                Spacer()
            }
            .accessibilityIdentifier(AXID.Settings.Status.uploadState)
            .accessibilityValue(status.axToken)

            AXStateCompanion(
                id: AXID.Settings.Status.uploadChecked,
                value: axIntegerString(uploadCheckedCount(for: status))
            )
            AXStateCompanion(
                id: AXID.Settings.Status.uploadTotal,
                value: axIntegerString(uploadTotalCount(for: status))
            )
            AXStateCompanion(
                id: AXID.Settings.Status.uploadPending,
                value: axIntegerString(pending)
            )
        }
    }

    func uploadCheckedCount(for status: UploadCoordinator.Status) -> Int {
        if case .syncing(let checked, _) = status {
            return checked
        }
        return 0
    }

    func uploadTotalCount(for status: UploadCoordinator.Status) -> Int {
        if case .syncing(_, let total) = status {
            return total
        }
        return 0
    }

    func uploadStatusColor(for status: UploadCoordinator.Status) -> Color {
        switch status {
        case .notSynced:
            .gray
        case .synced:
            .green
        case .syncing, .uploading:
            .blue
        case .retrying, .awaitingTunnel:
            .orange
        case .offline, .blocked:
            .red
        }
    }


    // MARK: - Connection Test

    @ViewBuilder
    var connectionTestIcon: some View {
        switch appState.connectionTestState {
        case .idle, .testing:
            EmptyView()
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Help Tab

    var agentInstructions: String {
        """
        this is solstone for macos.
        the solstone app takes in what you share with it, and all of it goes into your journal.
        installed at: \(Bundle.main.bundlePath)
        files: ~/Library/Application Support/Solstone/captures/
        logs: /usr/bin/log show --predicate '\(SolstoneLogSubsystem.persistedHelpPredicate)' --last 1h
        your journal's address: \(agentInstructionsJournalValue(pairedAddresses: appState.tunnelLifecycleOwner.pairedAddresses, serverURL: appState.config.serverURL))

        if intake isn't running, check settings → permissions.
        if it's not syncing, check settings → journal.
        source: https://github.com/solpbc/solstone-macos
        """
    }

    var helpTab: some View {
        let displayedAbout = aboutBlock
        return VStack(alignment: .leading, spacing: 20) {
            GroupBox("get help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("need a hand? reach us. we're happy to help.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("get help", destination: SupportReportURL.help)
                        .accessibilityIdentifier(AXID.Settings.Help.supportSite)
                    Button("report a problem") {
                        openProblemReport(aboutSnapshot: displayedAbout)
                    }
                    Link("support@solstone.app", destination: URL(string: "mailto:support@solstone.app?subject=solstone%20(macOS)")!)
                        .accessibilityIdentifier(AXID.Settings.Help.supportEmail)
                    Text(displayedAbout)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AXID.Settings.Help.aboutState)
                        .accessibilityValue(displayedAbout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("icon states") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(MenubarIconState.helpLegend, id: \.state.axToken) { entry in
                        HStack(spacing: 6) {
                            bundleImage(entry.state.iconName, isTemplate: true)
                                .frame(width: 22, height: 22)
                            Text(entry.label)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                    }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                    Text(UICopy.SETTINGS_HELP_BROWSER_FOOTNOTE)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Help.browserFootnote)
#endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(UICopy.SETTINGS_DIAGNOSTICS_TITLE) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UICopy.SETTINGS_DIAGNOSTICS_INTRO)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(diagnosticsExpanded
                        ? UICopy.SETTINGS_DIAGNOSTICS_HIDE
                        : UICopy.SETTINGS_DIAGNOSTICS_SHOW
                    ) {
                        toggleDiagnostics()
                    }
                    .accessibilityIdentifier(AXID.Settings.Help.diagnosticsDisclosure)

                    if diagnosticsExpanded {
                        if diagnosticsLoading {
                            Text(UICopy.SETTINGS_DIAGNOSTICS_CHECKING)
                                .foregroundStyle(.secondary)
                        } else if let diagnosticReport {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(diagnosticReport.rows) { row in
                                    LabeledContent(row.label) {
                                        Text(row.value)
                                            .font(.system(.caption, design: .monospaced))
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    .accessibilityIdentifier(diagnosticRowAXID(row.id))
                                    .accessibilityValue(row.value)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier(AXID.Settings.Help.diagnosticsPreview)

                            diagnosticAXCompanions(diagnosticReport)

                            HStack(spacing: 8) {
                                Spacer(minLength: 0)
                                if let diagnosticCopyFeedback {
                                    Text(diagnosticCopyFeedback.text)
                                        .font(.caption)
                                        .foregroundStyle(
                                            diagnosticCopyFeedback == .copied ? Color.secondary : Color.red
                                        )
                                }
                                Button(UICopy.SETTINGS_DIAGNOSTICS_COPY) {
                                    copyDiagnostics()
                                }
                                .accessibilityIdentifier(AXID.Settings.Help.diagnosticsCopy)
                                AXStateCompanion(
                                    id: AXID.Settings.Help.diagnosticsCopyResultState,
                                    value: (diagnosticCopyFeedback?.axState ?? .idle).axToken
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(UICopy.SETTINGS_LOG_EXPORT_TITLE) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UICopy.SETTINGS_LOG_EXPORT_INTRO)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(UICopy.SETTINGS_LOG_EXPORT_ACTION) {
                        startLogExportRead()
                    }
                    .accessibilityIdentifier(AXID.Settings.Help.logExport)

                    if logExportLoading {
                        Text(UICopy.SETTINGS_LOG_EXPORT_WORKING)
                            .foregroundStyle(.secondary)
                    } else if let document = logExportDocument {
                        logExportOutcomeViews(document)
                    }

                    AXStateCompanion(
                        id: AXID.Settings.Help.logExportState,
                        value: logExportAXState(
                            loading: logExportLoading,
                            document: logExportDocument,
                            writeFailed: logExportWriteFeedback == .failed
                        ).axToken
                    )
                    AXStateCompanion(
                        id: AXID.Settings.Help.logExportFailureReason,
                        value: logExportFailureReasonValue
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("agent instructions") {
                VStack(alignment: .trailing, spacing: 8) {
                    Text("working with a coding agent? hand it this context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ScrollView {
                        Text(agentInstructions)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .accessibilityIdentifier(AXID.Settings.Help.agentInstructions)

                    Button("copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(agentInstructions, forType: .string)
                    }
                    .accessibilityIdentifier(AXID.Settings.Help.copyAgentInstructions)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    func toggleDiagnostics() {
        diagnosticLoadGeneration &+= 1
        let loadGeneration = diagnosticLoadGeneration
        diagnosticCopyFeedback = nil
        if diagnosticsExpanded {
            diagnosticsExpanded = false
            diagnosticsLoading = false
            diagnosticReport = nil
            return
        }

        diagnosticsExpanded = true
        diagnosticsLoading = true
        Task { @MainActor in
            let report = await readDiagnosticReport()
            guard shouldPublishDiagnosticLoad(
                loadGeneration,
                activeGeneration: diagnosticLoadGeneration,
                diagnosticsExpanded: diagnosticsExpanded
            ) else { return }
            diagnosticReport = report
            diagnosticsLoading = false
        }
    }

    /// Reads everything the report shows, now. Copy reads again rather than reusing what the
    /// panel showed when it opened, so a copy taken after a re-link carries what happened.
    func readDiagnosticReport() async -> DiagnosticReport {
        let evidence = await appState.readDiagnosticEvidence()
        let backlog = await appState.uploadCoordinator.readDiagnosticBacklog()
        var reportInput = DiagnosticReportInput(
            appVersion: AppVersion.short,
            screenRecording: currentScreenPermissionOutcome,
            microphone: currentMicrophonePermissionOutcome,
            isRecording: appState.isRecording,
            isPaused: appState.isPaused,
            ownerPauseHeldIdle: appState.ownerPauseHeldIdle,
            hasError: appState.errorMessage != nil,
            lastDelivery: appState.uploadCoordinator.lastJournalDeliveryOutcome,
            lastJournalContact: appState.uploadCoordinator.lastSuccessfulJournalContactOutcome,
            evidence: evidence,
            ingestReason: appState.uploadCoordinator.lastErrorReason,
            ingestRoute: appState.uploadCoordinator.lastRequestedIngestPath,
            now: Date(),
            activeSources: appState.captureManager.activeSources,
            connection: DiagnosticConnectionInput(
                isPaired: appState.tunnelLifecycleOwner.cachedPairingIdentity != nil,
                pairedAddresses: appState.tunnelLifecycleOwner.pairedAddresses,
                dialableRelayHost: appState.tunnelLifecycleOwner.dialableRelayHost,
                triedAddresses: appState.tunnelLifecycleOwner.triedAddresses,
                connectedThrough: appState.tunnelLifecycleOwner.connectedThrough
            ),
            setAside: appState.segmentSetAside
        )
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        reportInput.browserRows = buildBrowserDiagnosticRows(
            snapshot: appState.browserHostSnapshot.value,
            repair: appState.browserRepair,
            now: Date()
        )
#endif
        reportInput.backlog = backlog
        return buildDiagnosticReport(reportInput)
    }

    func openProblemReport(aboutSnapshot: String) {
        Task { @MainActor in
            let evidence = await appState.readDiagnosticEvidence()
            let recent: String? = switch evidence {
            case .available(let envelope) where !envelope.entries.isEmpty:
                diagnosticEvidenceValue(evidence)
            case .available, .unavailable:
                nil
            }
            let state = appState.errorMessage != nil
                ? "error"
                : ((appState.isPaused || appState.ownerPauseHeldIdle) ? "paused" : (appState.isRecording ? "on" : "off"))
            NSWorkspace.shared.open(SupportReportURL.make(
                version: AppVersion.short,
                build: AppVersion.build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                state: state,
                recent: recent,
                about: aboutSnapshot
            ))
        }
    }

    var currentScreenPermissionOutcome: PermissionOutcome {
        PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            screenRecordingGranted: appState.screenRecordingGranted,
            hasPromptedScreenRecording: setupProbeSnapshot.hasPromptedScreenRecording,
            preflightSucceeded: setupProbeSnapshot.screenDiagnostic?.preflightSucceeded,
            sckFailedAfterPositivePreflight: setupProbeSnapshot.screenDiagnostic?.sckFailedAfterPositivePreflight ?? false
        )
    }

    var currentMicrophonePermissionOutcome: PermissionOutcome {
        PermissionOutcome.microphone(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            cause: appState.microphoneAuthorizationCause
        )
    }

    func copyDiagnostics() {
        diagnosticLoadGeneration &+= 1
        let loadGeneration = diagnosticLoadGeneration
        diagnosticCopyFeedback = nil
        Task { @MainActor in
            let report = await readDiagnosticReport()
            guard shouldPublishDiagnosticLoad(
                loadGeneration,
                activeGeneration: diagnosticLoadGeneration,
                diagnosticsExpanded: diagnosticsExpanded
            ) else { return }
            diagnosticReport = report
            diagnosticCopyFeedback = performDiagnosticCopy(
                report,
                write: diagnosticClipboardWrite,
                announce: diagnosticAnnouncement
            )
        }
    }

    var logExportFailureReasonValue: String {
        guard case .failed(let reason) = logExportDocument?.outcome else {
            return ""
        }
        return reason
    }

    @ViewBuilder
    func logExportOutcomeViews(_ document: LogExportDocument) -> some View {
        switch document.outcome {
        case .empty:
            Text(UICopy.SETTINGS_LOG_EXPORT_EMPTY)
                .foregroundStyle(.secondary)
        case .complete:
            EmptyView()
        case .partial(let lost):
            Text(UICopy.SETTINGS_LOG_EXPORT_PARTIAL)
                .foregroundStyle(.secondary)
            Text(
                NSOrderedSet(
                    array: lost.map { SolstoneLogSubsystem.displayName(for: $0.subsystem) }
                ).array.compactMap { $0 as? String }.joined(separator: ", ")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(UICopy.SETTINGS_LOG_EXPORT_FAILED)
                .foregroundStyle(.red)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if logExportOffersSave(document.outcome) {
            ScrollView {
                Text(logExportPreviewText(from: document))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AXID.Settings.Help.logExportPreview)

            if document.entryCount > LogExportBounds.previewEntryLimit {
                Text(
                    String(
                        format: UICopy.SETTINGS_LOG_EXPORT_PREVIEW_SUBSET,
                        LogExportBounds.previewEntryLimit,
                        document.entryCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if logExportWriteFeedback == .failed {
                    Text(UICopy.SETTINGS_LOG_EXPORT_WRITE_FAILED)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(UICopy.SETTINGS_LOG_EXPORT_SAVE) {
                    saveLogExport(document)
                }
                .accessibilityIdentifier(AXID.Settings.Help.logExportSave)
            }
        }
    }

    func startLogExportRead() {
        logExportTask?.cancel()
        logExportGeneration &+= 1
        let generation = logExportGeneration
        logExportWriteFeedback = nil
        logExportDocument = nil
        logExportLoading = true
        let source = logExportSource
        let version = AppVersion.short
        let build = AppVersion.build
        let now = Date()
        logExportTask = Task { @MainActor in
            let work = Task.detached {
                try await buildLogExport(
                    source: source,
                    now: now,
                    version: version,
                    build: build
                )
            }
            do {
                let document = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard shouldPublishLogExportLoad(generation, activeGeneration: logExportGeneration) else {
                    return
                }
                logExportDocument = document
                logExportLoading = false
            } catch is CancellationError {
                if shouldPublishLogExportLoad(generation, activeGeneration: logExportGeneration) {
                    logExportLoading = false
                }
            } catch {
                if shouldPublishLogExportLoad(generation, activeGeneration: logExportGeneration) {
                    logExportLoading = false
                }
            }
        }
    }

    func cancelLogExportRead() {
        logExportTask?.cancel()
        logExportTask = nil
        logExportGeneration &+= 1
        logExportLoading = false
    }

    func saveLogExport(_ document: LogExportDocument) {
        logExportWriteFeedback = performLogExportSave(
            document: document,
            chooseURL: logExportChooseSaveURL,
            writer: logExportWriter
        )
    }

    @ViewBuilder
    func diagnosticAXCompanions(_ report: DiagnosticReport) -> some View {
        AXStateCompanion(
            id: AXID.Settings.Help.diagnosticsScreenRecordingState,
            value: report.screenRecordingState.axToken
        )
        AXStateCompanion(
            id: AXID.Settings.Help.diagnosticsMicrophoneState,
            value: report.microphoneState.axToken
        )
        AXStateCompanion(
            id: AXID.Settings.Help.diagnosticsCaptureState,
            value: report.captureState.axToken
        )
        AXStateCompanion(
            id: AXID.Settings.Help.diagnosticsLastDeliveryState,
            value: report.lastDeliveryState.axToken
        )
        if let date = report.lastDeliveryTimestamp {
            AXStateCompanion(
                id: AXID.Settings.Help.diagnosticsLastDeliveryTimestamp,
                value: axIntegerString(Int(date.timeIntervalSince1970))
            )
        }
        AXStateCompanion(
            id: AXID.Settings.Help.diagnosticsLastJournalConnectionState,
            value: report.lastJournalContactState.axToken
        )
        if let date = report.lastJournalContactTimestamp {
            AXStateCompanion(
                id: AXID.Settings.Help.diagnosticsLastJournalConnectionTimestamp,
                value: axIntegerString(Int(date.timeIntervalSince1970))
            )
        }
    }

    func diagnosticRowAXID(_ rowID: DiagnosticReportRowID) -> String {
        switch rowID {
        case .appVersion:
            return AXID.Settings.Help.diagnosticsAppVersionRow
        case .screenRecording:
            return AXID.Settings.Help.diagnosticsScreenRecordingRow
        case .microphone:
            return AXID.Settings.Help.diagnosticsMicrophoneRow
        case .screenAndAudio:
            return AXID.Settings.Help.diagnosticsCaptureRow
        case .lastDelivery:
            return AXID.Settings.Help.diagnosticsLastDeliveryRow
        case .lastJournalConnection:
            return AXID.Settings.Help.diagnosticsLastJournalConnectionRow
        case .ingestReason:
            return AXID.Settings.Help.diagnosticsIngestReasonRow
        case .ingestRoute:
            return AXID.Settings.Help.diagnosticsIngestRouteRow
        case .journalLink:
            return AXID.Settings.Help.diagnosticsJournalLinkRow
        case .recentStateCodes:
            return AXID.Settings.Help.diagnosticsRecentStateCodesRow
        case .localCaptures:
            return AXID.Settings.Help.diagnosticsLocalCapturesRow
        case .journalAddresses:
            return AXID.Settings.Help.diagnosticsJournalAddressesRow
        case .relay:
            return AXID.Settings.Help.diagnosticsRelayRow
        case .addressesTried:
            return AXID.Settings.Help.diagnosticsAddressesTriedRow
        case .connectedThrough:
            return AXID.Settings.Help.diagnosticsConnectedThroughRow
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        case .browserPages:
            return AXID.Settings.Help.diagnosticsBrowserPagesRow
        case .browsersSeen:
            return AXID.Settings.Help.diagnosticsBrowsersSeenRow
        case .browserSetup:
            return AXID.Settings.Help.diagnosticsBrowserSetupRow
#endif
        }
    }

}

@MainActor
func presentLogExportSavePanel() -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "solstone-logs.txt"
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

func updatesSidebarBadge(for status: DurableUpdateStatus) -> SettingsView.SidebarBadgeState {
    if status == .upToDate {
        return .done
    }
    if updateAttentionReason(for: status) != nil {
        return .attention
    }
    return .blank
}

/// Row view for a microphone in the priority list
struct MicrophoneRow: View {
    let entry: MicrophoneDisplayEntry
    let onDelete: () -> Void
    let onToggleDisabled: () -> Void
    var onSelectMode: (MicrophoneEntry.Mode) -> Void = { _ in }
    var onSelectChoice: (MicrophoneChoice) -> Void = { _ in }
    var onRetry: () -> Void = {}

    var indicatorColor: Color {
        if !entry.isConnected {
            return .gray
        }
        if entry.mode == .off {
            return .orange
        }
        switch entry.interfaceState {
        case .admitted:
            return .green
        case .needsChoice, .layoutUnavailable:
            return .gray
        }
    }

    var axStateValue: String {
        let enabled = entry.mode == .whenInUseElsewhere ? "following" : (entry.isDisabled ? "disabled" : "enabled")
        guard entry.isConnected else { return "disconnected_\(enabled)" }
        if entry.mode == .off {
            return "connected_disabled"
        }
        switch entry.interfaceState {
        case .admitted:
            return "connected_\(enabled)"
        case .needsChoice:
            return "connected_needs_choice"
        case .layoutUnavailable:
            return "connected_layout_unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Connection status indicator
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)

                // Microphone name
                Text(entry.name)
                    .strikethrough(entry.mode == .off)
                    .foregroundStyle(entry.isConnected ? (entry.mode == .off ? .secondary : .primary) : .secondary)

                Spacer()

                if entry.offersFollowing {
                    Picker("", selection: Binding(get: { entry.mode }, set: { onSelectMode($0) })) {
                        Text(UICopy.MICROPHONE_MODE_WHEN_IN_USE).tag(MicrophoneEntry.Mode.whenInUseElsewhere)
                        Text(UICopy.MICROPHONE_MODE_ALWAYS).tag(MicrophoneEntry.Mode.always)
                        Text(UICopy.MICROPHONE_MODE_OFF).tag(MicrophoneEntry.Mode.off)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help(UICopy.MICROPHONE_MODE_HELP)
                    .accessibilityIdentifier(AXID.Settings.Microphones.deviceToggle(entry.uid))
                } else {
                    // Disable/Enable toggle
                    Button(action: onToggleDisabled) {
                        Image(systemName: entry.isDisabled ? "mic.slash" : "mic")
                            .foregroundStyle(entry.isDisabled ? .orange : .green)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isDisabled ? "enable microphone" : "disable microphone")
                    .accessibilityIdentifier(AXID.Settings.Microphones.deviceToggle(entry.uid))
                }

                // Remove is offered only while a microphone is disconnected: a connected one is
                // re-added by the next device sync, so removing it would not stick, and could bring
                // back one that was off at its default. Turning it off is the control for that.
                if !entry.isConnected {
                    Text("disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("if it connects again, it comes back at its default setting. to keep it off, turn it off instead.")
                    .accessibilityIdentifier(AXID.Settings.Microphones.deviceRemove(entry.uid))
                }
            }

            if entry.isConnected && entry.mode != .off {
                switch entry.interfaceState {
                case .admitted:
                    if let layout = entry.layout, layout.channelCount > 2 || entry.choice != nil {
                        Picker("", selection: Binding(
                            get: { microphonePickerSelection(interfaceState: entry.interfaceState, choice: entry.choice) },
                            set: { onSelectChoice(MicrophoneChoice(ordinal: $0, fingerprint: layout.fingerprint)) }
                        )) {
                            ForEach(0..<layout.channelCount, id: \.self) { i in
                                let label = i < layout.labels.count ? layout.labels[i] : nil
                                Text(UICopy.microphoneInputTitle(number: i + 1, label: label)).tag(i)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier(AXID.Settings.Microphones.inputChoice(entry.uid))
                    }
                case .needsChoice(let layout):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(microphoneChoiceCopy(choice: entry.choice, layout: layout))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { microphonePickerSelection(interfaceState: entry.interfaceState, choice: entry.choice) },
                            set: {
                                if $0 >= 0 {
                                    onSelectChoice(MicrophoneChoice(ordinal: $0, fingerprint: layout.fingerprint))
                                }
                            }
                        )) {
                            Text(microphoneChoiceCopy(choice: entry.choice, layout: layout)).tag(-1)
                            ForEach(0..<layout.channelCount, id: \.self) { i in
                                let label = i < layout.labels.count ? layout.labels[i] : nil
                                Text(UICopy.microphoneInputTitle(number: i + 1, label: label)).tag(i)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier(AXID.Settings.Microphones.inputChoice(entry.uid))
                    }
                case .layoutUnavailable:
                    HStack(spacing: 8) {
                        Text(UICopy.MICROPHONE_LAYOUT_UNAVAILABLE)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(action: onRetry) {
                            Text(UICopy.MICROPHONE_INPUT_RETRY)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier(AXID.Settings.Microphones.inputRetry(entry.uid))
                    }
                }
            }

            if entry.showsCallModeNote {
                Text(UICopy.MICROPHONE_ALWAYS_CALL_MODE)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(AXID.Settings.Microphones.device(entry.uid))
        .accessibilityValue(axStateValue)
    }
}

/// The mark question. Neither answer takes the default action: the owner chooses one on purpose,
/// and pressing return does not answer for them.
/// What an owner sees after declining a switch: their pairing is still the one in use.
struct PairingSwitchNotChangedPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(UICopy.JOURNAL_MARK_SWITCH_NOT_CHANGED_TITLE)
                .font(.headline)
            Text(UICopy.JOURNAL_MARK_SWITCH_NOT_CHANGED_BODY)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.Settings.Service.pairingSwitchNotChanged)
    }
}

struct JournalMarkSheetContent: View {
    let phase: JournalMarkConfirmationDriver.Phase
    let onMismatch: @MainActor () -> Void
    let onConfirm: @MainActor () -> Void
    let onCancelPairing: @MainActor () -> Void
    let onContinueAnyway: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .deriving:
                ProgressView()
                    .controlSize(.small)
            case .valid(let mark):
                JournalMarkView(mark: mark)
                VStack(spacing: 6) {
                    Text(UICopy.JOURNAL_MARK_CONFIRM_QUESTION)
                        .font(.headline)
                    Text(UICopy.JOURNAL_MARK_CONFIRM_SUBTEXT)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Button(UICopy.JOURNAL_MARK_MISMATCH_BUTTON) {
                        onMismatch()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkMismatch)

                    Button(UICopy.JOURNAL_MARK_CONFIRM_BUTTON) {
                        onConfirm()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkConfirm)
                }
            case .unverified:
                JournalMarkUnavailableView()
                VStack(spacing: 6) {
                    Text(UICopy.JOURNAL_MARK_UNVERIFIED_TITLE)
                        .font(.headline)
                    Text(UICopy.JOURNAL_MARK_UNVERIFIED_BODY)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Button(UICopy.JOURNAL_MARK_UNVERIFIED_CANCEL_BUTTON) {
                        onCancelPairing()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkCancelPairing)

                    Button(UICopy.JOURNAL_MARK_UNVERIFIED_CONTINUE_BUTTON) {
                        onContinueAnyway()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkContinueAnyway)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
