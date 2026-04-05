// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@preconcurrency import ScreenCaptureKit

@MainActor
final class WindowExclusionManager {
    private var windowExclusionDetector: WindowExclusionDetector?
    private var windowExclusionTimer: Timer?
    private var currentExcludedWindowIDs: Set<CGWindowID> = []
    private var isStreamReady: Bool = false
    nonisolated(unsafe) private var activateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var deactivateObserver: NSObjectProtocol?
    private var onFilterChanged: ((SCContentFilter) async throws -> Void)?
    private var primaryDisplay: (() -> SCDisplay?)?
    private var isRecording: (() -> Bool)?
    private let verbose: Bool

    init(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String],
        verbose: Bool = false
    ) {
        self.verbose = verbose

        if !excludedAppNames.isEmpty || !excludedTitlePatterns.isEmpty || excludePrivateBrowsing {
            self.windowExclusionDetector = WindowExclusionDetector(
                appNames: excludedAppNames,
                detectPrivateBrowsing: excludePrivateBrowsing,
                titlePatterns: excludedTitlePatterns
            )
        } else {
            self.windowExclusionDetector = nil
        }
    }

    func configure(
        onFilterChanged: @escaping (SCContentFilter) async throws -> Void,
        primaryDisplay: @escaping () -> SCDisplay?,
        isRecording: @escaping () -> Bool
    ) {
        self.onFilterChanged = onFilterChanged
        self.primaryDisplay = primaryDisplay
        self.isRecording = isRecording

        guard activateObserver == nil else { return }

        activateObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }

        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }
    }

    deinit {
        if let observer = activateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = deactivateObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        MainActor.assumeIsolated {
            windowExclusionTimer?.invalidate()
        }
    }

    func streamBecameReady() async {
        isStreamReady = true
        await updateWindowExclusions()
        startWindowExclusionTimer()
    }

    func resetForNewSegment() {
        isStreamReady = false
        currentExcludedWindowIDs = []
    }

    func stop() {
        isStreamReady = false
        windowExclusionTimer?.invalidate()
        windowExclusionTimer = nil
    }

    func updateExclusions(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String]
    ) {
        if !excludedAppNames.isEmpty || !excludedTitlePatterns.isEmpty || excludePrivateBrowsing {
            windowExclusionDetector = WindowExclusionDetector(
                appNames: excludedAppNames,
                detectPrivateBrowsing: excludePrivateBrowsing,
                titlePatterns: excludedTitlePatterns
            )
            Logger.capture.info("Updated window exclusions: \(excludedAppNames.count, privacy: .public) apps, \(excludedTitlePatterns.count, privacy: .public) title patterns, privateBrowsing=\(excludePrivateBrowsing, privacy: .public)")
        } else {
            windowExclusionDetector = nil
            Logger.capture.info("Cleared window exclusions")
        }
    }

    /// Starts a timer to periodically check for window exclusions
    private func startWindowExclusionTimer() {
        windowExclusionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }
        timer.tolerance = 2.0  // Allow coalescing to reduce energy impact
        windowExclusionTimer = timer
    }

    /// Updates the content filter to exclude detected windows
    private func updateWindowExclusions() async {
        guard isRecording?() == true,
              isStreamReady,
              let detector = windowExclusionDetector,
              let display = primaryDisplay?() else { return }

        // Detect windows to exclude
        let excludedWindows = await detector.detectExcludedWindows()
        let newExcludedIDs = Set(excludedWindows.map { $0.windowID })

        // Only update if exclusions changed
        guard newExcludedIDs != currentExcludedWindowIDs else { return }

        currentExcludedWindowIDs = newExcludedIDs

        // Create new filter with excluded windows
        let newFilter = SCContentFilter(
            display: display,
            excludingWindows: excludedWindows
        )

        do {
            try await onFilterChanged?(newFilter)
            if !excludedWindows.isEmpty {
                if verbose { Logger.capture.debug("Updated filter to exclude \(excludedWindows.count, privacy: .public) window(s)") }
            }
        } catch {
            Logger.capture.warning("Failed to update content filter: \(error, privacy: .public)")
        }
    }
}
