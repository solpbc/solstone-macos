// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import os

struct ProtectedVideoInterval: Equatable, Sendable {
    var ts: Int64
    var end_ts: Int64
    var app: String
    var service: String
    var titles: [String]
}

struct ProtectedVideoCacheKey: Hashable {
    let windowID: CGWindowID
    let title: String
}

func protectedVideoObservationIncluded(
    match: ProtectedVideoMatch,
    excludedAppNames: Set<String>,
    excludedTitlePatterns: [String],
    excludePrivateBrowsing: Bool,
    excludePrivateBrowsingAccessibility: Bool,
    accessibilityReader: any AccessibilityTitleReading,
    verdictCache: inout [ProtectedVideoCacheKey: TitleVerdict]
) -> Bool {
    // 1. Excluded app: lowercased owner name is in the excluded set
    if excludedAppNames.contains(match.ownerName.lowercased()) {
        return false
    }

    // 2. Excluded title: title contains an excluded pattern
    let lowerTitle = match.title.lowercased()
    for pattern in excludedTitlePatterns {
        let lowerPattern = pattern.lowercased()
        if !lowerPattern.isEmpty && lowerTitle.contains(lowerPattern) {
            return false
        }
    }

    // 3. Private browsing check
    guard excludePrivateBrowsing else { return true }

    // Firefox
    if match.ownerName == "Firefox" || match.ownerName == "Firefox Developer Edition" {
        let verdict = PrivateBrowser.firefoxVerdict(windowTitle: match.title)
        return verdict != .privateWindow
    }

    // Accessibility-supported browsers
    let browser: PrivateBrowser?
    switch match.ownerName {
    case "Safari", "Safari Technology Preview":
        browser = .safari
    case "Google Chrome", "Google Chrome Canary":
        browser = .chrome
    case "Microsoft Edge":
        browser = .edge
    case "Brave Browser":
        browser = .brave
    default:
        browser = nil
    }

    if let browser {
        guard excludePrivateBrowsingAccessibility else {
            return true
        }

        let cacheKey = ProtectedVideoCacheKey(windowID: match.windowID, title: match.title)
        let verdict: TitleVerdict
        if let cached = verdictCache[cacheKey] {
            verdict = cached
        } else {
            let titles = accessibilityReader.titles(pid: match.pid)
            if let aTitle = titles[match.windowID], !aTitle.isEmpty {
                verdict = browser.accessibilityVerdict(windowTitle: match.title, accessibilityTitle: aTitle)
            } else {
                verdict = .undecided
            }
            verdictCache[cacheKey] = verdict
        }

        return verdict != .privateWindow
    }

    // Comet, Arc, Dia, Chromium, and other browsers have no private rule
    return true
}

final class ProtectedVideoNoteStore {
    private(set) var openInterval: ProtectedVideoInterval?
    private(set) var closedIntervals: [ProtectedVideoInterval] = []
    private var verdictCache: [ProtectedVideoCacheKey: TitleVerdict] = [:]

    var closedCountForTesting: Int {
        closedIntervals.count
    }

    var openIntervalForTesting: ProtectedVideoInterval? {
        openInterval
    }

    func recordMatch(
        _ match: ProtectedVideoMatch,
        excludedAppNames: Set<String>,
        excludedTitlePatterns: [String],
        excludePrivateBrowsing: Bool,
        excludePrivateBrowsingAccessibility: Bool,
        accessibilityReader: any AccessibilityTitleReading,
        isScreenLocked: Bool,
        isMachineAwake: Bool,
        at date: Date
    ) {
        let isIncluded = protectedVideoObservationIncluded(
            match: match,
            excludedAppNames: excludedAppNames,
            excludedTitlePatterns: excludedTitlePatterns,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludePrivateBrowsingAccessibility: excludePrivateBrowsingAccessibility,
            accessibilityReader: accessibilityReader,
            verdictCache: &verdictCache
        )
        recordObservation(
            match: match,
            isIncluded: isIncluded,
            isScreenLocked: isScreenLocked,
            isMachineAwake: isMachineAwake,
            at: date
        )
    }

    func recordObservation(
        match: ProtectedVideoMatch,
        isIncluded: Bool,
        isScreenLocked: Bool,
        isMachineAwake: Bool,
        at date: Date
    ) {
        guard isIncluded else { return }

        let nowMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let canAdvanceEnd = !isScreenLocked && isMachineAwake

        if var interval = openInterval {
            if canAdvanceEnd {
                interval.end_ts = max(interval.end_ts, nowMs)
            }
            if match.service == interval.service, !match.title.isEmpty, interval.titles.count < 3 {
                let truncated = String(match.title.prefix(200))
                if !interval.titles.contains(truncated) {
                    interval.titles.append(truncated)
                }
            }
            openInterval = interval
        } else {
            let initialTitles = match.title.isEmpty ? [] : [String(match.title.prefix(200))]
            openInterval = ProtectedVideoInterval(
                ts: nowMs,
                end_ts: canAdvanceEnd ? nowMs : nowMs,
                app: match.ownerName,
                service: match.service,
                titles: initialTitles
            )
        }
    }

    func close() {
        guard var interval = openInterval else { return }
        interval.end_ts = max(interval.ts, interval.end_ts)
        closedIntervals.append(interval)
        openInterval = nil
        verdictCache.removeAll()
    }

    func takeForWrite(segmentStart: Date) -> Data? {
        let cutoffMs = Int64((segmentStart.timeIntervalSince1970 * 1000).rounded()) - (30 * 60 * 1000)
        closedIntervals.removeAll { $0.end_ts < cutoffMs }

        guard !closedIntervals.isEmpty else {
            closedIntervals.removeAll()
            return nil
        }

        var rowsData = Data()
        do {
            for interval in closedIntervals {
                var dict: [String: Any] = [
                    "t": "protected_video",
                    "ts": interval.ts,
                    "end_ts": max(interval.ts, interval.end_ts),
                    "service": interval.service
                ]
                if !interval.app.isEmpty {
                    dict["app"] = interval.app
                }
                let titleJoined = interval.titles.joined(separator: " / ")
                if !titleJoined.isEmpty {
                    dict["title"] = titleJoined
                }

                let lineData = try JSONSerialization.data(
                    withJSONObject: dict,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
                rowsData.append(lineData)
                rowsData.append(0x0A) // newline
            }
        } catch {
            Logger.capture.debug("[ProtectedVideo] note serialization failed")
            closedIntervals.removeAll()
            return nil
        }

        closedIntervals.removeAll()
        return rowsData.isEmpty ? nil : rowsData
    }

    @discardableResult
    func dropAll() -> Bool {
        let hadItems = openInterval != nil || !closedIntervals.isEmpty
        openInterval = nil
        closedIntervals.removeAll()
        verdictCache.removeAll()
        return hadItems
    }

    func checkInclusion(
        match: ProtectedVideoMatch,
        excludedAppNames: Set<String>,
        excludedTitlePatterns: [String],
        excludePrivateBrowsing: Bool,
        excludePrivateBrowsingAccessibility: Bool,
        accessibilityReader: any AccessibilityTitleReading
    ) -> Bool {
        protectedVideoObservationIncluded(
            match: match,
            excludedAppNames: excludedAppNames,
            excludedTitlePatterns: excludedTitlePatterns,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludePrivateBrowsingAccessibility: excludePrivateBrowsingAccessibility,
            accessibilityReader: accessibilityReader,
            verdictCache: &verdictCache
        )
    }
}
