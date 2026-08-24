// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
@testable import solstone

@Suite("Diagnostic evidence end to end", .serialized)
@MainActor
struct DiagnosticEvidenceEndToEndTests {
    @Test func automaticProducerOrder() async throws {
        let harness = DiagnosticEvidenceHarness()
        let target = CaptureCoordinatorTarget()
        let defaultsName = "DiagnosticEvidenceEndToEndTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    recorder: recorder,
                    screenPermissionProvider: makeScreenPermissionProvider(),
                    captureStartOperation: { _, _ in
                        target.coordinator?.handleCaptureStateChange(.recording)
                        return .committed
                    }
                )
            },
            makeUpdateController: { _ in
                UpdateController(
                    feedURL: nil,
                    publicKey: nil,
                    log: Logger(subsystem: "app.solstone.tests", category: "evidence"),
                    errorDomain: "app.solstone.tests.evidence",
                    defaults: defaults
                ) { _, _ in nil }
            },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        target.coordinator = state.capture
        state.capture.microphoneAuthorizationReader = { .authorized }

        await state.capture.checkPermissionsAndAutoStart()

        // CaptureCoordinator.swift:262 reads microphone truth before the SCK await at :272,
        // so honest enqueue order is microphone before screen recording.
        #expect(evidenceCodes(await harness.entries()) == [
            .appLaunch,
            .microphoneGranted,
            .screenRecordingGranted,
            .captureOn,
        ])
    }
}

@MainActor
private final class CaptureCoordinatorTarget {
    weak var coordinator: CaptureCoordinator?
}
