// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupOptionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    public let isSelected: Bool
    public let label: String
    public let subLabel: String?
    public let description: String
    public let action: () -> Void

    public init(
        isSelected: Bool,
        label: String,
        subLabel: String? = nil,
        description: String,
        action: @escaping () -> Void
    ) {
        self.isSelected = isSelected
        self.label = label
        self.subLabel = subLabel
        self.description = description
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? SetupChromeColor.solOrange : SetupChromeColor.hairline2(for: colorScheme),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle()
                            .fill(SetupChromeColor.solOrange)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        // The label is offered its full width first, so a label and sub-label
                        // that fit side by side stay on one line instead of both wrapping.
                        Text(label)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(SetupChromeColor.ink(for: colorScheme))
                            .layoutPriority(1)
                        if let subLabel {
                            Text(subLabel)
                                .font(.system(size: 12.5))
                                .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                        }
                    }

                    Text(description)
                        .font(.system(size: 13.5))
                        .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
                }
                // The text takes the row's whole width (a trailing spacer split it, wrapping
                // lines that fit).
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SetupChromeColor.orangeWash(for: colorScheme) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? SetupChromeColor.solOrange : SetupChromeColor.hairline(for: colorScheme),
                        lineWidth: 1
                    )
            )
            // The whole card is one target: without a shape, a plain button only takes clicks
            // on what it draws (the radio and the text), not its padding or the spacer.
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
