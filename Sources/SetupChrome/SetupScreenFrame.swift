// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

public struct SetupScreenFrame: View {
    @Environment(\.colorScheme) private var colorScheme
    public let image: NSImage?
    public let placeholder: String
    public let caption: String
    public let accessibilityIdentifier: String

    public init(
        image: NSImage?,
        placeholder: String,
        caption: String,
        accessibilityIdentifier: String
    ) {
        self.image = image
        self.placeholder = placeholder
        self.caption = caption
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(SetupChromeColor.sheet(for: colorScheme))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier(accessibilityIdentifier)
                } else {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                        .accessibilityIdentifier(accessibilityIdentifier)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SetupChromeColor.hairline(for: colorScheme), lineWidth: 1)
            )

            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
        }
    }
}
