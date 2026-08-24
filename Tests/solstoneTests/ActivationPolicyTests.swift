// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Testing
@testable import solstone

@Suite("Activation Policy")
@MainActor
struct ActivationPolicyTests {
    @Test func openingSettingsSceneComputesRegularPolicy() {
        let state = AppState.forSnapshot()
        state.openSceneIds.insert(.settings)

        #expect(state.openSceneIds == [.settings])
        #expect(state.computeDesiredPolicy() == .regular)
    }

    @Test func handleWindowWillCloseRemovesMatchingSceneID() {
        let state = AppState.forSnapshot()
        state.openSceneIds = [.settings]

        state.handleWindowWillClose(identifier: "settings-AppWindow-1")

        #expect(state.openSceneIds.isEmpty)
    }

    @Test func alwaysAccessoryOverridesOpenWindows() {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysAccessory
        state.openSceneIds = [.settings]

        #expect(state.computeDesiredPolicy() == .accessory)
    }

    @Test func alwaysRegularOverridesEmptyOpenWindows() {
        let state = AppState.forSnapshot()
        state.dockMode = .alwaysRegular
        state.openSceneIds = []

        #expect(state.computeDesiredPolicy() == .regular)
    }

    @Test func loginLaunchSuppressionForcesAccessoryUntilItExpires() {
        let state = AppState.forSnapshot()
        let now = Date()
        state.loginLaunchSuppressionExpires = now.addingTimeInterval(1)
        state.openSceneIds = [.settings]

        #expect(state.computeDesiredPolicy(now: now) == .accessory)
        #expect(state.computeDesiredPolicy(now: now.addingTimeInterval(2)) == .regular)
    }

}
