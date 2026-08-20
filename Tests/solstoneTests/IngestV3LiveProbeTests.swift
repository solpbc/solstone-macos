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
        #expect(IngestV3LiveProbe.permitsTunnelLifecycle)
    }

    @Test func requestedProbeWithoutDeveloperLaunchSuppressesPipelineAndRefusesBeforeTunnelStart() {
        let launch = IngestV3LiveProbe.configure(environment: [
            "SOLSTONE_V3_LIVE_PROBE": "1",
        ])
        #expect(launch.suppressesNormalPipeline == true)
        let state = AppState.forSnapshot()
        var tunnelStarts = 0
        let didStart = IngestV3LiveProbe.startTunnelLifecycleIfPermitted(appState: state) {
            tunnelStarts += 1
        }
        #expect(didStart == false)
        #expect(tunnelStarts == 0)
    }

    @Test func disposableJournalAcknowledgementIsRequired() throws {
        let root = try makeTempDirectory("v3-probe-acknowledgement")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.bin")
        try Data("fixture".utf8).write(to: fixture)

        for acknowledgement in [nil, "not-disposable"] {
            var environment = requestedProbeEnvironment(fixture: fixture)
            environment.removeValue(forKey: "SOLSTONE_V3_PROBE_DISPOSABLE_JOURNAL")
            if let acknowledgement {
                environment["SOLSTONE_V3_PROBE_DISPOSABLE_JOURNAL"] = acknowledgement
            }
            let launch = IngestV3LiveProbe.configure(environment: environment)
            #expect(launch.suppressesNormalPipeline)
            #expect(IngestV3LiveProbe.permitsTunnelLifecycle == false)
        }
    }

    @Test func fixtureMustBeAnExistingRegularFile() throws {
        let root = try makeTempDirectory("v3-probe-fixture")
        defer { try? FileManager.default.removeItem(at: root) }

        for fixture in [root.appendingPathComponent("missing"), root] {
            let launch = IngestV3LiveProbe.configure(environment: requestedProbeEnvironment(fixture: fixture))
            #expect(launch.suppressesNormalPipeline)
            #expect(IngestV3LiveProbe.permitsTunnelLifecycle == false)
        }
    }

    @Test func stagingPreservesFixtureBytesAndUsesSelectedAudioName() throws {
        let root = try makeTempDirectory("v3-probe-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.wav")
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: fixture)
        let directory = root.appendingPathComponent("staged", isDirectory: true)

        let staged = try IngestV3LiveProbe.stageFixture(fixture, in: directory, segment: "120000_300")

        #expect(staged.lastPathComponent == "120000_300_audio.m4a")
        #expect(UploadClient().sha256(of: staged) == UploadClient().sha256(of: fixture))
        let fixtureSize = try #require(fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let stagedSize = try #require(staged.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(stagedSize == fixtureSize)
    }

    private func requestedProbeEnvironment(fixture: URL) -> [String: String] {
        [
            "SOLSTONE_V3_LIVE_PROBE": "1",
            AppPlacementGate.developerLaunchEnvironmentKey: "1",
            "SOLSTONE_V3_PROBE_FIXTURE": fixture.path,
            "SOLSTONE_V3_PROBE_DISPOSABLE_JOURNAL": "I_UNDERSTAND_THIS_IS_DISPOSABLE",
            "SOLSTONE_V3_PROBE_ROUTE": "direct-pl",
        ]
    }
}
#endif
