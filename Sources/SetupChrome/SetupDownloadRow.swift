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

    /// The design's row width. A wider row squeezes the footer's primary onto two lines.
    static let width: CGFloat = 220

    private var showsBar: Bool { fraction != nil || indeterminate }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    // The name never wraps or truncates; the detail gives way first.
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupChromeColor.softInk(for: colorScheme))
                        .lineLimit(1)
                        .fixedSize()

                    if let detail {
                        Spacer(minLength: 8)
                        // A running download's bytes stay on one line, shortened in the middle
                        // when the name leaves too little room; a failure's own text may take a
                        // second line, as before.
                        Text(detail)
                            .lineLimit(showsBar ? 1 : 2)
                            .truncationMode(showsBar ? .middle : .tail)
                            .font(.system(size: 12))
                            .foregroundStyle(SetupChromeColor.faintInk(for: colorScheme))
                    }
                }

                if showsBar {
                    barView
                        .frame(width: Self.width, height: 4)
                }
            }
            .frame(width: Self.width)
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
