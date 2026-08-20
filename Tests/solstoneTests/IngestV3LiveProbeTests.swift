// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import Testing
@testable import solstone

@Suite("Ingest v3 live probe", .serialized)
@MainActor
struct IngestV3LiveProbeTests {
    @Test func disabledProbeLeavesNormalPipelineEligible() {
        let launch = IngestV3LiveProbe.configure(environment: [:])
        #expect(launch.suppressesNormalPipeline == false)
    }

    @Test func requestedProbeWithoutDeveloperLaunchSuppressesNormalPipelineAndRefuses() {
        let launch = IngestV3LiveProbe.configure(environment: [
            "SOLSTONE_V3_LIVE_PROBE": "1",
        ])
        #expect(launch.suppressesNormalPipeline == true)
    }
}
#endif
