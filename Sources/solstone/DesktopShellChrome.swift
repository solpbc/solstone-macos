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
    /// The macOS 26 floating glass sidebar's look, as the app's own inset panel over the ground.
    case glassSidebar = "a"
    /// No sidebar surface: the shelf's rows as outlined pills floating on the ground.
    case floatingPills = "b"
    /// The shelf's rows together in one outlined pill on the ground.
    case onePill = "c"

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
            ZStack(alignment: .topLeading) {
                SunArcBackgroundView().ignoresSafeArea()
                HStack(alignment: .top, spacing: 0) {
                    GlassShelfPanel(selection: $shelf, rows: shelfRowItems)
                    detailColumn(drawsGround: false)
                }
            }
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
        case .onePill:
            ZStack(alignment: .topLeading) {
                SunArcBackgroundView().ignoresSafeArea()
                HStack(alignment: .top, spacing: 0) {
                    OnePillShelf(selection: $shelf, rows: shelfRowItems)
                        .padding(.leading, 18)
                        .padding(.top, 20)
                    detailColumn(drawsGround: false)
                }
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

/// The shelf's five rows in one outlined pill on the ground; the place you are is washed orange.
struct OnePillShelf: View {
    @Binding var selection: ShelfRow
    let rows: [ShelfRowItem]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { item in
                ShelfRowButton(item: item, selected: selection == item.row) { selection = item.row }
            }
        }
        .padding(6)
        .frame(width: 172)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(SetupChromeColor.card(for: scheme)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(SetupChromeColor.hairline(for: scheme), lineWidth: 1))
    }
}

/// The macOS 26 floating sidebar's look on any release: an inset, rounded panel with the window
/// buttons inside its top, glass where the system has it and a material where it doesn't.
struct GlassShelfPanel: View {
    @Binding var selection: ShelfRow
    let rows: [ShelfRowItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window buttons sit in the panel's top band.
            Color.clear.frame(height: 34)
            ForEach(rows) { item in
                ShelfRowButton(item: item, selected: selection == item.row, glass: true) { selection = item.row }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(GlassPanelBackground(cornerRadius: 18))
        .padding(8)
        .ignoresSafeArea(edges: .top)
    }
}

struct GlassPanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// One shelf row: glyph, name, and the attention dot where a row needs the owner.
struct ShelfRowButton: View {
    let item: ShelfRowItem
    let selected: Bool
    var glass = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if item.badge == .attention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SetupChromeColor.solOrange)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(glass ? Color.primary : SetupChromeColor.ink(for: scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: glass ? 9 : 14, style: .continuous)
                        .fill(glass ? Color.primary.opacity(0.10) : SetupChromeColor.orangeWash(for: scheme))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.badge == .attention ? "\(item.title), \(UICopy.SETTINGS_TAB_ATTENTION_A11Y)" : item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AXID.Settings.Sidebar.row(item.row))
    }
}
