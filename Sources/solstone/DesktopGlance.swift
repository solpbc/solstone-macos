// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
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

/// The menu bar's one-click panel: the window's deck at a smaller size, in the same words.
struct GlanceView: View {
    @Bindable var appState: AppState
    @Bindable var updateController: UpdateController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pill = appState.journalPill
        let tiles = appState.deckTiles
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                JournalPillButton(pill: pill) { open("status") }
                Spacer()
                DeckPauseControl(appState: appState)
            }
            if let line = glanceLine(pill) {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                    .accessibilityIdentifier(AXID.Glance.line)
            }
            ForEach(notices, id: \.title) { notice in
                Button {
                    open(notice.route)
                } label: {
                    Text(notice.title)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupChromeColor.orangeText(for: scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AXID.Glance.notice)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(tiles, id: \.source) { tile in
                    DeckTileView(
                        tile: tile,
                        compact: true,
                        onOpen: { open("source:\(tile.source.rawValue)") },
                        onSwitch: { on in
                            if tile.source == .obsidian, on {
                                open("source:obsidian")
                            } else {
                                appState.setDeckSource(tile.source, on: on)
                            }
                        }
                    )
                    .accessibilityIdentifier(AXID.Glance.tile(tile.source))
                }
            }
            HStack {
                DeckJournalPill(appState: appState) { open("journal") }
                Spacer()
                Button {
                    open(nil)
                } label: {
                    Text("open solstone")
                        .font(.system(size: 12))
                        .foregroundStyle(SetupChromeColor.ink(for: scheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(SetupChromeColor.card(for: scheme)))
                        .overlay(Capsule().stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AXID.Glance.openSolstone)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(SetupChromeColor.sheet(for: scheme))
    }

    private func open(_ route: String?) {
        openSolstoneWindow(appState: appState, route: route)
        dismiss()
    }

    /// One line under the pill: what the status pane would lead with, or the time left while paused.
    private func glanceLine(_ pill: JournalPill) -> String? {
        let _ = appState.pauseManager.refreshTick
        let state = appState.pauseManager.pauseState
        if let paused = pausedTimeLeftLine(isPaused: state.isPaused, remaining: state.timeRemaining(at: Date())) {
            return paused
        }
        switch pill {
        case .connected: return "all caught up"
        case .notPaired: return "connect a journal"
        case .confirmMark: return "waiting for you to confirm your journal's mark"
        default:
            return pill.waiting > 0 ? "\(pill.waiting) waiting to sync, on this device" : nil
        }
    }

    /// Journal, update and shortcut matters that have nowhere else to show in the panel.
    /// A source's own fault is never here: its tile says it.
    private var notices: [(title: String, route: String)] {
        var rows: [(String, String)] = []
        if let reason = updateAttentionReason(for: updateController.durableUpdateStatus) {
            rows.append((attentionSuffix(reason), "updates"))
        }
        if appState.shortcutController.isUnavailableOrConflict {
            rows.append((UICopy.SHORTCUT_MENU_RECOVERY, "observer"))
        }
        for notice in appState.tunnelLifecycleOwner.unknownJournals.notices {
            rows.append((UnknownJournalNoticeCopy(site: notice.site).row, "journal"))
        }
        return rows
    }
}

/// The native menu on a secondary click of the menu bar icon: pause, the window, quit.
@MainActor
final class StatusItemSecondaryMenu: NSObject {
    static let shared = StatusItemSecondaryMenu()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard let window = event.window,
                  NSStringFromClass(type(of: window)).contains("StatusBarWindow") else { return event }
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            MainActor.assumeIsolated {
                StatusItemSecondaryMenu.shared.show(event: event, in: window)
            }
            return nil
        }
    }

    private func show(event: NSEvent, in window: NSWindow) {
        guard let appState = AppState.shared, let view = window.contentView else { return }
        NSMenu.popUpContextMenu(menu(appState: appState), with: event, for: view)
    }

    func menu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        let controls = appState.deckPauseControls
        if controls.pause {
            let pause = NSMenuItem(title: "pause", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, minutes) in [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60)] {
                sub.addItem(item(title) { appState.pauseManager.pause(for: .minutes(minutes)) })
            }
            sub.addItem(item("until I resume") { appState.pauseManager.pause(for: .indefinite) })
            pause.submenu = sub
            menu.addItem(pause)
            menu.addItem(.separator())
        } else if controls.resume {
            menu.addItem(item("resume") { appState.pauseManager.resume() })
            menu.addItem(.separator())
        }
        menu.addItem(item("open solstone") { openSolstoneWindow(appState: appState, route: nil) })
        if appState.canOpenJournal {
            menu.addItem(item("open journal") { appState.requestOpenJournal(.root) })
        }
        menu.addItem(item("about solstone") {
            NotificationCenter.default.post(name: .openAboutWindow, object: nil)
        })
        menu.addItem(.separator())
        menu.addItem(item("quit solstone") { appState.appQuitCoordinator.requestAppOwnedQuit() })
        return menu
    }

    private func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = action
        return item
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    var handler: (@MainActor () -> Void)?

    @objc func fire() {
        handler?()
    }
}
