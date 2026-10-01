// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

/// The planner decides which applications the capture filter keeps out and which of their windows
/// it lets back in. A window of a kept-out app that is not let back in is never captured, so these
/// tests pin what an owner sees: excluded apps never appear, a private window never appears, and an
/// ordinary browser window appears once it reads ordinary.
@Suite("ExclusionPlanner")
struct ExclusionPlannerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private let firefox = ExclusionApp(pid: 100, name: "Firefox", bundleIdentifier: "org.mozilla.firefox")
    private let chrome = ExclusionApp(pid: 200, name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
    private let safari = ExclusionApp(pid: 300, name: "Safari", bundleIdentifier: "com.apple.Safari")
    private let vault = ExclusionApp(pid: 400, name: "1Password", bundleIdentifier: "com.1password.1password")
    private let terminal = ExclusionApp(pid: 500, name: "Terminal", bundleIdentifier: "com.apple.Terminal")

    private func window(_ id: CGWindowID, _ app: ExclusionApp, _ title: String, layer: Int = 0) -> ExclusionWindow {
        ExclusionWindow(id: id, pid: app.pid, ownerName: app.name, title: title, layer: layer)
    }

    private func settings(
        apps: [String] = [],
        privateBrowsing: Bool = true,
        accessibility: Bool = false,
        patterns: [String] = []
    ) -> ExclusionSettings {
        ExclusionSettings(excludedAppNames: apps, excludePrivateBrowsing: privateBrowsing, accessibilityTitlesWorking: accessibility, titlePatterns: patterns)
    }

    // MARK: - Excluded apps

    @Test func excludedAppIsKeptOutWithNoWindowLetBackIn() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(
            windows: [window(1, vault, "Vault"), window(2, vault, "", layer: 3)],
            apps: [vault],
            settings: settings(apps: ["1password"], privateBrowsing: false),
            accessibilityTitles: [:],
            now: t0
        )
        #expect(plan.hiddenPIDs == [vault.pid])
        #expect(plan.exceptedWindowIDs.isEmpty)
    }

    @Test func excludedAppIsKeptOutBeforeItHasAWindow() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(windows: [], apps: [vault], settings: settings(apps: ["1Password"], privateBrowsing: false), accessibilityTitles: [:], now: t0)
        #expect(plan.hiddenPIDs == [vault.pid])
    }

    @Test func nothingIsKeptOutWithoutExclusions() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(
            windows: [window(1, firefox, "Example Domain \u{2014} Private Browsing")],
            apps: [firefox],
            settings: settings(privateBrowsing: false),
            accessibilityTitles: [:],
            now: t0
        )
        #expect(plan == .empty)
    }

    // MARK: - Firefox (level 1)

    @Test func firefoxPrivateWindowStaysOutAndOrdinaryWindowIsLetIn() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(
            windows: [
                window(1, firefox, "Example Domain \u{2014} Private Browsing"),
                window(2, firefox, "Example Domain"),
                window(3, firefox, "", layer: 101),  // a menu
            ],
            apps: [firefox],
            settings: settings(),
            accessibilityTitles: [:],
            now: t0
        )
        #expect(plan.hiddenPIDs == [firefox.pid])
        #expect(plan.exceptedWindowIDs == [2, 3])
        #expect(plan.privateWindowCount == 1)
    }

    @Test func firefoxWindowWithoutATitleIsHeldThenLetIn() {
        var planner = ExclusionPlanner()
        let windows = [window(1, firefox, "")]
        let first = planner.plan(windows: windows, apps: [firefox], settings: settings(), accessibilityTitles: [:], now: t0)
        #expect(first.exceptedWindowIDs.isEmpty)
        #expect(first.heldWindowCount == 1)

        let later = planner.plan(windows: windows, apps: [firefox], settings: settings(), accessibilityTitles: [:], now: t0 + ExclusionPlanner.holdLimit)
        #expect(later.exceptedWindowIDs == [1])
    }

    @Test func firefoxWindowWhoseTitleTurnsPrivateIsKeptOutFromThen() {
        var planner = ExclusionPlanner()
        let before = planner.plan(windows: [window(1, firefox, "Mozilla Firefox")], apps: [firefox], settings: settings(), accessibilityTitles: [:], now: t0)
        #expect(before.exceptedWindowIDs == [1])
        let after = planner.plan(windows: [window(1, firefox, "Forged \u{2014} Private Browsing")], apps: [firefox], settings: settings(), accessibilityTitles: [:], now: t0 + 1)
        #expect(after.exceptedWindowIDs.isEmpty)
    }

    // MARK: - Safari, Chrome, Edge, Brave (level 2)

    @Test func accessibilityBrowsersAreNotHeldUnlessReadsWork() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(
            windows: [window(1, chrome, "Example Domain")],
            apps: [chrome, safari],
            settings: settings(accessibility: false),
            accessibilityTitles: [:],
            now: t0
        )
        #expect(plan.hiddenPIDs.isEmpty)
        #expect(planner.windowsNeedingAccessibilityTitles(windows: [window(1, chrome, "Example Domain")], apps: [chrome], settings: settings(accessibility: false)).isEmpty)
    }

    @Test func chromePrivateWindowStaysOutAndOrdinaryAndForgedWindowsAreLetIn() {
        var planner = ExclusionPlanner()
        let windows = [
            window(1, chrome, "Example Domain"),
            window(2, chrome, "Example Domain"),
            window(3, chrome, "Forged - Google Chrome (Incognito)"),
        ]
        #expect(planner.windowsNeedingAccessibilityTitles(windows: windows, apps: [chrome], settings: settings(accessibility: true)) == [chrome.pid])
        let plan = planner.plan(
            windows: windows,
            apps: [chrome],
            settings: settings(accessibility: true),
            accessibilityTitles: [
                1: "Example Domain - Google Chrome (Incognito)",
                2: "Example Domain - Google Chrome",
                3: "Forged - Google Chrome (Incognito) - Google Chrome",
            ],
            now: t0
        )
        #expect(plan.hiddenPIDs == [chrome.pid])
        #expect(plan.exceptedWindowIDs == [2, 3])
        #expect(plan.privateWindowCount == 1)
    }

    @Test func decidedWindowsAreNotReadAgain() {
        var planner = ExclusionPlanner()
        let windows = [window(1, safari, "Example Domain")]
        _ = planner.plan(windows: windows, apps: [safari], settings: settings(accessibility: true), accessibilityTitles: [1: "Example Domain, Private Browsing"], now: t0)
        #expect(planner.windowsNeedingAccessibilityTitles(windows: windows, apps: [safari], settings: settings(accessibility: true)).isEmpty)
        // A later page title change does not let a private window in.
        let later = planner.plan(windows: [window(1, safari, "Another Page")], apps: [safari], settings: settings(accessibility: true), accessibilityTitles: [:], now: t0 + 5)
        #expect(later.exceptedWindowIDs.isEmpty)
        #expect(later.privateWindowCount == 1)
    }

    @Test func unreadableNewWindowIsHeldThenLetInAndStillReadLater() {
        var planner = ExclusionPlanner()
        let windows = [window(1, chrome, "Example Domain")]
        let s = settings(accessibility: true)
        let held = planner.plan(windows: windows, apps: [chrome], settings: s, accessibilityTitles: [:], now: t0)
        #expect(held.exceptedWindowIDs.isEmpty)
        #expect(held.heldWindowCount == 1)

        let letIn = planner.plan(windows: windows, apps: [chrome], settings: s, accessibilityTitles: [:], now: t0 + ExclusionPlanner.holdLimit)
        #expect(letIn.exceptedWindowIDs == [1])
        #expect(planner.windowsNeedingAccessibilityTitles(windows: windows, apps: [chrome], settings: s) == [chrome.pid])

        let read = planner.plan(windows: windows, apps: [chrome], settings: s, accessibilityTitles: [1: "Example Domain - Google Chrome (Incognito)"], now: t0 + 3)
        #expect(read.exceptedWindowIDs.isEmpty)
        #expect(read.privateWindowCount == 1)
    }

    // MARK: - Title patterns

    @Test func titlePatternWindowStaysOutAndItsAppsOtherWindowsAreLetIn() {
        var planner = ExclusionPlanner()
        let plan = planner.plan(
            windows: [window(1, terminal, "ssh bank-prod"), window(2, terminal, "notes")],
            apps: [terminal],
            settings: settings(privateBrowsing: false, patterns: ["BANK"]),
            accessibilityTitles: [:],
            now: t0
        )
        #expect(plan.hiddenPIDs == [terminal.pid])
        #expect(plan.exceptedWindowIDs == [2])
        #expect(plan.titlePatternCount == 1)
    }
}

/// The second level's status never reads "on" unless a real read works, and an owner who has just
/// turned it on sees "waiting" while macOS asks, not a fault.
@Suite("PrivateWindowAccessibilityState")
struct PrivateWindowAccessibilityStateTests {
    @Test func aWorkingReadIsWorking() {
        #expect(PrivateWindowAccessibilityState.after(readWorks: true, askedThisSession: false, hasWorkedSinceAsking: false) == .working)
    }

    @Test func justTurnedOnAndNotYetWorkingIsWaiting() {
        #expect(PrivateWindowAccessibilityState.after(readWorks: false, askedThisSession: true, hasWorkedSinceAsking: false) == .waiting)
    }

    @Test func stoppedAfterWorkingIsNotWorking() {
        #expect(PrivateWindowAccessibilityState.after(readWorks: false, askedThisSession: true, hasWorkedSinceAsking: true) == .notWorking)
    }

    @Test func onFromAnEarlierSessionAndFailingIsNotWorking() {
        #expect(PrivateWindowAccessibilityState.after(readWorks: false, askedThisSession: false, hasWorkedSinceAsking: false) == .notWorking)
    }
}
