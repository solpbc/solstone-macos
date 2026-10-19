// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

public enum SetupProofKind: Equatable, Sendable {
    case on
    case off
    case notRunning
    case paused
}

public struct SetupProofLine<Trailing: View>: View {
    public typealias Kind = SetupProofKind

    @Environment(\.colorScheme) private var colorScheme
    public let kind: SetupProofKind
    public let title: String
    private let trailing: Trailing

    public init(
        kind: Kind,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.kind = kind
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SetupChromeColor.ink(for: colorScheme))
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch kind {
        case .on:
            ZStack {
                Circle()
                    .fill(SetupChromeColor.successDot(for: colorScheme).opacity(0.2))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(SetupChromeColor.successDot(for: colorScheme))
                    .frame(width: 10, height: 10)
            }
            .frame(width: 18, height: 18)
        case .off, .notRunning:
            Circle()
                .stroke(SetupChromeColor.hairline2(for: colorScheme), lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .frame(width: 18, height: 18)
        case .paused:
            Circle()
                .fill(SetupChromeColor.pausedDot(for: colorScheme))
                .frame(width: 10, height: 10)
                .frame(width: 18, height: 18)
        }
    }
}

extension SetupProofLine where Trailing == EmptyView {
    public init(kind: Kind, title: String) {
        self.init(kind: kind, title: title, trailing: { EmptyView() })
    }
}
