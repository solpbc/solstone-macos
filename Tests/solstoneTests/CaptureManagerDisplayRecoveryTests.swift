// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@MainActor
@Suite("CaptureManager display recovery")
struct CaptureManagerDisplayRecoveryTests {
    @Test func noDisplayRecoveryFinishesAndEnqueuesActiveSegmentWithoutGoingIdle() async throws {
        let finalizer = FakeFinalizer()
        let root = try makeTempDirectory("capture-display-recovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let segmentBox = LockedValue<FakeCaptureSegment>()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: outputDirectory)
                segmentBox.set(segment)
                return segment
            },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        let startOutcome = await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }
        let segment = try #require(segmentBox.current)
        #expect(manager.hasSegmentTimerForTesting)
        #expect(manager.hasHeartbeatTimerForTesting)

        await manager.enterNoDisplayRecovery()

        #expect(segment.finishCaptureCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all == [segment.outputDirectory])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isError)
        #expect(!manager.state.isIdle)
        #expect(!manager.hasSegmentTimerForTesting)
        #expect(!manager.hasHeartbeatTimerForTesting)
        #expect(!manager.hasPendingRotationRetryForTesting)

        _ = await manager.enqueueTransition(.stop(reason: .user))
    }
}
