// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private static let hoverOrange = Color(.sRGB, red: 0xDB / 255.0, green: 0x83 / 255.0, blue: 0x30 / 255.0, opacity: 1.0)

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(SetupChromeColor.primaryLabel)
            .padding(.vertical, 9)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Self.hoverOrange : SetupChromeColor.solOrange)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.45)
            .onHover { isHovered = $0 }
    }
}

public struct SetupSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(SetupChromeColor.ink(for: colorScheme))
            .padding(.vertical, 9)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SetupChromeColor.card(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SetupChromeColor.hairline2(for: colorScheme), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45)
    }
}

public struct SetupTextButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(SetupChromeColor.orangeText(for: colorScheme))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45)
    }
}
