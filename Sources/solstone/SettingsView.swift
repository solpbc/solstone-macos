// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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

    init(from entry: MicrophoneEntry, isConnected: Bool) {
        self.id = entry.uid
        self.uid = entry.uid
        self.name = entry.name
        self.isConnected = isConnected
        self.isDisabled = entry.isDisabled
    }
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
    case .idle, .pairing, .switchConfirmPending, .saveFailed, .failed:
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
    case .error(.keychainUnavailable), .error(.loopbackUnavailable), .error(.revoked):
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
    enum Tab: String, Hashable, CaseIterable {
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
    @State var selectedTab: Tab = .status
    @Environment(\.dismiss) private var dismiss

    @State private var storageUsedMB: Int?
    @State private var tryAgainInFlight = false
    @State private var setupProbeSnapshot = SetupProbeSnapshot.checking

    // Help diagnostics are read only after the owner opens the disclosure.
    @State private var diagnosticsExpanded = false
    @State private var diagnosticsLoading = false
    @State private var diagnosticLoadGeneration: UInt = 0
    @State private var diagnosticReport: DiagnosticReport?
    @State private var diagnosticCopyFeedback: DiagnosticCopyFeedback?

    @State private var logExportGeneration: UInt = 0
    @State private var logExportLoading = false
    @State private var logExportDocument: LogExportDocument?
    @State private var logExportTask: Task<Void, Never>?
    @State private var logExportWriteFeedback: LogExportWriteFeedback?

    // Permissions tab state
    @State private var screenRecordingPrompted = false
    @State private var screenRestartPending = false

    // Privacy tab state
    @State private var newTitlePattern = ""
    @State private var newExcludedApp = ""
    @FocusState private var privateWindowKeyboardFocused: Bool
    @AccessibilityFocusState private var privateWindowAccessibilityFocused: Bool
    @State private var privateWindowAnnouncements = PrivateWindowAccessibilityAnnouncementPolicy()

    // Service tab state
    @State private var observerURL = ""
    @State private var observerKey = ""
    @State private var pairingLink = ""
    @State private var inFlightTestID: UUID?
    @State private var disconnectConfirmPending = false
    @State private var journalMarkDriver = JournalMarkConfirmationDriver()
    @State private var journalHandoffOrchestrator: JournalHandoffOrchestrator
    @State private var freshFlow: FreshJournalFlow
    @State private var onDiskJournalAdoptionFlow: OnDiskJournalAdoptionFlow
    @State private var pairingMismatch = false
    @State private var journalMarkRederiveEligible = false
    @State private var journalMarkRederiveStarted = false
    @State private var journalMarkRederiveTask: Task<Void, Never>?
    @State private var localJournalMark: JournalMark?
    @State private var localOnDiskDiscoveryPath: String?
    @State private var localOnDiskAdoptionAction: OnDiskJournalAdoptionAction = .install
    @State private var localDiscoveryCompleted = false
    @State private var localDiscoveryTask: Task<Void, Never>?
    @State private var localDiscoveryInFlight = false
    @State private var lastProbeFinishedAt: Date?
    @State private var localLinkInProgress = false
    @State private var localLinkError: String?
    @State private var showPairingFlow = false
    @State var entitlementOpenFailed = false
    @State var supportOpenFailed = false

    private let localIdentityFetch: @MainActor @Sendable (String) async -> JournalMark?
    private let onDiskJournalDiscovery: @MainActor @Sendable () async -> OnDiskJournalDiscovery
    private let sameMachinePairStart: @MainActor @Sendable (
        _ baseURL: String,
        _ deviceLabel: String
    ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure>
    private let markFetch: @MainActor @Sendable (String) async -> JournalMark?
    private let runningJournalController: any RunningJournalController
    private let diagnosticClipboardWrite: @MainActor (String) -> Bool
    private let diagnosticAnnouncement: @MainActor (String) -> Void
    private let openURL: @MainActor (URL) -> Bool
    private let logExportSource: any LogExportEntrySourcing
    private let logExportWriter: any LogExportFileWriting
    private let logExportChooseSaveURL: @MainActor (LogExportDocument) -> URL?

    init(
        appState: AppState,
        updateController: UpdateController,
        selectedTab: Tab = .observer,
        initialStorageUsedMB: Int? = nil,
        initialLocalJournalMark: JournalMark? = nil,
        initialLocalOnDiskDiscoveryPath: String? = nil,
        initialLocalDiscoveryCompleted: Bool = false,
        initialShowPairingFlow: Bool = false,
        journalHandoffOrchestrator: JournalHandoffOrchestrator = JournalHandoffOrchestrator(),
        freshFlow: FreshJournalFlow = FreshJournalFlow(),
        onDiskJournalAdoptionFlow: OnDiskJournalAdoptionFlow = OnDiskJournalAdoptionFlow(),
        localIdentityFetch: @escaping @MainActor @Sendable (String) async -> JournalMark? = { baseURL in
            switch await JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() }).fetch(baseURL: baseURL) {
            case .mark(let mark): return mark
            case .uncommitted, .unavailable: return nil
            }
        },
        onDiskJournalDiscovery: @escaping @MainActor @Sendable () async -> OnDiskJournalDiscovery = {
            await discoverOnDiskJournal()
        },
        sameMachinePairStart: @escaping @MainActor @Sendable (
            _ baseURL: String,
            _ deviceLabel: String
        ) async -> Result<SameMachinePairStartResponse, SameMachinePairStartFailure> = { baseURL, deviceLabel in
            await SameMachinePairStartClient().start(baseURL: baseURL, deviceLabel: deviceLabel)
        },
        markFetch: @escaping @MainActor @Sendable (String) async -> JournalMark? = { baseURL in
            switch await JournalIdentityFetcher(prepareRequest: { $0.attachLoopbackCapability() }).fetch(baseURL: baseURL) {
            case .mark(let mark): return mark
            case .uncommitted, .unavailable: return nil
            }
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
        self.markFetch = markFetch
        self.runningJournalController = runningJournalController
        self.diagnosticClipboardWrite = diagnosticClipboardWrite
        self.diagnosticAnnouncement = diagnosticAnnouncement
        self.openURL = openURL
        self.logExportSource = logExportSource
        self.logExportWriter = logExportWriter
        self.logExportChooseSaveURL = logExportChooseSaveURL
        self._selectedTab = State(initialValue: selectedTab)
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

    private var preserveSyncedSegmentsBinding: Binding<Bool> {
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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedTab) {
                sidebarPlainLabel("status", tab: .status, systemImage: "info.circle").tag(Tab.status)

                Section {
                    sidebarLabel(
                        "permissions",
                        tab: .permissions,
                        systemImage: "lock.shield",
                        badge: appState.permissionsAreDone ? .done : (appState.permissionsNeedAttention ? .attention : .blank)
                    )
                        .tag(Tab.permissions)
                    sidebarLabel(
                        "journal",
                        tab: .service,
                        systemImage: "book.closed",
                        badge: appState.serviceIsDone ? .done : (appState.serviceNeedsAttention ? .attention : .blank)
                    )
                        .tag(Tab.service)
                } header: {
                    Text("setup")
                }

                Section {
                    sidebarPlainLabel("sources", tab: .sources, systemImage: "waveform.badge.mic").tag(Tab.sources)
                    sidebarPlainLabel("microphones", tab: .microphones, systemImage: "mic").tag(Tab.microphones)
                    sidebarPlainLabel("privacy", tab: .privacy, systemImage: "eye.slash").tag(Tab.privacy)
                } header: {
                    Text("inputs")
                }

                Section {
                    sidebarPlainLabel("general", tab: .observer, systemImage: "gearshape").tag(Tab.observer)
                    sidebarLabel(
                        UpdatesCopy(provider: .solstone).tabTitle,
                        tab: .updates,
                        systemImage: "arrow.down.circle",
                        badge: updatesSidebarBadge(for: updateController.durableUpdateStatus),
                        doneAccessibilityLabel: UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y
                    )
                        .tag(Tab.updates)
                    sidebarPlainLabel("help", tab: .help, systemImage: "questionmark.circle").tag(Tab.help)
                } header: {
                    Text("app")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .modifier(SettingsPaneScrollEdgeModifier())
        } detail: {
            ScrollViewReader { proxy in
                ScrollView {
                    detailContent(scrollProxy: proxy)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .modifier(SettingsPaneScrollEdgeModifier())
            }
        }
        .frame(minWidth: 720, minHeight: 500)
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
            journalMarkDriver.startIfUnconfirmed(appState: appState)
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
        .onChange(of: appState.pairingCoordinator.tunnelState) { _, _ in
            startJournalMarkRederiveIfNeeded()
            journalMarkDriver.startIfUnconfirmed(appState: appState)
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != .privacy { appState.pendingPrivateWindowSettingsTarget = nil }
            if newValue == .status {
                refreshSetupProbes()
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
            selectedTab = .service
            journalMarkDriver.reaskUnconfirmed(appState: appState)
        }
        .sheet(isPresented: Binding(
            get: { journalMarkDriver.isPresented },
            set: { newValue in
                if !newValue {
                    journalMarkDriver.cancel()
                }
            }
        ), onDismiss: {
            journalMarkDriver.cancel()
        }) {
            journalMarkSheet
        }
        .onDisappear {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            appState.browserPendingDiscard.closeSettings()
#endif
            journalMarkDriver.cancel()
            journalMarkRederiveTask?.cancel()
            journalMarkRederiveTask = nil
        }
        .onExitCommand {
            dismiss()
        }
    }

    @ViewBuilder
    private func detailContent(scrollProxy: ScrollViewProxy) -> some View {
        switch selectedTab {
        case .status:
            statusTab.onAppear {
                appState.markSettingsTabVisited(.status)
                refreshSetupProbes()
            }
        case .observer:
            observerTab.onAppear { appState.markSettingsTabVisited(.observer) }
        case .service:
            serviceTab.onAppear { appState.markSettingsTabVisited(.service) }
        case .sources:
            sourcesTab
                .onAppear { appState.markSettingsTabVisited(.sources) }
                .onDisappear {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                    appState.browserRepair.viewGeneration += 1
#endif
                }
        case .microphones:
            microphoneTab.onAppear { appState.markSettingsTabVisited(.microphones) }
        case .privacy:
            privacyTab(scrollProxy: scrollProxy).onAppear {
                appState.markSettingsTabVisited(.privacy)
                privateWindowAnnouncements.reset(to: privateWindowAccessibilityState)
            }
        case .permissions:
            permissionsTab.onAppear {
                appState.markSettingsTabVisited(.permissions)
                appState.refreshMicrophoneAuthorization()
            }
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

    private func applyPendingSettingsTab() {
        if let pending = appState.pendingSettingsTab {
            switch pending {
            case "observer", "general": selectedTab = .observer
            case "permissions": selectedTab = .permissions
            case "service", "journal": selectedTab = .service
            case "sources": selectedTab = .sources
            case "microphones": selectedTab = .microphones
            case "privacy": selectedTab = .privacy
            case "help": selectedTab = .help
            case "status": selectedTab = .status
            case "updates": selectedTab = .updates
            default: break
            }
            appState.pendingSettingsTab = nil
        }
    }

    private var journalMarkSheet: some View {
        VStack(spacing: 16) {
            switch journalMarkDriver.phase {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                Text(UICopy.JOURNAL_MARK_CONNECTING)
                    .font(.headline)
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
                        rejectJournalMark()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkMismatch)

                    Button(UICopy.JOURNAL_MARK_CONFIRM_BUTTON) {
                        confirmJournalMark()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkConfirm)
                }
            case .unverified:
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
                        cancelUnverifiedPairing()
                    }
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkCancelPairing)

                    Button(UICopy.JOURNAL_MARK_UNVERIFIED_CONTINUE_BUTTON) {
                        continueUnverifiedMark()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingMarkContinueAnyway)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func handlePairingStateChange(_ state: PairingFlowState) {
        journalMarkDriver.startIfNeeded(for: state, appState: appState)
        switch state {
        case .paired, .alreadyConnected, .switched:
            showPairingFlow = false
            pairingLink = ""
        default:
            break
        }
    }

    private func confirmJournalMark() {
        journalMarkDriver.confirm(appState: appState)
        pairingMismatch = false
    }

    private func continueUnverifiedMark() {
        journalMarkDriver.continueAnyway(appState: appState)
        pairingMismatch = false
    }

    private func cancelUnverifiedPairing() {
        Task { @MainActor in
            await journalMarkDriver.cancelPairing(appState: appState)
            pairingMismatch = false
            journalMarkRederiveEligible = false
            journalMarkRederiveStarted = false
        }
    }

    private func rejectJournalMark() {
        Task { @MainActor in
            await journalMarkDriver.reject(appState: appState) {
                pairingMismatch = true
                journalMarkRederiveEligible = false
                journalMarkRederiveStarted = false
            }
        }
    }

    private func startJournalMarkRederiveIfNeeded() {
        guard journalMarkRederiveEligible,
              !journalMarkRederiveStarted,
              appState.confirmedMark == nil,
              appState.isJournalMarkConfirmed,
              appState.tunnelLifecycleOwner.isTunnelManaged,
              case .connected = appState.pairingCoordinator.tunnelState
        else {
            return
        }

        journalMarkRederiveStarted = true
        journalMarkRederiveTask?.cancel()
        journalMarkRederiveTask = Task { @MainActor in
            switch await appState.resolveHomeBase() {
            case .url(let baseURL):
                if let mark = await markFetch(baseURL) {
                    appState.setConfirmedMark(mark)
                }
            case .held:
                break
            }
        }
    }

    @ViewBuilder
    private func sidebarPlainLabel(_ title: String, tab: Tab, systemImage: String) -> some View {
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
    private func sidebarLabel(
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

    private func sidebarBadgeStateCompanion(tab: Tab, badge: SidebarBadgeState) -> some View {
        AXStateCompanion(
            id: AXID.Settings.Sidebar.tabState(tab),
            value: badge.axToken
        )
    }

    // MARK: - Sources Tab

    private func setCaptureSource(_ source: CaptureSources, enabled: Bool) {
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

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(UICopy.SOURCES_HELP)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(UICopy.SOURCES_MICROPHONE, isOn: Binding(
                        get: { appState.config.isMicrophoneCaptureEnabled },
                        set: { setCaptureSource(.microphone, enabled: $0) }
                    ))
                    .accessibilityIdentifier(AXID.Settings.Sources.microphoneCaptureEnabled)
                    Toggle(UICopy.SOURCES_SCREEN, isOn: Binding(
                        get: { appState.config.isScreenCaptureEnabled },
                        set: { setCaptureSource(.screen, enabled: $0) }
                    ))
                    .accessibilityIdentifier(AXID.Settings.Sources.screenCaptureEnabled)

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                    Toggle(isOn: Binding(
                        get: { appState.config.isBrowserIntakeEnabled },
                        set: { enabled in
                            if sourcesToggleRestartsMedia(.browserPages(enabled)) {
                                setCaptureSource(.microphone, enabled: enabled)
                            }
                            appState.setBrowserIntakeEnabled(enabled)
                        }
                    )) {
                        Text(UICopy.SOURCES_BROWSER_PAGES)
                    }
                    .accessibilityIdentifier(AXID.Settings.Sources.browserIntakeEnabled)

                    if browserSetupGroupIsVisible(
                        screenGranted: appState.screenRecordingGranted,
                        microphoneGranted: appState.microphoneGranted
                    ) {
                        browserSourcesGroup
                    }
#endif

                    Divider()

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                    Text(sourcesFooter(media: appState.captureSourcesStatusText, lead: sourcesLead))
                        .accessibilityIdentifier(AXID.Settings.Sources.sourceStatus)
#else
                    Text(appState.captureSourcesStatusText)
                        .accessibilityIdentifier(AXID.Settings.Sources.sourceStatus)
#endif
                    if appState.config.selectedSources.isEmpty {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
                        if sourcesLead != .draining && !appState.config.isBrowserIntakeEnabled {
                            Text(UICopy.SOURCES_NONE_REASON).foregroundStyle(.secondary)
                        }
#else
                        Text(UICopy.SOURCES_NONE_REASON).foregroundStyle(.secondary)
#endif
                    } else if appState.availableSelectedSources.isEmpty {
                        Text(UICopy.SOURCES_GRANT_OR_CHANGE).foregroundStyle(.secondary)
                        navRow(UICopy.SETTINGS_NEXT_GRANT_PERMISSIONS) {
                            selectedTab = .permissions
                        }
                    } else if appState.isRecording || appState.isPaused,
                              appState.captureManager.activeSources.isEmpty {
                        // Turned on and granted, but the device did not start. Without this the
                        // one state with no owner action attached is also the only one with no
                        // reason attached.
                        Text(UICopy.SOURCES_UNAVAILABLE_REASON).foregroundStyle(.secondary)
                    }
                    if let notice = appState.captureSourceNotice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    private var sourcesLead: BrowserOwnerStatusLead {
        browserOwnerStatusLead(
            mediaSourcesEmpty: appState.config.selectedSources.isEmpty,
            mediaRecording: appState.isRecording,
            mediaPaused: appState.isPaused,
            snapshot: appState.browserHostSnapshot.value,
            now: Date()
        )
    }

    private var browserSourcesGroup: some View {
        let snapshot = appState.browserHostSnapshot.value
        let rows = browserBrandRows(snapshot, now: Date())
        let verdict = browserOwnerVerdict(mediaSourcesEmpty: appState.config.selectedSources.isEmpty,
            mediaRecording: appState.isRecording, mediaPaused: appState.isPaused, snapshot: snapshot, now: Date())
        let hasAnyHistory = rows.contains { $0.lastSeen != nil }
        let hasAnyStore = BrowserBrand.allCases.contains { appState.browserStoreCatalog.url(for: $0) != nil }

        return VStack(alignment: .leading, spacing: 8) {
            Text(UICopy.SOURCES_BROWSERS_GROUP_TITLE)
                .font(.headline)
                .accessibilityIdentifier(AXID.Settings.Sources.browsersGroup)

            if !hasAnyHistory {
                Text(UICopy.SOURCES_BROWSERS_NO_HISTORY)
                    .foregroundStyle(.secondary)
            }

            if hasAnyStore {
                Text(UICopy.SOURCES_BROWSERS_STORES_CONFIGURED)
                    .foregroundStyle(.secondary)
            } else {
                Text(UICopy.SOURCES_BROWSERS_NO_STORE)
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

            ForEach(BrowserBrand.allCases, id: \.self) { brand in
                if appState.browserStoreCatalog.url(for: brand) != nil {
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
            }

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
    private var browserPendingDiscardLine: some View {
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

    private var browserPendingAXState: BrowserRetiredAXState {
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

    private func browserRowStatusText(_ row: BrowserBrandRow) -> String {
        if row.needsAppUpdate { return UICopy.SOURCES_BROWSER_NEEDS_APP_UPDATE }
        if row.needsExtensionUpdate { return UICopy.SOURCES_BROWSER_NEEDS_EXT_UPDATE }
        if row.connectedCount > 0 {
            return UICopy.SOURCES_BROWSER_CONNECTED_NOW
        }
        if let bucket = row.lastSeen {
            return UICopy.sourcesBrowserLastSeen(formatRelativeBucket(bucket))
        }
        return UICopy.SOURCES_BROWSERS_NO_HISTORY
    }

    private var browserRepairValue: BrowserRepairAXState {
        if appState.browserRepair.inFlight { return .inFlight }
        if appState.browserRepair.repaired { return .repaired }
        if appState.browserRepair.lastFailureReason != nil { return .failed }
        return .idle
    }

    private func browserStoreValue(_ brand: BrowserBrand) -> BrowserStoreLaunchAXState {
        switch appState.browserStoreLaunch[brand] ?? .disabled {
        case .disabled: return .disabled
        case .opened: return .opened
        case .failed: return .failed
        }
    }

    private func browserBrandAXID(_ brand: BrowserBrand) -> String {
        switch brand {
        case .chrome: return AXID.Settings.Sources.browserChrome
        case .edge: return AXID.Settings.Sources.browserEdge
        case .firefox: return AXID.Settings.Sources.browserFirefox
        }
    }

    private func browserStoreAXID(_ brand: BrowserBrand) -> String {
        switch brand {
        case .chrome: return AXID.Settings.Sources.browserStoreChrome
        case .edge: return AXID.Settings.Sources.browserStoreEdge
        case .firefox: return AXID.Settings.Sources.browserStoreFirefox
        }
    }
#endif

    // MARK: - Permissions Tab

    private var screenRecordingPermissionAXState: AXPermissionState {
        if appState.screenRecordingGranted {
            return .granted
        }
        return screenRecordingPrompted ? .waiting : .denied
    }

    private var microphonePermissionAXState: AXPermissionState {
        appState.microphoneAuthorizationCause.permissionAXState
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("the solstone app takes in what you share with it, and all of it goes into your journal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("all good")
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                            if screenRecordingPrompted {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("waiting for permission in system settings...")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            } else {
                                Spacer()
                                Button("enable screen recording →") {
                                    Logger.setup.info("Button tapped: enable screen recording")
                                    PermissionChecker().promptScreenRecording()
                                    screenRecordingPrompted = true
                                }
                                .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingEnable)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("microphone")
                        .font(.headline)
                    AXStateCompanion(
                        id: AXID.Settings.Permissions.microphoneState,
                        value: microphonePermissionAXState.axToken
                    )
                    if appState.microphoneGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("all good")
                                .foregroundStyle(.secondary)
                        }
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
                                Button("enable microphone") {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            HStack(spacing: 4) {
                Text("you can review or revoke these anytime in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("system settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    )
                }
                .font(.caption)
                .buttonStyle(.link)
                .accessibilityIdentifier(AXID.Settings.Permissions.systemSettingsOpen)
            }

            if appState.permissionsAreDone &&
                !appState.config.isUploadConfigured &&
                !appState.visitedSettingsTabs.contains(Tab.service.rawValue) {
                navRow(UICopy.SETTINGS_NEXT_CONNECT_JOURNAL) {
                    selectedTab = .service
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AXID.Settings.Permissions.nextConnectJournal)
            }

            Spacer()
        }
        .task(id: screenRecordingPrompted) {
            guard screenRecordingPrompted && !appState.screenRecordingGranted else { return }
            while !Task.isCancelled {
                // Gate on CGPreflightScreenCaptureAccess before calling SCShareableContent.
                // On macOS 26, SCShareableContent.current re-triggers the OS dialog every call
                // when no TCC entry exists yet — i.e. while the user hasn't granted yet.
                if CGPreflightScreenCaptureAccess() {
                    if await PermissionChecker.checkScreenRecording() {
                        screenRestartPending = true
                        appState.capture.publishScreenRecordingPermission(.granted)
                        return
                    }
                    // else: permission not yet granted
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func relaunchApp() {
        appState.appQuitCoordinator.requestSettingsRestart()
    }

    private func microphoneSettingsButton(message: String) -> some View {
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

    private func openMicrophoneSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        )
    }

    private func refreshSetupProbes() {
        Task { @MainActor in
            let permissionChecker = PermissionChecker()
            let screenDiagnostic = await PermissionChecker.screenRecordingDiagnostic()
            setupProbeSnapshot = SetupProbeSnapshot(
                solAppPlacement: solAppPlacementOutcome(),
                journalAppInstalled: runningJournalController.installedURL() == nil ? .needsAttention : .ready,
                hasPromptedScreenRecording: permissionChecker.hasPromptedScreenRecording,
                screenDiagnostic: screenDiagnostic
            )
        }
    }

    private func solAppPlacementOutcome() -> SetupProbeOutcome {
        switch AppPlacementGate.evaluate() {
        case .allowed(.canonical), .allowed(.stableLocation), .allowed(.developerBypass):
            return .ready
        case .repair:
            return .needsAttention
        }
    }

    // MARK: - Observer Tab

    private var observerTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("general") {
                Toggle("start at login", isOn: Binding(
                    get: { appState.isLoginItemEnabled },
                    set: { appState.setLoginItemEnabled($0) }
                ))
                .accessibilityIdentifier(AXID.Settings.Observer.startAtLogin)
                .padding(.vertical, 4)
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
    private var notificationAuthorizationDetails: some View {
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

    private var serviceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            serviceSection
            Spacer()
            if appState.serviceIsDone && !appState.visitedSettingsTabs.contains(Tab.status.rawValue) {
                navRow(UICopy.SETTINGS_NEXT_CHECK_STATUS) {
                    selectedTab = .status
                }
                .accessibilityIdentifier(AXID.Settings.Service.nextCheckStatus)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var journalPathIsValid: Bool {
        isJournalPathValid(appState.config.journalPath)
    }

    @ViewBuilder
    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if appState.permissionsNeedAttention {
                attentionRow(UICopy.SETTINGS_PREREQ_PERMISSIONS) {
                    selectedTab = .permissions
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
    private var configuredJournalPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("name") {
                    Text(resolvedJournalName)
                        .accessibilityIdentifier(AXID.Settings.Service.journalNameState)
                        .accessibilityValue(resolvedJournalName)
                }

                if appState.isJournalMarkConfirmed {
                    if let mark = appState.confirmedMark {
                        JournalMarkView(mark: mark, isConfirmed: true)
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
    private var journalAddressRows: some View {
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
    private var unconfiguredJournalPanel: some View {
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
    private var localJournalDiscoveryPanel: some View {
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
                            Button("confirm") {
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
                        // journal-mark.md section 4.3 — the org-wide "no journal identity yet"
                        // treatment. Never an empty box, never hidden.
                        JournalMarkView(mark: nil)
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
                        }

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
                        Button("create your journal on this mac") {
                            freshFlow.start()
                        }
                        .accessibilityIdentifier(AXID.Settings.Service.createJournalThisMac)
                        .disabled(freshFlow.state.isBusy)

                        if freshFlow.state != .idle {
                            Text(freshFlow.state.ownerStatusMessage)
                                .font(.caption)
                                .foregroundStyle(freshJournalStatusColor(for: freshFlow.state))
                        }

                        localJournalPairButton
                    }
                }

                if let localLinkError {
                    Text(localLinkError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        }

        if showPairingFlow {
            pairingSection
        }
    }

    private var localJournalDiscoveryPanelModel: LocalJournalDiscoveryPanelModel {
        if let localJournalMark {
            return .foundRunning(localJournalMark)
        }
        if let localOnDiskDiscoveryPath {
            return .foundOnDisk(path: localOnDiskDiscoveryPath)
        }
        return .none
    }

    private var localJournalPairButton: some View {
        Button("pair to a journal on another device") {
            showPairingFlow = true
        }
        .accessibilityIdentifier(AXID.Settings.Service.pairJournalAnotherDevice)
    }

    private var journalMigrationBanner: some View {
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
                }
                AXStateCompanion(
                    id: AXID.Settings.Service.journalHandoffState,
                    value: journalHandoffOrchestrator.step.axState.axToken
                )
            }
            Spacer(minLength: 0)
            Button {
                journalHandoffOrchestrator.start(
                    appState: appState,
                    markDriver: journalMarkDriver,
                    markFetch: markFetch
                )
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

    private var journalHandoffStatusColor: Color {
        switch journalHandoffOrchestrator.step {
        case .failed, .aborted:
            return .red
        case .completed:
            return .green
        default:
            return .secondary
        }
    }

    private func freshJournalStatusColor(for state: FreshJournalState) -> Color {
        switch state {
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var resolvedJournalName: String {
        resolvedJournalDisplayName(
            isConfirmed: appState.isJournalMarkConfirmed,
            mark: appState.confirmedMark
        )
    }

    private var journalLocationLabel: String {
        solstone.journalLocationLabel(
            isSameMacJournalDoor: isSameMacJournalDoor(
                sameMachineStoredPairingState: appState.tunnelLifecycleOwner.sameMachineStoredPairingState,
                serverURL: appState.config.serverURL
            )
        )
    }

    private var journalConnectionPresentation: JournalConnectionVerdict {
        journalConnectionVerdictPresentation(
            tunnel: appState.tunnelLifecycleOwner.connectionVerdict,
            pairingMismatch: pairingMismatch
        )
    }

    private var journalPanelAffordancesForPresentation: JournalPanelAffordances {
        let presentation = journalConnectionPresentation
        return journalPanelAffordances(
            for: journalPanelRemedy(
                failureCause: presentation.failureCause,
                axToken: presentation.axToken
            )
        )
    }

    private var externalJournalSyncSection: some View {
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

    private var lastDeliveryDetailRow: some View {
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

    private var externalJournalStorageSection: some View {
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

    private func navRow(_ text: String, action: @escaping () -> Void) -> some View {
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

    private func attentionRow(_ text: String, action: @escaping () -> Void) -> some View {
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

    private var pairingSection: some View {
        GroupBox("pairing") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("pairing link").font(.caption).foregroundStyle(.secondary)
                    TextField(UICopy.PAIRING_LINK_PLACEHOLDER, text: $pairingLink)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AXID.Settings.Service.pairingLink)
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

                pairingFailureRow

                if !appState.showsConfiguredJournal {
                    tunnelErrorRetryRow
                }

            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var pairingDisconnectControls: some View {
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
    private var pairingResultView: some View {
        if let mark = appState.confirmedMark, pairingCanUnpair {
            JournalMarkView(mark: mark, isConfirmed: true)
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
    private func configuredJournalRecoveryRow(for cause: JournalConnectionFailureCause?) -> some View {
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

    private var pairingMismatchPane: some View {
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

    private var pairingConnectionTruthRow: some View {
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

    private var pairingDisconnectConfirmText: String {
        if let mark = appState.confirmedMark {
            return "disconnect this mac from \(JournalMarkSlot.join(mark.words))? your journal keeps everything. you can pair again anytime."
        }
        return UICopy.PAIRING_DISCONNECT_CONFIRM
    }

    private var pairingSwitchConfirmText: String {
        "this link is for a different journal. switch to it?"
    }

    @ViewBuilder
    private var pairingFailureRow: some View {
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
        case .idle, .pairing, .switchConfirmPending, .paired, .alreadyConnected, .switched:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tunnelErrorRetryRow: some View {
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

    private var coordinatorShowsPairingRetry: Bool {
        switch appState.pairingCoordinator.state {
        case .failed, .saveFailed:
            return true
        default:
            return false
        }
    }

    private var pairingResultText: String? {
        solstone.pairingResultText(
            for: appState.pairingCoordinator.state,
            isPairedHome: appState.isPairedHome,
            sameMachineHomeMigrationComplete: appState.sameMachineHomeMigrationComplete
        )
    }

    private var pairingIsBusy: Bool {
        if case .pairing = appState.pairingCoordinator.state {
            return true
        }
        return false
    }

    private var pairingCanUnpair: Bool {
        appState.tunnelLifecycleOwner.hasPersistedPairing || pairingResultText != nil
    }

    private func submitPairingLink() {
        pairingMismatch = false
        journalMarkRederiveEligible = false
        journalMarkRederiveStarted = false
        journalMarkDriver.resetForNewPairAttempt()
        appState.clearConfirmedMark()
        // The owner is pairing on purpose, so the mark question is owed again. This is the only
        // thing that re-arms it after an automatic same-machine adoption suppressed it.
        appState.isAdoptingSameMachineHomeAutomatically = false
        Task {
            await appState.pairingCoordinator.submitPairingLink(pairingLink)
        }
    }

    private func disconnectPairing() {
        disconnectConfirmPending = false
        Task { @MainActor in
            await appState.pairingCoordinator.unpair()
            if appState.pairingCoordinator.state == .idle {
                appState.clearConfirmedMark()
                pairingMismatch = false
                journalMarkRederiveEligible = false
                journalMarkRederiveStarted = false
                journalMarkDriver.resetForNewPairAttempt()
            }
        }
    }

    @ViewBuilder
    private var externalServiceSection: some View {
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
                        selectedTab = .status
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
    private func normalizeServerURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed.contains(":") ? trimmed : "\(trimmed):5015")"
    }

    // MARK: - Service Connection Logic

    private func testServiceConnection() {
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

    private func invalidateConnectionTestState() {
        inFlightTestID = nil
        appState.connectionTestState = .idle
    }

    private func saveService(url: String, key: String, mode: ServiceMode) {
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

    private func refreshLocalJournalDiscoveryIfNeeded() {
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

    private func reprobeLocalJournalOnReturn() {
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
                break
            }
            localDiscoveryInFlight = false
            lastProbeFinishedAt = Date()
        }
    }

    private func relinkJournal() {
        resetForJournalRelink(appState: appState, journalMarkDriver: journalMarkDriver)
        localLinkError = nil
        if BundledJournalEndpoint.isBundledServiceURL(appState.config.serverURL) ||
            appState.config.serviceMode == .bundled {
            confirmLocalJournalLink()
        } else {
            showPairingFlow = true
        }
    }

    private func confirmLocalJournalLink() {
        localLinkInProgress = true
        localLinkError = nil
        resetForJournalRelink(appState: appState, journalMarkDriver: journalMarkDriver)

        Task { @MainActor in
            let result = await performSameMachineHomePairing(
                baseURL: ServiceMode.bundledServiceURL,
                existingPairing: appState.tunnelLifecycleOwner.sameMachineStoredPairingState,
                startPairing: sameMachinePairStart,
                submitPairingLink: { exactPairLink in
                    await appState.pairingCoordinator.submitPairingLink(exactPairLink)
                    return appState.pairingCoordinator.state
                }
            )

            switch result {
            case .pairingStarted, .notEligible:
                localLinkInProgress = false
                localDiscoveryCompleted = true
                showPairingFlow = false
            case .failed:
                localLinkInProgress = false
                localLinkError = "couldn't connect to your journal. try again."
            }
        }
    }

    // MARK: - Microphone Tab

    private var microphoneDisplayEntries: [MicrophoneDisplayEntry] {
        let connectedUIDs = Set(appState.audioDeviceMonitor.availableDevices.map { $0.uid })
        return appState.config.microphonePriority.map { entry in
            MicrophoneDisplayEntry(
                from: entry,
                isConnected: connectedUIDs.contains(entry.uid)
            )
        }
    }

    private var microphoneTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("microphone priority") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("drag to reorder. the microphone at the top is used first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if microphoneDisplayEntries.isEmpty {
                        Text("no microphones found yet")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        List {
                            ForEach(microphoneDisplayEntries) { entry in
                                MicrophoneRow(
                                    entry: entry,
                                    onDelete: { deleteMicrophone(uid: entry.uid) },
                                    onToggleDisabled: { toggleMicrophoneDisabled(uid: entry.uid) }
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

            Spacer()
        }
    }

    private func snapGain(_ value: Float) -> Float {
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

    private var microphoneGainBinding: Binding<Float> {
        Binding(
            get: { snapGain(appState.config.microphoneGain) },
            set: { newValue in
                var config = appState.config
                config.microphoneGain = snapGain(newValue)
                appState.updateConfig(config)
            }
        )
    }

    private var silenceMusicBinding: Binding<Bool> {
        Binding(
            get: { appState.config.silenceMusic },
            set: { newValue in
                var config = appState.config
                config.silenceMusic = newValue
                appState.updateConfig(config)
            }
        )
    }

    private func moveMicrophones(from: IndexSet, to: Int) {
        var newConfig = appState.config
        newConfig.reorderMicrophones(fromOffsets: from, toOffset: to)
        appState.updateConfig(newConfig)
    }

    private func deleteMicrophone(uid: String) {
        var newConfig = appState.config
        _ = newConfig.removeMicrophone(uid: uid)
        appState.updateConfig(newConfig)
    }

    private func toggleMicrophoneDisabled(uid: String) {
        var newConfig = appState.config
        newConfig.toggleMicrophoneDisabled(uid: uid)
        appState.updateConfig(newConfig)
    }

    // MARK: - Privacy Tab

    private func privacyTab(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                            .accessibilityHint("turning this on asks for Accessibility access, which lets an app see and control everything on this mac. solstone uses it only to read these browsers' window titles and to check that the access works.")
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
                        guard !Task.isCancelled, selectedTab == .privacy,
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
        .padding(.vertical, 4)
    }

    private static let privateWindowAccessibilityExplanation = "this needs Accessibility access (called Device Control and Data Access on macOS 27), which lets an app see and control everything on this mac, far more than window titles. solstone uses it only to read the window titles these browsers give to accessibility tools, and to check that the access works; those titles stay on this mac. turning this on asks for it, and allowing it needs your mac's password."

    @ViewBuilder
    private var privateWindowAccessibilityStatus: some View {
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

    private var privateWindowAccessibilityState: PrivateWindowAccessibilityState {
        appState.privateWindowAccessibilityEnabled ? appState.privateWindowAccessibilityMonitor.state : .off
    }

    private var privateWindowPrivacyIsVisible: Bool {
        selectedTab == .privacy && !NSApp.isHidden && NSApp.windows.contains {
            $0.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
                && $0.isVisible && !$0.isMiniaturized
        }
    }

    private var excludePrivateBrowsingAccessibilityBinding: Binding<Bool> {
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
                    AccessibilityTitleReader.ask()
                }
            }
        )
    }

    private var excludePrivateBrowsingBinding: Binding<Bool> {
        Binding(
            get: { appState.config.excludePrivateBrowsing },
            set: { newValue in
                var config = appState.config
                config.excludePrivateBrowsing = newValue
                appState.updateConfig(config)
            }
        )
    }

    private func addTitlePattern() {
        let pattern = newTitlePattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }

        var config = appState.config
        if !config.excludedTitlePatterns.contains(where: { $0.lowercased() == pattern.lowercased() }) {
            config.excludedTitlePatterns.append(pattern)
            appState.updateConfig(config)
        }
        newTitlePattern = ""
    }

    private func deleteTitlePattern(at index: Int) {
        var config = appState.config
        config.excludedTitlePatterns.remove(at: index)
        appState.updateConfig(config)
    }

    private func addExcludedApp(name: String? = nil) {
        let rawName = name ?? newExcludedApp
        let updated = ExcludedAppPicker.appending(rawName, to: appState.config.excludedApps)
        if updated.count != appState.config.excludedApps.count {
            var config = appState.config
            config.excludedApps = updated
            appState.updateConfig(config)
        }
        newExcludedApp = ""
    }

    private func deleteExcludedApp(at index: Int) {
        var config = appState.config
        config.excludedApps.remove(at: index)
        appState.updateConfig(config)
    }

    // MARK: - Status Tab

    /// True when the health card above has already claimed the source state as its verdict and
    /// this group would render an empty box under its own heading.
    private var statusGroupIsFullyClaimedByVerdict: Bool {
        guard !appState.isRecording, !appState.isPaused, appState.config.selectedSources.isEmpty else {
            return false
        }
        return observationRecoveryPresentation(
            observationRowState: appState.observationRowState,
            errorMessage: appState.errorMessage,
            tryAgainInFlight: tryAgainInFlight,
            uploadStatus: appState.uploadCoordinator.status
        ) == nil
    }

    private var renderedObservationAXState: SettingsObservationAXState {
        SettingsObservationAXState(appState.observationRowState)
    }

    private var renderedObservationText: String {
        if appState.isRecording || appState.isPaused || appState.errorMessage == nil {
            return appState.captureSourcesStatusText
        }
        return renderedObservationAXState.headline
    }

    private var storageGlanceText: String {
        if let storageUsedMB {
            return "\(storageUsedMB) MB"
        }
        return "calculating"
    }

    private var statusFooterText: String {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        sourcesFooter(media: appState.captureSourcesStatusText, lead: sourcesLead)
#else
        appState.captureSourcesStatusText
#endif
    }

    private var setupTopology: SetupTopology {
        classifySetupTopology(
            serviceMode: appState.config.serviceMode,
            serverURL: appState.config.serverURL,
            isTunnelManaged: appState.tunnelLifecycleOwner.isTunnelManaged,
            isPairedHome: appState.isPairedHome
        )
    }

    private var setupSnapshotPresentation: SetupSnapshotPresentation {
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

    private var primaryLastDeliveryOutcome: LastJournalDeliveryOutcome {
        appState.serviceIsDone ? appState.uploadCoordinator.lastJournalDeliveryOutcome : .notLinked
    }

    private var statusHealthSummary: StatusHealthSummary {
        let setupPresentation = setupSnapshotPresentation
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        return StatusHealthSummary.makeIncludingBrowser(
            serviceMode: appState.config.serviceMode,
            isRecording: appState.isRecording,
            isPaused: appState.isPaused,
            held: appState.needsJournalMarkConfirmation,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: appState.uploadCoordinator.status,
            pendingCount: appState.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: statusPrimaryDelivery(
                media: appState.uploadCoordinator.lastJournalDeliveryOutcome,
                browserDelivery: appState.browserHostSnapshot.value.delivery
            ),
            journalSlot: resolvedJournalName,
            now: Date(),
            selectedSources: appState.config.selectedSources,
            permittedSources: appState.capture.permittedSources,
            errorMessage: appState.errorMessage,
            setupVerdict: setupPresentation.verdict,
            lastHealthReason: appState.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: appState.isPairedIngestReady,
            journalConnectionAXToken: appState.tunnelLifecycleOwner.connectionVerdict.axToken,
            snapshot: appState.browserHostSnapshot.value
        )
#else
        return StatusHealthSummary.make(
            serviceMode: appState.config.serviceMode,
            isRecording: appState.isRecording,
            isPaused: appState.isPaused,
            held: appState.needsJournalMarkConfirmation,
            hasPersistedPairing: appState.tunnelLifecycleOwner.hasPersistedPairing,
            uploadStatus: appState.uploadCoordinator.status,
            pendingCount: appState.uploadCoordinator.pendingCount,
            lastDeliveryOutcome: appState.uploadCoordinator.lastJournalDeliveryOutcome,
            journalSlot: resolvedJournalName,
            now: Date(),
            selectedSources: appState.config.selectedSources,
            permittedSources: appState.capture.permittedSources,
            errorMessage: appState.errorMessage,
            setupVerdict: setupPresentation.verdict,
            lastHealthReason: appState.uploadCoordinator.lastHealthReason,
            isPairedIngestReady: appState.isPairedIngestReady,
            journalConnectionAXToken: appState.tunnelLifecycleOwner.connectionVerdict.axToken
        )
#endif
    }

    @ViewBuilder
    private func healthSummaryCard(showsAction: Bool = true) -> some View {
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
                        selectedTab = effect.tab
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

    private var aboutBlock: String {
        AboutPresentation.captureBlock(journal: appState.tunnelLifecycleOwner.journalVersion)
    }

    private var setupGroup: some View {
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
                        selectedTab = .service
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AXID.Settings.Status.setupManageJournal)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func setupCheckRow(_ row: SetupCheckRow) -> some View {
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

    private func setupStateAXID(for rowID: SetupCheckRowID) -> String {
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

    private func setupActionAXID(for rowID: SetupCheckRowID) -> String? {
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

    private func performSetupAction(_ action: SetupCheckAction) {
        switch action {
        case .openApplications:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .openJournalSettings, .connectJournal:
            selectedTab = .service
        case .grantPermission:
            selectedTab = .permissions
        }
    }

    private func setupRowColor(_ state: SetupCheckRowAXState) -> Color {
        switch state {
        case .ready:
            return .green
        case .needsAttention, .unavailable:
            return .red
        case .notRequired, .checking:
            return .secondary
        }
    }

    private func setupVerdictColor(_ verdict: SetupGroupVerdict) -> Color {
        verdict.severity.color
    }

    private func setupVerdictSystemImage(_ verdict: SetupGroupVerdict) -> String {
        switch verdict {
        case .ready:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .someUnavailable:
            return "questionmark.circle.fill"
        }
    }

    private var statusTab: some View {
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
                            selectedTab = .service
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
    private var debugSegmentsBinding: Binding<Bool> {
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
    private var uploadStatusView: some View {
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

    private func uploadCheckedCount(for status: UploadCoordinator.Status) -> Int {
        if case .syncing(let checked, _) = status {
            return checked
        }
        return 0
    }

    private func uploadTotalCount(for status: UploadCoordinator.Status) -> Int {
        if case .syncing(_, let total) = status {
            return total
        }
        return 0
    }

    private func uploadStatusColor(for status: UploadCoordinator.Status) -> Color {
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
    private var connectionTestIcon: some View {
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

    private var agentInstructions: String {
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

    private var helpTab: some View {
        let displayedAbout = aboutBlock
        return VStack(alignment: .leading, spacing: 20) {
            GroupBox("get help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("need a hand? reach a human. we're happy to help.")
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
                                    copyDiagnostics(diagnosticReport)
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

    private func toggleDiagnostics() {
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
            let evidence = await appState.readDiagnosticEvidence()
            let backlog = await appState.uploadCoordinator.readDiagnosticBacklog()
            guard shouldPublishDiagnosticLoad(
                loadGeneration,
                activeGeneration: diagnosticLoadGeneration,
                diagnosticsExpanded: diagnosticsExpanded
            ) else { return }
            var reportInput = DiagnosticReportInput(
                appVersion: AppVersion.short,
                screenRecording: currentScreenPermissionOutcome,
                microphone: currentMicrophonePermissionOutcome,
                isRecording: appState.isRecording,
                isPaused: appState.isPaused,
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
                )
            )
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            reportInput.browserRows = buildBrowserDiagnosticRows(
                snapshot: appState.browserHostSnapshot.value,
                repair: appState.browserRepair,
                now: Date()
            )
#endif
            reportInput.backlog = backlog
            diagnosticReport = buildDiagnosticReport(reportInput)
            diagnosticsLoading = false
        }
    }

    private func openProblemReport(aboutSnapshot: String) {
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
                : (appState.isPaused ? "paused" : (appState.isRecording ? "on" : "off"))
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

    private var currentScreenPermissionOutcome: PermissionOutcome {
        PermissionOutcome.screenRecording(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            screenRecordingGranted: appState.screenRecordingGranted,
            hasPromptedScreenRecording: setupProbeSnapshot.hasPromptedScreenRecording,
            preflightSucceeded: setupProbeSnapshot.screenDiagnostic?.preflightSucceeded,
            sckFailedAfterPositivePreflight: setupProbeSnapshot.screenDiagnostic?.sckFailedAfterPositivePreflight ?? false
        )
    }

    private var currentMicrophonePermissionOutcome: PermissionOutcome {
        PermissionOutcome.microphone(
            initialPermissionCheckComplete: appState.initialPermissionCheckComplete,
            cause: appState.microphoneAuthorizationCause
        )
    }

    private func copyDiagnostics(_ report: DiagnosticReport) {
        diagnosticCopyFeedback = performDiagnosticCopy(
            report,
            write: diagnosticClipboardWrite,
            announce: diagnosticAnnouncement
        )
    }

    private var logExportFailureReasonValue: String {
        guard case .failed(let reason) = logExportDocument?.outcome else {
            return ""
        }
        return reason
    }

    @ViewBuilder
    private func logExportOutcomeViews(_ document: LogExportDocument) -> some View {
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

    private func startLogExportRead() {
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

    private func cancelLogExportRead() {
        logExportTask?.cancel()
        logExportTask = nil
        logExportGeneration &+= 1
        logExportLoading = false
    }

    private func saveLogExport(_ document: LogExportDocument) {
        logExportWriteFeedback = performLogExportSave(
            document: document,
            chooseURL: logExportChooseSaveURL,
            writer: logExportWriter
        )
    }

    @ViewBuilder
    private func diagnosticAXCompanions(_ report: DiagnosticReport) -> some View {
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

    private func diagnosticRowAXID(_ rowID: DiagnosticReportRowID) -> String {
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

    private var indicatorColor: Color {
        if !entry.isConnected {
            return .gray
        }
        return entry.isDisabled ? .orange : .green
    }

    private var axStateValue: String {
        let connection = entry.isConnected ? "connected" : "disconnected"
        let enabled = entry.isDisabled ? "disabled" : "enabled"
        return "\(connection)_\(enabled)"
    }

    var body: some View {
        HStack {
            // Connection status indicator
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            // Microphone name
            Text(entry.name)
                .strikethrough(entry.isDisabled)
                .foregroundStyle(entry.isConnected ? (entry.isDisabled ? .secondary : .primary) : .secondary)

            Spacer()

            // Disable/Enable toggle
            Button(action: onToggleDisabled) {
                Image(systemName: entry.isDisabled ? "mic.slash" : "mic")
                    .foregroundStyle(entry.isDisabled ? .orange : .green)
            }
            .buttonStyle(.plain)
            .help(entry.isDisabled ? "enable microphone" : "disable microphone")
            .accessibilityIdentifier(AXID.Settings.Microphones.deviceToggle(entry.uid))

            // Delete button (only for connected mics)
            if entry.isConnected {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("remove from priority list")
                .accessibilityIdentifier(AXID.Settings.Microphones.deviceRemove(entry.uid))
            } else {
                Text("disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier(AXID.Settings.Microphones.device(entry.uid))
        .accessibilityValue(axStateValue)
    }
}
