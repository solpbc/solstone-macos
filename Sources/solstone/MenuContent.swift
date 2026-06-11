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
                Button("· \(pending.summary)") {
                    Task {
                        await AppState.shared?.solChatBridge.handleClick(requestID: pending.id)
                    }
                }
                .accessibilityIdentifier(AXID.Menubar.pendingChatButton)
            }

            Divider()
        }

        // Status section
        Section {
            statusRow
            AXStateCompanion(
                id: AXID.Menubar.statusRowState,
                value: statusRowAXValue
            )
        }

        if hasPauseResumeStartControl {
            Divider()

            // Pause / Resume / Start observing controls
            Section {
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
                if let reason = firstSettingsAttention(
                    permissionsNeedAttention: appState.permissionsNeedAttention,
                    journalNeedsAttention: appState.serviceNeedsAttention,
                    updateIsAvailable: updateController.updateIsAvailable,
                    updateCheckFailed: updateController.updateCheckFailed
                ) {
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
            Button("about solstone observer") {
                openWindow(id: "about")
                appState.didOpenWindow(.about)
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier(AXID.Menubar.aboutButton)
        }

        Divider()

        Button("quit solstone observer") {
            Task { @MainActor in
                await performMenuQuit(
                    isRecording: appState.isRecording,
                    stopRecording: { await appState.stopRecording() },
                    escapeActorJob: { work in DispatchQueue.main.async { work() } },
                    terminate: { NSApp.terminate(nil) }
                )
            }
        }
        .accessibilityIdentifier(AXID.Menubar.quitButton)
    }

    // MARK: - Status Row

    @ViewBuilder
    private var statusRow: some View {
        let rowState = statusRowState

        if appState.permissionsNeedAttention {
            Button("permissions needed — open settings →") {
                appState.pendingSettingsTab = "permissions"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier(AXID.Menubar.permissionsButton)
        } else if appState.bundledJournalStatusAvailable,
                  let journalRow = appState.journalRuntimeStatus.menuRowPresentation {
            if journalRow.isEnabled {
                Button(journalRow.text) {
                    appState.pendingSettingsTab = "journal"
                    openWindow(id: "settings")
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier(AXID.Menubar.journalState)
                .accessibilityValue(journalRow.state.axToken)
            } else {
                Text(journalRow.text)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AXID.Menubar.journalState)
                    .accessibilityValue(rowState.axToken)
            }
        } else if let error = appState.errorMessage {
            Button("error: \(error)") {
                appState.pendingSettingsTab = "status"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .foregroundStyle(.red)
            .accessibilityIdentifier(AXID.Menubar.errorButton)
        } else if appState.isRecording && !appState.config.isUploadConfigured && !appState.isPaused && !appState.pauseManager.isPaused {
            Button("observing - local only →") {
                appState.pendingSettingsTab = "journal"
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier(AXID.Menubar.localOnlyButton)
        } else if appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused {
            if appState.captureQueuedForJournalReadiness {
                Button(UICopy.JOURNAL_WAITING_FOR_READINESS_MENU_BUTTON) {
                    appState.pendingSettingsTab = "status"
                    openWindow(id: "settings")
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .accessibilityIdentifier(AXID.Menubar.journalState)
                .accessibilityValue(MenubarStatusRowState.journalWaiting.axToken)
            } else
            if appState.config.syncPaused {
                Text(recordingStatusText)
            } else {
                switch appState.uploadCoordinator.status {
                case .offline, .retrying:
                    Button("observing - offline (saved locally) →") {
                        appState.pendingSettingsTab = "status"
                        openWindow(id: "settings")
                        appState.didOpenWindow(.settings)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .accessibilityIdentifier(AXID.Menubar.offlineButton)
                default:
                    Text(recordingStatusText)
                        .accessibilityValue(rowState.axToken)
                }
            }
        } else if appState.pauseManager.isPaused {
            let _ = appState.pauseManager.refreshTick
            Text(pausedHeaderText(timeRemaining: appState.pauseManager.formatTimeRemaining()))
                .accessibilityValue(rowState.axToken)
        } else {
            Text(recordingStatusText)
                .accessibilityValue(rowState.axToken)
        }
    }

    private var statusRowAXValue: String {
        statusRowState.axToken
    }

    private var statusRowState: MenubarStatusRowState {
        if appState.permissionsNeedAttention {
            return .permissions
        }
        if appState.bundledJournalStatusAvailable,
           let journalRow = appState.journalRuntimeStatus.menuRowPresentation {
            return journalRow.state
        }
        if appState.errorMessage != nil {
            return .error
        }
        if appState.isRecording && !appState.config.isUploadConfigured && !appState.isPaused && !appState.pauseManager.isPaused {
            return .localOnly
        }
        if appState.pauseManager.isPaused || appState.isPaused {
            return .paused
        }
        if !appState.isRecording {
            return .stopped
        }
        if appState.config.syncPaused {
            return .observing
        }
        if appState.captureQueuedForJournalReadiness {
            return .journalWaiting
        }
        switch appState.uploadCoordinator.status {
        case .synced, .syncing, .uploading:
            return .observing
        case .notSynced, .retrying, .offline:
            return .offline
        }
    }

    private var recordingStatusText: String {
        if appState.pauseManager.isPaused {
            return "paused"
        }
        if appState.isPaused {
            return "paused"
        }
        if !appState.isRecording {
            return "stopped"
        }
        if appState.config.syncPaused {
            return "observing - sync paused"
        }
        if appState.captureQueuedForJournalReadiness {
            return UICopy.JOURNAL_WAITING_FOR_READINESS_MENU
        }
        switch appState.uploadCoordinator.status {
        case .synced, .syncing, .uploading:
            return "observing - connected"
        case .notSynced:
            return "observing - offline"
        case .retrying, .offline:
            return "observing - offline (saved locally)"
        }
    }

    // MARK: - Pause Controls

    private var hasPauseControl: Bool {
        appState.isRecording && !appState.isPaused && !appState.pauseManager.isPaused
    }

    private var hasResumeControl: Bool {
        appState.pauseManager.isPaused
    }

    private var hasStartControl: Bool {
        !appState.isRecording && appState.errorMessage == nil && !appState.permissionsNeedAttention
    }

    var hasPauseResumeStartControl: Bool {
        hasPauseControl || hasResumeControl || hasStartControl
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
        } else if hasStartControl {
            Button("start observing") {
                Task {
                    await appState.startRecording()
                }
            }
            .accessibilityIdentifier(AXID.Menubar.startObservingButton)
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
    return "paused - \(compact) left"
}

/// Drives the status-bar quit. `escapeActorJob` MUST schedule `terminate` to run
/// OUTSIDE the current Swift-concurrency job (a plain main-queue callout). Calling
/// `terminate()` inline here would deadlock: `NSApp.terminate` parks AppKit in a
/// nested event loop awaiting the `.terminateLater` handshake reply, but that reply
/// is a second @MainActor job that can't start while this non-reentrant job holds
/// the MainActor. Escaping the job first lets `terminate()` run with the MainActor
/// free, identical in shape to the proven AppleEvent/Sparkle/logout quit paths.
@MainActor
func performMenuQuit(
    isRecording: Bool,
    stopRecording: @MainActor () async -> Void,
    escapeActorJob: (@escaping @MainActor () -> Void) -> Void,
    terminate: @escaping @MainActor () -> Void
) async {
    if isRecording {
        await stopRecording()
    }
    escapeActorJob {
        terminate()
    }
}

enum SettingsAttentionReason: Equatable {
    case permissions, journal, updateAvailable, updateCheckFailed
}

func firstSettingsAttention(
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    updateIsAvailable: Bool,
    updateCheckFailed: Bool
) -> SettingsAttentionReason? {
    if permissionsNeedAttention { return .permissions }
    if journalNeedsAttention { return .journal }
    if updateIsAvailable { return .updateAvailable }
    if updateCheckFailed { return .updateCheckFailed }
    return nil
}

func settingsAttentionSuffix(_ reason: SettingsAttentionReason) -> String {
    switch reason {
    case .permissions: return UICopy.SETTINGS_ATTENTION_PERMISSIONS
    case .journal: return UICopy.SETTINGS_ATTENTION_JOURNAL
    case .updateAvailable: return UICopy.SETTINGS_ATTENTION_UPDATE_AVAILABLE
    case .updateCheckFailed: return UICopy.SETTINGS_ATTENTION_UPDATE_CHECK_FAILED
    }
}
