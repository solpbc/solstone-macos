// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum WatchdogSupervisionState: Equatable, Sendable {
    case supervising(pid: Int32, stableSince: Duration, consecutiveMisses: Int, failureCount: Int)
    case suppressed(until: Duration?)
    case retrying(failureCount: Int, nextAttemptAt: Duration)
}

public enum WatchdogSupervisionTransitionCause: Equatable, Sendable {
    case startup
    case ownerObserved
    case ownerPIDChanged
    case ownerExit
    case unstableOwnerExit
    case suppressionExpired
    case attemptFailed
    case attemptTimedOut
}

public struct WatchdogSupervisionTransition: Equatable, Sendable {
    public let destination: WatchdogSupervisionState
    public let cause: WatchdogSupervisionTransitionCause

    public init(destination: WatchdogSupervisionState, cause: WatchdogSupervisionTransitionCause) {
        self.destination = destination
        self.cause = cause
    }
}

public enum WatchdogSupervisionPolicy {
    public static let firstBackoff: Duration = .seconds(2)
    public static let backoffMultiplier = 3
    public static let backoffCeiling: Duration = .seconds(120)
    public static let stabilityWindow: Duration = .seconds(120)
    public static let selfRelaunchBound: Duration = .seconds(120)
    public static let updaterOrUnrecognizedBound: Duration = .seconds(300)
    public static let inFlightTimeout: Duration = .seconds(60)
    public static let confirmingReads = 2
}
