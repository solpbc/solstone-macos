// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import solstone

@Suite("WindowExclusionManager reconcile")
@MainActor
struct WindowExclusionReconcileTests {
    private struct TestError: Error {}

    @Test func failedApplyDoesNotCommitThenRetrySucceeds() async {
        let manager = WindowExclusionManager(
            excludedAppNames: [],
            excludePrivateBrowsing: false,
            excludedTitlePatterns: []
        )
        let ids: Set<CGWindowID> = [1, 2, 3]
        var applyCount = 0

        await manager.reconcile(newIDs: ids) {
            applyCount += 1
            throw TestError()
        }

        #expect(applyCount == 1)
        #expect(manager.currentExcludedWindowIDs.isEmpty)

        await manager.reconcile(newIDs: ids) {
            applyCount += 1
        }

        #expect(applyCount == 2)
        #expect(manager.currentExcludedWindowIDs == ids)
    }

    @Test func repeatOfCommittedSetIsSuppressed() async {
        let manager = WindowExclusionManager(
            excludedAppNames: [],
            excludePrivateBrowsing: false,
            excludedTitlePatterns: []
        )
        let ids: Set<CGWindowID> = [7]
        var applyCount = 0

        await manager.reconcile(newIDs: ids) {
            applyCount += 1
        }

        #expect(applyCount == 1)
        #expect(manager.currentExcludedWindowIDs == ids)

        await manager.reconcile(newIDs: ids) {
            applyCount += 1
        }

        #expect(applyCount == 1)
    }

    @Test func distinctTransitionsEachCommitOnce() async {
        let manager = WindowExclusionManager(
            excludedAppNames: [],
            excludePrivateBrowsing: false,
            excludedTitlePatterns: []
        )
        var applyCount = 0

        await manager.reconcile(newIDs: [1]) {
            applyCount += 1
        }

        #expect(applyCount == 1)
        #expect(manager.currentExcludedWindowIDs == [1])

        await manager.reconcile(newIDs: [1, 2]) {
            applyCount += 1
        }

        #expect(applyCount == 2)
        #expect(manager.currentExcludedWindowIDs == [1, 2])

        await manager.reconcile(newIDs: []) {
            applyCount += 1
        }

        #expect(applyCount == 3)
        #expect(manager.currentExcludedWindowIDs.isEmpty)
    }
}
