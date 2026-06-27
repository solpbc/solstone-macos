// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

struct ScreenshotCapturerTeardownTests {
    @MainActor
    @Test func stopTearsDownStreamBeforeDroppingOutputWhenNeverStarted() async throws {
        let root = try makeTempDirectory("screenshot-teardown")
        defer { try? FileManager.default.removeItem(at: root) }

        let capturer = try ScreenshotCapturer(
            displayID: 0,
            videoURL: root.appendingPathComponent("screen.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false
        )

        await capturer.stop()

        #expect(capturer._teardownTraceForTesting == ["stopCapture", "dropOutput"])
    }
}
