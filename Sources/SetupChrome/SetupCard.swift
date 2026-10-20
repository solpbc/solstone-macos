// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let heading: String?
    private let content: Content

    public init(
        heading: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.heading = heading
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let heading {
                Text(heading)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(SetupChromeColor.card(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SetupChromeColor.hairline(for: colorScheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
