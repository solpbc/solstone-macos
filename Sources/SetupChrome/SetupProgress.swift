// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupProgress: View {
    @Environment(\.colorScheme) private var colorScheme
    public let index: Int
    public let count: Int
    public let label: String

    public init(index: Int, count: Int, label: String) {
        self.index = index
        self.count = count
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(1...count, id: \.self) { n in
                if n < index {
                    Circle()
                        .fill(SetupChromeColor.gold)
                        .frame(width: 8, height: 8)
                } else if n == index {
                    Capsule()
                        .fill(SetupChromeColor.solOrange)
                        .frame(width: 22, height: 8)
                } else {
                    Circle()
                        .fill(SetupChromeColor.hairline2(for: colorScheme))
                        .frame(width: 8, height: 8)
                }

                if n == 4 && n < count {
                    Spacer().frame(width: 8)
                }
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
