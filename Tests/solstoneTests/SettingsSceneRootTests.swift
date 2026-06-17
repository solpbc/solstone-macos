// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
