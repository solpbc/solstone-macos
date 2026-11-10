// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SetupChrome
import SolstoneCore
import SwiftUI

// The window's home: the deck on the warm ground, and one pane beside it.
extension SettingsView {
    func deskHome(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            deckColumn
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            if let pane = homePane {
                Divider()
                ScrollView {
                    paneContent(pane, scrollProxy: scrollProxy)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: 420)
                .frame(maxHeight: .infinity)
                .background(DeckPaneGround())
            }
        }
    }

    private var deckColumn: some View {
        let tiles = appState.deckTiles
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: deckColumns(paneOpen: homePane != nil))
        return ZStack {
            SunArcBackgroundView()
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        DeckGreeting()
                        DeckPausedLine(appState: appState)
                    }
                    Spacer(minLength: 8)
                    DeckPauseControl(appState: appState)
                    JournalPillButton(pill: appState.journalPill, selected: homePane == .status) {
                        homePane = homePane == .status ? nil : .status
                    }
                }
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(tiles, id: \.source) { tile in
                            DeckTileView(
                                tile: tile,
                                selected: homePane == .source(tile.source),
                                onOpen: { homePane = .source(tile.source) },
                                onSwitch: { on in switchSource(tile.source, on: on) }
                            )
                            .focusable()
                            .focused($focusedTile, equals: tile.source)
                            .onKeyPress(.space) {
                                if let on = tile.switchOn { switchSource(tile.source, on: !on) }
                                return .handled
                            }
                            .onKeyPress(.return) {
                                homePane = .source(tile.source)
                                return .handled
                            }
                        }
                        addMoreTile
                    }
                    .padding(2)
                    .onMoveCommand { direction in moveTileFocus(direction, tiles: tiles) }
                }
                .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    DeckJournalPill(appState: appState) { navigate(.service) }
                    Spacer()
                }
            }
            .padding(20)
        }
    }

    private var addMoreTile: some View {
        AddMoreTile(selected: homePane == .addMore) { homePane = .addMore }
    }

    /// The tile switch. Turning Obsidian on needs a folder, so that opens its page instead.
    func switchSource(_ source: DeckSource, on: Bool) {
        if source == .obsidian, on {
            homePane = .source(.obsidian)
            return
        }
        appState.setDeckSource(source, on: on)
    }

    private func moveTileFocus(_ direction: MoveCommandDirection, tiles: [DeckTile]) {
        let order = tiles.map(\.source)
        guard !order.isEmpty else { return }
        let columns = deckColumns(paneOpen: homePane != nil)
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

    func paneHeader(_ title: String, systemImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 16)).accessibilityHidden(true)
            }
            Text(title)
                .font(DeckStyle.name(20))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                homePane = nil
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

    private var addMorePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            paneHeader("add more")
            Text("already on home")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(appState.deckTiles, id: \.source) { tile in
                Button {
                    homePane = .source(tile.source)
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
