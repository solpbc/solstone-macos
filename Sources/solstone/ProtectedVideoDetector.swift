// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

struct ProtectedVideoMatch: Equatable, Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let service: String
}

enum ProtectedVideoDetector {
    // MARK: - Data Table

    static let builtInApps: [String: String] = [
        "TV": "Apple TV",
        "Prime Video": "Prime Video"
    ]

    static let browserOwnerNames: Set<String> = [
        "Safari",
        "Safari Technology Preview",
        "Google Chrome",
        "Google Chrome Canary",
        "Chromium",
        "Comet",
        "Arc",
        "Dia",
        "Brave Browser",
        "Microsoft Edge",
        "Firefox",
        "Firefox Developer Edition",
        "Vivaldi",
        "Opera",
        "Orion",
        "Zen",
        "ChatGPT Atlas"
    ]

    static let separators: [String] = [
        " | ",
        " - ",
        " \u{2013} ",  // en-dash: " – "
        " \u{2014} ",  // em-dash: " — "
        " \u{00B7} ",  // middle dot: " · "
        ": "
    ]

    static let serviceAliases: [(canonical: String, aliases: [String])] = [
        ("Netflix", ["netflix", "netflix official site"]),
        ("Disney+", ["disney+", "disney plus"]),
        ("Prime Video", ["prime video", "amazon prime video"]),
        ("Max", ["max", "hbo max"]),
        ("Hulu", ["hulu"]),
        ("Apple TV", ["apple tv+", "apple tv"]),
        ("Peacock", ["peacock"]),
        ("Paramount+", ["paramount+", "paramount plus"]),
        ("Crunchyroll", ["crunchyroll"])
    ]

    static let nonServiceParts: Set<String> = [
        "youtube",
        "google search",
        "wikipedia",
        "bing",
        "duckduckgo",
        "reddit"
    ]

    // MARK: - Match Function

    static func match(
        windows: [OnScreenWindowRecord],
        patterns: [String],
        enabled: Bool,
        ownPid: pid_t
    ) -> ProtectedVideoMatch? {
        guard enabled else { return nil }

        for window in windows {
            guard window.pid != ownPid else { continue }

            // 1. Built-in apps
            if let service = builtInApps[window.ownerName] {
                return ProtectedVideoMatch(
                    windowID: window.windowID,
                    pid: window.pid,
                    ownerName: window.ownerName,
                    title: window.title,
                    service: service
                )
            }

            // 2. Built-in service in a browser
            if browserOwnerNames.contains(window.ownerName) {
                var cleanedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                for sep in separators {
                    let suffix = sep + window.ownerName
                    if cleanedTitle.hasSuffix(suffix) {
                        cleanedTitle = String(cleanedTitle.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }

                let parts = splitBySeparators(cleanedTitle)
                let lowerParts = parts.map { $0.lowercased() }

                // Non-service trailer/search check wins over service part
                let hasNonServicePart = lowerParts.contains { nonServiceParts.contains($0) }
                if hasNonServicePart {
                    // Window is clear; does not fall through to owner pattern
                    continue
                }

                if let matchedService = matchService(in: lowerParts) {
                    return ProtectedVideoMatch(
                        windowID: window.windowID,
                        pid: window.pid,
                        ownerName: window.ownerName,
                        title: window.title,
                        service: matchedService
                    )
                }
            }

            // 3. Owner-taught patterns (applies to any app, including Finder and browsers not decided above)
            for pattern in patterns {
                let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if window.title.localizedCaseInsensitiveContains(trimmed) {
                    return ProtectedVideoMatch(
                        windowID: window.windowID,
                        pid: window.pid,
                        ownerName: window.ownerName,
                        title: window.title,
                        service: trimmed
                    )
                }
            }
        }

        return nil
    }

    private static func splitBySeparators(_ text: String) -> [String] {
        var parts = [text]
        for sep in separators {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func matchService(in lowerParts: [String]) -> String? {
        for part in lowerParts {
            for entry in serviceAliases {
                if entry.aliases.contains(part) {
                    return entry.canonical
                }
            }
        }
        return nil
    }
}
