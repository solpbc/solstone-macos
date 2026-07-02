// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
}
