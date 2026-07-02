// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UserNotifications
import os
import SolstoneCore

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

func serviceTabHeadingText(for mode: ServiceMode?) -> String? {
    mode == nil ? "set up your journal" : nil
}

func initialServiceMode(for config: AppConfig) -> ServiceMode {
    config.serviceMode ?? .bundled
}

struct PairingConnectionPresentation {
    let message: String
    let severity: StatusDotSeverity
    let axToken: String
}

func makePairingConnectionPresentation(
    for state: TunnelLifecycleState,
    hasPairing: Bool
) -> PairingConnectionPresentation {
    switch state {
    case .connected:
        return PairingConnectionPresentation(
            message: "sync can connect through your journal",
            severity: .good,
            axToken: PairingConnectionAXState.connected.axToken
        )
    case .connecting:
        return PairingConnectionPresentation(
            message: "connecting to your journal…",
            severity: .warn,
            axToken: PairingConnectionAXState.connecting.axToken
        )
    case .disconnected:
        return PairingConnectionPresentation(
            message: hasPairing ? "paired · waiting to connect" : "not paired",
            severity: .warn,
            axToken: PairingConnectionAXState.disconnected.axToken
        )
    case .error(.notEntitled):
        return PairingConnectionPresentation(
            message: "can't sync over the internet yet",
            severity: .warn,
            axToken: PairingConnectionAXState.notEntitled.axToken
        )
    case .error(.revoked):
        return PairingConnectionPresentation(
            message: "pairing was revoked — pair again to reconnect.",
            severity: .attention,
            axToken: PairingConnectionAXState.revoked.axToken
        )
    case .error(.loopbackUnavailable):
        return PairingConnectionPresentation(
            message: "paired, but the local connection couldn't start",
            severity: .attention,
            axToken: PairingConnectionAXState.loopbackUnavailable.axToken
        )
    case .error(.keychainUnavailable):
        return PairingConnectionPresentation(
            message: "paired, but this Mac couldn't read the pairing",
            severity: .attention,
            axToken: PairingConnectionAXState.keychainUnavailable.axToken
        )
    }
}

func shouldShowPairingRetry(for state: TunnelLifecycleState) -> Bool {
    state == .error(.keychainUnavailable)
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

/// Settings window for configuring server upload
struct SettingsView: View {
    enum Tab: String, Hashable, CaseIterable {
        case permissions = "permissions"
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

    // Permissions tab state
    @State private var screenRecordingPrompted = false
    @State private var restartCountdown: Int? = nil

    // Privacy tab state
    @State private var newTitlePattern = ""
    @State private var newExcludedApp = ""

    // Service tab state
    @State private var observerURL = ""
    @State private var observerKey = ""
    @State private var pairingLink = ""
    @State private var serviceMode: ServiceMode
    @State private var preserveNextServiceFieldChange = false
    @State private var inFlightTestID: UUID?
    @State private var disconnectConfirmPending = false
    @State private var journalMarkDriver = JournalMarkConfirmationDriver()
    @State private var pairingMismatch = false
    @State private var journalMarkRederiveEligible = false
    @State private var journalMarkRederiveStarted = false
    @State private var journalMarkRederiveTask: Task<Void, Never>?

    init(
        appState: AppState,
        updateController: UpdateController,
        selectedTab: Tab = .observer,
        initialStorageUsedMB: Int? = nil
    ) {
        self.appState = appState
        self.updateController = updateController
        self._selectedTab = State(initialValue: selectedTab)
        self._storageUsedMB = State(initialValue: initialStorageUsedMB)
        self._serviceMode = State(initialValue: initialServiceMode(for: appState.config))
    }

    // MARK: - Auto-saving Bindings

    private var cacheRetentionBinding: Binding<Int> {
        Binding(
            get: { appState.config.cacheRetentionDays },
            set: { newValue in
                var config = appState.config
                config.cacheRetentionDays = newValue
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
                    sidebarPlainLabel("microphones", tab: .microphones, systemImage: "mic").tag(Tab.microphones)
                    sidebarPlainLabel("privacy", tab: .privacy, systemImage: "eye.slash").tag(Tab.privacy)
                } header: {
                    Text("inputs")
                }

                Section {
                    sidebarPlainLabel("general", tab: .observer, systemImage: "gearshape").tag(Tab.observer)
                    sidebarLabel(
                        UpdatesCopy.tabTitle,
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
            ScrollView {
                detailContent
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .modifier(SettingsPaneScrollEdgeModifier())
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
            journalMarkRederiveEligible = appState.confirmedMark == nil && appState.tunnelLifecycleOwner.isTunnelManaged
            startJournalMarkRederiveIfNeeded()
        }
        .onChange(of: appState.pairingCoordinator.state) { _, newValue in
            handlePairingStateChange(newValue)
        }
        .onChange(of: appState.pairingCoordinator.tunnelState) { _, _ in
            startJournalMarkRederiveIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
            applyPendingSettingsTab()
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
                .interactiveDismissDisabled(true)
        }
        .onDisappear {
            journalMarkDriver.cancel()
            journalMarkRederiveTask?.cancel()
            journalMarkRederiveTask = nil
        }
        .onExitCommand {
            dismiss()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .status:
            statusTab.onAppear { appState.markSettingsTabVisited(.status) }
        case .observer:
            observerTab.onAppear { appState.markSettingsTabVisited(.observer) }
        case .service:
            serviceTab.onAppear { appState.markSettingsTabVisited(.service) }
        case .microphones:
            microphoneTab.onAppear { appState.markSettingsTabVisited(.microphones) }
        case .privacy:
            privacyTab.onAppear { appState.markSettingsTabVisited(.privacy) }
        case .permissions:
            permissionsTab.onAppear { appState.markSettingsTabVisited(.permissions) }
        case .updates:
            UpdatesTabView(controller: updateController)
                .onAppear { appState.markSettingsTabVisited(.updates) }
        case .help:
            helpTab.onAppear { appState.markSettingsTabVisited(.help) }
        }
    }

    private func applyPendingSettingsTab() {
        if let pending = appState.pendingSettingsTab {
            switch pending {
            case "observer", "general": selectedTab = .observer
            case "permissions": selectedTab = .permissions
            case "service", "journal": selectedTab = .service
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
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func handlePairingStateChange(_ state: PairingFlowState) {
        journalMarkDriver.startIfNeeded(for: state, appState: appState)
    }

    private func confirmJournalMark() {
        journalMarkDriver.confirm(appState: appState)
        pairingMismatch = false
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
              appState.tunnelLifecycleOwner.isTunnelManaged,
              case .connected = appState.pairingCoordinator.tunnelState
        else {
            return
        }

        journalMarkRederiveStarted = true
        journalMarkRederiveTask?.cancel()
        journalMarkRederiveTask = Task { @MainActor in
            let fetcher = JournalIdentityFetcher()
            switch await appState.resolveHomeBase() {
            case .url(let baseURL):
                if let mark = await fetcher.fetch(baseURL: baseURL) {
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
            label
                .badge(Text("!"))
                .tint(.orange)
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

    // MARK: - Permissions Tab

    private var screenRecordingPermissionAXState: AXPermissionState {
        if appState.screenRecordingGranted || restartCountdown != nil {
            return .granted
        }
        return screenRecordingPrompted ? .waiting : .denied
    }

    private var microphonePermissionAXState: AXPermissionState {
        appState.microphoneGranted ? .granted : .denied
    }

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("solstone needs screen recording and microphone access to build your memory.")
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
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("all good")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("this is how you get searchable memory of every meeting, document, and idea. solstone observes your screen alongside you and keeps everything on your Mac, sent only to your journal.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        HStack {
                            if let countdown = restartCountdown {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("granted — restarting in \(countdown)...")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("restart now") { relaunchApp() }
                                        .accessibilityIdentifier(AXID.Settings.Permissions.screenRecordingRestartNow)
                                    AXStateCompanion(
                                        id: AXID.Settings.Permissions.screenRecordingRestartCountdown,
                                        value: axIntegerString(countdown)
                                    )
                                }
                            } else {
                                Spacer()
                                if screenRecordingPrompted {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("waiting for permission in system settings...")
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
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
                        Text("to take in conversations and meetings, solstone needs mic access. same rules: stored locally, sent only to your journal. no third parties, no exceptions.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("enable microphone") {
                                Task {
                                    await PermissionChecker().requestMicrophone()
                                    appState.microphoneGranted = PermissionChecker().microphoneGranted
                                }
                            }
                            .accessibilityIdentifier(AXID.Settings.Permissions.microphoneGrantAccess)
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

            if appState.screenRecordingGranted &&
                appState.microphoneGranted &&
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
                    do {
                        _ = try await SCShareableContent.current
                        restartCountdown = 5
                        return
                    } catch {
                        // permission not yet granted
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: restartCountdown) { _, newValue in
            if let value = newValue, value > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if restartCountdown == value {
                        restartCountdown = value - 1
                    }
                }
            } else if newValue == 0 {
                appState.screenRecordingGranted = true
                relaunchApp()
            }
        }
    }

    private func relaunchApp() {
        appState.appQuitCoordinator.requestSettingsRestart()
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
                    Toggle("notify me when sol reaches out", isOn: solChatNotificationsBinding)
                        .accessibilityIdentifier(AXID.Settings.Observer.solChatNotifications)
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

    private var solChatNotificationsBinding: Binding<Bool> {
        Binding(
            get: { appState.config.solInitiatedChatNotificationsEnabled },
            set: { newValue in appState.setSolChatNotificationPreference(newValue) }
        )
    }

    @ViewBuilder
    private var notificationAuthorizationDetails: some View {
        if appState.notificationAuthorizationStatus == .provisional {
            VStack(alignment: .leading, spacing: 6) {
                Text("want sol's notes to show up with a banner and sound?")
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
        }
    }

    @ViewBuilder
    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            restartRequiredBanner

            if appState.permissionsNeedAttention {
                navRow(UICopy.SETTINGS_PREREQ_PERMISSIONS) {
                    selectedTab = .permissions
                }
                .accessibilityIdentifier(AXID.Settings.Service.prereqPermissions)
            }

            if let heading = serviceTabHeadingText(for: appState.config.serviceMode) {
                Text(heading)
                    .font(.headline)
            }

            Picker("journal mode", selection: $serviceMode) {
                Text(UICopy.JOURNAL_MODE_THIS_MAC_LABEL).tag(ServiceMode.bundled)
                Text(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL).tag(ServiceMode.external)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AXID.Settings.Service.journalModePicker)

            AXStateCompanion(
                id: AXID.Settings.Service.journalModeState,
                value: serviceMode.rawValue
            )

            VStack(alignment: .leading, spacing: 6) {
                tradeoffLine(
                    label: UICopy.JOURNAL_MODE_THIS_MAC_LABEL,
                    text: UICopy.JOURNAL_MODE_THIS_MAC_TRADEOFF
                )
                tradeoffLine(
                    label: UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL,
                    text: UICopy.JOURNAL_MODE_ANOTHER_MACHINE_TRADEOFF
                )
            }

            switch serviceMode {
            case .bundled:
                BundledServiceCard(appState: appState, allowsLocalJournalActions: true)
                bundledJournalStatusSection
                if bundledTroubleshootingVisible {
                    DisclosureGroup("troubleshooting") {
                        VStack(alignment: .leading, spacing: 8) {
                            journalRestartControl
                            journalStopControl
                            journalStartControl
                        }
                    }
                }
            case .external:
                let cardState = terminalCardState(
                    main: appState.installer.main,
                    probe: appState.installer.probedVersion,
                    failureRecord: appState.installer.upgradeFailureRecord
                )
                if shouldShowBundledStatusSurface(cardState: cardState) {
                    BundledServiceCard(appState: appState, allowsLocalJournalActions: false)
                }
                pairingSection
                externalServiceSection
                externalJournalSyncSection
                externalJournalStorageSection
            }
        }
    }

    @ViewBuilder
    private var bundledJournalStatusSection: some View {
        if appState.bundledJournalStatusAvailable {
            GroupBox("journal status") {
                VStack(alignment: .leading, spacing: 8) {
                    bundledJournalStatusRows
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var bundledJournalStatusRows: some View {
        LabeledContent("journal") {
            let presentation = appState.journalRuntimeStatus.settingsPresentation
            VStack(alignment: .trailing, spacing: 2) {
                Text(presentation.shortText)
                    .foregroundStyle(presentation.severity.color)
                    .accessibilityIdentifier(AXID.Settings.Status.journalRuntimeState)
                    .accessibilityValue(presentation.axValue)
                if let reason = presentation.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        if appState.captureQueuedForJournalReadiness {
            LabeledContent("journal") {
                Text(UICopy.JOURNAL_WAITING_FOR_READINESS)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AXID.Settings.Status.journalReadinessQueueState)
                    .accessibilityValue(MenubarStatusRowState.journalWaiting.axToken)
            }
        }
    }

    private var externalJournalSyncSection: some View {
        GroupBox("sync") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("journal") {
                    Text(appState.config.serverURL ?? "not configured")
                        .foregroundStyle(appState.config.serverURL == nil ? .secondary : .primary)
                        .accessibilityIdentifier(AXID.Settings.Status.uploadJournalState)
                        .accessibilityValue(appState.config.serverURL ?? "")
                }
                uploadStatusView
                Toggle("pause sync", isOn: Binding(
                    get: { appState.config.syncPaused },
                    set: { newValue in
                        var config = appState.config
                        config.syncPaused = newValue
                        appState.updateConfig(config)
                    }
                ))
                .disabled(!appState.config.isUploadConfigured)
                .help("keeps observing locally but stops sending to your journal")
                .accessibilityIdentifier(AXID.Settings.Status.pauseSync)
                if let lastSynced = appState.uploadCoordinator.lastSyncedAt {
                    LabeledContent("last synced") {
                        Text(lastSynced, style: .relative)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AXID.Settings.Status.lastSyncedState)
                            .accessibilityValue(axIntegerString(Int(lastSynced.timeIntervalSince1970)))
                    }
                }
                if let error = appState.uploadCoordinator.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Status.lastErrorState)
                        .accessibilityValue(error)
                }
                Button("resync all") {
                    appState.uploadCoordinator.forceFullSync()
                }
                .help("re-check all days, including previously synced ones")
                .accessibilityIdentifier(AXID.Settings.Status.resyncAll)
            }
            .padding(.vertical, 4)
        }
    }

    private var externalJournalStorageSection: some View {
        GroupBox("kept on this Mac") {
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

                LabeledContent("keep on this Mac for") {
                    Picker("", selection: cacheRetentionBinding) {
                        Text("don't keep").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("forever").tag(-1)
                    }
                    .accessibilityIdentifier(AXID.Settings.Observer.cacheRetentionPicker)
                    .frame(width: 120)
                    AXStateCompanion(
                        id: AXID.Settings.Observer.cacheRetentionState,
                        value: axIntegerString(appState.config.cacheRetentionDays)
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

                Text("synced segments older than the retention period are removed from your Mac. unsynced segments are never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var restartRequiredBanner: some View {
        if appState.restartRequiredBannerVisible
            && appState.config.serviceMode == .bundled
            && appState.bundledJournalRestartAvailable {
            Button {
                appState.requestJournalRestart()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Text(UICopy.SETTINGS_RESTART_REQUIRED_BANNER)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(appState.journalRuntimeStatus.isRestarting)
            .accessibilityIdentifier(AXID.Settings.Service.restartRequiredBanner)
            .accessibilityHint(Text("restart the bundled journal supervisor so the saved change takes effect"))
        }
    }

    @ViewBuilder
    private var journalRestartControl: some View {
        if appState.config.serviceMode == .bundled
            && appState.bundledJournalRestartAvailable
            && !appState.restartRequiredBannerVisible
            && journalRestartControlVisible {
            Button {
                appState.requestJournalRestart()
            } label: {
                Label(UICopy.RESTART_JOURNAL, systemImage: "arrow.clockwise")
            }
            .disabled(appState.journalRuntimeStatus.isRestarting)
            .accessibilityIdentifier(AXID.Settings.Service.restartJournalButton)
        }
    }

    private var journalRestartControlVisible: Bool {
        appState.journalRuntimeStatus.canOfferRestart
    }

    @ViewBuilder
    private var journalStopControl: some View {
        if appState.config.serviceMode == .bundled
            && appState.bundledJournalRestartAvailable
            && !appState.restartRequiredBannerVisible
            && journalStopControlVisible {
            Button {
                appState.requestJournalStop()
            } label: {
                Label(UICopy.STOP_JOURNAL, systemImage: "stop.circle")
            }
            .accessibilityIdentifier(AXID.Settings.Service.stopJournalButton)
        }
    }

    @ViewBuilder
    private var journalStartControl: some View {
        if appState.config.serviceMode == .bundled
            && appState.bundledJournalRestartAvailable
            && !appState.restartRequiredBannerVisible
            && journalStartControlVisible {
            Button {
                appState.requestJournalStart()
            } label: {
                Label(UICopy.START_JOURNAL, systemImage: "play.circle")
            }
            .accessibilityIdentifier(AXID.Settings.Service.startJournalButton)
        }
    }

    private var journalStopControlVisible: Bool {
        if case .running = appState.journalRuntimeStatus { return true }
        return false
    }

    private var journalStartControlVisible: Bool {
        appState.journalRuntimeStatus.isStoppedByUser
    }

    private var bundledTroubleshootingVisible: Bool {
        appState.bundledJournalRestartAvailable
            && !appState.restartRequiredBannerVisible
            && (journalRestartControlVisible || journalStopControlVisible || journalStartControlVisible)
    }

    private func tradeoffLine(label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(label):")
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
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

    private var pairingSection: some View {
        GroupBox("pairing") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("pairing link").font(.caption).foregroundStyle(.secondary)
                    TextField("paste relay pairing link", text: $pairingLink)
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

                pairingConnectionTruthRow

                if pairingMismatch {
                    pairingMismatchPane
                }

                if case .error(.notEntitled) = appState.pairingCoordinator.tunnelState {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(UICopy.PAIRING_NOTENTITLED_RECOVERY)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Link("set up the paid plan ↗", destination: URL(string: "https://link.solstone.app")!)
                            .font(.callout)
                            .accessibilityIdentifier(AXID.Settings.Service.pairingPaidPlanLink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                }

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

                if case .switchConfirmPending = appState.pairingCoordinator.state {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("this link is for a different journal. switch to it?")
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

                tunnelErrorRetryRow

                AXStateCompanion(
                    id: AXID.Settings.Service.pairingFlowState,
                    value: appState.pairingCoordinator.state.axToken
                )
                AXStateCompanion(
                    id: AXID.Settings.Service.pairingConnectionState,
                    value: pairingConnectionPresentation.axToken
                )
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var pairingResultView: some View {
        if let mark = appState.confirmedMark, pairingCanUnpair {
            JournalMarkView(mark: mark, isConfirmed: true)
        } else if let result = pairingResultText {
            LabeledContent("pairing") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(result)
                }
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
                    if let url = URL(string: "mailto:support@solstone.app") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityIdentifier(AXID.Settings.Service.pairingMismatchSupport)
            }
        }
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
        let presentation = pairingConnectionPresentation
        return LabeledContent("connection") {
            HStack(spacing: 6) {
                Circle()
                    .fill(presentation.severity.color)
                    .frame(width: 8, height: 8)
                Text(presentation.message)
                    .foregroundStyle(presentation.severity.color)
            }
        }
    }

    private var pairingDisconnectConfirmText: String {
        if let mark = appState.confirmedMark {
            return "disconnect this Mac from \(mark.words.joined(separator: " · "))? your journal keeps everything — you can pair again anytime."
        }
        return UICopy.PAIRING_DISCONNECT_CONFIRM
    }

    @ViewBuilder
    private var pairingFailureRow: some View {
        switch appState.pairingCoordinator.state {
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.message)
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
                Text("pairing worked, but this Mac couldn't save it. try again.")
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
        if shouldShowPairingRetry(for: appState.pairingCoordinator.tunnelState),
           !coordinatorShowsPairingRetry {
            HStack {
                Button("retry") {
                    Task { await appState.tunnelLifecycleOwner.reevaluatePairing() }
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
        switch appState.pairingCoordinator.state {
        case .paired:
            return "paired ✓"
        case .alreadyConnected:
            return "already paired ✓"
        case .switched:
            return "switched ✓"
        case .idle, .pairing, .switchConfirmPending, .saveFailed, .failed:
            return nil
        }
    }

    private var pairingIsBusy: Bool {
        if case .pairing = appState.pairingCoordinator.state {
            return true
        }
        return false
    }

    private var pairingCanUnpair: Bool {
        appState.tunnelLifecycleOwner.isTunnelManaged || pairingResultText != nil
    }

    private var pairingConnectionPresentation: PairingConnectionPresentation {
        makePairingConnectionPresentation(
            for: appState.pairingCoordinator.tunnelState,
            hasPairing: pairingCanUnpair
        )
    }

    private func submitPairingLink() {
        pairingMismatch = false
        journalMarkRederiveEligible = false
        journalMarkRederiveStarted = false
        journalMarkDriver.resetForNewPairAttempt()
        appState.clearConfirmedMark()
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
                    TextField("localhost, host:port, or https://...", text: $observerURL)
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
                    .disabled(observerURL.isEmpty || observerKey.isEmpty || appState.connectionTestState == .testing)
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
        Text("observations are sent only to your configured journal. nothing else, nowhere else.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .onChange(of: observerURL) { _, _ in invalidateConnectionTestState() }
            .onChange(of: observerKey) { _, _ in invalidateConnectionTestState() }
    }

    /// Normalizes flexible host input to a full URL.
    /// Accepts: "localhost", "myhost:5015", "https://myhost", full URLs.
    private func normalizeServerURL(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed.contains(":") ? trimmed : "\(trimmed):5015")"
    }

    // MARK: - Service Connection Logic

    private func testServiceConnection() {
        let url = normalizeServerURL(observerURL)
        let key = observerKey
        let testGeneration = UUID()
        inFlightTestID = testGeneration
        appState.connectionTestState = .testing
        Task {
            let error = await UploadCoordinator.testConnection(serverURL: url, serverKey: key)
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
                    if observerURL != url {
                        preserveNextServiceFieldChange = true
                    }
                    observerURL = url
                    appState.connectionTestState = .success
                }
            }
        }
    }

    private func invalidateConnectionTestState() {
        if preserveNextServiceFieldChange {
            preserveNextServiceFieldChange = false
            return
        }
        inFlightTestID = nil
        appState.connectionTestState = .idle
    }

    private func saveService(url: String, key: String, mode: ServiceMode) {
        var config = appState.config
        config.serverURL = url
        config.serverKey = key
        config.serviceMode = mode
        appState.updateConfig(config)
        if appState.microphoneGranted {
            Task {
                await appState.startRecording()
                if mode != .bundled || appState.journalDependentServicesReady {
                    Task.detached { await appState.uploadCoordinator?.syncOnStartup() }
                }
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

    private var privacyTab: some View {
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

                    HStack {
                        TextField("app name (e.g., slack)", text: $newExcludedApp)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExcludedApp() }
                            .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppField)
                        Button("add") { addExcludedApp() }
                            .disabled(newExcludedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier(AXID.Settings.Privacy.excludedAppAdd)
                    }
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
                Toggle("exclude private/incognito browser windows", isOn: excludePrivateBrowsingBinding)
                    .help("automatically excludes safari private, chrome incognito, and firefox private browsing windows")
                    .accessibilityIdentifier(AXID.Settings.Privacy.privateBrowsing)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
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

    private func addExcludedApp() {
        let name = newExcludedApp.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        var config = appState.config
        // Check if already excluded (case-insensitive)
        if !config.excludedApps.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            // Use a simple bundle ID based on the name
            let bundleID = "user.excluded.\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            config.excludedApps.append(AppEntry(bundleID: bundleID, name: name))
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

    private var renderedObservationAXState: SettingsObservationAXState {
        SettingsObservationAXState(appState.observationRowState)
    }

    private var renderedObservationText: String {
        switch renderedObservationAXState {
        case .observing:
            return UICopy.SETTINGS_OBSERVATION_OBSERVING
        case .paused:
            return UICopy.SETTINGS_OBSERVATION_PAUSED
        case .starting:
            return UICopy.SETTINGS_OBSERVATION_STARTING
        case .error:
            return UICopy.SETTINGS_OBSERVATION_ERROR
        }
    }

    private func retentionGlanceLabel(_ days: Int) -> String {
        if days == -1 { return "keeping forever" }
        if days == 0 { return "not keeping" }
        return "keeping \(days) days"
    }

    private var storageGlanceText: String {
        let retentionDays = appState.config.cacheRetentionDays
        let retention = retentionGlanceLabel(retentionDays)
        let retentionClause = retentionDays > 0 ? "\(retention), then removed" : retention
        if let storageUsedMB {
            return "\(storageUsedMB) MB · \(retentionClause)"
        }
        return "calculating · \(retentionClause)"
    }

    private var statusFooterText: String {
        if appState.config.serviceMode == .bundled {
            return bundledStatusFooterText(
                permissionsGranted: appState.permissionsAreDone,
                microphoneCount: appState.config.microphonePriority.count
            )
        }
        return externalStatusFooterText(
            serverURL: appState.config.serverURL,
            permissionsGranted: appState.permissionsAreDone
        )
    }

    private var syncTargetText: String {
        if appState.config.serviceMode == .bundled {
            return "journal on this Mac"
        }

        guard let serverURL = appState.config.serverURL, !serverURL.isEmpty else {
            return "journal not configured"
        }

        return "syncing to \(journalHost(serverURL))"
    }

    private var statusHealthSummary: StatusHealthSummary {
        StatusHealthSummary.make(
            serviceMode: appState.config.serviceMode,
            isRecording: appState.isRecording,
            isPaused: appState.isPaused,
            journalRuntimeStatus: appState.journalRuntimeStatus,
            uploadStatus: appState.uploadCoordinator.status,
            pendingCount: appState.uploadCoordinator.pendingCount,
            lastSyncedAt: appState.uploadCoordinator.lastSyncedAt,
            serverURL: appState.config.serverURL,
            now: Date()
        )
    }

    private var bundledVersionCaption: String {
        let state = appState.bundledJournalCardState
        if case .installedCurrent(let version) = state {
            return "solstone \(version) · on this Mac"
        }
        return "on this Mac"
    }

    @ViewBuilder
    private var healthSummaryCard: some View {
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

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            healthSummaryCard

            GroupBox("observing") {
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
                }
                .padding(.vertical, 4)
            }

            GroupBox("journal") {
                VStack(alignment: .leading, spacing: 8) {
                    if appState.config.serviceMode == .bundled {
                        bundledJournalStatusRows
                        Text(bundledVersionCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastIngestAt = appState.bundledJournalLastIngestAt {
                            let relative = coarseRelativeTime(lastIngestAt, now: Date())
                            Text("last activity \(relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(AXID.Settings.Status.bundledLastActivity)
                                .accessibilityValue(relative)
                        }
                    } else {
                        Text(syncTargetText)
                            .foregroundStyle(.secondary)
                        uploadStatusView
                        if let lastSyncedAt = appState.uploadCoordinator.lastSyncedAt {
                            Text("last synced \(coarseRelativeTime(lastSyncedAt, now: Date()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("app version \(AppVersion.short)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Status.appVersionState)
                        .accessibilityValue(AppVersion.short)
                    Button(appState.config.serviceMode == .bundled ? "manage journal →" : "manage connection →") {
                        selectedTab = .service
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityIdentifier(AXID.Settings.Status.manageJournal)
                }
                .padding(.vertical, 4)
            }

            if appState.config.serviceMode == .external {
                GroupBox("kept on this Mac") {
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

            Text(statusFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            GroupBox("debug") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("1-minute segments", isOn: debugSegmentsBinding)
                        .help("use 1-minute segments instead of 5-minute for testing")
                        .accessibilityIdentifier(AXID.Settings.Status.debugOneMinuteSegments)
                    Toggle("keep rejected audio", isOn: debugKeepRejectedBinding)
                        .help("move rejected mic tracks to rejected/ folder instead of deleting")
                        .accessibilityIdentifier(AXID.Settings.Status.debugKeepRejectedAudio)
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
                    await appState.captureManager?.setDebugSegments(newValue)
                }
            }
        )
    }

    private var debugKeepRejectedBinding: Binding<Bool> {
        Binding(
            get: { appState.config.debugKeepRejectedAudio },
            set: { newValue in
                var config = appState.config
                config.debugKeepRejectedAudio = newValue
                appState.updateConfig(config)
            }
        )
    }
    #endif

    // MARK: - Upload Status

    @ViewBuilder
    private var uploadStatusView: some View {
        let status = appState.uploadCoordinator.status
        let pending = appState.uploadCoordinator.pendingCount

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                statusIcon(for: status)
                Text(statusText(for: status))
                Spacer()
                if pending > 0 {
                    Text("\(pending) pending")
                        .foregroundStyle(.secondary)
                }
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

    private func statusIcon(for status: UploadCoordinator.Status) -> some View {
        let (name, color): (String, Color) = switch status {
        case .notSynced:
            ("questionmark.circle", .gray)
        case .synced:
            ("checkmark.circle", .green)
        case .syncing:
            ("arrow.triangle.2.circlepath", .blue)
        case .uploading:
            ("arrow.up.circle", .blue)
        case .retrying:
            ("exclamationmark.triangle", .orange)
        case .awaitingTunnel:
            ("arrow.triangle.2.circlepath", .orange)
        case .offline:
            ("xmark.circle", .red)
        }

        return Image(systemName: name)
            .foregroundStyle(color)
    }

    private func statusText(for status: UploadCoordinator.Status) -> String {
        switch status {
        case .notSynced:
            return "connecting..."
        case .synced:
            return "synced"
        case .syncing(let checked, let total):
            return "syncing: \(checked)/\(total)"
        case .uploading(let segment):
            return "uploading: \(segment)"
        case .retrying(let segment, let attempts):
            return "retrying \(segment) (attempt \(attempts))"
        case .awaitingTunnel:
            return "connecting to your journal…"
        case .offline(let error):
            return "offline: \(error)"
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
        this is solstone-macos, a screen and audio observer for solstone.
        installed at: \(Bundle.main.bundlePath)
        captures: ~/Library/Application Support/Solstone/captures/
        logs: /usr/bin/log stream --predicate 'subsystem == "app.solstone.observer"' --level debug
        journal: \(appState.config.serverURL ?? "not configured")

        if the observer isn't running, check settings → permissions.
        if it's not syncing, check settings → journal.
        source: https://github.com/solpbc/solstone-macos
        """
    }

    private var helpTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("get help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("need a hand? reach a human — we're happy to help.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link("support.solstone.app", destination: failureDiagnosticSupportURL)
                        .accessibilityIdentifier(AXID.Settings.Help.supportSite)
                    Link("support@solstone.app", destination: URL(string: "mailto:support@solstone.app?subject=solstone%20(macOS)")!)
                        .accessibilityIdentifier(AXID.Settings.Help.supportEmail)
                    Text("version \(AppVersion.short)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Help.versionState)
                        .accessibilityValue(AppVersion.short)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("icon states") {
                HStack(spacing: 24) {
                    HStack(spacing: 6) {
                        bundleImage("sol-ring-template", isTemplate: true)
                            .frame(width: 16, height: 16)
                        Text(UICopy.SETTINGS_HELP_ICON_FULL)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AXID.Settings.Help.iconStateRecording)
                    HStack(spacing: 6) {
                        bundleImage("sol-ring-icon-half-template", isTemplate: true)
                            .frame(width: 16, height: 16)
                        Text(UICopy.SETTINGS_HELP_ICON_HALF)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AXID.Settings.Help.iconStateOffline)
                    HStack(spacing: 6) {
                        bundleImage("sol-ring-icon-paused-template", isTemplate: true)
                            .frame(width: 16, height: 16)
                        Text(UICopy.SETTINGS_HELP_ICON_PAUSED)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AXID.Settings.Help.iconStatePaused)
                    HStack(spacing: 6) {
                        bundleImage("sol-ring-icon-error-template", isTemplate: true)
                            .frame(width: 16, height: 16)
                        Text(UICopy.SETTINGS_HELP_ICON_ERROR)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AXID.Settings.Help.iconStateError)
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

}

func updatesSidebarBadge(for status: DurableUpdateStatus) -> SettingsView.SidebarBadgeState {
    switch status {
    case .deferred, .staged, .failedWithAvailable, .available, .failed:
        return .attention
    case .upToDate:
        return .done
    case .idle:
        return .blank
    }
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
