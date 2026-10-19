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

    private var horizontalContent: some View {
        ViewThatFits(in: .horizontal) {
            // Horizontal columns: left weight 0.9, right 1.1, gap 40, side padding 32
            HStack(alignment: .top, spacing: 40) {
                leftColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0.9)

                card
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1.1)
            }
            .padding(.horizontal, 32)

            // Stacked columns (below ~760 pt or when text does not fit)
            VStack(alignment: .leading, spacing: 24) {
                leftColumn
                card
            }
            .padding(.horizontal, 32)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    horizontalContent
                    Spacer(minLength: 0)
                }

                ScrollView(.vertical) {
                    horizontalContent
                        .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
    }
}
