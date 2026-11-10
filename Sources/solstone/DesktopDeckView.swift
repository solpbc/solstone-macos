// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import SetupChrome
import SolstoneCore
import SwiftUI

/// The deck's ground and face: the phone's warm ground in both appearances, Comfortaa for
/// names, the system face for everything read, sol orange as the one accent.
enum DeckStyle {
    static let nameFont = "Comfortaa-Bold"
    /// A fault's ink: dark red on the light ground, a lighter red on the dark one, so both read.
    static let attentionInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.48, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.16, blue: 0.13, alpha: 1)
    })

    static func name(_ size: CGFloat) -> Font { .custom(nameFont, size: size) }
}

/// One source's tile: name, glyph, state word, sub-line, and a switch where the Mac can start
/// and stop it. The tile opens the source's page; the switch is its own control beside it.
struct DeckTileView: View {
    let tile: DeckTile
    var selected = false
    var compact = false
    let onOpen: () -> Void
    let onSwitch: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    HStack(spacing: 6) {
                        Image(systemName: tile.source.systemImage)
                            .font(.system(size: compact ? 13 : 15))
                            .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                            .accessibilityHidden(true)
                        if compact {
                            Text(tile.source.label)
                                .font(DeckStyle.name(14))
                                .foregroundStyle(SetupChromeColor.ink(for: scheme))
                        }
                    }
                    if !compact {
                        Spacer(minLength: 8)
                        Text(tile.source.label)
                            .font(DeckStyle.name(17))
                            .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    }
                    DeckStateLine(state: tile.state)
                    if !compact, let subline = tile.subline {
                        Text(subline)
                            .font(.system(size: 11))
                            .foregroundStyle(SetupChromeColor.faintInk(for: scheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 46 : 104, alignment: .topLeading)
                .padding(compact ? 10 : 13)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tile.source.label)
            .accessibilityValue(tile.accessibilityValue)
            .accessibilityIdentifier(AXID.Deck.tile(tile.source))
            .overlay(alignment: .topLeading) {
                AXStateCompanion(id: AXID.Deck.tileState(tile.source), value: tile.state.axToken)
            }

            if let on = tile.switchOn {
                Toggle(tile.source.label, isOn: Binding(get: { on }, set: onSwitch))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SetupChromeColor.solOrange)
                    .controlSize(compact ? .mini : .small)
                    .padding(compact ? 8 : 11)
                    .accessibilityLabel(tile.source.label)
                    .accessibilityIdentifier(AXID.Deck.tileSwitch(tile.source))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SetupChromeColor.card(for: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? SetupChromeColor.solOrange : SetupChromeColor.hairline(for: scheme), lineWidth: selected ? 2 : 1)
        )
    }
}

/// The state word with its mark: a filled dot for on, two bars for paused, a diamond for a
/// fault, a ring for anything not yet running.
struct DeckStateLine: View {
    let state: DeckStateWord
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            mark
                .accessibilityHidden(true)
            Text(state.word)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
        }
    }

    private var ink: Color {
        switch state {
        case .needsAttention: return DeckStyle.attentionInk
        case .readyToSetUp: return SetupChromeColor.orangeText(for: scheme)
        case .off: return SetupChromeColor.softInk(for: scheme)
        default: return SetupChromeColor.ink(for: scheme)
        }
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .on:
            Circle().fill(SetupChromeColor.solOrange).frame(width: 7, height: 7)
        case .paused:
            HStack(spacing: 2) {
                Rectangle().frame(width: 2, height: 8)
                Rectangle().frame(width: 2, height: 8)
            }
            .foregroundStyle(SetupChromeColor.softInk(for: scheme))
        case .needsAttention:
            Rectangle().fill(DeckStyle.attentionInk).frame(width: 6, height: 6).rotationEffect(.degrees(45))
        case .readyToSetUp:
            Circle().stroke(SetupChromeColor.orangeText(for: scheme), lineWidth: 1.2).frame(width: 7, height: 7)
        case .off, .settingUp, .checking:
            Circle().stroke(SetupChromeColor.faintInk(for: scheme), lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}

/// The status pill: whether what was taken in reached the journal. Never a source's state.
struct JournalPillButton: View {
    let pill: JournalPill
    var selected = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if pill.isCaughtUp {
                    Circle().fill(SetupChromeColor.successDot(for: scheme)).frame(width: 7, height: 7)
                } else {
                    Circle().stroke(SetupChromeColor.softInk(for: scheme), lineWidth: 1.2).frame(width: 7, height: 7)
                }
                Text(pill.text)
                    .font(.system(size: 12))
                    .foregroundStyle(SetupChromeColor.ink(for: scheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(SetupChromeColor.card(for: scheme)))
            .overlay(Capsule().stroke(selected ? SetupChromeColor.solOrange : SetupChromeColor.hairline(for: scheme), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pill.text)
        .accessibilityIdentifier(AXID.Deck.pill)
        .overlay(alignment: .topLeading) {
            AXStateCompanion(id: AXID.Deck.pillState, value: pill.axToken)
        }
    }
}

/// `pause ▾` and its durations, or `resume` while paused. The durations are the 2.0.64 menu's.
struct DeckPauseControl: View {
    let appState: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let controls = appState.deckPauseControls
        if controls.pause {
            Menu {
                Button("15 minutes") { appState.pauseManager.pause(for: .minutes(15)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseFifteenMinutes)
                Button("30 minutes") { appState.pauseManager.pause(for: .minutes(30)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseThirtyMinutes)
                Button("1 hour") { appState.pauseManager.pause(for: .minutes(60)) }
                    .accessibilityIdentifier(AXID.Menubar.pauseOneHour)
                Button("until I resume") { appState.pauseManager.pause(for: .indefinite) }
                    .accessibilityIdentifier(AXID.Menubar.pauseIndefinite)
            } label: {
                Text("pause")
                    .font(.system(size: 12))
            }
            .menuStyle(.button)
            .fixedSize()
            .accessibilityLabel("pause")
            .accessibilityIdentifier(AXID.Deck.pause)
        } else if controls.resume {
            Button {
                appState.pauseManager.resume()
            } label: {
                Text("resume")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.primaryLabel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(SetupChromeColor.solOrange))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AXID.Deck.resume)
        }
    }
}

/// The time-left line while paused, refreshed with the pause manager's own tick.
struct DeckPausedLine: View {
    let appState: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let _ = appState.pauseManager.refreshTick
        let state = appState.pauseManager.pauseState
        if let line = pausedTimeLeftLine(isPaused: state.isPaused, remaining: state.timeRemaining(at: Date())) {
            Text(line)
                .font(.system(size: 12))
                .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                .accessibilityIdentifier(AXID.Deck.pausedLine)
        }
    }
}

/// The journal at the foot: its mark and words on the mark's own card, and the way in. With no
/// journal it shows the generic mark, which says "your · journal".
struct DeckJournalPill: View {
    let appState: AppState
    let fallback: () -> Void

    var body: some View {
        let mark = appState.confirmedMark
        Button {
            if appState.canOpenJournal {
                appState.requestOpenJournal(.root)
            } else {
                fallback()
            }
        } label: {
            JournalMarkInlineView(mark: mark)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(JournalMarkInlineView.cardFill))
                .overlay(Capsule().stroke(JournalMarkInlineView.cardBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("your journal")
        .accessibilityIdentifier(AXID.Deck.journalPill)
    }
}

/// The greeting band, refreshed each minute.
struct DeckGreeting: View {
    var size: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(deckGreeting(forHour: Calendar.current.component(.hour, from: context.date)))
                .font(DeckStyle.name(size))
                .foregroundStyle(SetupChromeColor.ink(for: scheme))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
