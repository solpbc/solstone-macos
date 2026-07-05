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

enum JournalDevicesCopiedState: CaseIterable {
    case idle
    case copied
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

extension JournalDevicesLoadState {
    static let axTokens = ["loading", "loaded", "empty", "not_running", "not_ready"]

    var axToken: String {
        rawValue
    }
}

extension PairingState {
    static let axTokens = ["idle", "opening", "open", "paired", "expired", "open_failed"]

    var axToken: String {
        switch self {
        case .idle: return "idle"
        case .opening: return "opening"
        case .open: return "open"
        case .paired: return "paired"
        case .expired: return "expired"
        case .openFailed: return "open_failed"
        }
    }
}

extension JournalDevicesCopiedState {
    static let axTokens = ["idle", "copied"]

    var axToken: String {
        switch self {
        case .idle: return "idle"
        case .copied: return "copied"
        }
    }
}
