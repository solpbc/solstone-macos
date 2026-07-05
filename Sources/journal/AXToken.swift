// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

enum JournalSidebarTabState: CaseIterable {
    case selected
    case unselected
}

enum JournalEnabledState: CaseIterable {
    case enabled
    case disabled
}

struct AXStateCompanion: View {
    let id: String
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .clipped()
            .accessibilityIdentifier(id)
            .accessibilityLabel(id)
            .accessibilityValue(value)
    }
}

extension JournalSidebarTabState {
    static let axTokens = ["selected", "unselected"]

    var axToken: String {
        switch self {
        case .selected: return "selected"
        case .unselected: return "unselected"
        }
    }
}

extension JournalRunDisplay {
    static let axTokens = ["starting", "running", "stopped", "blocked", "unknown"]

    var axToken: String {
        rawValue
    }
}

extension JournalHealthDisplay {
    static let axTokens = ["healthy", "stopped", "unknown"]

    var axToken: String {
        rawValue
    }
}

extension JournalEnabledState {
    static let axTokens = ["enabled", "disabled"]

    var axToken: String {
        switch self {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        }
    }
}
