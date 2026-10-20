// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupToggle: View {
    @Environment(\.colorScheme) private var colorScheme
    public let isOn: Binding<Bool>
    public let label: String
    public let help: String?
    public let accessibilityIdentifier: String

    public init(
        isOn: Binding<Bool>,
        label: String,
        help: String? = nil,
        accessibilityIdentifier: String
    ) {
        self.isOn = isOn
        self.label = label
        self.help = help
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SetupChromeColor.ink(for: colorScheme))
            }
            .tint(SetupChromeColor.solOrange)
            .accessibilityIdentifier(accessibilityIdentifier)

            if let help {
                Text(help)
                    .font(.system(size: 12))
                    .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
            }
        }
    }
}
