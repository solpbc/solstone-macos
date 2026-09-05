// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum WatchdogProduct: String, Codable, Equatable, Sendable {
    case observer
    case journal

    public init?(enclosingBundleIdentifier: String) {
        // The designated-identifier signals in Makefile are deliberately not cross-checked here; code identity is deferred to future work.
        switch enclosingBundleIdentifier {
        case "app.solstone.observer": self = .observer
        case "app.solstone.journal": self = .journal
        default: return nil
        }
    }

    public var targetBundleID: String {
        switch self {
        case .observer: "app.solstone.observer"
        case .journal: "app.solstone.journal"
        }
    }

    public var loggerSubsystem: String {
        switch self {
        case .observer: "app.solstone.observer.watchdog"
        case .journal: "app.solstone.journal.watchdog"
        }
    }

    public var markerDiscriminator: String {
        switch self {
        case .observer: ExpectedExitMarker.solMarkerDiscriminator
        case .journal: ExpectedExitMarker.journalMarkerDiscriminator
        }
    }
}
