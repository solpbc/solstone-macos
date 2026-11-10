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
        ForEach(appState.deckTiles.filter { $0.state == .needsAttention }, id: \.source) { tile in
            Button("\(tile.source.label) needs attention") {
                openSolstoneWindow(appState: appState, route: "source:\(tile.source.rawValue)")
            }
        }

        Text(statusLine)
            .accessibilityIdentifier(AXID.Menubar.statusRowState)

        let controls = appState.deckPauseControls
        if controls.pause {
            Menu("pause") {
                Button("15 minutes") { appState.pauseManager.pause(for: .minutes(15)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseFifteenMinutes)
                Button("30 minutes") { appState.pauseManager.pause(for: .minutes(30)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseThirtyMinutes)
                Button("1 hour") { appState.pauseManager.pause(for: .minutes(60)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseOneHour)
                Button("until I resume") { appState.pauseManager.pause(for: .indefinite) }
                    .accessibilityIdentifier(AXID.Menubar.pauseIndefinite)
            }
            .accessibilityIdentifier(AXID.Menubar.pauseMenu)
        } else if controls.resume {
            Button("resume") { appState.pauseManager.resume() }
                .accessibilityIdentifier(AXID.Menubar.resumeButton)
        }

        Divider()

        Button("open settings") {
            openSolstoneWindow(appState: appState, route: nil)
        }
        .accessibilityIdentifier(AXID.Menubar.settingsButton)
        if appState.deckHasJournal {
            Button("open journal") { appState.requestOpenJournal(.root) }
                .disabled(!appState.canOpenJournal)
                .accessibilityIdentifier(AXID.Menubar.openJournalButton)
        }

        Divider()

        Button("about solstone") {
            NotificationCenter.default.post(name: .openAboutWindow, object: nil)
        }
        .accessibilityIdentifier(AXID.Menubar.aboutButton)

        Divider()

        Button("quit solstone") {
            appState.appQuitCoordinator.requestAppOwnedQuit()
        }
        .accessibilityIdentifier(AXID.Menubar.quitButton)
    }

    /// The pill's words with the status lead, or the time left while paused.
    private var statusLine: String {
        let _ = appState.pauseManager.refreshTick
        let pause = appState.pauseManager.pauseState
        if let paused = pausedTimeLeftLine(isPaused: pause.isPaused, remaining: pause.timeRemaining(at: Date())) {
            return paused
        }
        let pill = appState.journalPill
        return menuStatusLine(pill)
    }
}

/// The menu's status line for a pill: caught up gets its lead beside the pill's word.
func menuStatusLine(_ pill: JournalPill) -> String {
    pill == .connected ? "connected · all caught up" : pill.text
}
