// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import solstone

@Suite("WindowExclusionManager reconcile")
@MainActor
struct WindowExclusionReconcileTests {
    private struct TestError: Error {}

    private func manager() -> WindowExclusionManager {
        WindowExclusionManager(excludedAppNames: [], excludePrivateBrowsing: false, excludedTitlePatterns: [])
    }

    private func plan(hidden: Set<pid_t>, excepted: Set<CGWindowID> = []) -> ExclusionPlan {
        var plan = ExclusionPlan()
        plan.hiddenPIDs = hidden
        plan.exceptedWindowIDs = excepted
        return plan
    }

    @Test func failedApplyDoesNotCommitThenRetrySucceeds() async {
        let manager = manager()
        let next = plan(hidden: [10], excepted: [1, 2])
        var applyCount = 0

        let failing: () async throws -> Bool = {
            applyCount += 1
            throw TestError()
        }
        await manager.reconcile(plan: next, apply: failing)
        #expect(applyCount == 1)
        #expect(manager.currentPlan == .empty)

        await manager.reconcile(plan: next) { applyCount += 1; return true }
        #expect(applyCount == 2)
        #expect(manager.currentPlan == next)
    }

    @Test func partialApplyIsNotCommittedSoTheNextTickRetries() async {
        let manager = manager()
        let next = plan(hidden: [42])
        var applyCount = 0

        await manager.reconcile(plan: next) { applyCount += 1; return false }
        #expect(manager.currentPlan == .empty)
        await manager.reconcile(plan: next) { applyCount += 1; return true }
        #expect(applyCount == 2)
        #expect(manager.currentPlan == next)
    }

    @Test func aPlanIsResolvedOnlyWhenEveryAppAndWindowWasListed() {
        let p = plan(hidden: [1, 2], excepted: [10])
        #expect(p.isFullyResolved(listedPIDs: [1, 2, 3], listedWindowIDs: [10, 11]))
        #expect(!p.isFullyResolved(listedPIDs: [1], listedWindowIDs: [10]))
        #expect(!p.isFullyResolved(listedPIDs: [1, 2], listedWindowIDs: []))
    }

    @Test func repeatOfCommittedPlanIsSuppressed() async {
        let manager = manager()
        let next = plan(hidden: [7])
        var applyCount = 0

        await manager.reconcile(plan: next) { applyCount += 1; return true }
        await manager.reconcile(plan: next) { applyCount += 1; return true }
        #expect(applyCount == 1)
    }

    @Test func distinctTransitionsEachCommitOnce() async {
        let manager = manager()
        var applyCount = 0

        await manager.reconcile(plan: plan(hidden: [1])) { applyCount += 1; return true }
        await manager.reconcile(plan: plan(hidden: [1], excepted: [5])) { applyCount += 1; return true }
        await manager.reconcile(plan: .empty) { applyCount += 1; return true }
        #expect(applyCount == 3)
        #expect(manager.currentPlan == .empty)
    }
}
