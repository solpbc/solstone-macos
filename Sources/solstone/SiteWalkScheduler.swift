// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

public enum ScheduledWalk: Equatable, Sendable {
    case pending(SiteDecisionKey)
    case sweep(CGWindowID)
}

public struct SiteWalkScheduler: Sendable {
    public static let budget = 4

    /// Schedules up to 4 walks for a 1-second tick.
    /// - Parameters:
    ///   - pending: Pending pairs newest first.
    ///   - decided: Windows currently having a fresh decision, sorted by window ID.
    ///   - cursor: Persistent round-robin index into `decided`.
    public static func schedule(
        pending: [SiteDecisionKey],
        decided: [CGWindowID],
        cursor: inout Int
    ) -> [ScheduledWalk] {
        var scheduled: [ScheduledWalk] = []
        var scheduledPending = Set<SiteDecisionKey>()
        var scheduledSweeps = Set<CGWindowID>()
        var pendingIndex = 0

        func nextPending() -> SiteDecisionKey? {
            while pendingIndex < pending.count {
                let candidate = pending[pendingIndex]
                pendingIndex += 1
                if !scheduledPending.contains(candidate) {
                    scheduledPending.insert(candidate)
                    return candidate
                }
            }
            return nil
        }

        func nextSweep() -> CGWindowID? {
            guard !decided.isEmpty else { return nil }
            let count = decided.count
            let allowRepeat = count < Self.budget
            for _ in 0..<count {
                let wid = decided[cursor % count]
                cursor = (cursor + 1) % count
                if allowRepeat || !scheduledSweeps.contains(wid) {
                    scheduledSweeps.insert(wid)
                    return wid
                }
            }
            return nil
        }

        if !pending.isEmpty && !decided.isEmpty {
            for i in 0..<Self.budget {
                if i % 2 == 0 {
                    if let p = nextPending() {
                        scheduled.append(.pending(p))
                    } else if let s = nextSweep() {
                        scheduled.append(.sweep(s))
                    }
                } else {
                    if let s = nextSweep() {
                        scheduled.append(.sweep(s))
                    } else if let p = nextPending() {
                        scheduled.append(.pending(p))
                    }
                }
            }
        } else if !pending.isEmpty {
            while scheduled.count < Self.budget, let p = nextPending() {
                scheduled.append(.pending(p))
            }
        } else if !decided.isEmpty {
            while scheduled.count < Self.budget, let s = nextSweep() {
                scheduled.append(.sweep(s))
            }
        }

        return scheduled
    }
}
