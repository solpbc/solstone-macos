// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// Detects windows belonging to specified applications for exclusion from capture
public final class WindowExclusionDetector: @unchecked Sendable {
    private let targetAppNames: Set<String>  // Lowercase for case-insensitive matching
    private let detectPrivateBrowsing: Bool
    private let titlePatterns: [String]  // Patterns to match in any window title

    /// Track last log time for periodic summaries
    private var lastLogTime: Date = .distantPast
    private let logInterval: TimeInterval = 10.0

    /// Browser names for private browsing detection
    private static let browserNames: Set<String> = ["safari", "google chrome", "firefox"]

    /// Creates a detector for the specified app names
    /// - Parameters:
    ///   - appNames: Application names to match (case-insensitive, exact match)
    ///   - detectPrivateBrowsing: Whether to also detect private/incognito browser windows
    ///   - titlePatterns: Patterns to match in any window title - exclude window if any pattern matches
    public init(appNames: [String], detectPrivateBrowsing: Bool = false, titlePatterns: [String] = []) {
        self.targetAppNames = Set(appNames.map { $0.lowercased() })
        self.detectPrivateBrowsing = detectPrivateBrowsing
        self.titlePatterns = titlePatterns.map { $0.lowercased() }
    }

    /// Detects windows to exclude and returns their SCWindow objects
    /// - Returns: Array of SCWindow objects that should be excluded from capture
    public func detectExcludedWindows() async -> [SCWindow] {
        // Get window IDs to exclude using CGWindowList (for title inspection)
        let excludedWindowIDs = detectExcludedWindowIDs()
        guard !excludedWindowIDs.isEmpty else { return [] }

        // Get SCWindow objects from ScreenCaptureKit
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // Map window IDs to SCWindow objects
            let scWindowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

            return excludedWindowIDs.compactMap { scWindowsByID[$0] }
        } catch {
            Log.warn("Failed to get SCShareableContent for window exclusion: \(error)")
            return []
        }
    }

    /// Detects window IDs to exclude using CGWindowList
    /// - Returns: Set of window IDs that should be excluded
    private func detectExcludedWindowIDs() -> Set<CGWindowID> {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var excludedIDs = Set<CGWindowID>()
        var excludedDescriptions: [String] = []

        for window in windowList {
            // Only consider normal layer windows (layer 0)
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let ownerNameLower = ownerName.lowercased()
            let windowTitle = window[kCGWindowName as String] as? String ?? ""

            // Check if this is a target window (excluded app)
            var exclusionReason: String? = nil
            if targetAppNames.contains(ownerNameLower) {
                exclusionReason = "excluded app"
            }

            // Check for title pattern matches in any window
            if exclusionReason == nil && !titlePatterns.isEmpty {
                let titleLower = windowTitle.lowercased()
                if let matchedPattern = titlePatterns.first(where: { titleLower.contains($0) }) {
                    exclusionReason = "matched '\(matchedPattern)'"
                }
            }

            // Also check for private browsing windows if enabled
            if exclusionReason == nil && detectPrivateBrowsing {
                if Self.isPrivateBrowserWindow(ownerName: ownerNameLower, windowTitle: windowTitle) {
                    exclusionReason = "private browsing"
                }
            }

            if let reason = exclusionReason {
                if let windowID = window[kCGWindowNumber as String] as? CGWindowID {
                    excludedIDs.insert(windowID)
                    excludedDescriptions.append("\(ownerName): \(reason)")
                }
            }
        }

        // Log periodically if we have exclusions
        if !excludedIDs.isEmpty && Date().timeIntervalSince(lastLogTime) >= logInterval {
            lastLogTime = Date()
            let summary = excludedDescriptions.joined(separator: ", ")
            Log.info("Hiding windows: \(summary)")
        }

        return excludedIDs
    }

    /// Checks if a window is a private/incognito browser window
    /// - Parameters:
    ///   - ownerName: The application name (lowercase)
    ///   - windowTitle: The window title
    /// - Returns: True if this is a private browsing window
    private static func isPrivateBrowserWindow(ownerName: String, windowTitle: String) -> Bool {
        guard browserNames.contains(ownerName) else {
            return false
        }

        let titleLower = windowTitle.lowercased()

        switch ownerName {
        case "safari":
            // Safari private windows have "Private" in the title
            return titleLower.contains("private")

        case "google chrome":
            // Chrome incognito windows have "(Incognito)" in the title
            return titleLower.contains("(incognito)") || titleLower.contains("incognito")

        case "firefox":
            // Firefox private windows have "(Private Browsing)" in the title
            return titleLower.contains("(private browsing)") || titleLower.contains("private browsing")

        default:
            return false
        }
    }
}
