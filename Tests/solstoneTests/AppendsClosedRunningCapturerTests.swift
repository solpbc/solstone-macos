// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("Appends closed on a running capturer", .serialized)
@MainActor
struct AppendsClosedRunningCapturerTests {
    // The per-frame closed check is what stops a capturer that is still running
    // (its isRunning guard does not apply), on the rule-off path.
    @Test func closingAppendsOnARunningCapturerDropsItsNextFrame() async throws {
        let root = try makeTempDirectory("appends-closed-running")
        defer { try? FileManager.default.removeItem(at: root) }
        let stream = FakeCaptureStream()
        let siteRuleLock = OSAllocatedUnfairLock(initialState: false)
        let appendsClosedLock = OSAllocatedUnfairLock(initialState: false)
        let capturer = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("1.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: { _, _, _ in stream },
            siteRuleLock: siteRuleLock,
            appendsClosedLock: appendsClosedLock
        )
        try await capturer.start()
        #expect(capturer._isRunningForTesting)
        let buffer = makeTestPixelBuffer(width: 16, height: 16)
        capturer.handleFrameFromOutput(generation: capturer._streamGenerationForTesting, pixelBuffer: buffer, isIdle: false, epoch: 0)
        #expect(capturer._submittedVideoFrameCountForTesting == 1)
        appendsClosedLock.withLock { $0 = true }
        #expect(capturer._isRunningForTesting)
        capturer.handleFrameFromOutput(generation: capturer._streamGenerationForTesting, pixelBuffer: buffer, isIdle: false, epoch: 0)
        #expect(capturer._submittedVideoFrameCountForTesting == 1)
        await capturer.stop()
    }
}
