// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI
import UpdateKit

/// How the window's chrome meets the ground. `current` is the system sidebar on its own material
/// with a standard title bar; the other three let the ground run to the top edge and differ in
/// where the shelf lives. Chosen by a hidden setting while the design is open.
enum ShellChrome: String, CaseIterable, Sendable {
    case current
    /// The system sidebar, with the ground and the sun running under and behind it.
    case glassSidebar = "a"
    /// No sidebar surface: the shelf's rows as outlined pills floating on the ground.
    case floatingPills = "b"
    /// The shelf behind one control at the top left, beside the window buttons.
    case menuButton = "c"

    static let defaultsKey = "solstone.shell.chrome"
    static let appearanceKey = "solstone.shell.appearance"

    static var configured: ShellChrome {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ShellChrome.init(rawValue:)) ?? .current
    }

    var groundChrome: Bool { self != .current }

    /// A hidden appearance override for reviewing a build in light and dark on a shared Mac
    /// without changing the Mac's own appearance.
    @MainActor
    static func applyConfiguredAppearance() {
        switch UserDefaults.standard.string(forKey: appearanceKey) {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

extension SettingsView {
    @ViewBuilder
    var shellChromeContent: some View {
        switch chrome {
        case .current:
            NavigationSplitView(columnVisibility: .constant(.all)) {
                shelfList
            } detail: {
                detailColumn(drawsGround: true)
            }
        case .glassSidebar:
            NavigationSplitView(columnVisibility: .constant(.all)) {
                shelfList
                    .scrollContentBackground(.hidden)
            } detail: {
                detailColumn(drawsGround: false)
            }
            .background(SunArcBackgroundView().ignoresSafeArea())
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
        case .floatingPills:
            ZStack(alignment: .topLeading) {
                SunArcBackgroundView().ignoresSafeArea()
                HStack(alignment: .top, spacing: 0) {
                    ShelfPills(selection: $shelf, rows: shelfRowItems)
                        .padding(.leading, 18)
                        .padding(.top, 20)
                    detailColumn(drawsGround: false)
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
        case .menuButton:
            ZStack(alignment: .topLeading) {
                SunArcBackgroundView().ignoresSafeArea()
                detailColumn(drawsGround: false)
                    .padding(.top, 14)
                ShelfMenuButton(selection: $shelf, rows: shelfRowItems)
                    // Beside the window buttons, on their centre line.
                    .padding(.leading, 84)
                    .padding(.top, -24)
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
        }
    }

    var shelfRowItems: [ShelfRowItem] {
        [
            ShelfRowItem(row: .home, title: "home", systemImage: "house", badge: .blank),
            ShelfRowItem(
                row: .service, title: "your journal", systemImage: "book.closed",
                badge: appState.serviceIsDone ? .done : (appState.serviceNeedsAttention ? .attention : .blank)
            ),
            ShelfRowItem(row: .observer, title: "this mac", systemImage: "laptopcomputer", badge: .blank),
            ShelfRowItem(
                row: .updates, title: UpdatesCopy(provider: .solstone).tabTitle, systemImage: "arrow.down.circle",
                badge: updatesSidebarBadge(for: updateController.durableUpdateStatus)
            ),
            ShelfRowItem(row: .help, title: "help", systemImage: "questionmark.circle", badge: .blank),
        ]
    }

    var shelfList: some View {
        let items = shelfRowItems
        return List(selection: $shelf) {
            shelfLabel(items[0].title, row: items[0].row, systemImage: items[0].systemImage, badge: items[0].badge)
            shelfLabel(items[1].title, row: items[1].row, systemImage: items[1].systemImage, badge: items[1].badge)
            shelfLabel(items[2].title, row: items[2].row, systemImage: items[2].systemImage, badge: items[2].badge)
            shelfLabel(
                items[3].title, row: items[3].row, systemImage: items[3].systemImage, badge: items[3].badge,
                doneAccessibilityLabel: UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y
            )
            shelfLabel(items[4].title, row: items[4].row, systemImage: items[4].systemImage, badge: items[4].badge)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .modifier(SettingsPaneScrollEdgeModifier())
    }

    /// Home is the deck; every other row is its body, on the sheet when the ground is the window's.
    func detailColumn(drawsGround: Bool) -> some View {
        ScrollViewReader { proxy in
            if shelf == .home {
                deskHome(scrollProxy: proxy, drawsGround: drawsGround)
            } else {
                let body = ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = appState.configSaveError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier(AXID.Settings.configSaveError)
                        }
                        detailContent(scrollProxy: proxy)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .modifier(SettingsPaneScrollEdgeModifier())
                if drawsGround {
                    body
                } else {
                    body
                        .background { DeckPaneGround().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
                        .padding(18)
                }
            }
        }
    }
}

struct ShelfRowItem: Identifiable {
    let row: ShelfRow
    let title: String
    let systemImage: String
    let badge: SettingsView.SidebarBadgeState
    var id: ShelfRow { row }
}

/// The shelf as outlined pills on the ground, like the tiles and the status pill.
struct ShelfPills: View {
    @Binding var selection: ShelfRow
    let rows: [ShelfRowItem]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { item in
                let selected = selection == item.row
                Button {
                    selection = item.row
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        if item.badge == .attention {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SetupChromeColor.solOrange)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(minWidth: 132, alignment: .leading)
                    .background(Capsule().fill(SetupChromeColor.card(for: scheme)))
                    .overlay(Capsule().stroke(selected ? SetupChromeColor.solOrange : SetupChromeColor.hairline(for: scheme), lineWidth: selected ? 2 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.badge == .attention ? "\(item.title), \(UICopy.SETTINGS_TAB_ATTENTION_A11Y)" : item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(AXID.Settings.Sidebar.row(item.row))
            }
        }
    }
}

/// The shelf behind one control: the place the owner is, and the other four a click away.
struct ShelfMenuButton: View {
    @Binding var selection: ShelfRow
    let rows: [ShelfRowItem]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let current = rows.first { $0.row == selection }
        Menu {
            ForEach(rows) { item in
                Button {
                    selection = item.row
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .accessibilityIdentifier(AXID.Settings.Sidebar.row(item.row))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                Text(current?.title ?? "home")
                    .font(.system(size: 13))
                if rows.contains(where: { $0.badge == .attention }) {
                    Circle().fill(SetupChromeColor.solOrange).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(SetupChromeColor.ink(for: scheme))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(SetupChromeColor.card(for: scheme)))
            .overlay(Capsule().stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("places, \(current?.title ?? "home")")
    }
}
