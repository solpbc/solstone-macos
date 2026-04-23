// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Testing
@testable import solstone

@Suite("Activation Policy")
@MainActor
struct ActivationPolicyTests {
    @Test func openingSettingsSceneComputesRegularPolicy() {
        let delegate = AppDelegate()
        delegate.openSceneIds.insert(.settings)

        #expect(delegate.openSceneIds == [.settings])
        #expect(delegate.computeDesiredPolicy() == .regular)
    }

    @Test func handleWindowWillCloseRemovesMatchingSceneID() {
        let delegate = AppDelegate()
        delegate.openSceneIds = [.settings]

        delegate.handleWindowWillClose(identifier: "settings-AppWindow-1")

        #expect(delegate.openSceneIds.isEmpty)
    }

    @Test func alwaysAccessoryOverridesOpenWindows() {
        let delegate = AppDelegate()
        delegate.dockMode = .alwaysAccessory
        delegate.openSceneIds = [.settings]

        #expect(delegate.computeDesiredPolicy() == .accessory)
    }

    @Test func alwaysRegularOverridesEmptyOpenWindows() {
        let delegate = AppDelegate()
        delegate.dockMode = .alwaysRegular
        delegate.openSceneIds = []

        #expect(delegate.computeDesiredPolicy() == .regular)
    }

    @Test func loginLaunchSuppressionForcesAccessoryUntilItExpires() {
        let delegate = AppDelegate()
        let now = Date()
        delegate.loginLaunchSuppressionExpires = now.addingTimeInterval(1)
        delegate.openSceneIds = [.settings]

        #expect(delegate.computeDesiredPolicy(now: now) == .accessory)
        #expect(delegate.computeDesiredPolicy(now: now.addingTimeInterval(2)) == .regular)
    }
}
