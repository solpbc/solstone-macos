// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public enum RelaunchDecision: Equatable, Sendable {
    case relaunch
    case suppress
    case throttleStop
}

public func relaunchDecision(
    marker: ExpectedExitMarker?,
    terminatedPID: Int32,
    now: Date,
    freshnessWindow: TimeInterval = ExpectedExitMarker.defaultFreshnessWindow,
    recentRelaunches: [Date],
    throttleLimit: Int = ExpectedExitMarker.defaultThrottleLimit,
    throttleWindow: TimeInterval = ExpectedExitMarker.defaultThrottleWindow
) -> RelaunchDecision {
    if ExpectedExitMarker.isExpectedExit(
        marker: marker,
        terminatedPID: terminatedPID,
        now: now,
        freshnessWindow: freshnessWindow
    ) {
        return .suppress
    }

    let recentCount = recentRelaunches.count { relaunchDate in
        let age = now.timeIntervalSince(relaunchDate)
        return age >= 0 && age <= throttleWindow
    }

    if recentCount >= throttleLimit {
        return .throttleStop
    }

    return .relaunch
}

public func shouldAdopt(runningBundleIDs: Set<String>, target: String) -> Bool {
    runningBundleIDs.contains(target)
}
