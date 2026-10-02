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

        // The row answers "is my journal receiving my life right now?"; this line answers
        // "from what?" — extra room is for more, never for a different answer.
        if appState.isRecording || appState.isPaused, !appState.captureManager.activeSources.isEmpty {
            Text(UICopy.sourceNames(appState.captureManager.activeSources))
        }
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        Button(menubarBrowserRowTitle(snapshot: appState.browserHostSnapshot.value, now: Date())) {
            openSettings(tab: "sources")
        }
        .accessibilityIdentifier(AXID.Menubar.browsers)
#endif
        Divider()

        Section {
            if appState.canOpenJournal {
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
                let label = settingsRowLabel(
                    observation: menubarPresentation.observation,
                    attention: menubarPresentation.attention,
                    verdict: appState.tunnelLifecycleOwner.connectionVerdict
                )
                if label.showsAttentionIcon {
                    Label {
                        Text(label.title)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(SolstoneColors.solOrange)
                    }
                } else {
                    Text(label.title)
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

    private var menubarPresentation: MenubarPresentation {
        appState.menubarPresentation(durableUpdateStatus: updateController.durableUpdateStatus)
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
        case .stopped:
            if appState.config.selectedSources.isEmpty {
                Button(UICopy.MENUBAR_SOURCES_OFF_OPEN_SETTINGS) {
                    openSettings(tab: "sources")
                }
                .accessibilityIdentifier(AXID.Menubar.statusRowState)
                .accessibilityValue(rowState.axToken)
            } else {
                Text(UICopy.MENUBAR_STARTING)
                    .accessibilityIdentifier(AXID.Menubar.statusRowState)
                    .accessibilityValue(rowState.axToken)
            }
        case .permissions:
            Button(UICopy.MENUBAR_NO_SOURCE_OPEN_SETTINGS) {
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
            } else if case .blocked(let reason) = appState.uploadCoordinator.status {
                Button(UICopy.menubarErrorOpenSettings(reason)) {
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
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            if !appState.isRecording && !appState.isPaused {
                let verdict = browserOwnerVerdict(
                    mediaSourcesEmpty: appState.config.selectedSources.isEmpty,
                    mediaRecording: false,
                    mediaPaused: false,
                    snapshot: appState.browserHostSnapshot.value,
                    now: Date()
                )
                let text: String = {
                    switch verdict.lead {
                    case .ready:
                        return UICopy.SOURCES_BROWSER_HEADLINE_READY
                    case .waiting:
                        return UICopy.SOURCES_BROWSER_HEADLINE_WAITING
                    case .draining:
                        return UICopy.SOURCES_BROWSER_DRAINING
                    case .paused:
                        return UICopy.SOURCES_BROWSER_PAUSED
                    case .custodyFull:
                        return UICopy.SOURCES_BROWSER_FULL
                    case .hold(let reason):
                        return reason == "unaccepted_lost" ? UICopy.SOURCES_BROWSER_LOST_AND_HELD : UICopy.SOURCES_BROWSER_HELD
                    case .notPaired:
                        return UICopy.SOURCES_BROWSER_CANNOT_START
                    case .intakeOff:
                        return UICopy.SOURCES_BROWSER_INTAKE_OFF
                    case .unavailable:
                        return UICopy.SOURCES_BROWSER_CANNOT_START
                    case .unknown:
                        return UICopy.SOURCES_BROWSER_UNKNOWN
                    case .shutdown, .sessionClosed:
                        return UICopy.SOURCES_BROWSER_INTAKE_OFF
                    case .mediaUnchanged:
                        return UICopy.MENUBAR_OBSERVING_CONNECTED
                    }
                }()
                Text(text)
                    .accessibilityValue(rowState.axToken)
                    .accessibilityIdentifier(AXID.Menubar.statusRowState)
            } else {
                Text(UICopy.MENUBAR_OBSERVING_CONNECTED)
                    .accessibilityValue(rowState.axToken)
                    .accessibilityIdentifier(AXID.Menubar.statusRowState)
            }
#else
            Text(UICopy.MENUBAR_OBSERVING_CONNECTED)
                .accessibilityValue(rowState.axToken)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)
#endif

        case .awaitingMarkConfirmation:
            Button(UICopy.MENUBAR_AWAITING_MARK_CONFIRMATION) {
                openSettings(tab: "journal")
                NotificationCenter.default.post(name: .reaskJournalMark, object: nil)
            }
            .accessibilityIdentifier(AXID.Menubar.journalMarkHeldButton)
            .accessibilityValue(rowState.axToken)
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
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        menuPauseControls(
            mediaRecording: appState.isRecording,
            mediaPaused: appState.isPaused,
            mediaUserPaused: appState.capture.isUserPaused,
            pauseManagerPaused: appState.pauseManager.isPaused,
            browserCapturePermitted: appState.browserPauseEnabled
        ).pause
#else
        appState.isRecording && !appState.isPaused
#endif
    }

    private var hasResumeControl: Bool {
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        menuPauseControls(
            mediaRecording: appState.isRecording,
            mediaPaused: appState.isPaused,
            mediaUserPaused: appState.capture.isUserPaused,
            pauseManagerPaused: appState.pauseManager.isPaused,
            browserCapturePermitted: appState.browserPauseEnabled
        ).resume
#else
        appState.capture.isUserPaused
#endif
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
