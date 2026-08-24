// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
@testable import solstone

@Suite("Permission polling isolation", .serialized)
@MainActor
struct PermissionPollingIsolationTests {
    @Test func normalSharedStateRegistrationAndLaunch() async throws {
        let harness = DiagnosticEvidenceHarness()
        var registrations: [AppState] = []

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in AppState.forSnapshot(recorder: recorder) },
            registerSharedState: { registrations.append($0) },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)

        #expect(registrations.count == 1)
        #expect(registrations.first === state)
        #expect(evidenceCodes(await harness.entries()) == [.appLaunch])
        #expect(!state.capture.isPermissionPollingActiveForTesting)
    }

    @Test func repairAndSnapshotDoNotRegisterSharedState() {
        let original = AppState.shared
        defer { AppState.shared = original }
        AppState.shared = nil
        var registrations = 0
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let context = AppPlacementContext(
            runningBundleURL: URL(fileURLWithPath: "/var/tmp/solstone.app", isDirectory: true),
            canonicalBundleURL: applicationsURL.appendingPathComponent("solstone.app", isDirectory: true),
            applicationsURL: applicationsURL
        )
        let repairCoordinator = AppPlacementRepairCoordinator { _ in }

        _ = AppState.forSnapshot()
        let startup: Void? = SolstoneStartupComposition.makeNormalStartup(
            decision: .repair(context),
            repairCoordinator: repairCoordinator,
            automaticObservationPipelineEnabled: false,
            registerSharedState: { _ in registrations += 1 },
            makeStartup: { _, _ in () }
        )

        #expect(startup == nil)
        #expect(registrations == 0)
        #expect(AppState.shared == nil)
    }

    @Test func realAutomaticCompositionPublishesThroughInstalledCallback() async throws {
        let original = AppState.shared
        let defaults = DefaultsSnapshot()
        defer {
            defaults.restore()
            AppState.shared = original
        }

        let harness = DiagnosticEvidenceHarness()
        let scheduler = PermissionPollTestScheduler()
        let start = EvidenceStartSpy()
        let target = CaptureCoordinatorTarget()

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: true,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    recorder: recorder,
                    screenPermissionProvider: makeScreenPermissionProvider(),
                    permissionPollScheduler: scheduler.scheduler,
                    captureStartOperation: { _, _ in
                        start.count += 1
                        target.coordinator?.captureManager.onStateChanged?(.recording)
                        return .committed
                    }
                )
            },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        target.coordinator = state.capture
        state.capture.microphoneAuthorizationReader = { .authorized }

        #expect(scheduler.armCount == 1)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await scheduler.fireOutstandingPasses()
        try await harness.waitForRecorderTasks(4)
        try await harness.waitForStoreCalls(1)
        #expect(harness.recorderTaskStartCount == 4)
        #expect(harness.storeCallCount >= 1)

        #expect(start.count == 1)
        #expect(state.capture.isRecording)
        #expect(!state.capture.isPermissionPollingActiveForTesting)
        #expect(evidenceCodes(await harness.entries()) == [
            .appLaunch,
            .screenRecordingGranted,
            .microphoneGranted,
            .captureOn,
        ])
    }

    @Test func disabledCompositionDoesNotArmOrInstallCaptureCallback() throws {
        let harness = DiagnosticEvidenceHarness()
        let scheduler = PermissionPollTestScheduler()
        let start = EvidenceStartSpy()
        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    recorder: recorder,
                    permissionPollScheduler: scheduler.scheduler,
                    captureStartOperation: { _, _ in
                        start.count += 1
                        return .committed
                    }
                )
            },
            registerSharedState: { _ in },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)

        #expect(scheduler.armCount == 0)
        #expect(state.capture.captureManager.onStateChanged == nil)
        #expect(start.count == 0)
    }

    @Test func activationStopsAndTearsDownInjectedPermissionPolling() throws {
        let defaults = DefaultsSnapshot()
        defer { defaults.restore() }

        let scheduler = PermissionPollTestScheduler()
        let target = CaptureCoordinatorTarget()
        var root: URL?
        defer {
            if let root {
                try? FileManager.default.removeItem(at: root)
            }
        }

        do {
            let (coordinator, fixtureRoot) = try makeEvidenceCoordinator(
                recorder: .dormant,
                screenPermissionProvider: makeScreenPermissionProvider(prompted: false),
                permissionPollScheduler: scheduler.scheduler
            )
            root = fixtureRoot
            target.coordinator = coordinator

            coordinator.activate()

            #expect(scheduler.armCount == 1)
            #expect(scheduler.outstandingArmCount == 1)

            let callback = try #require(coordinator.captureManager.onStateChanged)
            callback(.recording)

            #expect(scheduler.cancellationCount == 1)
            #expect(scheduler.outstandingArmCount == 0)

            callback(.idle)

            #expect(scheduler.armCount == 2)
            #expect(scheduler.outstandingArmCount == 1)
        }

        #expect(target.coordinator == nil)
        #expect(scheduler.cancellationCount == 2)
        #expect(scheduler.outstandingArmCount == 0)
    }

    @Test func unactivatedCoordinatorHasNoCallbackOrCaptureEvidence() async throws {
        let harness = DiagnosticEvidenceHarness()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider()
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(coordinator.captureManager.onStateChanged == nil)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.captureManager.onStateChanged?(.recording)
        #expect(evidenceCodes(await harness.entries()).isEmpty)
    }

    @Test func installedCaptureCallbackMatrixUsesInertPolling() async throws {
        let original = AppState.shared
        let defaults = DefaultsSnapshot()
        defer {
            defaults.restore()
            AppState.shared = original
        }

        let harness = DiagnosticEvidenceHarness()
        let scheduler = PermissionPollTestScheduler()
        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: true,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    recorder: recorder,
                    screenPermissionProvider: makeScreenPermissionProvider(prompted: false),
                    permissionPollScheduler: scheduler.scheduler
                )
            },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        let callback = try #require(state.capture.captureManager.onStateChanged)

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.recording)
        _ = await harness.canonicalBytes()
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.paused(reasons: [.user]))
        let pausedBytes = try #require(await harness.canonicalBytes())
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.paused(reasons: [.lock]))
        #expect(await harness.canonicalBytes() == pausedBytes)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.error("error-a"))
        let errorBytes = try #require(await harness.canonicalBytes())
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.error("error-b"))
        #expect(await harness.canonicalBytes() == errorBytes)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.idle)
        let idleBytes = try #require(await harness.canonicalBytes())
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        callback(.idle)
        let finalBytes = try #require(await harness.canonicalBytes())
        #expect(finalBytes == idleBytes)

        #expect(evidenceCodes(await harness.entries()) == [.appLaunch, .captureOn, .capturePaused, .captureError, .captureOff])
        let canonicalText = String(decoding: finalBytes, as: UTF8.self)
        #expect(!canonicalText.contains("error-a"))
        #expect(!canonicalText.contains("error-b"))
        #expect(!canonicalText.contains("user"))
        #expect(!canonicalText.contains("lock"))
        #expect(scheduler.outstandingArmCount == 1, "Repeated idle correctly leaves the inert poll arm active.")
    }

    @Test func unavailableEvidenceStorageDoesNotBlockCompositionOrCapture() async throws {
        let original = AppState.shared
        let defaults = DefaultsSnapshot()
        defer {
            defaults.restore()
            AppState.shared = original
        }

        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = InMemoryDiagnosticEvidenceBytesStore()
        bytes.readOverride = .failed
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let scheduler = PermissionPollTestScheduler()
        let start = EvidenceStartSpy()
        let target = CaptureCoordinatorTarget()
        var registrations = 0

        let startup = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: true,
            evidenceNow: { clock.now },
            makeEvidenceStore: { _ in store },
            makeRecorder: { _, _ in recorder },
            makeState: { evidenceRecorder, _ in
                AppState.forSnapshot(
                    recorder: evidenceRecorder,
                    screenPermissionProvider: makeScreenPermissionProvider(),
                    permissionPollScheduler: scheduler.scheduler,
                    captureStartOperation: { _, _ in
                        start.count += 1
                        target.coordinator?.captureManager.onStateChanged?(.recording)
                        return .committed
                    }
                )
            },
            registerSharedState: { _ in registrations += 1 },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        )
        let state = try #require(startup)
        target.coordinator = state.capture
        state.capture.microphoneAuthorizationReader = { .authorized }

        clock.now = clock.now.addingTimeInterval(1)
        await scheduler.fireOutstandingPasses()
        clock.now = clock.now.addingTimeInterval(1)
        state.capture.publishScreenRecordingPermission(.granted)

        #expect(registrations == 1)
        #expect(state.capture.initialPermissionCheckComplete)
        #expect(state.capture.screenRecordingGranted)
        #expect(state.capture.isRecording)
        #expect(start.count == 1)
        await recorder.drain()
        #expect(await store.read() == .unavailable)
    }

    private func testUpdateController() -> UpdateController {
        let defaults = UserDefaults(suiteName: "PermissionPollingIsolation.\(UUID().uuidString)")!
        return UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger(subsystem: "app.solstone.tests", category: "permission-polling"),
            errorDomain: "app.solstone.tests.permission-polling",
            defaults: defaults
        ) { _, _ in nil }
    }
}

@MainActor
private final class CaptureCoordinatorTarget {
    weak var coordinator: CaptureCoordinator?
}

@MainActor
private final class DefaultsSnapshot {
    private let keys = [
        "audioMuteExpiration", "audioMuteIndefinite", "videoMuteExpiration",
        "videoMuteIndefinite", "pauseExpiration", "pauseIndefinite",
        "hasPromptedScreenRecording",
    ]
    private let values: [String: Any?]

    init() {
        values = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
    }

    func restore() {
        for key in keys {
            if let value = values[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
