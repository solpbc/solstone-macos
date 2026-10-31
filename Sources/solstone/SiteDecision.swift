// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

public enum SiteVerdict: String, Sendable, Equatable {
    case ordinary
    case covered
    case pending
}

public struct SiteDecisionKey: Hashable, Sendable {
    public let windowID: CGWindowID
    public let title: String

    public init(windowID: CGWindowID, title: String) {
        self.windowID = windowID
        self.title = title
    }
}

public struct SiteDecisionEntry: Sendable, Equatable {
    public let verdict: SiteVerdict // .ordinary or .covered
    public let decisionTime: TimeInterval

    public init(verdict: SiteVerdict, decisionTime: TimeInterval) {
        self.verdict = verdict
        self.decisionTime = decisionTime
    }
}

public struct SiteDecision: Sendable {
    public static let cacheCapacity = 128
    public static let freshnessLimit: TimeInterval = 5.0
    public static let emptyWalkMinGap: TimeInterval = 1.0

    public private(set) var entries: [SiteDecisionKey: SiteDecisionEntry] = [:]
    public private(set) var emptyWalkTimes: [SiteDecisionKey: TimeInterval] = [:]
    public private(set) var consecutiveFailures: Int = 0
    public private(set) var titleMismatchStreaks: [SiteDecisionKey: Int] = [:]

    public init() {}

    public var hasSafariCaution: Bool {
        consecutiveFailures >= 10 || titleMismatchStreaks.values.contains { $0 >= 5 }
    }

    /// Looks up verdict for a (windowID, title) pair at frame host-time `c`.
    /// Fresh when 0 <= c - decisionTime <= 5.
    public func verdict(for key: SiteDecisionKey, at c: TimeInterval) -> SiteVerdict {
        guard let entry = entries[key] else { return .pending }
        let age = c - entry.decisionTime
        if age >= 0 && age <= Self.freshnessLimit {
            return entry.verdict
        }
        return .pending
    }

    /// Checks if an AX title matches a CG window title (either bare or with the Safari private tail).
    public static func titleMatches(axTitle: String?, cgTitle: String) -> Bool {
        guard let axTitle else { return false }
        if axTitle == cgTitle { return true }
        if let tail = PrivateBrowser.safari.privateAccessibilityTail, axTitle == cgTitle + tail {
            return true
        }
        return false
    }

    /// Evaluates a walk result for a window key, updating cache and caution streaks.
    @discardableResult
    public mutating func evaluate(
        key: SiteDecisionKey,
        initialAXTitle: String?,
        finalAXTitle: String?,
        walk: WebAreaWalkResult,
        sites: [String],
        now: TimeInterval,
        isSweep: Bool
    ) -> SiteVerdict {
        // 1. Title mismatch
        let initialMatch = Self.titleMatches(axTitle: initialAXTitle, cgTitle: key.title)
        let finalMatch = Self.titleMatches(axTitle: finalAXTitle, cgTitle: key.title)
        if !initialMatch || !finalMatch {
            recordTitleMismatch(for: key)
            return .pending
        }
        // Matching title resets mismatch streak for this pair
        titleMismatchStreaks[key] = 0

        // 2. Any covered host (even on an incomplete walk) -> covered
        for urlStr in walk.urls.compactMap({ $0 }) {
            if let host = SiteRule.normalizeReadHost(urlStr) {
                if sites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
                    recordSuccess(for: key, verdict: .covered, now: now)
                    return .covered
                }
            }
        }

        // 3. Missing URL -> pending
        if walk.urls.contains(where: { $0 == nil }) {
            recordFailure()
            return .pending
        }

        // 4. Incomplete -> pending
        if walk.completeness != .complete {
            recordFailure()
            return .pending
        }

        // 5. Zero web areas -> ordinary only after two complete empty walks at least 1 s apart
        if walk.urls.isEmpty {
            if let firstTime = emptyWalkTimes[key] {
                if now - firstTime >= Self.emptyWalkMinGap {
                    // Second complete empty walk >= 1s later
                    emptyWalkTimes.removeValue(forKey: key)
                    recordSuccess(for: key, verdict: .ordinary, now: now)
                    return .ordinary
                } else {
                    // Closer than 1 s: keep earlier timestamp, return pending
                    return .pending
                }
            } else {
                // First empty walk
                emptyWalkTimes[key] = now
                return .pending
            }
        }

        // 6. Otherwise ordinary
        emptyWalkTimes.removeValue(forKey: key)
        recordSuccess(for: key, verdict: .ordinary, now: now)
        return .ordinary
    }

    private mutating func recordSuccess(for key: SiteDecisionKey, verdict: SiteVerdict, now: TimeInterval) {
        consecutiveFailures = 0
        insertEntry(key: key, entry: SiteDecisionEntry(verdict: verdict, decisionTime: now))
    }

    private mutating func recordFailure() {
        consecutiveFailures += 1
    }

    private mutating func recordTitleMismatch(for key: SiteDecisionKey) {
        titleMismatchStreaks[key, default: 0] += 1
    }

    private mutating func insertEntry(key: SiteDecisionKey, entry: SiteDecisionEntry) {
        if entries[key] == nil && entries.count >= Self.cacheCapacity {
            // Evict oldest decision time
            if let oldest = entries.min(by: { $0.value.decisionTime < $1.value.decisionTime }) {
                entries.removeValue(forKey: oldest.key)
                emptyWalkTimes.removeValue(forKey: oldest.key)
                titleMismatchStreaks.removeValue(forKey: oldest.key)
            }
        }
        entries[key] = entry
    }
}
