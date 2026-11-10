// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import SwiftUI

/// The window's sidebar: five rows. Raw values are the sidebar's accessibility ids, kept from
/// the panes these rows replace so automation that knew `service` and `updates` still finds them.
enum ShelfRow: String, CaseIterable, Hashable, Sendable {
    case home = "home"
    case service = "service"
    case observer = "observer"
    case updates = "updates"
    case help = "help"
}

/// What opens in the one pane beside the deck.
enum HomePane: Hashable, Sendable {
    case status
    case source(DeckSource)
    case addMore
}

/// Where a request to open the window lands.
struct ShellRoute: Equatable {
    var shelf: ShelfRow
    var pane: HomePane?

    init(shelf: ShelfRow, pane: HomePane?) {
        self.shelf = shelf
        self.pane = pane
    }

    @MainActor
    init(tab: SettingsView.Tab, appState: AppState) {
        let screenMissing = appState.config.isScreenCaptureEnabled && !appState.screenRecordingGranted
        let microphoneMissing = appState.config.isMicrophoneCaptureEnabled && !appState.microphoneGranted
        self.init(tab: tab, screenPermissionMissing: screenMissing, microphonePermissionMissing: microphoneMissing)
    }

    init(tab: SettingsView.Tab, screenPermissionMissing: Bool, microphonePermissionMissing: Bool) {
        switch tab {
        case .home, .sources: (shelf, pane) = (.home, nil)
        case .status: (shelf, pane) = (.home, .status)
        case .microphones: (shelf, pane) = (.home, .source(.audio))
        case .privacy: (shelf, pane) = (.home, .source(.screen))
        case .permissions:
            if !screenPermissionMissing && microphonePermissionMissing {
                (shelf, pane) = (.home, .source(.audio))
            } else {
                (shelf, pane) = (.home, .source(.screen))
            }
        case .service: (shelf, pane) = (.service, nil)
        case .observer: (shelf, pane) = (.observer, nil)
        case .updates: (shelf, pane) = (.updates, nil)
        case .help: (shelf, pane) = (.help, nil)
        }
    }
}

extension SettingsView.Tab {
    /// The route strings menus, notifications and other windows have always written.
    init?(legacyRoute: String) {
        switch legacyRoute {
        case "home": self = .home
        case "observer", "general": self = .observer
        case "permissions": self = .permissions
        case "service", "journal": self = .service
        case "sources": self = .sources
        case "microphones": self = .microphones
        case "privacy": self = .privacy
        case "help": self = .help
        case "status": self = .status
        case "updates": self = .updates
        default: return nil
        }
    }
}

extension SettingsView {
    /// Every in-window jump goes through here, so a legacy place always opens its new home.
    func navigate(_ tab: Tab) {
        let route = ShellRoute(tab: tab, appState: appState)
        shelf = route.shelf
        homePane = route.pane
    }

    /// The page that holds the left-out lists is showing. Websites live on screen and browsers;
    /// private windows on screen.
    var leftOutShowing: Bool {
        shelf == .home && Self.paneHoldsLeftOut(homePane)
    }

    static func paneHoldsLeftOut(_ pane: HomePane?) -> Bool {
        pane == .source(.screen) || pane == .source(.browsers)
    }

    @ViewBuilder
    func shelfLabel(
        _ title: String,
        row: ShelfRow,
        systemImage: String,
        badge: SidebarBadgeState = .blank,
        doneAccessibilityLabel: String = UICopy.SETTINGS_TAB_DONE_A11Y
    ) -> some View {
        let label = Label(title, systemImage: systemImage)
        Group {
            switch badge {
            case .blank:
                label
                    .accessibilityIdentifier(AXID.Settings.Sidebar.row(row))
            case .attention:
                HStack {
                    label
                    Spacer()
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(SolstoneColors.solOrange)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), \(UICopy.SETTINGS_TAB_ATTENTION_A11Y)")
                .accessibilityIdentifier(AXID.Settings.Sidebar.row(row))
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
                .accessibilityIdentifier(AXID.Settings.Sidebar.row(row))
            }
        }
        .overlay(alignment: .topLeading) {
            AXStateCompanion(id: AXID.Settings.Sidebar.rowState(row), value: badge.axToken)
        }
        .tag(row)
    }
}
