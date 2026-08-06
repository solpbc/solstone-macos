// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum ExitReason: Equatable, Sendable, CaseIterable {
    case ordinaryQuit
    case externalQuit
    case settingsRestart
    case updaterInstall
    case placementRepair
    case journalUpdaterInstall

    public var markerString: String {
        switch self {
        case .ordinaryQuit: "ordinary-quit"
        case .externalQuit: "external-quit"
        case .settingsRestart: "settings-restart"
        case .updaterInstall: "sparkle-update"
        case .placementRepair: "placement-repair"
        case .journalUpdaterInstall: "updater-install"
        }
    }

    public init?(markerString: String) {
        guard let reason = Self.allCases.first(where: { $0.markerString == markerString }) else {
            return nil
        }
        self = reason
    }

    public var watchdogExitClass: WatchdogExitClass {
        switch self {
        case .ordinaryQuit, .externalQuit:
            .ownerIntent
        case .settingsRestart, .placementRepair:
            .selfRelaunch(bound: WatchdogSupervisionPolicy.selfRelaunchBound)
        case .updaterInstall, .journalUpdaterInstall:
            .selfRelaunch(bound: WatchdogSupervisionPolicy.updaterOrUnrecognizedBound)
        }
    }
}

public enum WatchdogExitClass: Equatable, Sendable {
    case ownerIntent
    case selfRelaunch(bound: Duration)
}
