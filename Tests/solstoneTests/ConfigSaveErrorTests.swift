// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ServiceManagement
import Testing
@testable import solstone

@MainActor
@Suite("Config save error")
struct ConfigSaveErrorTests {
    @Test func updateConfigSaveFailureStaysBesideTheSetting() {
        let state = AppState.forLoginItemTest(
            loginService: FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        )
        let flipped = !state.config.preserveSyncedSegments
        var config = state.config
        config.preserveSyncedSegments = flipped
        state.configSaver = { _ in throw CocoaError(.fileWriteUnknown) }

        state.updateConfig(config)

        #expect(state.configSaveError == UICopy.ERROR_SAVE_CONFIG)
        #expect(state.errorMessage == nil)
        #expect(state.config.preserveSyncedSegments == flipped)

        state.configSaver = { _ in }
        state.updateConfig(config)

        #expect(state.configSaveError == nil)
    }
}
