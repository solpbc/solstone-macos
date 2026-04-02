// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import SolstoneCapture

@Suite("AppState.forSnapshot")
@MainActor
struct AppStateSnapshotTests {
    @Test func snapshotStateDefaults() {
        let state = AppState.forSnapshot()
        #expect(state.isRecording == false)
        #expect(state.errorMessage == nil)
    }
}
