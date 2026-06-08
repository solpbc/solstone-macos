// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
import SolstoneCore
@testable import solstone

@Suite("AppState.forSnapshot")
@MainActor
struct AppStateSnapshotTests {
    @Test func snapshotStateDefaults() {
        let state = AppState.forSnapshot()
        #expect(state.isRecording == false)
        #expect(state.errorMessage == nil)
    }

    @Test func launchBundledDetectionRunsOnceWhenExplicitlyStarted() async {
        let counter = LockedCounter()
        let state = AppState.forLaunchDetectionTest(
            config: AppConfig(serviceMode: .bundled),
            detectionRunner: {
                counter.increment()
                return true
            }
        )

        await state.startBundledJournalDetectionIfNeeded()
        await state.startBundledJournalDetectionIfNeeded()

        #expect(counter.count == 1)
    }

    @Test func launchBundledDetectionSkipsSnapshotsAndNonBundledMode() async {
        let snapshotCounter = LockedCounter()
        let snapshot = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        snapshot.bundledJournalDetectionRunner = {
            snapshotCounter.increment()
            return true
        }

        await snapshot.startBundledJournalDetectionIfNeeded()

        let externalCounter = LockedCounter()
        let external = AppState.forLaunchDetectionTest(
            config: AppConfig(serviceMode: .external),
            detectionRunner: {
                externalCounter.increment()
                return true
            }
        )

        await external.startBundledJournalDetectionIfNeeded()

        #expect(snapshotCounter.count == 0)
        #expect(externalCounter.count == 0)
    }
}
