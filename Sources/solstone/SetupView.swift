// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SolstoneCore
import SwiftUI

struct SetupView: View {
    @Bindable var model: SetupModel
    let appState: AppState
    let journalMarkDriver: JournalMarkConfirmationDriver

    @State private var pairingLinkInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                    if SetupPairingLinkOffer.isVisible(
                        phase: phase,
                        isPeerSupportingSetup: model.isPeerSupportingSetup,
                        hasPendingPairing: hasPendingPairing
                    ) {
                        pairingLinkSection
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if model.isPeerSupportingSetup && model.phase != .journal {
            Divider()
            SetupDownloadFooter(downloads: model.downloadProgress.downloads)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        }
    }

    // MARK: - Journal Step

    private var journalStepView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if model.continuation?.mode == .ownerComparison && appState.confirmedMark == nil {
                    Text(UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL).font(.headline)
                } else if model.isPeerSupportingSetup {
                    Text(UICopy.SETUP_OPEN_THE_JOURNAL_APP_TO_CONTINUE)
                        .font(.headline)
                    if let text = model.journalPollingText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = model.journalPollingError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.retryJournalPhase()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)
                    }
                } else {
                    if let mark = appState.confirmedMark ?? model.olderDiscoveredMark {
                        JournalMarkView(mark: mark, isConfirmed: appState.isJournalMarkConfirmed)
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
                            .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)
                        }
                        Button(UICopy.SETUP_CONTINUE) {
                            model.continueFromOlderJournal()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Journal.continue)
                    } else {
                        if model.journalPollingError == nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(model.journalPollingText ?? UICopy.SETUP_OPENING_YOUR_JOURNAL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = model.journalPollingError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button(UICopy.SETUP_TRY_AGAIN) {
                                model.retryJournalPhase()
                            }
                            .accessibilityIdentifier(AXID.Settings.Setup.Journal.retry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Step 5 (Microphone)

    private var microphoneStepView: some View {
        GroupBox("5") {
            VStack(alignment: .leading, spacing: 12) {
                Text(UICopy.SETUP_MICROPHONE)
                    .font(.headline)
                Text(UICopy.SETUP_MICROPHONE_EXPLAINER)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.microphoneGranted || !appState.config.isMicrophoneCaptureEnabled {
                    PermissionSourceLiveRowView(source: .microphone, appState: appState, showOffHint: false)
                }

                if !appState.config.isMicrophoneCaptureEnabled {
                    HStack {
                        Button(UICopy.SETUP_TURN_ON_MICROPHONE) {
                            model.turnOnMicrophone()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Microphone.turnOn)

                        Button(UICopy.SETUP_NOT_NOW) {
                            model.notNowMicrophone()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Microphone.notNow)
                    }
                } else {
                    if !appState.microphoneGranted {
                        MicrophonePermissionRepairView(
                            cause: appState.microphoneAuthorizationCause,
                            onRequestAccess: {
                                model.turnOnMicrophone()
                            }
                        )
                    }
                    Button(UICopy.SETUP_CONTINUE) {
                        model.continueFromMicrophone()
                    }
                    .accessibilityIdentifier(AXID.Settings.Setup.Microphone.continue)
                }

                if let error = model.acknowledgementError {
                    HStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.ingestStep5IfNeeded()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Step 6 (Screen & Computer Sound)

    private var screenStepView: some View {
        GroupBox("6") {
            VStack(alignment: .leading, spacing: 12) {
                Text(UICopy.SETUP_SCREEN_AND_COMPUTER_SOUND)
                    .font(.headline)
                Text(UICopy.SETUP_SCREEN_EXPLAINER)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.screenRecordingGranted || !appState.config.isScreenCaptureEnabled {
                    PermissionSourceLiveRowView(source: .screen, appState: appState, showOffHint: false)
                }

                let hasLiveFrame = appState.latestFrame != nil
                AXStateCompanion(
                    id: AXID.Settings.Setup.Screen.frame,
                    value: hasLiveFrame ? SetupScreenFrameAXState.live.rawValue : SetupScreenFrameAXState.off.rawValue
                )

                if let frame = appState.latestFrame {
                    Image(frame, scale: 1.0, label: Text("screen"))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.frame)
                        .accessibilityValue(SetupScreenFrameAXState.live.rawValue)
                } else {
                    Text(UICopy.SETUP_SCREEN_SHOWS_HERE)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.frame)
                        .accessibilityValue(SetupScreenFrameAXState.off.rawValue)
                }

                if !appState.config.isScreenCaptureEnabled {
                    HStack {
                        Button(UICopy.SETUP_TURN_ON_SCREEN) {
                            model.turnOnScreen()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.turnOn)

                        Button(UICopy.SETUP_NOT_NOW) {
                            model.notNowScreen()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Screen.notNow)
                    }
                } else {
                    if !appState.screenRecordingGranted {
                        ScreenRecordingPermissionRepairView(
                            isWaiting: appState.capture.screenRecordingNeedsRestart,
                            showResetHint: false,
                            onEnable: {
                                model.turnOnScreen()
                            },
                            onRestart: {
                                model.prepareScreenRestart(requestRestart: {
                                    appState.appQuitCoordinator.requestSettingsRestart()
                                })
                            }
                        )
                    }
                    Button(UICopy.SETUP_CONTINUE) {
                        model.continueFromScreen()
                    }
                    .accessibilityIdentifier(AXID.Settings.Setup.Screen.continue)
                }

                if let error = model.acknowledgementError {
                    HStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.ingestStep5IfNeeded()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
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
        GroupBox("7") {
            VStack(alignment: .leading, spacing: 12) {
                Text(UICopy.SETUP_CONNECT_TO_YOUR_JOURNAL)
                    .font(.headline)

                if model.isPeerSupportingSetup {
                    switch model.connectionStepState {
                    case .connecting, .idle:
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(UICopy.SETUP_CONNECTING_TO_YOUR_JOURNAL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.retryConnection()
                        }
                        .accessibilityIdentifier(AXID.Settings.Setup.Connection.retry)
                    case .connected(let mark):
                        JournalMarkView(mark: mark, isConfirmed: true)
                        if case .connected = appState.pairingCoordinator.tunnelState {
                            Text(UICopy.SETUP_CONNECTED_TO_YOUR_JOURNAL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if let mark = appState.confirmedMark {
                        JournalMarkView(mark: mark, isConfirmed: true)
                        if case .connected = appState.pairingCoordinator.tunnelState {
                            Text(UICopy.SETUP_CONNECTED_TO_YOUR_JOURNAL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        .accessibilityIdentifier(AXID.Settings.Setup.Connection.retry)
                    }
                }

                Divider()

                Toggle("start at login", isOn: Binding(
                    get: { appState.isLoginItemEnabled },
                    set: { appState.setLoginItemEnabled($0) }
                ))
                .accessibilityIdentifier(AXID.Settings.Setup.Connection.loginItem)

                if let error = appState.loginItemError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(UICopy.SETUP_OPEN_YOUR_JOURNAL) {
                    model.performSetupFinalOpen()
                }
                .accessibilityIdentifier(AXID.Settings.Setup.Connection.openJournal)
                .disabled(!isBranchVerified)
                .keyboardShortcut(.defaultAction)

                if let error = model.acknowledgementError {
                    HStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.ingestStep5IfNeeded()
                        }
                    }
                }

                if let error = model.finalOpenError {
                    HStack {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button(UICopy.SETUP_TRY_AGAIN) {
                            model.performSetupFinalOpen()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var hasPendingPairing: Bool {
        appState.pendingPairingLink != nil
            || !pairingLinkInput.isEmpty
            || model.ownerPairingError != nil
            || appState.pendingPairingLinkError != nil
    }

    private var pairingLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("or pair to a journal on another device")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                TextField("paste pairing link", text: $pairingLinkInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AXID.Settings.Service.pairingLink)
                Button("connect") {
                    Task {
                        _ = await appState.submitPairingInput(pairingLinkInput)
                    }
                }
                .accessibilityIdentifier(AXID.Settings.Service.pairingConnect)
                .disabled(pairingLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.ownerPairingError ?? appState.pendingPairingLinkError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            switch appState.pairingCoordinator.state {
            case .failed(let failure):
                Text(failure.message(address: appState.pairingCoordinator.failedAddress))
                    .font(.caption).foregroundStyle(.red)
            case .saveFailed:
                Text(UICopy.PAIRING_SAVE_FAILED).font(.caption).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding(.top, 12)
        .onAppear { consumePendingPairingLink() }
        .onChange(of: appState.pendingPairingLink) { _, newValue in
            if newValue != nil { consumePendingPairingLink() }
        }
    }

    private func consumePendingPairingLink() {
        guard let pending = appState.takePendingPairingLink(forSetup: true) else { return }
        pairingLinkInput = pending
    }

}

/// The native sequence starts from the journal app on this Mac, so after its
/// first step there is no other journal to choose. Pairing elsewhere stays
/// offered in the older setup, on the first step, and whenever a pairing link
/// or its error is waiting to be seen.
enum SetupPairingLinkOffer {
    static func isVisible(phase: SetupPhase, isPeerSupportingSetup: Bool, hasPendingPairing: Bool) -> Bool {
        !isPeerSupportingSetup || phase == .journal || hasPendingPairing
    }
}
