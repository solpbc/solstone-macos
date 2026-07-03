// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@preconcurrency import ScreenCaptureKit

protocol DisplayIDProvider {
    var displayID: CGDirectDisplayID { get }
}

extension SCDisplay: DisplayIDProvider {}

@MainActor
final class WindowExclusionManager {
    private var windowExclusionDetector: WindowExclusionDetector?
    private var windowExclusionTimer: Timer?
    var currentExcludedWindowIDs: Set<CGWindowID> = []
    private var isStreamReady: Bool = false
    nonisolated(unsafe) private var activateObserver: NSObjectProtocol?
    nonisolated(unsafe) private var deactivateObserver: NSObjectProtocol?
    private var onFiltersChanged: (@MainActor ([CGDirectDisplayID: SCContentFilter]) async throws -> Void)?
    private var allDisplays: (@MainActor () -> [SCDisplay]?)?
    private var isRecording: (@MainActor () -> Bool)?
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
        onFiltersChanged: @MainActor @escaping ([CGDirectDisplayID: SCContentFilter]) async throws -> Void,
        allDisplays: @MainActor @escaping () -> [SCDisplay]?,
        isRecording: @MainActor @escaping () -> Bool
    ) {
        self.onFiltersChanged = onFiltersChanged
        self.allDisplays = allDisplays
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

    nonisolated static func filterMapKeys<D: DisplayIDProvider>(from displays: [D]) -> Set<CGDirectDisplayID> {
        Set(displays.map(\.displayID))
    }

    /// Commits `newIDs` as the excluded set only if the filter update succeeds.
    /// A failed `apply` leaves `currentExcludedWindowIDs` unchanged so the next
    /// timer tick re-attempts — the manager never reports windows hidden that the
    /// stream is still capturing. The no-change guard lives here so a non-committed
    /// set correctly re-runs `apply` on the following tick.
    func reconcile(newIDs: Set<CGWindowID>, apply: () async throws -> Void) async {
        guard newIDs != currentExcludedWindowIDs else { return }
        do {
            try await apply()
            currentExcludedWindowIDs = newIDs
        } catch {
            Logger.capture.warning("Failed to update content filter: \(error, privacy: .public)")
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
              let displays = allDisplays?(),
              !displays.isEmpty else { return }

        // Detect windows to exclude
        let excludedWindows = await detector.detectExcludedWindows()
        let newExcludedIDs = Set(excludedWindows.map { $0.windowID })

        await reconcile(newIDs: newExcludedIDs) { [self] in
            let filters = Dictionary(
                uniqueKeysWithValues: displays.map { display in
                    (display.displayID, SCContentFilter(display: display, excludingWindows: excludedWindows))
                }
            )
            try await onFiltersChanged?(filters)
            if !excludedWindows.isEmpty, verbose {
                Logger.capture.debug("Updated filter to exclude \(excludedWindows.count, privacy: .public) window(s)")
            }
        }
    }
}
