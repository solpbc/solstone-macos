// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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

    init() { _ = NSApplication.shared }

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

    private func state(_ scene: Scene) -> AppState {
        let state = AppState.forSnapshot()
        state.initialPermissionCheckComplete = true
        state.capture.publishScreenRecordingPermission(.granted)
        state.microphoneAuthorizationCause = .authorized
        state.isRecording = scene != .fresh
        let (deck, pill) = Self.inputs(scene)
        state.snapshotDeckInputs = deck
        state.snapshotJournalPillInputs = pill
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

    @Test(arguments: Scene.allCases)
    func glance(_ scene: Scene) throws {
        for dark in [false, true] {
            let view = GlanceView(appState: state(scene), updateController: updateController())
            try render(view, size: CGSize(width: 340, height: 360), to: "glance-\(scene.rawValue)", dark: dark)
        }
    }

    @Test(arguments: [SettingsView.Tab.service, .observer, .updates, .help])
    func shelfRow(_ tab: SettingsView.Tab) throws {
        for dark in [false, true] {
            let view = SettingsView(appState: state(.good), updateController: updateController(), selectedTab: tab, initialStorageUsedMB: 42)
            try render(view, size: windowSize, to: "shelf-\(tab.rawValue)", dark: dark)
        }
    }
}
