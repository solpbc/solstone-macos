// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupErrorText: View {
    @Environment(\.colorScheme) private var colorScheme
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
        }
        .font(.system(size: 13))
        .foregroundStyle(SetupChromeColor.ink(for: colorScheme))
    }
}
