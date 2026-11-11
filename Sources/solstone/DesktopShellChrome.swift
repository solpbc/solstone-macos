// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI
import UpdateKit

extension SettingsView {
    /// The ground reaches the top edge, and the shelf floats on it as an inset glass panel with the
    /// window buttons inside its top: the look macOS 26 gave its sidebar, drawn by the app because
    /// later macOS draws the system sidebar edge to edge. Narrower, the shelf tucks behind a button
    /// beside the window buttons and floats over the content when opened.
    var shellChromeContent: some View {
        GeometryReader { geometry in
            let layout = ShellLayout(width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                SunArcBackgroundView().ignoresSafeArea()
                if layout == .full {
                    HStack(alignment: .top, spacing: 0) {
                        GlassShelfPanel(selection: shelfSelection, rows: shelfRowItems)
                        detailColumn
                    }
                } else {
                    detailColumn
                    if shelfOpen {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture { shelfOpen = false }
                        GlassShelfPanel(selection: shelfSelection, rows: shelfRowItems, floating: true)
                            .frame(maxHeight: 300, alignment: .top)
                            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                            .transition(.opacity)
                    }
                    ShelfToggleButton(isOpen: $shelfOpen)
                        // On the window buttons' line, just past them.
                        .padding(.leading, 82)
                        .padding(.top, -22)
                }
            }
            .onAppear { shellLayout = layout }
            .onChange(of: layout) { _, newValue in
                shellLayout = newValue
                shelfOpen = false
                if newValue != .phone { phonePushed = false }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
    }

    /// Choosing a shelf row also closes the floating shelf and returns a pushed page to its deck.
    var shelfSelection: Binding<ShelfRow> {
        Binding(
            get: { shelf },
            set: { row in
                shelf = row
                shelfOpen = false
                phonePushed = false
            }
        )
    }

    var shelfRowItems: [ShelfRowItem] {
        [
            ShelfRowItem(row: .home, title: "home", systemImage: "house", badge: .blank),
            // A notice that belongs to no tile badges the row it belongs to: an unknown journal on
            // your journal, a shortcut needing repair on this mac, an update on updates.
            ShelfRowItem(
                row: .service, title: "your journal", systemImage: "book.closed",
                badge: appState.serviceNeedsAttention || !appState.tunnelLifecycleOwner.unknownJournals.notices.isEmpty
                    ? .attention : (appState.serviceIsDone ? .done : .blank)
            ),
            ShelfRowItem(
                row: .observer, title: "this mac", systemImage: "laptopcomputer",
                badge: appState.shortcutController.isUnavailableOrConflict ? .attention : .blank
            ),
            ShelfRowItem(
                row: .updates, title: UpdatesCopy(provider: .solstone).tabTitle, systemImage: "arrow.down.circle",
                badge: updatesSidebarBadge(for: updateController.durableUpdateStatus)
            ),
            ShelfRowItem(row: .help, title: "help", systemImage: "questionmark.circle", badge: .blank),
        ]
    }

    /// Home is the deck and its pane; every other row is its body, on the sheet over the ground.
    var detailColumn: some View {
        ScrollViewReader { proxy in
            if shelf == .home {
                deskHome(scrollProxy: proxy)
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
                body
                    .background { DeckPaneGround().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary, lineWidth: 1))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .padding(.top, shellLayout == .full ? 18 : 30)
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

/// The macOS 26 floating sidebar's look on any release: an inset, rounded panel with the window
/// buttons inside its top, glass where the system has it and a material where it doesn't.
/// Floating over the deck at the narrower widths it is opaque, so no tile shows through it.
struct GlassShelfPanel: View {
    @Binding var selection: ShelfRow
    let rows: [ShelfRowItem]
    /// Opened from the shelf button, over the content, below the window buttons.
    var floating = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window buttons sit in the panel's top band; floating, the button sits there.
            Color.clear.frame(height: floating ? 30 : 34)
            ForEach(rows) { item in
                ShelfRowButton(item: item, selected: selection == item.row) { selection = item.row }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(GlassPanelBackground(cornerRadius: 18, opaque: floating ? SetupChromeColor.sheet(for: scheme) : nil))
        .padding(8)
        .ignoresSafeArea(edges: .top)
    }
}

struct GlassPanelBackground: ViewModifier {
    let cornerRadius: CGFloat
    /// A solid fill in place of the glass, for a panel that floats over content.
    var opaque: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if let opaque {
            content
                .background(opaque, in: shape)
                .overlay(shape.stroke(.quaternary, lineWidth: 1))
        } else if #available(macOS 26.0, *) {
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
    let action: () -> Void

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
                switch item.badge {
                case .attention:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SetupChromeColor.solOrange)
                        .accessibilityHidden(true)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                case .blank:
                    EmptyView()
                }
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(AXID.Settings.Sidebar.row(item.row))
        .overlay(alignment: .topLeading) {
            AXStateCompanion(id: AXID.Settings.Sidebar.rowState(item.row), value: item.badge.axToken)
        }
    }

    private var accessibilityLabel: String {
        switch item.badge {
        case .attention: return "\(item.title), \(UICopy.SETTINGS_TAB_ATTENTION_A11Y)"
        case .done: return "\(item.title), \(item.row == .updates ? UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y : UICopy.SETTINGS_TAB_DONE_A11Y)"
        case .blank: return item.title
        }
    }
}

/// The shelf's button beside the window buttons, at the narrower widths.
struct ShelfToggleButton: View {
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("sidebar")
        .accessibilityValue(isOpen ? "open" : "closed")
        .accessibilityIdentifier(AXID.Deck.shelfButton)
    }
}
