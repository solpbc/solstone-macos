// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import JournalMarkKit
import SwiftUI

public struct SetupStep<Card: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let headline: String
    private let explanations: [String]
    private let card: Card
    private let footer: Footer

    public init(
        headline: String,
        explanations: [String],
        @ViewBuilder card: () -> Card,
        @ViewBuilder footer: () -> Footer
    ) {
        self.headline = headline
        self.explanations = explanations
        self.card = card()
        self.footer = footer()
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(
                    JournalMarkFont.isRegistered
                        ? .custom("Comfortaa-Bold", size: 34, relativeTo: .largeTitle)
                        : .system(size: 34, weight: .bold, design: .rounded)
                )
                .lineSpacing(4)
                .foregroundStyle(SetupChromeColor.ink(for: colorScheme))

            if !explanations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(explanations.enumerated()), id: \.offset) { index, explanation in
                        Text(explanation)
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .foregroundStyle(
                                index == 0
                                    ? SetupChromeColor.ink(for: colorScheme)
                                    : SetupChromeColor.softInk(for: colorScheme)
                            )
                            .frame(maxWidth: 510, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Below this width the headline block stacks above the card.
    static var stackWidth: CGFloat { 760 }

    @ViewBuilder
    private func columns(width: CGFloat) -> some View {
        if width >= Self.stackWidth {
            // Horizontal columns: left 0.9, right 1.1 of the space after a 40 pt gap and 32 pt sides.
            let usable = max(0, width - 64 - 40)
            HStack(alignment: .center, spacing: 40) {
                leftColumn
                    .frame(width: usable * 0.9 / 2.0, alignment: .leading)
                card
                    .frame(width: usable * 1.1 / 2.0, alignment: .leading)
            }
            .padding(.horizontal, 32)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                leftColumn
                card
            }
            .padding(.horizontal, 32)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                // Centred when it fits; scrolls above the footer when it does not.
                ScrollView(.vertical) {
                    columns(width: proxy.size.width)
                        .padding(.vertical, 24)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
    }
}
