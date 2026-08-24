// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Timeout injection defaults")
@MainActor
struct TimeoutInjectionDefaultsTests {
    @Test func defaultTimeoutsMatchProductionLiterals() async throws {
        let queue = RemixQueue()
        #expect(await queue.remixTimeoutSecondsForTesting == 60)

        let root = try makeTempDirectory("timeout-defaults")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = SegmentWriter(
            outputDirectory: root.appendingPathComponent("120000.incomplete", isDirectory: true),
            timePrefix: "120000"
        )
        #expect(writer.capturerStopTimeoutSecondsForTesting == 5)
        #expect(writer.audioFinishTimeoutSecondsForTesting == 10)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: true
        )
        #expect(manager.rotationTimeoutSecondsForTesting == 30)
        #expect(AppQuitCoordinator.diagnosticEvidenceDrainCutoffSeconds == 2)
        #expect(AppState.terminationRemixDrainTimeoutSeconds == 30)

        let before = Date()
        let observed = manager.nowForTesting()
        let after = Date()
        #expect(observed >= before)
        #expect(observed <= after)
    }

    @Test func pauseManagerDefaultSchedulerArmsRealTimer() {
        let manager = PauseManager()
        let timer = manager.expirySchedulerForTesting(3600) { }
        #expect(timer is Timer)
        timer.invalidate()
    }
}
