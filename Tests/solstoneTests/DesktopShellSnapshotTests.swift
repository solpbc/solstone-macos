// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import JournalMarkKit
import os
import SwiftUI
import Testing
import UpdateKit
@testable import solstone

/// Renders the desktop shell in every state, light and dark, for review by eye. The images are
/// review artifacts: these tests check that each one rendered, not how it looks.
@Suite("Desktop shell snapshots")
@MainActor
struct DesktopShellSnapshotTests {
    private let isolatedDefaults = IsolatedUserDefaults()
    private static nonisolated(unsafe) var outputDirectory: URL?

    init() {
        _ = NSApplication.shared
        // The app registers the names' face at launch; the renders need it before their first frame.
        JournalMarkFont.register()
    }

    enum Scene: String, CaseIterable {
        case good, attn, offline, paused, fresh, many
    }

    private func outputDir() throws -> URL {
        if let dir = Self.outputDirectory { return dir }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dir = root.appendingPathComponent("snapshots/shell-\(formatter.string(from: Date()))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.outputDirectory = dir
        return dir
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, dark: Bool) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: try outputDir().appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        #expect(png.count > 10_000, "\(name) rendered almost nothing")
    }

    private func updateController() -> UpdateController {
        UpdateController(
            feedURL: nil, publicKey: nil, log: Logger.setup,
            errorDomain: "app.solstone.observer.updates", defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
    }

    static func inputs(_ scene: Scene) -> (DeckInputs, JournalPillInputs) {
        var deck = DeckInputs()
        deck.terminalOn = true
        deck.terminalState = .running
        deck.browserState = .running(connected: ["Chrome", "Safari"])
        deck.obsidianState = .on
        deck.obsidianVaultName = "field notes"
        var pill = JournalPillInputs()
        switch scene {
        case .good:
            break
        case .attn:
            deck.screenAccess = .denied
        case .offline:
            pill.connection = .offline
            pill.pending = 12
        case .paused:
            deck.ownerPaused = true
            deck.microphoneLive = .ownerPaused
            deck.screenLive = .ownerPaused
            deck.activityGoingIn = false
            deck.terminalState = .paused
            deck.browserState = .paused
            deck.obsidianState = .paused
        case .fresh:
            deck.paired = false
            deck.microphoneAccess = .notAsked
            deck.screenAccess = .notAsked
            deck.terminalOn = false
            deck.browserState = .notPaired
            deck.obsidianState = .off
            pill.hasJournal = false
        case .many:
            deck.browserState = .running(connected: ["Chrome", "Edge", "Firefox", "Safari"])
            deck.obsidianVaultName = "the long field notes vault, 2019 onward"
            pill.pending = 3
        }
        return (deck, pill)
    }

    /// Sample totals, the mock's own values, with times relative to now.
    static func sampleTotals() -> SourceTotals.View {
        let now = Date()
        let iso = { (seconds: TimeInterval) in SourceTotals.iso(now.addingTimeInterval(-seconds)) }
        return SourceTotals.View(
            audioSeconds: 265 * 3600, audioRemainderMs: 0, audioLast: iso(4 * 60), audioSegments: [], audioStarted: "2026-03-03",
            screenSeconds: 212 * 3600, screenRemainderMs: 0, screenLast: iso(10), screenSegments: [], screenStarted: "2026-03-03",
            terminalSeconds: 38 * 3600, terminalLast: iso(12 * 60), terminalCarried: false, terminalStarted: "2026-03-03",
            browsersTotal: 1351, browsersLast: iso(26 * 3600), browsersTabs: [:], browsersStarted: "2026-06-12",
            obsidianTotal: 412, obsidianLast: iso(2 * 3600), obsidianNotes: [], obsidianBaseline: true, obsidianStarted: "2026-03-03"
        )
    }

    private func state(_ scene: Scene) -> AppState {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(scene == .attn ? .notGranted : .granted)
        state.microphoneAuthorizationCause = .authorized
        state.isRecording = scene != .fresh
        let (deck, pill) = Self.inputs(scene)
        state.snapshotDeckInputs = deck
        state.snapshotJournalPillInputs = pill
        state.snapshotSourceTotals = scene == .fresh ? nil : Self.sampleTotals()
        if scene != .fresh {
            state.snapshotJournalFacts = [
                ["connection", "connected to your journal on this mac"],
                [UICopy.SETTINGS_LAST_DELIVERY_LABEL, "just now"],
            ]
        }
        if scene == .paused { state.pauseManager.pause(for: .minutes(14)) }
        return state
    }

    private let windowSize = CGSize(width: 1040, height: 700)

    @Test(arguments: Scene.allCases)
    func deck(_ scene: Scene) throws {
        for dark in [false, true] {
            let view = SettingsView(appState: state(scene), updateController: updateController(), selectedTab: .home, initialStorageUsedMB: 42)
            try render(view, size: windowSize, to: "deck-\(scene.rawValue)", dark: dark)
        }
    }

    @Test(arguments: [
        (Scene.attn, HomePane.source(.screen), "pane-screen"),
        (Scene.good, HomePane.source(.audio), "pane-audio"),
        (Scene.good, HomePane.source(.terminal), "pane-terminal"),
        (Scene.many, HomePane.source(.browsers), "pane-browsers"),
        (Scene.good, HomePane.source(.obsidian), "pane-obsidian"),
        (Scene.offline, HomePane.status, "pane-status-offline"),
        (Scene.good, HomePane.status, "pane-status-good"),
        (Scene.fresh, HomePane.status, "pane-status-fresh"),
        (Scene.good, HomePane.addMore, "pane-add-more"),
    ])
    func pane(_ scene: Scene, _ pane: HomePane, _ name: String) throws {
        for dark in [false, true] {
            let view = SettingsView(appState: state(scene), updateController: updateController(), selectedTab: .home, initialHomePane: pane, initialStorageUsedMB: 42)
            try render(view, size: CGSize(width: 1160, height: 900), to: name, dark: dark)
        }
    }

    @Test(arguments: [
        ("full", CGFloat(1240), false, HomePane?.none),
        ("narrow", CGFloat(900), false, HomePane?.none),
        ("phone-deck", CGFloat(420), false, HomePane?.none),
        ("phone-page", CGFloat(420), true, HomePane?.some(.source(.screen))),
        ("phone-status", CGFloat(420), true, HomePane?.none),
    ])
    func width(_ name: String, _ width: CGFloat, _ pushed: Bool, _ pane: HomePane?) throws {
        for dark in [false, true] {
            let view = SettingsView(
                appState: state(.good), updateController: updateController(), selectedTab: .home,
                initialHomePane: pane, initialPhonePushed: pushed, initialStorageUsedMB: 42
            )
            try render(view, size: CGSize(width: width, height: 760), to: "width-\(name)", dark: dark)
        }
    }

    @Test(arguments: [SettingsView.Tab.service, .observer, .updates, .help])
    func shelfRow(_ tab: SettingsView.Tab) throws {
        for dark in [false, true] {
            let view = SettingsView(appState: state(.good), updateController: updateController(), selectedTab: tab, initialStorageUsedMB: 42)
            try render(view, size: windowSize, to: "shelf-\(tab.rawValue)", dark: dark)
        }
    }

    /// The screenshots page in each condition the shell can show. Light is enough to compare with the mock.
    @Test(arguments: ["not-set-up", "access-off", "moved", "chooser", "bringing-in", "waiting", "paused", "off", "refused"])
    func screenshotPage(_ name: String) throws {
        let facts = Self.screenshotFacts(name)
        let app = state(.good)
        var deck = Self.inputs(.good).0
        deck.screenshot = presentScreenshots(facts)
        app.snapshotDeckInputs = deck
        if name == "bringing-in" || name == "paused" || name == "refused" {
            var totals = Self.sampleTotals()
            totals.screenshotsTotal = 40
            totals.screenshotsLast = SourceTotals.iso(Date().addingTimeInterval(-120))
            totals.screenshotsStarted = "2026-03-03"
            app.snapshotSourceTotals = totals
        }
        let wide = CGSize(width: 1160, height: 1100)
        let view = SettingsView(
            appState: app, updateController: updateController(), selectedTab: .home,
            initialHomePane: .source(.screenshots), initialStorageUsedMB: 42
        )
        try render(view, size: wide, to: "screenshots-\(name)", dark: false)
        if name == "chooser" || name == "bringing-in" {
            let phone = SettingsView(
                appState: app, updateController: updateController(), selectedTab: .home,
                initialHomePane: .source(.screenshots), initialPhonePushed: true, initialStorageUsedMB: 42
            )
            try render(phone, size: CGSize(width: 420, height: 900), to: "screenshots-\(name)-phone", dark: false)
        }
    }

    private static func screenshotFacts(_ name: String) -> ScreenshotFacts {
        var facts = ScreenshotFacts()
        facts.folderName = "Documents"
        facts.folderLine = "Documents"
        facts.folderIsDesktop = false
        switch name {
        case "not-set-up":
            facts.folderName = "Desktop"
            facts.folderIsDesktop = true
        case "access-off":
            facts.consented = true
            facts.enabled = true
            facts.access = .denied
        case "moved":
            facts.consented = true
            facts.enabled = true
            facts.access = .moved
            facts.movedName = "Desktop"
        case "chooser":
            facts.consented = true
            facts.enabled = true
            facts.count = .ready(128)
            facts.folderPath = "/Users/owner/Documents"
            facts.showReturnNote = true
        case "bringing-in":
            facts.consented = true
            facts.enabled = true
            facts.confirmed = true
            facts.backlogOpen = true
            facts.done = 12
            facts.total = 128
            facts.lastChecked = Date().addingTimeInterval(-20)
        case "waiting":
            facts.consented = true
            facts.enabled = true
            facts.confirmed = true
            facts.waitingForJournal = true
            facts.lastChecked = Date().addingTimeInterval(-40)
        case "paused":
            facts.consented = true
            facts.enabled = true
            facts.confirmed = true
            facts.ownerPaused = true
            facts.backlogOpen = true
            facts.done = 12
            facts.total = 128
        case "off":
            facts.consented = true
            facts.enabled = false
        case "refused":
            facts.consented = true
            facts.enabled = true
            facts.confirmed = true
            facts.refused = 1
            facts.unreadable = 2
            facts.lastChecked = Date().addingTimeInterval(-90)
            facts.waiting = 3
        default:
            break
        }
        return facts
    }
}
