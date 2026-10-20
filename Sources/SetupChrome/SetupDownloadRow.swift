// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public struct SetupDownloadRow: View {
    @Environment(\.colorScheme) private var colorScheme
    public let name: String
    public let detail: String?
    public let fraction: Double?
    public let indeterminate: Bool
    public let actionTitle: String?
    public let actionEnabled: Bool
    public let actionIdentifier: String?
    public let action: () -> Void

    public init(
        name: String,
        detail: String?,
        fraction: Double?,
        indeterminate: Bool,
        actionTitle: String?,
        actionEnabled: Bool,
        actionIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.actionIdentifier = actionIdentifier
        self.name = name
        self.detail = detail
        self.fraction = fraction
        self.indeterminate = indeterminate
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))

                    if let detail {
                        Spacer()
                        Text(detail)
                            .lineLimit(2)
                            .font(.system(size: 12))
                            .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                    }
                }

                if fraction != nil || indeterminate {
                    barView
                        .frame(width: 220, height: 4)
                }
            }
            .frame(width: 220)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text([name, detail].compactMap { $0 }.joined(separator: ", ")))

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(SetupTextButtonStyle())
                    .lineLimit(1)
                    .fixedSize()
                    .disabled(!actionEnabled)
                    .accessibilityLabel(Text("\(name) \(actionTitle)"))
                    .modifier(OptionalAccessibilityIdentifier(identifier: actionIdentifier))
            }
        }
    }

    @ViewBuilder
    private var barView: some View {
        if indeterminate {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(SetupChromeColor.solOrange)
        } else if let fraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SetupChromeColor.hairline2(for: colorScheme))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SetupChromeColor.solOrange)
                        .frame(width: max(0, min(CGFloat(fraction), 1.0) * geo.size.width))
                }
            }
        }
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
