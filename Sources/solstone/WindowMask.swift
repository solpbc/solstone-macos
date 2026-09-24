// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreGraphics
import os
@preconcurrency import ScreenCaptureKit

/// Detects windows belonging to specified applications for exclusion from capture
public final class WindowExclusionDetector: @unchecked Sendable {
    private let targetAppNames: Set<String>  // Lowercase for case-insensitive matching
    private let detectPrivateBrowsing: Bool
    private let titlePatterns: [String]  // Patterns to match in any window title
    private let windowRecordProvider: @Sendable () -> [OnScreenWindowRecord]

    /// Track last log time for periodic summaries
    private var lastLogTime: Date = .distantPast
    private let logInterval: TimeInterval = 10.0

    /// The one private-window form measured on a Mac: Firefox 156 (English) ends a private
    /// window's title with this, after the page title. Safari 27, Chrome 154, Edge 153 and
    /// Brave 1.95 were measured too and put no private marker in the title, so they have no row.
    /// An ordinary Firefox window shows the bare page title, so a page whose own title ends with
    /// this exact text is also matched; nothing in the title can tell the two apart.
    static let firefoxPrivateTitleSuffix = " \u{2014} Private Browsing"

    /// Creates a detector for the specified app names
    /// - Parameters:
    ///   - appNames: Application names to match (case-insensitive, exact match)
    ///   - detectPrivateBrowsing: Whether to also detect private browser windows by title (Firefox only, see `firefoxPrivateTitleSuffix`)
    ///   - titlePatterns: Patterns to match in any window title - exclude window if any pattern matches
    ///   - windowRecordProvider: Provider of on-screen layer-0 window records
    public init(
        appNames: [String],
        detectPrivateBrowsing: Bool = false,
        titlePatterns: [String] = [],
        windowRecordProvider: @escaping @Sendable () -> [OnScreenWindowRecord] = OnScreenWindowList.onScreenLayer0Windows
    ) {
        self.targetAppNames = Set(appNames.map { $0.lowercased() })
        self.detectPrivateBrowsing = detectPrivateBrowsing
        self.titlePatterns = titlePatterns.map { $0.lowercased() }
        self.windowRecordProvider = windowRecordProvider
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
            Logger.capture.warning("Failed to get SCShareableContent for window exclusion: \(error, privacy: .public)")
            return []
        }
    }

    /// Detects window IDs to exclude using OnScreenWindowList records
    /// - Returns: Set of window IDs that should be excluded
    func detectExcludedWindowIDs() -> Set<CGWindowID> {
        let records = windowRecordProvider()
        guard !records.isEmpty else {
            return []
        }

        var excludedIDs = Set<CGWindowID>()
        var excludedAppCount = 0
        var titlePatternCount = 0
        var privateBrowsingCount = 0

        for record in records {
            let ownerName = record.ownerName
            let ownerNameLower = ownerName.lowercased()
            let windowTitle = record.title

            var reasonToken: String? = nil
            if targetAppNames.contains(ownerNameLower) {
                reasonToken = "excluded-app"
            }

            if reasonToken == nil && !titlePatterns.isEmpty {
                let titleLower = windowTitle.lowercased()
                if titlePatterns.contains(where: { titleLower.contains($0) }) {
                    reasonToken = "title-pattern"
                }
            }

            if reasonToken == nil && detectPrivateBrowsing {
                if Self.isPrivateBrowserWindow(ownerName: ownerNameLower, windowTitle: windowTitle) {
                    reasonToken = "private-browsing"
                }
            }

            if let reasonToken {
                excludedIDs.insert(record.windowID)
                switch reasonToken {
                case "excluded-app": excludedAppCount += 1
                case "title-pattern": titlePatternCount += 1
                case "private-browsing": privateBrowsingCount += 1
                default: break
                }
            }
        }

        if !excludedIDs.isEmpty && Date().timeIntervalSince(lastLogTime) >= logInterval {
            lastLogTime = Date()
            Logger.capture.info("Hiding windows count=\(excludedIDs.count, privacy: .public) excluded-app=\(excludedAppCount, privacy: .public) title-pattern=\(titlePatternCount, privacy: .public) private-browsing=\(privateBrowsingCount, privacy: .public)")
        }

        return excludedIDs
    }

    /// Checks if a window is a private browser window by its title
    /// - Parameters:
    ///   - ownerName: The application name (lowercase)
    ///   - windowTitle: The window title
    /// - Returns: True if this is a private browsing window
    static func isPrivateBrowserWindow(ownerName: String, windowTitle: String) -> Bool {
        ownerName == "firefox" && windowTitle.hasSuffix(firefoxPrivateTitleSuffix)
    }
}
