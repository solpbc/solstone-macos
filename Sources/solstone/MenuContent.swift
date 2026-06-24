// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCore

/// The content of the status bar menu
struct MenuContent: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let pending = appState.solChatPending {
            Section {
                Button {
                    Task {
                        await AppState.shared?.solChatBridge.handleClick(requestID: pending.id)
                    }
                } label: {
                    Label {
                        Text(pending.summary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        bundleImage("sol-ring-template", isTemplate: true)
                    }
                }
                .accessibilityIdentifier(AXID.Menubar.pendingChatButton)
            }

            Divider()
        }

        // Status + pause/resume controls (single section — no internal divider)
        Section {
            statusRow
                .accessibilityValue(statusRowAXValue)
            if hasPauseResumeControl {
                pauseResumeSection
            }
        }

        Divider()

        Section {
            if appState.config.isUploadConfigured {
                Button("open journal") {
                    if let url = journalURLToOpen(from: appState.config.serverURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityIdentifier(AXID.Menubar.openJournalButton)
            }
            Button {
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                if let reason = settingsAttentionToShow {
                    Label {
                        Text("settings… — \(settingsAttentionSuffix(reason))")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("settings…")
                }
            }
            .accessibilityIdentifier(AXID.Menubar.settingsButton)
            Button("about solstone") {
                openWindow(id: "about")
                appState.didOpenWindow(.about)
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier(AXID.Menubar.aboutButton)
        }

        Divider()

        Button("quit solstone") {
            appState.appQuitCoordinator.requestAppOwnedQuit()
        }
        .accessibilityIdentifier(AXID.Menubar.quitButton)
    }

    // MARK: - Status Row

    private var settingsAttentionToShow: SettingsAttentionReason? {
        settingsAttentionSuffixToShow(
            reason: firstSettingsAttention(
                permissionsNeedAttention: appState.permissionsNeedAttention,
                journalNeedsAttention: appState.serviceNeedsAttention,
                durableUpdateStatus: updateController.durableUpdateStatus
            ),
            statusRowCarriesPermissions: appState.permissionsNeedAttention,
            statusRowCarriesJournal: appState.bundledJournalStatusAvailable && appState.journalRuntimeStatus.menuRowPresentation != nil
        )
    }

    private func openSettings(tab: String) {
        appState.pendingSettingsTab = tab
        openWindow(id: "settings")
        appState.didOpenWindow(.settings)
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var statusRow: some View {
        let rowState = statusRowState

        switch rowState {
        case .permissions:
            Button(UICopy.MENUBAR_PERMISSIONS_OPEN_SETTINGS) {
                openSettings(tab: "permissions")
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier(AXID.Menubar.permissionsButton)

        case .error:
            if let error = appState.errorMessage {
                Button(UICopy.menubarErrorOpenSettings(error)) {
                    openSettings(tab: "status")
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier(AXID.Menubar.errorButton)
            } else {
                Button(UICopy.MENUBAR_OBSERVATION_WEDGE_OPEN_SETTINGS) {
                    openSettings(tab: "status")
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier(AXID.Menubar.errorButton)
            }

        case .starting:
            Text(UICopy.MENUBAR_STARTING)
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)

        case .journalSetupNeeded,
             .journalRestarting,
             .journalStopped,
             .journalUnknown,
             .journalStoppedByUser:
            journalRuntimeRow(rowState: rowState)

        case .journalWaiting:
            Button(UICopy.MENUBAR_JOURNAL_WAITING) {
                openSettings(tab: "status")
            }
            .accessibilityIdentifier(AXID.Menubar.journalState)
            .accessibilityValue(rowState.axToken)

        case .localOnly:
            Button(UICopy.MENUBAR_LOCAL_ONLY_SETUP_JOURNAL) {
                openSettings(tab: "journal")
            }
            .accessibilityIdentifier(AXID.Menubar.localOnlyButton)

        case .syncPaused:
            Text(UICopy.MENUBAR_SYNC_PAUSED)
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)

        case .offline:
            Button(UICopy.MENUBAR_OBSERVING_OFFLINE_SAVED_LOCALLY) {
                openSettings(tab: "status")
            }
            .accessibilityIdentifier(AXID.Menubar.offlineButton)

        case .paused:
            let _ = appState.pauseManager.refreshTick
            Text(pausedHeaderText(timeRemaining: appState.pauseManager.formatTimeRemaining()))
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)

        case .observing:
            Text(appState.bundledJournalStatusAvailable ? UICopy.MENUBAR_OBSERVING_BUNDLED : UICopy.MENUBAR_OBSERVING_CONNECTED)
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)
        }
    }

    @ViewBuilder
    private func journalRuntimeRow(rowState: MenubarStatusRowState) -> some View {
        if let journalRow = appState.journalRuntimeStatus.menuRowPresentation {
            if journalRow.isEnabled {
                Button(journalRow.text) {
                    openSettings(tab: "journal")
                }
                .accessibilityIdentifier(AXID.Menubar.journalState)
                .accessibilityValue(rowState.axToken)
            } else {
                Text(journalRow.text)
                    .accessibilityIdentifier(AXID.Menubar.journalState)
                    .accessibilityValue(rowState.axToken)
            }
        } else {
            missingJournalRuntimeRow(rowState: rowState)
        }
    }

    private func missingJournalRuntimeRow(rowState: MenubarStatusRowState) -> EmptyView {
        assertionFailure("Journal runtime row state \(rowState.axToken) requires a menuRowPresentation")
        return EmptyView()
    }

    private var statusRowAXValue: String {
        statusRowState.axToken
    }

    private var statusRowState: MenubarStatusRowState {
        appState.observationRowState
    }

    // MARK: - Pause Controls

    private var hasPauseControl: Bool {
        appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused
    }

    private var hasResumeControl: Bool {
        appState.pauseManager.isPaused
    }

    var hasPauseResumeControl: Bool {
        hasPauseControl || hasResumeControl
    }

    @ViewBuilder
    private var pauseResumeSection: some View {
        if hasPauseControl {
            Menu("pause") {
                Button("15 minutes") {
                    appState.pauseManager.pause(for: .minutes(15))
                }
                .accessibilityIdentifier(AXID.Menubar.pauseFifteenMinutes)
                Button("30 minutes") {
                    appState.pauseManager.pause(for: .minutes(30))
                }
                .accessibilityIdentifier(AXID.Menubar.pauseThirtyMinutes)
                Button("1 hour") {
                    appState.pauseManager.pause(for: .minutes(60))
                }
                .accessibilityIdentifier(AXID.Menubar.pauseOneHour)
                Button("until I resume") {
                    appState.pauseManager.pause(for: .indefinite)
                }
                .accessibilityIdentifier(AXID.Menubar.pauseIndefinite)
            }
            .accessibilityIdentifier(AXID.Menubar.pauseMenu)
        } else if hasResumeControl {
            Button("resume") { appState.pauseManager.resume() }
                .accessibilityIdentifier(AXID.Menubar.resumeButton)
        }
    }

    // MARK: - Upload Status Row

}

func journalURLToOpen(from serverURL: String?) -> URL? {
    URL(string: serverURL ?? "")
}

func pausedHeaderText(timeRemaining: String?) -> String {
    guard let t = timeRemaining else { return "paused" }
    let compact = t.replacingOccurrences(of: " mins", with: " min")
                   .replacingOccurrences(of: " secs", with: " sec")
                   .replacingOccurrences(of: " hrs", with: " hr")
    return "paused, \(compact) left"
}

enum SettingsAttentionReason: Equatable {
    case permissions, journal, updateAvailable, updateCheckFailed
}

func firstSettingsAttention(
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus
) -> SettingsAttentionReason? {
    if permissionsNeedAttention { return .permissions }
    if journalNeedsAttention { return .journal }

    switch durableUpdateStatus {
    case .deferred, .staged, .failedWithAvailable, .available:
        return .updateAvailable
    case .failed:
        return .updateCheckFailed
    case .upToDate, .idle:
        return nil
    }
}

func settingsAttentionSuffixToShow(
    reason: SettingsAttentionReason?,
    statusRowCarriesPermissions: Bool,
    statusRowCarriesJournal: Bool
) -> SettingsAttentionReason? {
    guard let reason else { return nil }
    switch reason {
    case .permissions: return statusRowCarriesPermissions ? nil : reason
    case .journal: return statusRowCarriesJournal ? nil : reason
    case .updateAvailable, .updateCheckFailed: return reason
    }
}

func settingsAttentionSuffix(_ reason: SettingsAttentionReason) -> String {
    switch reason {
    case .permissions: return UICopy.SETTINGS_ATTENTION_PERMISSIONS
    case .journal: return UICopy.SETTINGS_ATTENTION_JOURNAL
    case .updateAvailable: return UICopy.SETTINGS_ATTENTION_UPDATE_AVAILABLE
    case .updateCheckFailed: return UICopy.SETTINGS_ATTENTION_UPDATE_CHECK_FAILED
    }
}
