// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("ExternalMicCapture")
struct ExternalMicCaptureTests {
    @Test func stopTearsDownEngineBeforeRemovingTapWhenNeverStarted() {
        let device = AudioInputDevice(
            id: 0,
            name: "test-mic",
            uid: "test-uid",
            manufacturer: nil,
            sampleRate: 48_000,
            transportType: .virtual
        )
        let capture = ExternalMicCapture(device: device)

        capture.stop()

        // Proves stop tears down even when never started, and stops before tap removal.
        #expect(capture._teardownTraceForTesting == ["engine.stop", "removeTap"])
    }
}
