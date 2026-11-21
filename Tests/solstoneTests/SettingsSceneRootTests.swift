// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import Testing
@testable import solstone

@Suite("Settings Scene Root")
@MainActor
struct SettingsSceneRootTests {
    @Test func closedSettingsWindowRendersInertContent() {
        #expect(!shouldRenderSettingsContent(settingsWindowOpen: false))
    }

    @Test func openSettingsWindowRendersSettingsContent() {
        #expect(shouldRenderSettingsContent(settingsWindowOpen: true))
    }

    @Test func openSettingsWindowNotificationRoutesToSettingsContent() {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory
        let center = NotificationCenter()
        var openedWindowID: String?
        var activationRequested = false

        let observer = center.addObserver(forName: .openSettingsWindow, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                routeOpenSettingsWindow(
                    appState: state,
                    openWindow: { openedWindowID = $0 },
                    activate: { activationRequested = true }
                )
            }
        }
        defer { center.removeObserver(observer) }

        center.post(name: .openSettingsWindow, object: nil)

        #expect(openedWindowID == SolstoneSceneID.settings.rawValue)
        #expect(state.openSceneIds.contains(.settings))
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))
        #expect(activationRequested)
    }

    @Test func settingsContentGateTracksOpenSceneMembershipWithoutLatch() {
        let state = AppState.forSnapshot()

        #expect(!shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        state.openSceneIds.insert(.settings)
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        state.openSceneIds.remove(.settings)
        #expect(!shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        state.openSceneIds.insert(.settings)
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))
    }

    @Test func sceneIDMatchingAcceptsExactAndAppWindowSuffixOnly() {
        #expect(SolstoneSceneID.matching(windowIdentifier: "settings") == .settings)
        #expect(SolstoneSceneID.matching(windowIdentifier: "settings-AppWindow-1") == .settings)
        #expect(SolstoneSceneID.matching(windowIdentifier: "about") == .about)
        #expect(SolstoneSceneID.matching(windowIdentifier: "about-AppWindow-2") == .about)
        #expect(SolstoneSceneID.matching(windowIdentifier: "journal") == .journal)
        #expect(SolstoneSceneID.matching(windowIdentifier: "journal-AppWindow-1") == .journal)

        #expect(SolstoneSceneID.matching(windowIdentifier: nil) == nil)
        #expect(SolstoneSceneID.matching(windowIdentifier: "") == nil)
        #expect(SolstoneSceneID.matching(windowIdentifier: "com.apple.systemsettings.sheet") == nil)
        #expect(SolstoneSceneID.matching(windowIdentifier: "settings-sheet") == nil)
        #expect(SolstoneSceneID.matching(windowIdentifier: "about-panel") == nil)
        #expect(SolstoneSceneID.matching(windowIdentifier: "my-journal") == nil)
    }

    @Test func ensureWindowTrackedOpenRestoresSceneContentAndRegularPolicy() {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory

        #expect(!shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))
        #expect(!shouldRenderJournalContent(journalWindowOpen: state.openSceneIds.contains(.journal)))

        state.ensureWindowTrackedOpen(.settings)
        #expect(state.openSceneIds == [.settings])
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        // Idempotent when already tracked.
        state.ensureWindowTrackedOpen(.settings)
        #expect(state.openSceneIds == [.settings])

        state.ensureWindowTrackedOpen(.journal)
        #expect(state.openSceneIds == [.settings, .journal])
        #expect(shouldRenderJournalContent(journalWindowOpen: state.openSceneIds.contains(.journal)))

        state.dockMode = .auto
        #expect(state.computeDesiredPolicy() == .regular)
    }

    @Test func presenceViewStaysInertWhileWindowClosedAndTracksWhenOrderedVisible() async throws {
        _ = NSApplication.shared
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(SolstoneSceneID.settings.rawValue)

        let tracker = SceneWindowPresenceView()
        tracker.onWindowVisible = { [weak state] in
            state?.ensureWindowTrackedOpen(.settings)
        }
        window.contentView?.addSubview(tracker)
        defer {
            tracker.stopObserving()
            window.close()
        }

        // Attached to a closed off-screen window: must stay inert so closed windows never mount content.
        try await Task.sleep(for: .milliseconds(30))
        #expect(!state.openSceneIds.contains(.settings))

        // Ordering the window visible without didOpenWindow self-heals tracking.
        window.orderFrontRegardless()
        try await waitUntil { state.openSceneIds.contains(.settings) }
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        // Closing the window drops tracking and must not re-insert while closed.
        state.handleWindowWillClose(identifier: window.identifier?.rawValue)
        window.close()
        try await Task.sleep(for: .milliseconds(40))
        #expect(!state.openSceneIds.contains(.settings))

        // Re-ordering the same NSWindow front without didOpenWindow restores tracking again.
        window.orderFrontRegardless()
        try await waitUntil { state.openSceneIds.contains(.settings) }
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))

        // Removing and re-attaching the view to a visible window preserves its callback and tracks again.
        tracker.removeFromSuperview()
        state.openSceneIds.remove(.settings)
        window.contentView?.addSubview(tracker)
        try await waitUntil { state.openSceneIds.contains(.settings) }
        #expect(shouldRenderSettingsContent(settingsWindowOpen: state.openSceneIds.contains(.settings)))
    }

    @Test func trackedWindowScenesOptOutOfSwiftUIExternalEventsAndAttachPresenceTracker() throws {
        let appSource = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let journalSource = try readWireUpSource("Sources/solstone/JournalWindow.swift")

        let externalEventOptOutCount = appSource.components(separatedBy: ".handlesExternalEvents(matching: [])").count - 1
        #expect(externalEventOptOutCount == SolstoneSceneID.allCases.count)
        #expect(appSource.contains("SceneWindowPresenceTracker(sceneID: .settings, appState: appState)"))
        #expect(appSource.contains("SceneWindowPresenceTracker(sceneID: .about, appState: startup.appState)"))
        #expect(journalSource.contains("SceneWindowPresenceTracker(sceneID: .journal, appState: appState)"))
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
