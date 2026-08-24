// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
@testable import solstone

@Suite("Diagnostic evidence normal composition", .serialized)
@MainActor
struct DiagnosticEvidenceNormalCompositionTests {
    @Test func normalCompositionSharesRecorderWithStateProducers() async throws {
        let harness = DiagnosticEvidenceHarness()
        let defaultsName = "DiagnosticEvidenceNormalCompositionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let state = try #require(makeNormalState(harness: harness, defaults: defaults, useRootRecorder: true))
        state.isTerminating = true
        state.capture.microphoneAuthorizationReader = { .authorized }
        await state.capture.checkPermissionsAndAutoStart()

        #expect(evidenceCodes(await harness.entries()) == [
            .appLaunch,
            .microphoneGranted,
            .screenRecordingGranted,
            .permissionAutoStartSkipped,
        ])
    }

    @Test func removalFixtureShowsProducerEvidenceDependsOnInjectedRecorder() async throws {
        let harness = DiagnosticEvidenceHarness()
        let defaultsName = "DiagnosticEvidenceNormalCompositionRemoval.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let state = try #require(makeNormalState(harness: harness, defaults: defaults, useRootRecorder: false))
        state.isTerminating = true
        state.capture.microphoneAuthorizationReader = { .authorized }
        await state.capture.checkPermissionsAndAutoStart()

        #expect(evidenceCodes(await harness.entries()) == [.appLaunch])
    }

    @Test func repairBranchRegistersWithoutRecordingLaunch() async {
        let harness = DiagnosticEvidenceHarness()
        let context = repairContext()
        var registered: [AppPlacementContext] = []
        let repairCoordinator = AppPlacementRepairCoordinator { registered.append($0) }

        let startup: Void? = SolstoneStartupComposition.makeNormalStartup(
            decision: .repair(context),
            repairCoordinator: repairCoordinator,
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeStartup: { _, _ in () }
        )

        #expect(startup == nil)
        repairCoordinator.signalReadiness()
        #expect(registered == [context])
        #expect((await harness.entries()).isEmpty)
    }

    @Test func snapshotDefaultDormantRecorderLeavesHarnessEmpty() async {
        let harness = DiagnosticEvidenceHarness()
        _ = AppState.forSnapshot()

        #expect((await harness.entries()).isEmpty)
    }

    @Test func synchronousLaunchEnqueuePrecedesMainActorScheduledPermissionWork() async throws {
        let harness = DiagnosticEvidenceHarness()
        let defaultsName = "DiagnosticEvidenceNormalCompositionOrdering.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: true,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                // Like startPermissionPolling(), this cannot run until the main actor yields.
                Task { @MainActor in
                    recorder.enqueue(.captureOn)
                }
                return AppState.forSnapshot(recorder: recorder)
            },
            makeUpdateController: { _ in makeTestUpdateController(defaults) },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        _ = try #require(startup)
        await Task.yield()

        #expect(evidenceCodes(await harness.entries()) == [.appLaunch, .captureOn])
    }

    private func makeNormalState(
        harness: DiagnosticEvidenceHarness,
        defaults: UserDefaults,
        useRootRecorder: Bool
    ) -> AppState? {
        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    recorder: useRootRecorder ? recorder : .dormant,
                    screenPermissionProvider: makeScreenPermissionProvider()
                )
            },
            makeUpdateController: { _ in makeTestUpdateController(defaults) },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        return startup
    }

    private func makeTestUpdateController(_ defaults: UserDefaults) -> UpdateController {
        UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger(subsystem: "app.solstone.tests", category: "evidence"),
            errorDomain: "app.solstone.tests.evidence",
            defaults: defaults
        ) { _, _ in nil }
    }

    private func repairContext() -> AppPlacementContext {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return AppPlacementContext(
            runningBundleURL: URL(fileURLWithPath: "/var/tmp/solstone.app", isDirectory: true),
            canonicalBundleURL: applicationsURL.appendingPathComponent("solstone.app", isDirectory: true),
            applicationsURL: applicationsURL
        )
    }
}
