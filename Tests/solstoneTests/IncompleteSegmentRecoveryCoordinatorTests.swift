// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Incomplete segment recovery coordinator")
struct IncompleteSegmentRecoveryCoordinatorTests {
    @Test func concurrentRecoverAllCallsAreSingleFlighted() async throws {
        let recovery = CountingRecovery(.hang)
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })

        let first = Task {
            await coordinator.recoverAll()
        }

        try await waitUntil(timeout: .seconds(1)) {
            recovery.count.count == 1
        }

        let clock = ContinuousClock()
        let start = clock.now
        let second = await coordinator.recoverAll()
        let elapsed = start.duration(to: clock.now)

        first.cancel()
        #expect(second == 0)
        #expect(elapsed < .milliseconds(750))
        #expect(recovery.count.count == 1)
    }
}
