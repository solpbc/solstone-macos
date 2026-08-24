// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
import Testing
@testable import UpdateKit
@testable import solstone

@Suite("AppKit termination", .serialized)
@MainActor
struct AppKitTerminationTests {
    @Test func nilCoordinatorReturnsLaterAndRepliesTrue() {
        var replies: [Bool] = []
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { nil },
            reply: { replies.append($0) }
        )

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        #expect(replies == [true])
    }

    @Test func unpreparedTerminationRecordsAttemptAndRepliesTrue() async throws {
        let harness = DiagnosticEvidenceHarness()
        let coordinator = makeCoordinator(recorder: harness.recorder)
        let replies = LockedArray<Bool>([])
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { replies.append($0) }
        )

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        try await waitUntil(timeout: .seconds(5)) {
            replies.all == [true]
        }

        #expect(evidenceCodes(await harness.entries()) == [
            .terminationAppKitBegan,
            .terminationCommitted,
        ])
    }

    @Test func duplicatePreparedCallbacksUseOneDrainReplyEachCallbackAndOneAttemptEvidenceEntry() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = GatedDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let logEvents = AppKitTerminationLogEvents()
        let coordinator = makeCoordinator(
            recorder: recorder,
            logAdapter: DiagnosticEvidenceLoggingAdapter { logEvents.events.append($0) }
        )
        await coordinator.prepareForUpdaterInstall()
        let replies = LockedArray<Bool>([])
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { replies.append($0) }
        )

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        #expect(await Task.detached { bytes.waitForFirstRead() }.value)
        #expect(seam.applicationShouldTerminate() == .terminateLater)
        await Task.yield()
        #expect(coordinator.externalReplyDrainCountForTesting == 1)
        bytes.releaseFirstRead()
        try await waitUntil(timeout: .seconds(5)) {
            replies.all.count == 2
        }

        #expect(replies.all == [true, true])
        #expect(coordinator.externalReplyDrainCountForTesting == 1)
        await recorder.drain()
        guard let stored = bytes.stored,
              let envelope = try? DiagnosticEvidenceEnvelope.decoded(from: stored, now: clock.now) else {
            Issue.record("AppKit attempt evidence was not durable")
            return
        }
        #expect(evidenceCodes(envelope.entries) == [.terminationCommitted, .terminationAppKitBegan])
        let attempts = envelope.entries.filter { $0.code == .terminationAppKitBegan }
        #expect(attempts.map(\.repeatCount) == [1])
        #expect(logEvents.events.filter { $0 == .terminationAppKitBegan } == [.terminationAppKitBegan])
    }

    @Test func duplicateUnpreparedCallbacksUseOneDrain() async throws {
        let gate = AppKitPreparationGate()
        let coordinator = AppQuitCoordinator(
            dependencies: .init(prepareForQuit: {
                await gate.wait()
            }),
            evidenceDrainCutoffSeconds: 0.05
        )
        let replies = LockedArray<Bool>([])
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { replies.append($0) }
        )

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        try await waitUntil(timeout: .seconds(5)) {
            await gate.started
        }
        #expect(seam.applicationShouldTerminate() == .terminateLater)
        gate.release()
        try await waitUntil(timeout: .seconds(5)) {
            replies.all.count == 2
        }

        #expect(replies.all == [true, true])
        #expect(coordinator.externalReplyDrainCountForTesting == 1)
    }

    @Test func mixedWitnessIsDurableWhenPreparedReplyFires() async throws {
        let harness = DiagnosticEvidenceHarness()
        let logEvents = AppKitTerminationLogEvents()
        let config = AppConfig(
            serverURL: "https://journal.example.test",
            serverKey: "test-key",
            serviceMode: .external
        )
        let delivery = InMemoryLastJournalDeliveryStore(writeResult: .failed)
        guard let state = SolstoneStartupComposition.makeNormalStartup(
            decision: .allowed(.developerBypass),
            automaticObservationPipelineEnabled: false,
            evidenceNow: { harness.clock.now },
            makeEvidenceStore: { _ in harness.store },
            makeRecorder: { _, _ in harness.recorder },
            makeState: { recorder, _ in
                AppState.forSnapshot(
                    config: config,
                    lastDeliveryStore: delivery,
                    recorder: recorder,
                    logAdapter: DiagnosticEvidenceLoggingAdapter { logEvents.events.append($0) }
                )
            },
            registerSharedState: { _ in },
            makeUpdateController: { _ in testUpdateController() },
            registerUpdateAnnouncement: { _ in },
            makeStartup: { state, _ in state }
        ) else {
            Issue.record("normal startup was unexpectedly unavailable")
            return
        }
        guard case .identified(let proof) = state.currentJournalIdentity() else {
            Issue.record("snapshot identity was not available")
            return
        }

        state.uploadCoordinator.handleProgressEvent(
            .uploadSucceeded(segment: "x", journalFingerprint: proof.value)
        )
        state.terminationDrainer = NeverCompletingAppKitTerminationDrainer()
        state.terminationDrainRunner = { operation in
            try await withTimeout(seconds: 0.05, operation: operation)
        }
        guard let coordinator = state.appQuitCoordinator else {
            Issue.record("snapshot app quit coordinator was unexpectedly unavailable")
            return
        }
        coordinator.requestAppOwnedQuit()
        try await waitUntil(timeout: .seconds(5)) {
            await coordinator.isPrepared
        }

        let replyCodes = LockedValue<[DiagnosticEvidenceCode]>()
        let replies = LockedArray<Bool>([])
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { proceed in
                replies.append(proceed)
                replyCodes.set(codesInCanonicalBytes(harness.bytes.stored, now: harness.clock.now))
            }
        )

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        try await waitUntil(timeout: .seconds(5)) {
            replies.all == [true]
        }

        #expect(replyCodes.current == [
            .appLaunch,
            .deliveryWriteFailed,
            .terminationCommitted,
            .terminationDrainTimeout,
            .terminationAppKitBegan,
        ])
        #expect(logEvents.events == [
            .deliveryWriteFailed,
            .terminationCommitted,
            .terminationDrainTimeout,
            .terminationAppKitBegan,
        ])
    }

    @Test func stalledEvidenceDrainDoesNotChangeSettingsRestartOutcome() async throws {
        let healthyHarness = DiagnosticEvidenceHarness()
        let healthy = try await settingsRestartOutcome(recorder: healthyHarness.recorder)

        let bytes = GatedDiagnosticEvidenceBytesStore()
        let store = DiagnosticEvidenceStore(bytesStore: bytes)
        let recorder = DiagnosticEvidenceRecorder(store: store)
        let stalled = try await settingsRestartOutcome(
            recorder: recorder,
            gatedBytes: bytes
        )

        #expect(stalled.events == healthy.events)
        #expect(stalled.replyElapsed < .milliseconds(500))
        #expect(stalled.events == [
            "committed:true",
            "prepared",
            "marker:settingsRestart",
            "reply:true",
            "replacement",
            "terminate",
        ])
    }

    @Test func updaterRecoveryRepliesFalseAndRearmsAppKitAttempt() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let bytes = GatedDiagnosticEvidenceBytesStore(gatedReadNumber: 2)
        let store = DiagnosticEvidenceStore(bytesStore: bytes, now: { clock.now })
        let recorder = DiagnosticEvidenceRecorder(store: store, now: { clock.now })
        let events = LockedArray<String>([])
        let diagnosticEvents = LockedArray<DiagnosticEvidenceLogEvent>([])
        let coordinator = AppQuitCoordinator(
            dependencies: .init(
                setCommitted: { events.append("committed:\($0)") },
                writeMarker: { events.append("marker:\($0)") },
                invalidateMarker: { events.append("invalidate") },
                terminate: { events.append("terminate") },
                launchReplacement: { events.append("replacement") }
            ),
            recorder: recorder,
            logAdapter: DiagnosticEvidenceLoggingAdapter { diagnosticEvents.append($0) },
            evidenceDrainCutoffSeconds: 0.05
        )
        let recoveryChecks = LockedArray<Bool>([])
        let scheduledRecovery = LockedValue<@MainActor () -> Void>()
        let update = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger(subsystem: "app.solstone.tests", category: "appkit-termination"),
            errorDomain: "app.solstone.tests.appkit-termination",
            preInstallFinalizer: {
                await coordinator.prepareForUpdaterInstall()
            },
            installFailureRecovery: {
                coordinator.resetAfterFailedUpdaterInstall()
            },
            postInstallRecoveryScheduler: { check in
                scheduledRecovery.set(check)
            },
            terminationBegan: {
                let began = false
                recoveryChecks.append(began)
                return began
            }
        ) { _, _ in nil }
        update.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.0", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .staged)
        )
        update.recordImmediateStagedInstallHandler {
            events.append("handler")
        }

        update.installStagedUpdate()
        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("handler") && scheduledRecovery.current != nil
        }
        await recorder.drain()

        let replies = LockedArray<Bool>([])
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { replies.append($0) }
        )
        #expect(seam.applicationShouldTerminate() == .terminateLater)
        #expect(diagnosticEvents.all == [.terminationCommitted, .terminationAppKitBegan])
        #expect(await Task.detached { bytes.waitForFirstRead() }.value)
        scheduledRecovery.current?()
        try await waitUntil(timeout: .seconds(5)) {
            replies.all == [false]
        }

        #expect(recoveryChecks.all == [false])
        #expect(!events.all.contains("terminate"))
        #expect(!events.all.contains("replacement"))

        bytes.releaseFirstRead()
        await recorder.drain()
        #expect(codesInCanonicalBytes(bytes.stored, now: clock.now).contains(.terminationAppKitBegan))

        #expect(seam.applicationShouldTerminate() == .terminateLater)
        #expect(diagnosticEvents.all == [
            .terminationCommitted,
            .terminationAppKitBegan,
            .terminationAppKitBegan,
            .terminationCommitted,
        ])
        try await waitUntil(timeout: .seconds(5)) {
            replies.all == [false, true]
        }
        await recorder.drain()
        guard let stored = bytes.stored,
              let envelope = try? DiagnosticEvidenceEnvelope.decoded(from: stored, now: clock.now) else {
            Issue.record("rearmed AppKit evidence was not durable")
            return
        }
        let attempts = envelope.entries.filter { $0.code == .terminationAppKitBegan }
        #expect(attempts.map(\.repeatCount) == [2])
        #expect(!events.all.contains("terminate"))
        #expect(!events.all.contains("replacement"))
    }

    private func makeCoordinator(
        recorder: DiagnosticEvidenceRecorder,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live
    ) -> AppQuitCoordinator {
        AppQuitCoordinator(
            dependencies: AppQuitCoordinator.Dependencies(),
            recorder: recorder,
            logAdapter: logAdapter,
            evidenceDrainCutoffSeconds: 0.05
        )
    }

    private func settingsRestartOutcome(
        recorder: DiagnosticEvidenceRecorder,
        gatedBytes: GatedDiagnosticEvidenceBytesStore? = nil
    ) async throws -> (events: [String], replyElapsed: Duration) {
        let events = LockedArray<String>([])
        let gate = AppKitPreparationGate()
        let coordinator = AppQuitCoordinator(
            dependencies: .init(
                setCommitted: { events.append("committed:\($0)") },
                writeMarker: { events.append("marker:\($0)") },
                prepareForQuit: {
                    events.append("prepared")
                    await gate.wait()
                },
                terminate: { events.append("terminate") },
                launchReplacement: { events.append("replacement") }
            ),
            recorder: recorder,
            evidenceDrainCutoffSeconds: 0.05
        )
        let seam = AppKitTerminationSeam(
            coordinatorLookup: { coordinator },
            reply: { events.append("reply:\($0)") }
        )

        coordinator.requestSettingsRestart()
        try await waitUntil(timeout: .seconds(5)) {
            await gate.started
        }
        let replyStartedAt = ContinuousClock.now
        #expect(seam.applicationShouldTerminate() == .terminateLater)
        gate.release()
        if let gatedBytes {
            #expect(await Task.detached { gatedBytes.waitForFirstRead() }.value)
        }
        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        gatedBytes?.releaseFirstRead()
        return (events.all, replyStartedAt.duration(to: .now))
    }

    private func testUpdateController() -> UpdateController {
        UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger(subsystem: "app.solstone.tests", category: "appkit-termination"),
            errorDomain: "app.solstone.tests.appkit-termination"
        ) { _, _ in nil }
    }

    private func codesInCanonicalBytes(_ bytes: Data?, now: Date) -> [DiagnosticEvidenceCode] {
        guard let bytes,
              let envelope = try? DiagnosticEvidenceEnvelope.decoded(from: bytes, now: now) else {
            return []
        }
        return envelope.entries.map(\.code)
    }
}

@MainActor
private final class AppKitPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor NeverCompletingAppKitTerminationDrainer: TerminationDraining {
    func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) async {}

    func waitForCompletion() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class AppKitTerminationLogEvents {
    var events: [DiagnosticEvidenceLogEvent] = []
}
