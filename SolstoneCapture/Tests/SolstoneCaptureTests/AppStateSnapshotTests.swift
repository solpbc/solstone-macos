// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import SolstoneCapture

@Suite("AppState.forSnapshot")
@MainActor
struct AppStateSnapshotTests {
    @Test func recordingStatusIcon() {
        let state = AppState.forSnapshot()
        state.isRecording = true
        #expect(state.statusIconName == "record.circle.fill")
    }
}
