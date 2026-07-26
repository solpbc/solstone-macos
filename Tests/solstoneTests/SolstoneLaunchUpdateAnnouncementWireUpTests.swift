// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("Solstone launch update announcement wire-up")
struct SolstoneLaunchUpdateAnnouncementWireUpTests {
    @Test func postLaunchEvaluationRunsAfterBootstrapNotificationAuthorization() throws {
        let source = try readWireUpSource("Sources/solstone/SolstoneCaptureApp.swift")
        let bootstrap = try #require(source.range(of: "await state.bootstrapNotificationAuthorization()"))
        let evaluate = try #require(source.range(of: "updateController.evaluatePendingUpdateAnnouncement()"))

        #expect(bootstrap.lowerBound < evaluate.lowerBound)
        #expect(wireUpContains(source, "UpdateAnnouncementLaunchRegistry.register(updateController)"))
        #expect(wireUpContains(source, "UpdateAnnouncementLaunchRegistry.take()"))
    }
}
