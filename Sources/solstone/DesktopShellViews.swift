// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI

// The window's home: the deck on the warm ground, and the pane beside it, always open with
// status by default. At phone width it becomes one column that pushes like the iPhone.
extension SettingsView {
    @ViewBuilder
    func deskHome(scrollProxy: ScrollViewProxy) -> some View {
        let pane = homePane ?? .status
        if shellLayout == .phone {
            if phonePushed {
                paneScroll(pane, scrollProxy: scrollProxy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                deckColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(spacing: 0) {
                deckColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                paneScroll(pane, scrollProxy: scrollProxy)
                    .frame(width: shellLayout.paneWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func paneScroll(_ pane: HomePane, scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            paneContent(pane, scrollProxy: scrollProxy)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // The pane's sheet runs to the window's top edge, like the ground beside it.
        .background(DeckPaneGround().ignoresSafeArea(edges: .top))
    }

    /// Opens a pane: a source's page, status or add more. At phone width it pushes.
    func openPane(_ pane: HomePane) {
        homePane = pane == .status ? nil : pane
        if shellLayout == .phone { phonePushed = true }
    }

    /// Back to status at the wider widths, back to the deck at phone width.
    func closePane() {
        if shellLayout == .phone {
            phonePushed = false
        } else {
            homePane = nil
        }
    }

    private var deckColumn: some View {
        let tiles = appState.deckTiles
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: shellLayout.deckColumns)
        let pane = homePane ?? .status
        let paused = appState.pauseManager.isPaused
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    DeckGreeting()
                    DeckPausedLine(appState: appState)
                }
                Spacer(minLength: 8)
                if paused, appState.deckPauseControls.resume {
                    DeckResumeButton(appState: appState)
                }
                JournalPillButton(pill: appState.journalPill, selected: shellLayout != .phone && pane == .status) {
                    openPane(.status)
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(tiles, id: \.source) { tile in
                        DeckTileView(
                            tile: tile,
                            selected: shellLayout != .phone && pane == .source(tile.source),
                            keyboardFocused: tileFocusFromKeyboard && focusedTile == tile.source,
                            onOpen: { openPane(.source(tile.source)) },
                            onSwitch: { on in switchSource(tile.source, on: on) }
                        )
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedTile, equals: tile.source)
                        .onKeyPress(.space) {
                            if let on = tile.switchOn { switchSource(tile.source, on: !on) }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            openPane(.source(tile.source))
                            return .handled
                        }
                    }
                    AddMoreTile(selected: shellLayout != .phone && pane == .addMore) { openPane(.addMore) }
                }
                .padding(4)
                .onMoveCommand { direction in
                    tileFocusFromKeyboard = true
                    moveTileFocus(direction, tiles: tiles)
                }
                // A click focuses a tile too; only focus that arrived by key draws the ring.
                .onChange(of: focusedTile) { _, _ in
                    tileFocusFromKeyboard = NSApp.currentEvent?.type == .keyDown
                }
            }
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                DeckJournalPill(appState: appState) { navigate(.service) }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, shellLayout == .full ? 20 : 30)
    }

    /// The tile switch. Turning Obsidian on needs a folder, so that opens its page instead.
    func switchSource(_ source: DeckSource, on: Bool) {
        if source == .obsidian, on {
            openPane(.source(.obsidian))
            return
        }
        if source == .screenshots, on {
            openPane(.source(.screenshots))
            Task { await appState.screenshotSource?.turnOn() }
            return
        }
        appState.setDeckSource(source, on: on)
    }

    private func moveTileFocus(_ direction: MoveCommandDirection, tiles: [DeckTile]) {
        let order = tiles.map(\.source)
        guard !order.isEmpty else { return }
        let columns = shellLayout.deckColumns
        let index = focusedTile.flatMap { order.firstIndex(of: $0) } ?? -1
        var next = index
        switch direction {
        case .left: next = index - 1
        case .right: next = index + 1
        case .up: next = index - columns
        case .down: next = index + columns
        @unknown default: break
        }
        if index < 0 { next = 0 }
        if order.indices.contains(next) { focusedTile = order[next] }
    }

    // MARK: - the pane

    @ViewBuilder
    func paneContent(_ pane: HomePane, scrollProxy: ScrollViewProxy) -> some View {
        switch pane {
        case .status:
            statusPane
                .onAppear {
                    appState.markSettingsTabVisited(.status)
                    refreshSetupProbes()
                }
        case .addMore:
            addMorePane
        case .source(let source):
            sourcePage(source, scrollProxy: scrollProxy)
                .id(source)
        }
    }

    /// A pane's title row. Status has no `×`, because the pane always shows it; at phone width
    /// every pushed page carries `‹ home` above its title instead.
    func paneHeader(_ title: String, systemImage: String? = nil, closable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if shellLayout == .phone {
                Button {
                    closePane()
                } label: {
                    Text("‹ home")
                        .font(.system(size: 13))
                        .foregroundStyle(SetupChromeColor.solOrange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("home")
                .accessibilityIdentifier(AXID.Deck.paneBack)
            }
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 16)).accessibilityHidden(true)
                }
                Text(title)
                    .font(DeckStyle.name(20))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if closable, shellLayout != .phone {
                    Button {
                        closePane()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("close")
                    .accessibilityIdentifier(AXID.Deck.paneClose)
                }
            }
        }
    }

    private var addMorePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            paneHeader("add more")
            Text("already on home")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(appState.deckTiles, id: \.source) { tile in
                Button {
                    openPane(.source(tile.source))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tile.source.systemImage).frame(width: 18).accessibilityHidden(true)
                        Text(tile.source.label).font(DeckStyle.name(14))
                        Spacer()
                        DeckStateLine(state: tile.state)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tile.source.label)
                .accessibilityValue(tile.state.word)
            }
        }
    }
}

/// `add more` on the deck: dotted, with the category as its sub-line.
struct AddMoreTile: View {
    var selected = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 15))
                    .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Text("add more")
                    .font(DeckStyle.name(17))
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                Text("sources")
                    .font(.system(size: 11))
                    .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(13)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? SetupChromeColor.solOrange : SetupChromeColor.hairline2(for: scheme),
                        style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
        )
        .accessibilityLabel("add more, sources")
        .accessibilityIdentifier(AXID.Deck.addMore)
    }
}

/// The pane's ground: the warm sheet, flat.
struct DeckPaneGround: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { SetupChromeColor.sheet(for: scheme) }
}
