// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os
@preconcurrency import ScreenCaptureKit

protocol DisplayIDProvider {
    var displayID: CGDirectDisplayID { get }
}

extension SCDisplay: DisplayIDProvider {}

/// Keeps excluded apps, private browser windows and title-pattern windows out of screen capture.
///
/// The capture filter keeps whole applications out and lets chosen windows of theirs back in
/// (`SCContentFilter(display:excludingApplications:exceptingWindows:)`). A window of a kept-out
/// application that has not been let back in is never captured, including one opened after the
/// filter was made. So a new private window, or a new window of an excluded app, cannot reach a
/// frame before it is checked, and every segment's stream starts with the current filter.
@MainActor
final class WindowExclusionManager {
    private var settings: ExclusionSettings
    private var readsAccessibilityTitles: Bool
    private var planner = ExclusionPlanner()
    private(set) var currentPlan: ExclusionPlan = .empty
    /// The filters last applied, reused if content cannot be listed when a segment starts.
    private var lastFilters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var tickTimer: Timer?
    private var isStreamReady = false
    private var isTicking = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var onFiltersChanged: (@MainActor ([CGDirectDisplayID: SCContentFilter]) async throws -> Void)?
    private var allDisplays: (@MainActor () -> [SCDisplay]?)?
    private var isRecording: (@MainActor () -> Bool)?
    private let reader = AccessibilityTitleReader()
    private let verbose: Bool
    private var lastLogTime: Date = .distantPast

    /// How often windows are re-checked. Capture runs at 1 frame per second, so a new ordinary
    /// window of a held browser is let back in by the next frame or the one after.
    static let tickInterval: TimeInterval = 1.0

    init(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String],
        readsAccessibilityTitles: Bool = false,
        verbose: Bool = false
    ) {
        self.verbose = verbose
        self.readsAccessibilityTitles = readsAccessibilityTitles
        self.settings = ExclusionSettings(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            accessibilityTitlesWorking: false,
            titlePatterns: excludedTitlePatterns
        )
    }

    func configure(
        onFiltersChanged: @MainActor @escaping ([CGDirectDisplayID: SCContentFilter]) async throws -> Void,
        allDisplays: @MainActor @escaping () -> [SCDisplay]?,
        isRecording: @MainActor @escaping () -> Bool
    ) {
        self.onFiltersChanged = onFiltersChanged
        self.allDisplays = allDisplays
        self.isRecording = isRecording

        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.tick() }
            })
        }
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        MainActor.assumeIsolated {
            tickTimer?.invalidate()
        }
    }

    var hasExclusions: Bool {
        !settings.excludedAppNames.isEmpty || settings.excludePrivateBrowsing || !settings.titlePatterns.isEmpty
    }

    func updateExclusions(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String],
        readsAccessibilityTitles: Bool
    ) {
        self.readsAccessibilityTitles = readsAccessibilityTitles
        settings = ExclusionSettings(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            accessibilityTitlesWorking: settings.accessibilityTitlesWorking && readsAccessibilityTitles,
            titlePatterns: excludedTitlePatterns
        )
        Logger.capture.info("Updated window exclusions: \(excludedAppNames.count, privacy: .public) apps, \(excludedTitlePatterns.count, privacy: .public) title patterns, privateBrowsing=\(excludePrivateBrowsing, privacy: .public), accessibilityTitles=\(readsAccessibilityTitles, privacy: .public)")
        Task { await tick() }
    }

    /// The filters a new segment's streams start with: the current plan, freshly computed. If
    /// ScreenCaptureKit cannot list content, the last applied filters are reused, and `base` only
    /// when there are none for these displays.
    func filtersForNewSegment(
        displays: [SCDisplay],
        base: [CGDirectDisplayID: SCContentFilter]
    ) async -> [CGDirectDisplayID: SCContentFilter] {
        isStreamReady = false
        let plan = await computePlan()
        guard plan.hiddenPIDs.isEmpty == false else {
            currentPlan = plan
            lastFilters = base
            return base
        }
        do {
            let (filters, complete) = try await Self.filters(for: plan, displays: displays)
            // An app or window ScreenCaptureKit did not list yet is retried on the first tick.
            currentPlan = complete ? plan : .empty
            lastFilters = filters
            return filters
        } catch {
            let keys = Self.filterMapKeys(from: displays)
            let reuse = keys.isSubset(of: Set(lastFilters.keys))
            Logger.capture.error("Window exclusion: could not list shareable content for a new segment, reusing last filters=\(reuse, privacy: .public): \(error, privacy: .public)")
            currentPlan = .empty  // re-applied on the first tick
            return reuse ? lastFilters : base
        }
    }

    func streamBecameReady() async {
        isStreamReady = true
        await tick()
        startTimer()
    }

    func resetForNewSegment() {
        isStreamReady = false
    }

    func stop() {
        isStreamReady = false
        tickTimer?.invalidate()
        tickTimer = nil
    }

    nonisolated static func filterMapKeys<D: DisplayIDProvider>(from displays: [D]) -> Set<CGDirectDisplayID> {
        Set(displays.map(\.displayID))
    }

    /// Commits `plan` only if applying it succeeds and the filter could say all of it, so a failed
    /// or partial update is retried on the next tick and the manager never reports windows kept out
    /// that the stream is still capturing. (A just-launched app can be missing from shareable content
    /// for a moment; committing that plan would leave the app captured until the plan next changed.)
    func reconcile(plan: ExclusionPlan, apply: () async throws -> Bool) async {
        guard plan != currentPlan else { return }
        do {
            if try await apply() {
                currentPlan = plan
            }
        } catch {
            Logger.capture.warning("Failed to update content filter: \(error, privacy: .public)")
        }
    }

    private func startTimer() {
        tickTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = 0.25
        tickTimer = timer
    }

    private func tick() async {
        guard !isTicking,
              isRecording?() == true,
              isStreamReady,
              let displays = allDisplays?(),
              !displays.isEmpty else { return }
        isTicking = true
        defer { isTicking = false }

        let plan = await computePlan()
        await reconcile(plan: plan) { [self] in
            let (filters, complete) = try await Self.filters(for: plan, displays: displays)
            try await onFiltersChanged?(filters)
            lastFilters = filters
            return complete
        }
        logPlan(plan)
    }

    private func computePlan() async -> ExclusionPlan {
        guard hasExclusions else { return .empty }
        let reader = self.reader
        if readsAccessibilityTitles && settings.excludePrivateBrowsing {
            let health = await Task.detached { reader.health() }.value
            settings.accessibilityTitlesWorking = health == .working
        } else {
            settings.accessibilityTitlesWorking = false
        }

        let windows = Self.onScreenWindows()
        let apps = NSWorkspace.shared.runningApplications.map {
            ExclusionApp(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier)
        }
        let pids = planner.windowsNeedingAccessibilityTitles(windows: windows, apps: apps, settings: settings)
        var titles: [CGWindowID: String] = [:]
        if !pids.isEmpty {
            titles = await Task.detached {
                var all: [CGWindowID: String] = [:]
                for pid in pids { all.merge(reader.titles(pid: pid)) { first, _ in first } }
                return all
            }.value
        }
        return planner.plan(windows: windows, apps: apps, settings: settings, accessibilityTitles: titles, now: Date())
    }

    private static func onScreenWindows() -> [ExclusionWindow] {
        OnScreenWindowList.copyOnScreenInfo().compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int else { return nil }
            return ExclusionWindow(
                id: id,
                pid: pid_t(pid),
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                title: window[kCGWindowName as String] as? String ?? "",
                layer: layer
            )
        }
    }

    /// The filters for `plan`, and whether they say all of it.
    private static func filters(for plan: ExclusionPlan, displays: [SCDisplay]) async throws -> ([CGDirectDisplayID: SCContentFilter], Bool) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.filter { plan.hiddenPIDs.contains($0.processID) }
        let excepted = content.windows.filter { plan.exceptedWindowIDs.contains($0.windowID) }
        let complete = plan.isFullyResolved(
            listedPIDs: Set(apps.map(\.processID)),
            listedWindowIDs: Set(excepted.map(\.windowID))
        )
        let filters = Dictionary(uniqueKeysWithValues: displays.map { display in
            (display.displayID, SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: excepted))
        })
        return (filters, complete)
    }

    private func logPlan(_ plan: ExclusionPlan) {
        guard plan != .empty, Date().timeIntervalSince(lastLogTime) >= 10 else { return }
        lastLogTime = Date()
        Logger.capture.info("Window exclusion: apps-kept-out=\(plan.hiddenPIDs.count, privacy: .public) excluded-app=\(plan.excludedAppCount, privacy: .public) private=\(plan.privateWindowCount, privacy: .public) held=\(plan.heldWindowCount, privacy: .public) title-pattern=\(plan.titlePatternCount, privacy: .public) accessibility=\(self.settings.accessibilityTitlesWorking, privacy: .public)")
    }
}
