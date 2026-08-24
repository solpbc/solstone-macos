// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Capture coordinator diagnostic evidence")
@MainActor
struct CaptureCoordinatorEvidenceTests {
    @Test func rawScreenPermissionMapping() async throws {
        let scenarios: [(
            prompted: Bool,
            preflight: Bool,
            screenGranted: Bool,
            microphoneCause: MicrophoneAuthorizationCause,
            expectedTruth: Bool,
            expectedCodes: [DiagnosticEvidenceCode],
            expectedStartCount: Int
        )] = [
            (true, true, true, .authorized, true, [.microphoneGranted, .screenRecordingGranted], 1),
            (true, false, false, .denied, false, [.microphoneNotGranted, .screenRecordingNotGranted], 0),
            (false, false, false, .denied, false, [.microphoneNotGranted, .screenRecordingUnavailable], 0),
        ]

        for scenario in scenarios {
            let harness = DiagnosticEvidenceHarness()
            let start = EvidenceStartSpy()
            let (coordinator, root) = try makeEvidenceCoordinator(
                recorder: harness.recorder,
                screenPermissionProvider: makeScreenPermissionProvider(
                    prompted: scenario.prompted,
                    preflight: scenario.preflight,
                    screenGranted: scenario.screenGranted
                ),
                isTerminating: { false },
                startOperation: { _, _ in
                    start.count += 1
                    return .committed
                }
            )
            defer { try? FileManager.default.removeItem(at: root) }
            coordinator.screenRecordingGranted = true
            coordinator.microphoneAuthorizationReader = { scenario.microphoneCause }

            await coordinator.checkPermissionsAndAutoStart()

            #expect(coordinator.screenRecordingGranted == scenario.expectedTruth)
            #expect(evidenceCodes(await harness.entries()) == scenario.expectedCodes)
            #expect(start.count == scenario.expectedStartCount)
        }
    }

    @Test func cdHashMismatchIsRecurringBeforeUnavailableAndLogsExactEvent() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = EvidenceLogEvents()
        let adapter = DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        var resetCount = 0
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(
                screenGranted: false,
                reset: { resetCount += 1 }
            ),
            isTerminating: { true },
            logAdapter: adapter
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .denied }

        await coordinator.checkPermissionsAndAutoStart()
        await coordinator.checkPermissionsAndAutoStart()

        let entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(resetCount == 2)
        #expect(events.events == [.screenRecordingCDHashMismatch, .screenRecordingCDHashMismatch])
        #expect(evidenceCodes(entries) == [
            .microphoneNotGranted,
            .screenRecordingCDHashMismatch,
            .screenRecordingUnavailable,
            .screenRecordingCDHashMismatch,
        ])
    }

    @Test func microphoneAndCaptureFamiliesDeduplicateIndependently() async throws {
        let harness = DiagnosticEvidenceHarness()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(prompted: false)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        coordinator.microphoneAuthorizationReader = { .authorized }
        coordinator.refreshMicrophoneAuthorization()
        coordinator.handleCaptureStateChange(.recording)
        coordinator.refreshMicrophoneAuthorization()
        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))
        coordinator.handleCaptureStateChange(.paused(reasons: [.lock]))

        let entries = await harness.entries()
        #expect(evidenceCodes(entries) == [
            .microphoneGranted,
            .captureOn,
            .capturePaused,
        ])
        #expect(entries.allSatisfy { $0.repeatCount == 1 })
    }

    @Test func nonPermissionStartFailurePublishesCaptureErrorThroughSameFamily() async throws {
        let harness = DiagnosticEvidenceHarness()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                .threw(TransitionFailure(message: "test failure", isPermissionError: false))
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await coordinator.startRecording()

        let entries = await harness.entries()
        #expect(coordinator.captureError == UICopy.ERROR_START_OBSERVING)
        #expect(evidenceCodes(entries) == [.captureError])
        #expect(entries[0].repeatCount == 1)
    }

    @Test func vetoedAndDroppedStartsDoNotPublishEvidence() async throws {
        for outcome in [TransitionOutcome.vetoed, .dropped] {
            let harness = DiagnosticEvidenceHarness()
            let (coordinator, root) = try makeEvidenceCoordinator(
                recorder: harness.recorder,
                screenPermissionProvider: makeScreenPermissionProvider(),
                startOperation: { _, _ in outcome }
            )
            defer { try? FileManager.default.removeItem(at: root) }

            await coordinator.startRecording()

            #expect(evidenceCodes(await harness.entries()).isEmpty)
        }
    }

    @Test func activateInstalledCallbackIsRequiredForCaptureEvidence() async throws {
        let activeHarness = DiagnosticEvidenceHarness()
        let (active, activeRoot) = try makeEvidenceCoordinator(
            recorder: activeHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(prompted: false)
        )
        defer { try? FileManager.default.removeItem(at: activeRoot) }
        active.microphoneAuthorizationReader = { .unknown }

        active.activate()
        active.captureManager.onStateChanged?(.recording)
        // startPermissionPolling() schedules its first pass on the main actor. The callback
        // stops its timer before this yield, so no live timer can outlast this test.
        await Task.yield()

        #expect(evidenceCodes(await activeHarness.entries()) == [
            .captureOn,
            .microphoneUnavailable,
            .screenRecordingUnavailable,
        ])
        #expect(!active.isPermissionPollingActiveForTesting)

        let inactiveHarness = DiagnosticEvidenceHarness()
        let (inactive, inactiveRoot) = try makeEvidenceCoordinator(
            recorder: inactiveHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(prompted: false)
        )
        defer { try? FileManager.default.removeItem(at: inactiveRoot) }

        #expect(inactive.captureManager.onStateChanged == nil)
        inactive.captureManager.onStateChanged?(.recording)
        #expect(evidenceCodes(await inactiveHarness.entries()).isEmpty)
    }

    @Test func autoStartSkipIsRecurringAndCoalesces() async throws {
        let harness = DiagnosticEvidenceHarness()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            isTerminating: { true }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        await coordinator.checkPermissionsAndAutoStart()
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()

        let entries = await harness.entries()
        #expect(evidenceCodes(entries) == [
            .microphoneGranted,
            .screenRecordingGranted,
            .permissionAutoStartSkipped,
        ])
        #expect(entries[2].repeatCount == 2)
        #expect(entries[2].lastAt == harness.clock.now)
    }

    @Test func microphoneRefreshDuringScreenAwaitRemainsLiveInBothDirections() async throws {
        try await assertRefreshDuringScreenAwait(initial: .authorized, refreshed: .denied, terminates: false)
        try await assertRefreshDuringScreenAwait(initial: .denied, refreshed: .authorized, terminates: true)
    }

    @Test func committedAndPermissionFailedStartsPublishScreenTruth() async throws {
        let committedHarness = DiagnosticEvidenceHarness()
        let (committed, committedRoot) = try makeEvidenceCoordinator(
            recorder: committedHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in .committed }
        )
        defer { try? FileManager.default.removeItem(at: committedRoot) }
        await committed.startRecording()
        #expect(evidenceCodes(await committedHarness.entries()) == [.screenRecordingGranted])

        let deniedHarness = DiagnosticEvidenceHarness()
        let (denied, deniedRoot) = try makeEvidenceCoordinator(
            recorder: deniedHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                .threw(TransitionFailure(message: "permission", isPermissionError: true))
            }
        )
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        await denied.startRecording()
        #expect(evidenceCodes(await deniedHarness.entries()) == [.screenRecordingNotGranted])
    }

    private func assertRefreshDuringScreenAwait(
        initial: MicrophoneAuthorizationCause,
        refreshed: MicrophoneAuthorizationCause,
        terminates: Bool
    ) async throws {
        let harness = DiagnosticEvidenceHarness()
        let gate = ScreenCheckGate()
        let provider = ScreenRecordingPermissionProvider(
            hasPrompted: { true },
            preflight: { true },
            checkScreenRecording: { await gate.waitForRelease() },
            resetPromptedFlag: {}
        )
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: provider,
            isTerminating: { terminates }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { initial }

        let check = Task { @MainActor in
            await coordinator.checkPermissionsAndAutoStart()
        }
        await gate.waitUntilEntered()
        coordinator.microphoneAuthorizationReader = { refreshed }
        coordinator.refreshMicrophoneAuthorization()
        await gate.release()
        await check.value

        #expect(coordinator.microphoneAuthorizationCause == refreshed)
        #expect(coordinator.microphoneGranted == (refreshed == .authorized))
        if terminates {
            #expect(evidenceCodes(await harness.entries()).last == .permissionAutoStartSkipped)
        }
    }
}

@MainActor
private final class EvidenceLogEvents {
    var events: [DiagnosticEvidenceLogEvent] = []
}

private actor ScreenCheckGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async -> Bool {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return true
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
