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
    static let readPendingSpokenValue = "your journal, mark not read yet"
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
    private let accessibleName: String

    /// `accessibleName` is for a slot that isn't the owner's own journal.
    public init(accessibleName: String = JournalMarkUnavailable.accessibleName) {
        self.accessibleName = accessibleName
    }

    public var body: some View {
        VStack(spacing: MarkGeometry.verticalGap) {
            HStack(spacing: MarkGeometry.iconGap) {
                chip
                chip
            }

            Text(MarkGeometry.markWords(JournalMarkUnavailable.words))
                .font(JournalMarkFont.isRegistered ? .custom("Comfortaa-Bold", size: MarkGeometry.wordFontSize, relativeTo: .headline) : .system(size: MarkGeometry.wordFontSize, weight: .bold, design: .rounded))
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
        .accessibilityValue(accessibleName)
        .accessibilityAddTraits(.isStaticText)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
            .fill(MarkGeometry.unavailableChipFill)
            .overlay {
                RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
                    .stroke(MarkGeometry.unavailableChipBorder, lineWidth: MarkGeometry.chipBorderWidth)
            }
            .overlay {
                Text("?")
                    .font(.system(size: MarkGeometry.size * MarkGeometry.glyphScale, weight: .bold, design: .rounded))
                    .foregroundStyle(MarkGeometry.faintInk)
            }
            .frame(width: MarkGeometry.size, height: MarkGeometry.size)
    }
}

public enum JournalMarkNotPresented {
    public static let words = ["not", "presented"]
    public static let accessibleName = "no identity presented"
    /// Neutral ink. Brand colour here would claim an affiliation with whatever answered.
    static let chipHex = "#6E6453"
}

/// The slot for a peer that presented no identity. Same geometry as every other mark state, so the
/// layout never jumps.
public struct JournalMarkNotPresentedView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: MarkGeometry.verticalGap) {
            HStack(spacing: MarkGeometry.iconGap) {
                JournalMarkGenericChip(hex: JournalMarkNotPresented.chipHex, rotated: false)
                JournalMarkGenericChip(hex: JournalMarkNotPresented.chipHex, rotated: true)
            }

            Text(MarkGeometry.markWords(JournalMarkNotPresented.words))
                .font(JournalMarkFont.isRegistered ? .custom("Comfortaa-Bold", size: MarkGeometry.wordFontSize, relativeTo: .headline) : .system(size: MarkGeometry.wordFontSize, weight: .bold, design: .rounded))
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
        .accessibilityValue(JournalMarkNotPresented.accessibleName)
        .accessibilityAddTraits(.isStaticText)
    }
}

nonisolated enum JournalMarkAccessibility {
    static func spokenValue(mark: JournalMark?, isReadPending: Bool = false) -> String {
        guard let mark, mark.words.count >= 2 else {
            return isReadPending ? JournalMarkGeneric.readPendingSpokenValue : JournalMarkGeneric.spokenValue
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
        let paper = MarkGeometry.color(hex: JournalIconTileGeometry.genericPaperHex)
        let shape = RoundedRectangle(cornerRadius: MarkGeometry.chipRadius, style: .continuous)
        return shape
            .fill(paper)
            .overlay {
                // Paper under the dashes too, so the gaps never show the ground behind the mark.
                shape.stroke(
                    paper,
                    lineWidth: MarkGeometry.chipBorderWidth * JournalIconTileGeometry.genericBackingWidthRatio
                )
            }
            .overlay {
                shape.stroke(
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
