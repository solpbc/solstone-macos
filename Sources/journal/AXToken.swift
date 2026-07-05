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

enum JournalFirstRunRouteState: CaseIterable {
    case deciding
    case nameLocation
    case setupProgress
    case markReveal
    case finalizing
    case adopting
    case home
}

enum JournalFirstRunBusyState: CaseIterable {
    case idle
    case running
    case failed
}

enum JournalFirstRunMarkState: CaseIterable {
    case unlocked
    case trying
    case locked
    case hidden
}

enum JournalAdoptState: CaseIterable {
    case idle
    case opening
    case landed
    case blocked
    case failed
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

extension JournalFirstRunRouteState {
    static let axTokens = ["deciding", "name_location", "setup_progress", "mark_reveal", "finalizing", "adopting", "home"]

    var axToken: String {
        switch self {
        case .deciding: return "deciding"
        case .nameLocation: return "name_location"
        case .setupProgress: return "setup_progress"
        case .markReveal: return "mark_reveal"
        case .finalizing: return "finalizing"
        case .adopting: return "adopting"
        case .home: return "home"
        }
    }
}

extension JournalFirstRunBusyState {
    static let axTokens = ["idle", "running", "failed"]

    var axToken: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .failed: return "failed"
        }
    }
}

extension JournalFirstRunMarkState {
    static let axTokens = ["unlocked", "trying", "locked", "hidden"]

    var axToken: String {
        switch self {
        case .unlocked: return "unlocked"
        case .trying: return "trying"
        case .locked: return "locked"
        case .hidden: return "hidden"
        }
    }
}

extension JournalAdoptState {
    static let axTokens = ["idle", "opening", "landed", "blocked", "failed"]

    var axToken: String {
        switch self {
        case .idle: return "idle"
        case .opening: return "opening"
        case .landed: return "landed"
        case .blocked: return "blocked"
        case .failed: return "failed"
        }
    }
}

extension JournalFirstRunRoute {
    var axToken: String {
        switch self {
        case .deciding:
            return JournalFirstRunRouteState.deciding.axToken
        case .ritual(.nameLocation):
            return JournalFirstRunRouteState.nameLocation.axToken
        case .ritual(.setupProgress):
            return JournalFirstRunRouteState.setupProgress.axToken
        case .ritual(.markReveal):
            return JournalFirstRunRouteState.markReveal.axToken
        case .ritual(.finalizing):
            return JournalFirstRunRouteState.finalizing.axToken
        case .adopting:
            return JournalFirstRunRouteState.adopting.axToken
        case .home:
            return JournalFirstRunRouteState.home.axToken
        }
    }
}

extension JournalFirstRunModel {
    var markState: JournalFirstRunMarkState {
        if currentMark == nil { return .hidden }
        if isTryingAnotherMark { return .trying }
        return markLocked ? .locked : .unlocked
    }

    var adoptState: JournalAdoptState {
        if adoptMessage == JournalFirstRunCopy.adoptLandingLine { return .landed }
        if route == .home { return .landed }
        if errorMessage != nil { return .failed }
        if route == .adopting { return .opening }
        return .idle
    }
}
