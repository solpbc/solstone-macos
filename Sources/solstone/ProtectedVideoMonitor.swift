// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum ProtectedVideoMonitorAction: Equatable {
    case none
    case pause
    case resume
}

enum ProtectedVideoMonitorDecision {
    static let backoffDelays: [TimeInterval] = [10, 30, 60, 300]

    static func backoffDelay(forStep step: Int) -> TimeInterval {
        guard step >= 0 else { return backoffDelays[0] }
        return step < backoffDelays.count ? backoffDelays[step] : backoffDelays.last!
    }

    static func decide(
        isRecording: Bool,
        isPaused: Bool,
        hasProtectedVideoPauseReason: Bool,
        sessionIncludesScreen: Bool,
        predicate: Bool,
        toggleEnabled: Bool,
        now: Date,
        clearSince: Date?,
        resumeNotBefore: Date?,
        backoffStep: Int
    ) -> (action: ProtectedVideoMonitorAction, nextClearSince: Date?, nextResumeNotBefore: Date?, nextBackoffStep: Int) {
        guard isRecording || isPaused else {
            return (.none, nil, resumeNotBefore, backoffStep)
        }

        if isRecording {
            if sessionIncludesScreen && predicate && toggleEnabled {
                return (.pause, nil, resumeNotBefore, backoffStep)
            }
            return (.none, nil, resumeNotBefore, backoffStep)
        }

        if isPaused {
            guard hasProtectedVideoPauseReason else {
                return (.none, nil, resumeNotBefore, backoffStep)
            }

            if !toggleEnabled {
                return (.resume, nil, nil, 0)
            }

            if !predicate {
                let firstClear = clearSince ?? now
                if let resumeNotBefore, now < resumeNotBefore {
                    return (.none, firstClear, resumeNotBefore, backoffStep)
                }
                if now.timeIntervalSince(firstClear) >= 3.0 {
                    return (.resume, firstClear, resumeNotBefore, backoffStep)
                }
                return (.none, firstClear, resumeNotBefore, backoffStep)
            } else {
                // Predicate is true, window still present
                return (.none, nil, resumeNotBefore, backoffStep)
            }
        }

        return (.none, nil, resumeNotBefore, backoffStep)
    }
}
