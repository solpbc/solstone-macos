// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The mark at pill size, on one line: the two chips small, then the words. It is the same unit as
/// the card (same chips, same words, same spoken value), drawn smaller, for a place that points at
/// the journal rather than introduces it. With no identity it draws the generic dashed chips and
/// "your · journal", never an empty slot.
public struct JournalMarkInlineView: View {
    let mark: JournalMark?
    let chipSide: CGFloat
    let wordSize: CGFloat

    public init(mark: JournalMark?, chipSide: CGFloat = 15, wordSize: CGFloat = 13) {
        self.mark = mark
        self.chipSide = chipSide
        self.wordSize = wordSize
    }

    public var body: some View {
        HStack(spacing: chipSide * 0.5) {
            HStack(spacing: chipSide * 0.3) {
                if let mark {
                    scaled(JournalMarkIconChip(icon: mark.icon1))
                    scaled(JournalMarkIconChip(icon: mark.icon2))
                } else {
                    scaled(JournalMarkGenericChip(hex: JournalIconTileGeometry.genericChip1Hex, rotated: false))
                    scaled(JournalMarkGenericChip(hex: JournalIconTileGeometry.genericChip2Hex, rotated: true))
                }
            }
            Text(MarkGeometry.markWords(mark?.words ?? JournalMarkGeneric.words))
                .font(JournalMarkFont.isRegistered ? .custom("Comfortaa-Bold", size: wordSize) : .system(size: wordSize, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(JournalMarkAccessibility.spokenValue(mark: mark))
        .accessibilityAddTraits(.isStaticText)
    }

    private func scaled<V: View>(_ chip: V) -> some View {
        chip
            .scaleEffect(chipSide / MarkGeometry.size)
            .frame(width: chipSide, height: chipSide)
    }

    /// The mark's own card fill: the words' fixed ink is set against it in both appearances.
    public static var cardFill: Color { MarkGeometry.cardFill }
    public static var cardBorder: Color { MarkGeometry.cardBorder }
}
