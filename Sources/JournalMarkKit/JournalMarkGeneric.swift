// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// Visual and spoken contract for the generic mark (nil / absent / uncommitted).
/// journal-mark.md section 4.3. Colors and dash geometry are the single source in
/// `JournalIconTileGeometry` (shared with the app-icon compositor) — never re-declared here,
/// so a palette fix in one place can't drift from the other.
nonisolated enum JournalMarkGeneric {
    static let words = ["your", "journal"]
    static let spokenValue = "your journal, not set up yet"
}

public enum JournalMarkSlot {
    public static func join(_ words: some Sequence<String>) -> String {
        words.joined(separator: "\u{00B7}")
    }
}

public enum JournalMarkUnavailable {
    public static let words = ["mark", "unavailable"]
    public static var slot: String { JournalMarkSlot.join(words) }
    public static let accessibleName = "your journal's mark, unavailable right now"
}

public struct JournalMarkUnavailableView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: MarkGeometry.verticalGap) {
            HStack(spacing: MarkGeometry.iconGap) {
                chip
                chip
            }

            Text(JournalMarkUnavailable.words.joined(separator: " · "))
                .font(JournalMarkFont.isRegistered ? .custom("Comfortaa-Bold", size: MarkGeometry.wordFontSize, relativeTo: .headline) : .system(size: MarkGeometry.wordFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(MarkGeometry.wordColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, MarkGeometry.cardHorizontalPadding)
        .padding(.vertical, MarkGeometry.cardVerticalPadding)
        .background(MarkGeometry.cardFill, in: RoundedRectangle(cornerRadius: MarkGeometry.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MarkGeometry.cardRadius, style: .continuous)
                .stroke(MarkGeometry.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(JournalMarkUnavailable.accessibleName)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
            .fill(MarkGeometry.wordColor)
            .overlay {
                RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                    .stroke(MarkGeometry.chipBorder, lineWidth: MarkGeometry.chipBorderWidth)
            }
            .overlay {
                Text("?")
                    .font(.system(size: MarkGeometry.size * MarkGeometry.glyphScale, weight: .bold, design: .rounded))
                    .foregroundStyle(MarkGeometry.confirmationColor)
            }
            .frame(width: MarkGeometry.size, height: MarkGeometry.size)
    }
}

nonisolated enum JournalMarkAccessibility {
    static func spokenValue(mark: JournalMark?) -> String {
        guard let mark, mark.words.count >= 2 else {
            return JournalMarkGeneric.spokenValue
        }
        let c1 = mark.icon1.color.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let c2 = mark.icon2.color.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !c1.isEmpty, !c2.isEmpty {
            return "\(c1), \(c2), \(mark.words[0]), \(mark.words[1])"
        }
        return "\(mark.words[0]), \(mark.words[1])"
    }
}

/// The no-identity-yet chip: same tile, dashed border, no glyph.
/// journal-mark.md section 4.3.
struct JournalMarkGenericChip: View {
    let hex: String
    let rotated: Bool

    var body: some View {
        let color = MarkGeometry.color(hex: self.hex)
        return RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
            .fill(color.opacity(JournalIconTileGeometry.genericFillOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: MarkGeometry.chipBorderWidth,
                            dash: JournalIconTileGeometry.genericDashLengths(chipSide: MarkGeometry.size)
                        )
                    )
            }
            .frame(width: MarkGeometry.size, height: MarkGeometry.size)
            .rotationEffect(.degrees(self.rotated ? 45 : 0))
    }
}
