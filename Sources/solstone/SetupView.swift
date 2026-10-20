// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SetupChrome
import SolstoneCore
import SwiftUI

struct SetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: SetupModel
    let appState: AppState
    let journalMarkDriver: JournalMarkConfirmationDriver
    var sun: SunArcBackgroundView = SunArcBackgroundView()

    @State private var pairingLinkInput: String = ""
    @State private var setupWindowPairingSucceeded = false
    @State private var connectChoiceRevealed = false

    private var isRevealOpen: Bool {
        connectChoiceRevealed
            || !pairingLinkInput.isEmpty
            || appState.pendingPairingLink != nil
            || appState.pendingPairingLinkError != nil
            || model.ownerPairingError != nil
            || appState.pairingCoordinator.state != .idle
    }

    var body: some View {
        SetupWindow(appLabel: UICopy.SETUP_APP_LABEL, background: sun) {
            if let phase = model.phase {
                AXStateCompanion(
                    id: AXID.Settings.Setup.phase,
                    value: phase.rawValue
                )
                switch phase {
                case .journal:
                    journalStepView
                case .microphone:
                    microphoneStepView
                case .screen:
                    screenStepView
                case .connection:
                    connectionStepView
                }
            }
        }
        .onAppear {
            if appState.pendingPairingLink != nil {
                consumePendingPairingLink()
            }
        }
        .onChange(of: appState.pendingPairingLink) { _, newValue in
            if newValue != nil {
                consumePendingPairingLink()
            }
        }
        .onChange(of: pairingLinkInput) { oldValue, newValue in
            model.setJournalPairingLinkHeld(!newValue.isEmpty || appState.pendingPairingLink != nil)
            if !oldValue.isEmpty && newValue.isEmpty && appState.pendingPairingLink == nil && !setupWindowPairingSucceeded {
                model.startJournalPhase()
            }
        }
        .onChange(of: appState.pairingCoordinator.state) { _, newState in
            if SetupPairingLinkOffer.clearsSetupLink(on: newState) {
                setupWindowPairingSucceeded = true
                pairingLinkInput = ""
            }
        }
    }

    // MARK: - Footer Helper

    @ViewBuilder
    private func stepFooter(phase: SetupPhase, @ViewBuilder primary: () -> some View = { EmptyView() }) -> some View {
        let progressVal = SetupStepProgress.value(phase: phase)
        let dest = SetupBack.destination(from: phase)
        let downloadRows = (model.isPeerSupportingSetup && phase != .journal)
            ? SetupDownloadPresentation.rows(downloads: model.downloadProgress.downloads)
            : []

        SetupFooter(
            back: {
                if let dest {
                    Button {
                        model.setPhase(dest)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text(UICopy.SETUP_BACK)
                        }
                    }
                    .buttonStyle(SetupTextButtonStyle())
                }
            },
            progress: {
                if let progressVal {
                    SetupProgress(
                        index: progressVal.index,
                        count: progressVal.count,
                        label: UICopy.setupStepProgress(n: progressVal.index, m: progressVal.count)
                    )
                }
            },
            downloads: {
                if !downloadRows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(downloadRows.enumerated()), id: \.offset) { _, row in
                            SetupDownloadRow(
                                name: row.name,
                                detail: row.detail,
                                fraction: row.fraction,
                                indeterminate: row.indeterminate,
                                actionTitle: row.actionTitle,
                                actionEnabled: model.downloadProgress.actionsEnabled,
                                action: {
                                    if let action = row.action {
                                        model.performDownloadAction(action)
                                    }
                                }
                            )
                        }
                    }
                }
            },
            primary: primary
        )
    }

    // MARK: - Journal Step

    private var journalStepView: some View {
        let linkWaiting = !pairingLinkInput.isEmpty || appState.pendingPairingLink != nil
        let statusCaption = SetupJournalStatus.caption(
            flowState: model.freshFlow.state,
            journalPollingText: model.journalPollingText
        )
        let content = SetupJournalStep.content(
            isOwnerComparison: model.continuation?.mode == .ownerComparison && appState.confirmedMark == nil,
            isPeerSupporting: model.isPeerSupportingSetup,
            hasMark: (appState.confirmedMark ?? model.olderDiscoveredMark) != nil,
            hasError: model.journalPollingError != nil,
            hasStatus: statusCaption != nil,
            linkWaiting: linkWaiting
        )
        return journalStepView(content: content, statusCaption: statusCaption)
    }

    @ViewBuilder
    private func journalStepView(content: SetupJournalStepContent, statusCaption: String?) -> some View {
        let showPairingBlock = SetupPairingLinkOffer.isVisible(
            phase: .journal,
            isPeerSupportingSetup: model.isPeerSupportingSetup,
            hasPendingPairing: hasPendingPairing,
            setupWindowPairingSucceeded: setupWindowPairingSucceeded
        )

        switch content {
        case .create, .omitted:
            // One branch for both, so the pairing field keeps its identity (and focus) when a
            // typed link turns create into omitted. With a link waiting there is no create.
            SetupStep(
                headline: UICopy.SETUP_WELCOME_HEADLINE,
                explanations: [UICopy.SETUP_WELCOME_BODY_1, UICopy.SETUP_WELCOME_BODY_2]
            ) {
                SetupCard(heading: UICopy.SETUP_JOURNAL_CARD_HEADING) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(UICopy.SETUP_JOURNAL_CARD_BODY)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))

                        if content == .create {
                            VStack(spacing: 10) {
                                Button {
                                    model.retryJournalPhase()
                                } label: {
                                    Text(UICopy.SETUP_CREATE_JOURNAL_CHOICE)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SetupSecondaryButtonStyle())
                                .accessibilityIdentifier(AXID.Settings.Setup.Journal.create)

                                Button {
                                    connectChoiceRevealed = true
                                } label: {
                                    Text(UICopy.SETUP_CONNECT_JOURNAL_CHOICE)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(SetupSecondaryButtonStyle())
                            }
                        }

                        if content == .omitted || isRevealOpen {
                            if content == .create {
                                Divider()
                            }
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }

        case .ownerComparison:
            SetupStep(
                headline: UICopy.SETUP_JOURNAL_CARD_HEADING,
                explanations: []
            ) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL).font(.headline)
                        if showPairingBlock {
                            Divider()
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }

        case .peerSupporting:
            SetupStep(
                headline: UICopy.SETUP_JOURNAL_CARD_HEADING,
                explanations: []
            ) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(UICopy.SETUP_OPEN_THE_JOURNAL_APP_TO_CONTINUE)
                            .font(.headline)
                        if let text = model.journalPollingText {
                            Text(text)
                                .font(.caption)
                                .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
                        }
                        if let error = model.journalPollingError {
                            SetupErrorText(error)
                            if model.journalPollingOffersJournalAppDownload {
                                JournalAppDownloadLink()
                            }
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.retryJournalPhase()
                            }
                            .buttonStyle(SetupSecondaryButtonStyle())
                            .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)
                        }
                        if showPairingBlock {
                            Divider()
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }

        case .mark:
            SetupStep(
                headline: UICopy.SETUP_JOURNAL_CARD_HEADING,
                explanations: []
            ) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let mark = appState.confirmedMark ?? model.olderDiscoveredMark {
                            JournalMarkView(mark: mark, isConfirmed: appState.isJournalMarkConfirmed)
                            HStack {
                                if !appState.isJournalMarkConfirmed {
                                    Button("pair") {
                                        appState.beginOwnerPairingAttempt()
                                        journalMarkDriver.startIfUnconfirmed(appState: appState)
                                        Task {
                                            _ = await runOwnerSameMachineLink(
                                                appState: appState,
                                                journalMarkDriver: journalMarkDriver,
                                                startPairing: appState.sameMachinePairStart
                                            )
                                        }
                                    }
                                    .buttonStyle(SetupSecondaryButtonStyle())
                                    .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)
                                }

                                Button(UICopy.SETUP_CONTINUE) {
                                    model.continueFromOlderJournal()
                                }
                                .buttonStyle(SetupPrimaryButtonStyle())
                                .accessibilityIdentifier(AXID.Settings.Setup.Journal.continue)
                            }
                        }
                        if showPairingBlock {
                            Divider()
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }

        case .failure:
            SetupStep(
                headline: UICopy.SETUP_JOURNAL_CARD_HEADING,
                explanations: []
            ) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = model.journalPollingError {
                            SetupErrorText(error)
                        }
                        if model.journalPollingOffersJournalAppDownload {
                            JournalAppDownloadLink()
                        }
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.retryJournalPhase()
                        }
                        .buttonStyle(SetupPrimaryButtonStyle())
                        .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)

                        if showPairingBlock {
                            Divider()
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }

        case .activity:
            SetupStep(
                headline: UICopy.SETUP_JOURNAL_CARD_HEADING,
                explanations: []
            ) {
                SetupCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if let statusCaption {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(statusCaption)
                                    .font(.caption)
                                    .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
                            }
                        }
                        if showPairingBlock {
                            Divider()
                            pairingLinkBlock
                        }
                    }
                }
            } footer: {
                // Unnumbered: no progress and no primary, so no footer bar at all.
                EmptyView()
            }
        }
    }

    // MARK: - Step 5 (Microphone)

    private var microphoneStepView: some View {
        let showPairingBlock = SetupPairingLinkOffer.isVisible(
            phase: .microphone,
            isPeerSupportingSetup: model.isPeerSupportingSetup,
            hasPendingPairing: hasPendingPairing,
            setupWindowPairingSucceeded: setupWindowPairingSucceeded
        )

        return SetupStep(
            headline: UICopy.SETUP_MICROPHONE_HEADLINE,
            explanations: [UICopy.SETUP_MICROPHONE_EXPLAINER]
        ) {
            SetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    SetupMicrophoneProofView(appState: appState, model: model)

                    if let error = model.acknowledgementError {
                        HStack(spacing: 8) {
                            SetupErrorText(error)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.ingestStep5IfNeeded()
                            }
                            .buttonStyle(SetupTextButtonStyle())
                        }
                    }

                    if showPairingBlock {
                        Divider()
                        pairingLinkBlock
                    }
                }
            }
        } footer: {
            stepFooter(phase: .microphone) {
                if appState.config.isMicrophoneCaptureEnabled {
                    Button(UICopy.SETUP_CONTINUE) {
                        model.continueFromMicrophone()
                    }
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityIdentifier(AXID.Settings.Setup.Microphone.continue)
                    .keyboardShortcut(SetupReturnKey.shortcut(pairingLinkWaiting: hasPendingPairing))
                }
            }
        }
    }

    // MARK: - Step 6 (Screen & Computer Sound)

    private var screenStepView: some View {
        let showPairingBlock = SetupPairingLinkOffer.isVisible(
            phase: .screen,
            isPeerSupportingSetup: model.isPeerSupportingSetup,
            hasPendingPairing: hasPendingPairing,
            setupWindowPairingSucceeded: setupWindowPairingSucceeded
        )

        return SetupStep(
            headline: UICopy.SETUP_SCREEN_HEADLINE,
            explanations: [UICopy.SETUP_SCREEN_EXPLAINER]
        ) {
            SetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    SetupScreenProofView(appState: appState, model: model)

                    if let error = model.acknowledgementError {
                        HStack(spacing: 8) {
                            SetupErrorText(error)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.ingestStep5IfNeeded()
                            }
                            .buttonStyle(SetupTextButtonStyle())
                        }
                    }

                    if showPairingBlock {
                        Divider()
                        pairingLinkBlock
                    }
                }
            }
        } footer: {
            stepFooter(phase: .screen) {
                if appState.config.isScreenCaptureEnabled {
                    Button(UICopy.SETUP_CONTINUE) {
                        model.continueFromScreen()
                    }
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .accessibilityIdentifier(AXID.Settings.Setup.Screen.continue)
                    .keyboardShortcut(SetupReturnKey.shortcut(pairingLinkWaiting: hasPendingPairing))
                }
            }
        }
    }

    // MARK: - Step 7 (Connection)

    private var isBranchVerified: Bool {
        guard case .connected = appState.pairingCoordinator.tunnelState else {
            return false
        }
        if model.isPeerSupportingSetup {
            if case .connected = model.connectionStepState {
                return true
            }
            return false
        } else {
            return appState.isJournalMarkConfirmed
        }
    }

    private var connectionStepView: some View {
        let tunnelConnected: Bool = {
            if case .connected = appState.pairingCoordinator.tunnelState { return true }
            return false
        }()
        let heading = SetupConnectionStep.content(
            isPeerSupporting: model.isPeerSupportingSetup,
            state: model.connectionStepState,
            tunnelConnected: tunnelConnected,
            ownerMarkWords: appState.confirmedMark?.words
        )
        let showPairingBlock = SetupPairingLinkOffer.isVisible(
            phase: .connection,
            isPeerSupportingSetup: model.isPeerSupportingSetup,
            hasPendingPairing: hasPendingPairing,
            setupWindowPairingSucceeded: setupWindowPairingSucceeded
        )
        let explanations: [String] = {
            if heading.headline != UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL {
                return [UICopy.SETUP_CONNECTED_EXPLANATION]
            }
            return []
        }()

        return SetupStep(
            headline: heading.headline,
            explanations: explanations
        ) {
            SetupCard {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isPeerSupportingSetup {
                        switch model.connectionStepState {
                        case .connecting, .idle:
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(UICopy.SETUP_CONNECTING_TO_YOUR_JOURNAL)
                                    .font(.caption)
                                    .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
                            }
                        case .failed(let msg):
                            SetupErrorText(msg)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.retryConnection()
                            }
                            .buttonStyle(SetupPrimaryButtonStyle())
                            .accessibilityIdentifier(AXID.Settings.Setup.Connection.retry)
                        case .connected(let mark):
                            JournalMarkView(mark: mark, isConfirmed: true)
                        }
                    } else {
                        if let mark = appState.confirmedMark {
                            JournalMarkView(mark: mark, isConfirmed: true)
                        } else {
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                appState.beginOwnerPairingAttempt()
                                journalMarkDriver.startIfUnconfirmed(appState: appState)
                                Task {
                                    _ = await runOwnerSameMachineLink(
                                        appState: appState,
                                        journalMarkDriver: journalMarkDriver,
                                        startPairing: appState.sameMachinePairStart
                                    )
                                }
                            }
                            .buttonStyle(SetupPrimaryButtonStyle())
                            .accessibilityIdentifier(AXID.Settings.Setup.Connection.retry)
                        }
                    }

                    Divider()

                    SetupToggle(
                        isOn: Binding(
                            get: { appState.isLoginItemEnabled },
                            set: { appState.setLoginItemEnabled($0) }
                        ),
                        label: "start at login",
                        accessibilityIdentifier: AXID.Settings.Setup.Connection.loginItem
                    )

                    if let error = appState.loginItemError {
                        SetupErrorText(error)
                    }

                    if let error = model.acknowledgementError {
                        HStack(spacing: 8) {
                            SetupErrorText(error)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.ingestStep5IfNeeded()
                            }
                            .buttonStyle(SetupTextButtonStyle())
                        }
                    }

                    if let error = model.finalOpenError {
                        HStack(spacing: 8) {
                            SetupErrorText(error)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.performSetupFinalOpen()
                            }
                            .buttonStyle(SetupTextButtonStyle())
                        }
                    }

                    if showPairingBlock {
                        Divider()
                        pairingLinkBlock
                    }
                }
            }
        } footer: {
            stepFooter(phase: .connection) {
                Button(UICopy.SETUP_OPEN_YOUR_JOURNAL) {
                    model.performSetupFinalOpen()
                }
                .buttonStyle(SetupPrimaryButtonStyle())
                .accessibilityIdentifier(AXID.Settings.Setup.Connection.openJournal)
                .disabled(!isBranchVerified)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var hasPendingPairing: Bool {
        appState.pendingPairingLink != nil
            || !pairingLinkInput.isEmpty
            || model.ownerPairingError != nil
            || appState.pendingPairingLinkError != nil
    }

    private var pairingLinkBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("or pair to a journal on another device")
                .font(.subheadline)
                .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
            HStack(spacing: 8) {
                TextField("paste pairing link", text: $pairingLinkInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingLink)
                Button("connect") {
                    Task {
                        _ = await appState.submitPairingInput(pairingLinkInput)
                    }
                }
                .buttonStyle(SetupSecondaryButtonStyle())
                .accessibilityIdentifier(AXID.Settings.Service.pairingConnect)
                .disabled(pairingLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.ownerPairingError ?? appState.pendingPairingLinkError {
                SetupErrorText(error)
            }
            switch appState.pairingCoordinator.state {
            case .failed(let failure):
                SetupErrorText(failure.message(address: appState.pairingCoordinator.failedAddress))
            case .saveFailed:
                SetupErrorText(UICopy.PAIRING_SAVE_FAILED)
            default:
                EmptyView()
            }
        }
    }

    private func consumePendingPairingLink() {
        model.setJournalPairingLinkHeld(true)
        guard let pending = appState.takePendingPairingLink(forSetup: true) else { return }
        pairingLinkInput = pending
    }
}

/// Return activates a step's one footer primary, as it does on the journal app's steps, except
/// while a pairing link is typed or waiting: then Return belongs to the link, never to continue.
enum SetupReturnKey {
    static func shortcut(pairingLinkWaiting: Bool) -> KeyboardShortcut? {
        pairingLinkWaiting ? nil : .defaultAction
    }
}

/// The native sequence starts from the journal app on this Mac, so after its
/// first step there is no other journal to choose. Pairing elsewhere stays
/// offered in the older setup on every step, on the first step of the native
/// sequence, whenever a pairing link or its error is waiting to be seen, and
/// is hidden on later steps after setup-window pairing succeeds.
enum SetupPairingLinkOffer {
    static func isVisible(
        phase: SetupPhase,
        isPeerSupportingSetup: Bool,
        hasPendingPairing: Bool,
        setupWindowPairingSucceeded: Bool
    ) -> Bool {
        if hasPendingPairing { return true }
        if setupWindowPairingSucceeded && phase != .journal { return false }
        return !isPeerSupportingSetup || phase == .journal
    }

    static func clearsSetupLink(on state: PairingFlowState) -> Bool {
        switch state {
        case .paired, .alreadyConnected, .switched:
            return true
        case .idle, .pairing, .switchConfirmPending, .saveFailed, .failed:
            return false
        }
    }
}

enum SetupJournalStepContent: Equatable {
    case ownerComparison
    case peerSupporting
    case mark
    case failure
    case activity
    case create
    case omitted
}

enum SetupJournalStep {
    static func content(
        isOwnerComparison: Bool,
        isPeerSupporting: Bool,
        hasMark: Bool,
        hasError: Bool,
        hasStatus: Bool,
        linkWaiting: Bool
    ) -> SetupJournalStepContent {
        if isOwnerComparison { return .ownerComparison }
        if isPeerSupporting { return .peerSupporting }
        if hasMark { return .mark }
        if hasError { return .failure }
        if hasStatus { return .activity }
        if !linkWaiting { return .create }
        return .omitted
    }
}

struct SetupConnectionStepContent: Equatable {
    let headline: String
    let showsConnectedCaption: Bool
}

enum SetupConnectionStep {
    static func content(
        isPeerSupporting: Bool,
        state: SetupModel.ConnectionStepState,
        tunnelConnected: Bool,
        ownerMarkWords: [String]? = nil
    ) -> SetupConnectionStepContent {
        if isPeerSupporting {
            switch state {
            case .connected(let mark):
                return SetupConnectionStepContent(
                    headline: mark.words.isEmpty
                        ? UICopy.SETUP_CONNECTED_TO_YOUR_JOURNAL
                        : UICopy.connectedTo(mark: mark.words.joined(separator: " · ")),
                    showsConnectedCaption: false
                )
            case .idle, .connecting, .failed:
                return SetupConnectionStepContent(
                    headline: UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL,
                    showsConnectedCaption: false
                )
            }
        } else if tunnelConnected {
            let words = ownerMarkWords ?? []
            return SetupConnectionStepContent(
                headline: words.isEmpty
                    ? UICopy.SETUP_CONNECTED_TO_YOUR_JOURNAL
                    : UICopy.connectedTo(mark: words.joined(separator: " · ")),
                showsConnectedCaption: false
            )
        } else {
            return SetupConnectionStepContent(
                headline: UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL,
                showsConnectedCaption: false
            )
        }
    }
}

enum SetupJournalStatus {
    static func caption(flowState: FreshJournalState, journalPollingText: String?) -> String? {
        switch flowState {
        case .acquiring:
            let message = flowState.ownerStatusMessage
            return message.isEmpty ? nil : message
        case .launching:
            return UICopy.SETUP_OPENING_YOUR_JOURNAL
        case .idle, .waitingForJournal, .failed:
            return journalPollingText
        }
    }
}
