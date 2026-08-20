// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCore
import UpdateKit

/// The content of the status bar menu
struct MenuContent: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
                    appState.requestOpenJournal(.root)
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
                        Text("settings… · \(attentionSuffix(reason))")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(SolstoneColors.solOrange)
                    }
                } else {
                    Text("settings…")
                }
            }
            .accessibilityIdentifier(AXID.Menubar.settingsButton)
            Button("about sol") {
                openWindow(id: "about")
                appState.didOpenWindow(.about)
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier(AXID.Menubar.aboutButton)
        }

        Divider()

        Button("quit sol") {
            appState.appQuitCoordinator.requestAppOwnedQuit()
        }
        .accessibilityIdentifier(AXID.Menubar.quitButton)
    }

    // MARK: - Status Row

    private var menubarPresentation: MenubarPresentation {
        appState.menubarPresentation(durableUpdateStatus: updateController.durableUpdateStatus)
    }

    private var settingsAttentionToShow: AttentionReason? {
        attentionToSurface(
            menubarPresentation.attention,
            alreadySaidBy: menubarPresentation.observation
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

        case .journalMigrationNeeded:
            Button("your journal needs a new link →") {
                openSettings(tab: "journal")
            }
            .accessibilityIdentifier(AXID.Menubar.journalMigrationNeededButton)
            .accessibilityValue(rowState.axToken)

        case .connectionWaiting:
            Button("connecting to your journal…") {
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
            Text(UICopy.MENUBAR_OBSERVING_CONNECTED)
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)
        }
    }

    private var statusRowAXValue: String {
        statusRowState.axToken
    }

    private var statusRowState: MenubarStatusRowState {
        menubarPresentation.observation
    }

    // MARK: - Pause Controls

    private var hasPauseControl: Bool {
        appState.isRecording && !appState.isPaused
    }

    private var hasResumeControl: Bool {
        appState.capture.isUserPaused
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

func pausedHeaderText(timeRemaining: String?) -> String {
    guard let t = timeRemaining else { return "paused" }
    let compact = t.replacingOccurrences(of: " mins", with: " min")
                   .replacingOccurrences(of: " secs", with: " sec")
                   .replacingOccurrences(of: " hrs", with: " hr")
    return "paused, \(compact) left"
}
