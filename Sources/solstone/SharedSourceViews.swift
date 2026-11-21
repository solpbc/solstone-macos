// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SetupChrome
import SwiftUI

extension SharedSourceDetail {
    private var stateWords: String? {
        switch state {
        case "paused": return DeckStateWord.paused.word
        case "needs_attention": return DeckStateWord.needsAttention.word
        default: return nil
        }
    }

    func line(at now: Date) -> String? { line(at: now, part: { $0 }) }

    /// The card's line as drawn: the vault name may wrap at its own spaces, but the state and the
    /// time never split, and a separator ends a line rather than starting one.
    func drawnLine(at now: Date) -> String? { line(at: now, part: keptWhole).map(separatorsEndLines) }

    func summary(device: String, at now: Date) -> String { summary(device: device, at: now, part: { $0 }) }

    func drawnSummary(device: String, at now: Date) -> String {
        separatorsEndLines(summary(device: device, at: now, part: keptWhole))
    }

    private func line(at now: Date, part: (String) -> String) -> String? {
        let state = stateWords.map(part)
        let relative = time.map { part(relativeWords($0, now: now)) }
        switch (detail, state, relative) {
        case let (detail?, state?, time?): return MacStrings.macos_shared_sa4(detail, state, time)
        case let (detail?, nil, time?): return MacStrings.macos_shared_sa4time(detail, time)
        case let (detail?, state?, nil): return MacStrings.macos_shared_sa4state(detail, state)
        case let (nil, state?, time?): return MacStrings.macos_shared_sa4statetime(state, time)
        default: return detail ?? state ?? relative
        }
    }

    private func summary(device: String, at now: Date, part: (String) -> String) -> String {
        switch (stateWords.map(part), time.map { part(relativeWords($0, now: now)) }) {
        case let (state?, time?): return MacStrings.macos_shared_sa3(device, state, time)
        case let (state?, nil): return MacStrings.macos_shared_sa3state(device, state)
        case let (nil, time?): return MacStrings.macos_shared_sa3time(device, time)
        default: return device
        }
    }
}

/// The separator wrap rule: a part's own spaces become no-break spaces, so it never splits.
private func keptWhole(_ part: String) -> String { part.replacingOccurrences(of: " ", with: "\u{a0}") }

/// The space before each separator becomes a no-break space, so the separator stays with the part
/// before it: the only place left to break is after a separator, and no line starts with one.
private func separatorsEndLines(_ line: String) -> String {
    line.replacingOccurrences(of: " \u{b7}", with: "\u{a0}\u{b7}")
}

extension SharedSourceDevice {
    /// The longest device name the tile shows whole. A longer one gives way first, so the state
    /// and the time always show.
    static let tileNameLimit = 20

    func summary(at now: Date) -> String { rows.first?.summary(device: name, at: now) ?? name }

    /// The tile's line: a long name shortened, every part kept whole, so a narrow tile wraps it
    /// only after a separator.
    func tileLine(at now: Date) -> String {
        let short = name.count > Self.tileNameLimit
            ? name.prefix(Self.tileNameLimit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
            : name
        return rows.first?.drawnSummary(device: keptWhole(short), at: now) ?? keptWhole(short)
    }

    /// An `also on` value: the full name, which may wrap at its own spaces, with the state and the
    /// time kept whole.
    func factLine(at now: Date) -> String { rows.first?.drawnSummary(device: name, at: now) ?? name }

    /// The app's own glyphs: a phone, a tablet, and for every computer, or a device that names no
    /// type, the one "this mac" uses.
    var glyph: String {
        switch type {
        case "phone", "mobile": return "smartphone"
        case "tablet": return "ipad"
        default: return "laptopcomputer"
        }
    }
}

struct SharedSourceHeading: View {
    let count: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Circle().strokeBorder(lineWidth: 1.2)
                .overlay { Circle().frame(width: 3, height: 3) }
                .frame(width: 8, height: 8).accessibilityHidden(true)
            Text(MacStrings.macos_shared_sa12(count))
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(SetupChromeColor.softInk(for: scheme))
    }
}

struct SharedSourceCard: View {
    let devices: [SharedSourceDevice]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
                SharedSourceHeading(count: devices.count)
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 {
                        Rectangle()
                            .fill(SetupChromeColor.hairline(for: scheme))
                            .frame(height: 1)
                            .padding(.leading, 26)
                            .accessibilityHidden(true)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: device.glyph)
                            .font(.system(size: 13))
                            .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SetupChromeColor.ink(for: scheme))
                            ForEach(device.rows.indices, id: \.self) { row in
                                if let line = device.rows[row].drawnLine(at: context.date) {
                                    Text(line)
                                        .font(.system(size: 11))
                                        .foregroundStyle(SetupChromeColor.softInk(for: scheme))
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(SetupChromeColor.card(for: scheme)))
        }
    }
}
