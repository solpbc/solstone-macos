// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
@testable import solstone

@Suite("Diagnostic evidence failure isolation")
@MainActor
struct DiagnosticEvidenceFailureIsolationTests {
    @Test func unavailableEvidenceDoesNotBlockPermissionOrCaptureState() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.readOverride = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: recorder,
            screenPermissionProvider: makeScreenPermissionProvider(prompted: false)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .denied }

        await coordinator.checkPermissionsAndAutoStart()
        coordinator.handleCaptureStateChange(.recording)
        await recorder.drain()

        #expect(coordinator.initialPermissionCheckComplete)
        #expect(!coordinator.screenRecordingGranted)
        #expect(coordinator.isRecording)
    }

    @Test func unavailableLaunchEvidenceDoesNotBlockNormalStartup() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.readOverride = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let defaultsName = "DiagnosticEvidenceFailureStartup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let stateFactory = StartupStateFactorySpy()
        let updateAnnouncementRegistration = UpdateAnnouncementRegistrationSpy()
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { clock.now },
            makeEvidenceStore: { _ in store },
            makeRecorder: { _, _ in recorder },
            makeState: { recorder, _ in
                let state = AppState.forSnapshot(recorder: recorder)
                stateFactory.state = state
                return state
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
            registerUpdateAnnouncement: { _ in
                updateAnnouncementRegistration.count += 1
            },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        let factoryState = try #require(stateFactory.state)
        await recorder.drain()

        #expect((await store.read()) == .unavailable)
        #expect(updateAnnouncementRegistration.count == 1)
        #expect(state === factoryState)
    }

    @Test func unavailableEvidenceDoesNotBlockAutoStart() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.readOverride = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let start = EvidenceStartSpy()
        let target = EvidenceCoordinatorTarget()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            isTerminating: { false },
            startOperation: { _, _ in
                start.count += 1
                target.coordinator?.handleCaptureStateChange(.recording)
                return .committed
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        target.coordinator = coordinator
        coordinator.microphoneAuthorizationReader = { .authorized }

        await coordinator.checkPermissionsAndAutoStart()
        await recorder.drain()

        #expect(start.count == 1)
        #expect(coordinator.isRecording)
        #expect(coordinator.initialPermissionCheckComplete)
    }
}

@MainActor
private final class EvidenceCoordinatorTarget {
    weak var coordinator: CaptureCoordinator?
}

@MainActor
private final class StartupStateFactorySpy {
    var state: AppState?
}

@MainActor
private final class UpdateAnnouncementRegistrationSpy {
    var count = 0
}
