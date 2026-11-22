// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SolstoneCore
import SwiftUI
import UpdateKit

extension Notification.Name {
    static let openAboutWindow = Notification.Name("app.solstone.observer.openAbout")
}

/// Opens the window on a route: a legacy place name, or `source:<id>` for a source's page.
@MainActor
func openSolstoneWindow(appState: AppState, route: String?) {
    appState.pendingSettingsTab = route ?? "home"
    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
}

/// The menu bar icon's menu: the platform's own, on any click. The window is the one full surface,
/// so the menu names a source only when it needs the owner, and has no switches. Pause lives here.
struct ShellMenuContent: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            rowView(row)
        }
    }

    private var rows: [ShellMenuRow] {
        let _ = appState.pauseManager.refreshTick
        let pause = appState.pauseManager.pauseState
        let controls = appState.deckPauseControls
        return shellMenuRows(
            tiles: appState.deckTiles,
            pill: appState.journalPill,
            pausedLine: pausedTimeLeftLine(isPaused: pause.isPaused, remaining: pause.timeRemaining(at: Date())),
            canPause: controls.pause,
            canResume: controls.resume,
            hasJournal: appState.deckHasJournal,
            canOpenJournal: appState.canOpenJournal,
            update: updateController.durableUpdateStatus,
            importHasFault: appState.importSource?.snapshot.hasFault ?? false
        )
    }

    @ViewBuilder
    private func rowView(_ row: ShellMenuRow) -> some View {
        switch row {
        case .attention(let source):
            Button(row.title) {
                openSolstoneWindow(appState: appState, route: "source:\(source.rawValue)")
            }
        case .importAttention:
            Button(row.title) {
                openSolstoneWindow(appState: appState, route: "import")
            }
        case .update:
            Button(row.title) { openSolstoneWindow(appState: appState, route: ShelfRow.updates.rawValue) }
                .accessibilityIdentifier(AXID.Menubar.updateNotice)
        case .checkForUpdates:
            Button(row.title) {
                openSolstoneWindow(appState: appState, route: ShelfRow.updates.rawValue)
                updateController.checkForUpdates()
            }
            .accessibilityIdentifier(AXID.Menubar.checkForUpdates)
        case .status:
            Text(row.title)
                .accessibilityIdentifier(AXID.Menubar.statusRowState)
        case .pause:
            Menu(row.title) {
                Button(MacStrings.macos_setup_n15minutes()) { appState.pauseManager.pause(for: .minutes(15)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseFifteenMinutes)
                Button(MacStrings.macos_setup_n30minutes()) { appState.pauseManager.pause(for: .minutes(30)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseThirtyMinutes)
                Button(MacStrings.macos_setup_n1hour()) { appState.pauseManager.pause(for: .minutes(60)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseOneHour)
                Button(MacStrings.macos_setup_untiliresume()) { appState.pauseManager.pause(for: .indefinite) }
                    .accessibilityIdentifier(AXID.Menubar.pauseIndefinite)
            }
            .accessibilityIdentifier(AXID.Menubar.pauseMenu)
        case .resume:
            Button(row.title) { appState.pauseManager.resume() }
                .accessibilityIdentifier(AXID.Menubar.resumeButton)
        case .divider:
            Divider()
        case .openSettings:
            Button(row.title) { openSolstoneWindow(appState: appState, route: nil) }
                .accessibilityIdentifier(AXID.Menubar.settingsButton)
        case .openJournal(let enabled):
            Button(row.title) { appState.requestOpenJournal(.root) }
                .disabled(!enabled)
                .accessibilityIdentifier(AXID.Menubar.openJournalButton)
        case .about:
            Button(row.title) { NotificationCenter.default.post(name: .openAboutWindow, object: nil) }
                .accessibilityIdentifier(AXID.Menubar.aboutButton)
        case .quit:
            Button(row.title) { appState.appQuitCoordinator.requestAppOwnedQuit() }
                .accessibilityIdentifier(AXID.Menubar.quitButton)
        }
    }
}

/// The menu's status line for a pill: caught up gets its lead beside the pill's word.
func menuStatusLine(_ pill: JournalPill) -> String {
    switch pill {
    case .connected: return MacStrings.macos_desktopglance_connectedallcaughtup()
    case .waiting, .readyToReview: return MacStrings.macos_desktopglance_connected("\(pill.text)")
    default: return pill.text
    }
}
