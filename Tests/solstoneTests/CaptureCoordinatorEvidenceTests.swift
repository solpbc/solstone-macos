// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Capture coordinator diagnostic evidence")
@MainActor
struct CaptureCoordinatorEvidenceTests {
    @Test func rawScreenPermissionMapping() async throws {
        let harness = DiagnosticEvidenceHarness()
        let values = MutableScreenPermissionProvider()
        values.granted = true
        let start = EvidenceStartSpy()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: values.provider,
            startOperation: { _, _ in
                start.count += 1
                return .committed
            }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        var entries = await harness.entries()
        #expect(coordinator.screenRecordingGranted)
        #expect(start.count == 1)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted])
        #expect(entries.map(\.repeatCount) == [1, 1])
        let grantedBytes = try #require(harness.bytes.stored)

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted])
        #expect(entries.map(\.repeatCount) == [1, 1])
        #expect(harness.bytes.stored == grantedBytes)

        values.preflight = false
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted])
        #expect(entries.map(\.repeatCount) == [1, 1, 1])

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.handleCaptureStateChange(.error("interleaved"))
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1])
        let notGrantedBytes = try #require(harness.bytes.stored)

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1])
        #expect(harness.bytes.stored == notGrantedBytes)

        values.prompted = false
        values.preflight = false
        values.granted = false
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError, .screenRecordingUnavailable])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1, 1])

        coordinator.microphoneAuthorizationReader = { .unknown }
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.refreshMicrophoneAuthorization()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError, .screenRecordingUnavailable, .microphoneUnavailable])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1, 1, 1])
        let unavailableBytes = try #require(harness.bytes.stored)

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError, .screenRecordingUnavailable, .microphoneUnavailable])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1, 1, 1])
        #expect(harness.bytes.stored == unavailableBytes)

        values.prompted = true
        values.preflight = false
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(start.count == 2)
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .screenRecordingNotGranted, .captureError, .screenRecordingUnavailable, .microphoneUnavailable, .screenRecordingNotGranted])
        #expect(entries.map(\.repeatCount) == [1, 1, 1, 1, 1, 1, 1])
    }

    @Test func mismatchResetAndRepromptSequence() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = EvidenceLogEvents()
        let adapter = DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        let values = MutableScreenPermissionProvider()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: values.provider,
            isTerminating: { true },
            logAdapter: adapter
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .denied }

        await coordinator.checkPermissionsAndAutoStart()
        await coordinator.checkPermissionsAndAutoStart()
        values.prompted = true
        await coordinator.checkPermissionsAndAutoStart()

        let entries = await harness.entries()
        #expect(!coordinator.screenRecordingGranted)
        #expect(values.resetCount == 2)
        #expect(events.events == [.screenRecordingCDHashMismatch, .screenRecordingCDHashMismatch])
        #expect(evidenceCodes(entries) == [
            .screenRecordingCDHashMismatch,
            .screenRecordingUnavailable,
            .microphoneNotGranted,
            .screenRecordingCDHashMismatch,
        ])
    }

    @Test func microphoneAndCaptureFamiliesDeduplicateIndependently() async throws {
        let cases: [(MicrophoneAuthorizationCause, DiagnosticEvidenceCode)] = [
            (.authorized, .microphoneGranted),
            (.denied, .microphoneNotGranted),
            (.restricted, .microphoneNotGranted),
            (.notDetermined, .microphoneNotGranted),
            (.unknown, .microphoneUnavailable),
        ]
        var bytesByClosedCode: [DiagnosticEvidenceCode: Data] = [:]

        for (cause, expectedCode) in cases {
            let loopHarness = DiagnosticEvidenceHarness()
            let (loopCoordinator, loopRoot) = try makeEvidenceCoordinator(
                recorder: loopHarness.recorder,
                screenPermissionProvider: makeScreenPermissionProvider(prompted: true, preflight: false)
            )
            defer { try? FileManager.default.removeItem(at: loopRoot) }
            loopHarness.clock.now = loopHarness.clock.now.addingTimeInterval(1)
            loopCoordinator.publishScreenRecordingPermission(.notGranted)
            loopCoordinator.microphoneAuthorizationReader = { cause }
            loopHarness.clock.now = loopHarness.clock.now.addingTimeInterval(1)
            await loopCoordinator.checkPermissionsAndAutoStart()
            let loopEntries = await loopHarness.entries()
            let loopBytes = try #require(await loopHarness.canonicalBytes())
            #expect(evidenceCodes(loopEntries) == [.screenRecordingNotGranted, expectedCode])

            let refreshHarness = DiagnosticEvidenceHarness()
            let (refreshCoordinator, refreshRoot) = try makeEvidenceCoordinator(
                recorder: refreshHarness.recorder,
                screenPermissionProvider: makeScreenPermissionProvider(prompted: true, preflight: false)
            )
            defer { try? FileManager.default.removeItem(at: refreshRoot) }
            refreshHarness.clock.now = refreshHarness.clock.now.addingTimeInterval(1)
            refreshCoordinator.publishScreenRecordingPermission(.notGranted)
            refreshCoordinator.microphoneAuthorizationReader = { cause }
            refreshHarness.clock.now = refreshHarness.clock.now.addingTimeInterval(1)
            refreshCoordinator.refreshMicrophoneAuthorization()
            let refreshEntries = await refreshHarness.entries()
            let refreshBytes = try #require(await refreshHarness.canonicalBytes())
            #expect(evidenceCodes(refreshEntries) == [.screenRecordingNotGranted, expectedCode])
            #expect(loopBytes == refreshBytes)

            if let firstBytes = bytesByClosedCode[expectedCode] {
                #expect(loopBytes == firstBytes)
            } else {
                bytesByClosedCode[expectedCode] = loopBytes
            }
        }

        let harness = DiagnosticEvidenceHarness()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(prompted: false)
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .denied }
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.refreshMicrophoneAuthorization()
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.publishScreenRecordingPermission(.unavailable)
        coordinator.microphoneAuthorizationReader = { .restricted }
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.refreshMicrophoneAuthorization()
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.handleCaptureStateChange(.paused(reasons: [.user]))
        coordinator.microphoneAuthorizationReader = { .notDetermined }
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.refreshMicrophoneAuthorization()

        let entries = await harness.entries()
        #expect(evidenceCodes(entries) == [.microphoneNotGranted, .screenRecordingUnavailable, .capturePaused])
        #expect(entries[0].repeatCount == 1)
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

    @Test func autoStartSkipIsRecurringAndCoalesces() async throws {
        let terminatingHarness = DiagnosticEvidenceHarness()
        let terminatingEvents = EvidenceLogEvents()
        let (terminating, terminatingRoot) = try makeEvidenceCoordinator(
            recorder: terminatingHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            isTerminating: { true },
            logAdapter: DiagnosticEvidenceLoggingAdapter { terminatingEvents.events.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: terminatingRoot) }
        terminating.microphoneAuthorizationReader = { .authorized }
        terminatingHarness.clock.now = terminatingHarness.clock.now.addingTimeInterval(1)
        let firstSkipTime = terminatingHarness.clock.now
        await terminating.checkPermissionsAndAutoStart()
        terminatingHarness.clock.now = terminatingHarness.clock.now.addingTimeInterval(1)
        let secondSkipTime = terminatingHarness.clock.now
        await terminating.checkPermissionsAndAutoStart()

        let terminatingEntries = await terminatingHarness.entries()
        #expect(evidenceCodes(terminatingEntries) == [.screenRecordingGranted, .microphoneGranted, .permissionAutoStartSkipped])
        #expect(terminatingEntries[2] == DiagnosticEvidenceEntry(
            code: .permissionAutoStartSkipped,
            firstAt: firstSkipTime,
            lastAt: secondSkipTime,
            repeatCount: 2
        ))
        #expect(terminatingEvents.events == [.permissionAutoStartSkipped, .permissionAutoStartSkipped])

        let nonterminatingHarness = DiagnosticEvidenceHarness()
        let nonterminatingEvents = EvidenceLogEvents()
        let nonterminatingStart = EvidenceStartSpy()
        let nonterminatingTarget = EvidenceCaptureCoordinatorTarget()
        let (nonterminating, nonterminatingRoot) = try makeEvidenceCoordinator(
            recorder: nonterminatingHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                nonterminatingStart.count += 1
                nonterminatingTarget.coordinator?.captureManager.onStateChanged?(.recording)
                return .committed
            },
            logAdapter: DiagnosticEvidenceLoggingAdapter { nonterminatingEvents.events.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: nonterminatingRoot) }
        nonterminatingTarget.coordinator = nonterminating
        nonterminating.captureManager.onStateChanged = { [weak nonterminating] state in
            nonterminating?.handleCaptureStateChange(state)
        }
        nonterminating.microphoneAuthorizationReader = { .authorized }
        nonterminatingHarness.clock.now = nonterminatingHarness.clock.now.addingTimeInterval(1)
        await nonterminating.checkPermissionsAndAutoStart()
        nonterminatingHarness.clock.now = nonterminatingHarness.clock.now.addingTimeInterval(1)
        await nonterminating.checkPermissionsAndAutoStart()
        let nonterminatingEntries = await nonterminatingHarness.entries()
        #expect(nonterminatingStart.count == 1)
        #expect(!evidenceCodes(nonterminatingEntries).contains(.permissionAutoStartSkipped))
        #expect(nonterminatingEvents.events.isEmpty)

        let closedGuards: [(String, ScreenRecordingPermissionProvider, MicrophoneAuthorizationCause, @MainActor (CaptureCoordinator) -> Void)] = [
            ("screen not granted", makeScreenPermissionProvider(prompted: true, preflight: false), .authorized, { _ in }),
            ("screen unavailable", makeScreenPermissionProvider(prompted: false, preflight: false, screenGranted: false), .authorized, { _ in }),
            ("microphone denied", makeScreenPermissionProvider(), .denied, { _ in }),
            ("microphone restricted", makeScreenPermissionProvider(), .restricted, { _ in }),
            ("microphone not determined", makeScreenPermissionProvider(), .notDetermined, { _ in }),
            ("microphone unknown", makeScreenPermissionProvider(), .unknown, { _ in }),
            ("already recording", makeScreenPermissionProvider(), .authorized, { coordinator in
                coordinator.captureManager.onStateChanged = { [weak coordinator] state in
                    coordinator?.handleCaptureStateChange(state)
                }
                coordinator.captureManager.onStateChanged?(.recording)
            }),
            ("user paused", makeScreenPermissionProvider(), .authorized, { coordinator in
                coordinator.captureManager.onStateChanged = { [weak coordinator] state in
                    coordinator?.handleCaptureStateChange(state)
                }
                coordinator.captureManager.onStateChanged?(.paused(reasons: [.user]))
            }),
            ("recovery scheduled", makeScreenPermissionProvider(), .authorized, { coordinator in
                coordinator.captureManager.lifecycleTransitionToError(
                    message: "transient",
                    error: CaptureManager.CaptureError.noDisplaysAvailable,
                    trigger: "test"
                )
            }),
        ]

        for (name, provider, cause, closeGuard) in closedGuards {
            let harness = DiagnosticEvidenceHarness()
            let events = EvidenceLogEvents()
            let start = EvidenceStartSpy()
            let (coordinator, root) = try makeEvidenceCoordinator(
                recorder: harness.recorder,
                screenPermissionProvider: provider,
                startOperation: { _, _ in
                    start.count += 1
                    return .committed
                },
                logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
            )
            defer { try? FileManager.default.removeItem(at: root) }
            coordinator.microphoneAuthorizationReader = { cause }
            harness.clock.now = harness.clock.now.addingTimeInterval(1)
            closeGuard(coordinator)
            harness.clock.now = harness.clock.now.addingTimeInterval(1)
            await coordinator.checkPermissionsAndAutoStart()
            let entries = await harness.entries()
            #expect(start.count == 0, "\(name) must block automatic start")
            #expect(!evidenceCodes(entries).contains(.permissionAutoStartSkipped), "\(name) must not publish a terminating skip")
            #expect(events.events.isEmpty, "\(name) must not log a terminating skip")
        }
    }

    @Test func microphoneRefreshDuringScreenAwaitRemainsLiveInBothDirections() async throws {
        try await assertRefreshDuringScreenAwait(initial: .authorized, refreshed: .denied, expectedStarts: 0)
        try await assertRefreshDuringScreenAwait(initial: .denied, refreshed: .authorized, expectedStarts: 1)
    }

    @Test func allScreenWritersUsePublicationSeam() async throws {
        let committedHarness = DiagnosticEvidenceHarness()
        let permissionValues = MutableScreenPermissionProvider()
        let committedTarget = EvidenceCaptureCoordinatorTarget()
        let (committed, committedRoot) = try makeEvidenceCoordinator(
            recorder: committedHarness.recorder,
            screenPermissionProvider: permissionValues.provider,
            startOperation: { _, _ in
                committedTarget.coordinator?.captureManager.onStateChanged?(.recording)
                return .committed
            }
        )
        defer { try? FileManager.default.removeItem(at: committedRoot) }
        committedTarget.coordinator = committed
        committed.captureManager.onStateChanged = { [weak committed] state in
            committed?.handleCaptureStateChange(state)
        }
        committed.microphoneAuthorizationReader = { .authorized }

        permissionValues.preflight = false
        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        await committed.checkPermissionsAndAutoStart()
        permissionValues.prompted = false
        permissionValues.preflight = false
        permissionValues.granted = false
        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        await committed.checkPermissionsAndAutoStart()
        #expect(!committed.screenRecordingGranted)

        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        committed.captureManager.onStateChanged?(.idle)
        #expect(committed.isPermissionPollingActiveForTesting)
        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        await committed.startRecording()
        let committedEntries = await committedHarness.entries()
        #expect(committed.screenRecordingGranted)
        #expect(committed.isRecording)
        #expect(!committed.isPermissionPollingActiveForTesting)
        #expect(evidenceCodes(committedEntries) == [
            .screenRecordingNotGranted,
            .microphoneGranted,
            .screenRecordingUnavailable,
            .captureOff,
            .captureOn,
            .screenRecordingGranted,
        ])
        let committedBytes = try #require(committedHarness.bytes.stored)

        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        committed.captureManager.onStateChanged?(.recording)
        committedHarness.clock.now = committedHarness.clock.now.addingTimeInterval(1)
        committed.publishScreenRecordingPermission(.granted)
        let deduplicatedEntries = await committedHarness.entries()
        #expect(committedEntries == deduplicatedEntries)
        #expect(committedHarness.bytes.stored == committedBytes)

        let deniedHarness = DiagnosticEvidenceHarness()
        let (denied, deniedRoot) = try makeEvidenceCoordinator(
            recorder: deniedHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                .threw(TransitionFailure(message: "permission", isPermissionError: true))
            }
        )
        defer { try? FileManager.default.removeItem(at: deniedRoot) }
        deniedHarness.clock.now = deniedHarness.clock.now.addingTimeInterval(1)
        await denied.startRecording()
        #expect(evidenceCodes(await deniedHarness.entries()) == [.screenRecordingNotGranted])

        let failureHarness = DiagnosticEvidenceHarness()
        let (failure, failureRoot) = try makeEvidenceCoordinator(
            recorder: failureHarness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                .threw(TransitionFailure(message: "test failure", isPermissionError: false))
            }
        )
        defer { try? FileManager.default.removeItem(at: failureRoot) }
        failureHarness.clock.now = failureHarness.clock.now.addingTimeInterval(1)
        await failure.startRecording()
        #expect(evidenceCodes(await failureHarness.entries()) == [.captureError])
        let failureBytes = try #require(failureHarness.bytes.stored)
        #expect(!String(decoding: failureBytes, as: UTF8.self).contains("test failure"))
    }

    private func assertRefreshDuringScreenAwait(
        initial: MicrophoneAuthorizationCause,
        refreshed: MicrophoneAuthorizationCause,
        expectedStarts: Int
    ) async throws {
        let harness = DiagnosticEvidenceHarness()
        let start = EvidenceStartSpy()
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
            startOperation: { _, _ in
                start.count += 1
                return .committed
            }
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
        #expect(start.count == expectedStarts)
        let expectedMicrophone: DiagnosticEvidenceCode = refreshed == .authorized ? .microphoneGranted : .microphoneNotGranted
        #expect(evidenceCodes(await harness.entries()) == [expectedMicrophone, .screenRecordingGranted])
    }
}

@MainActor
private final class EvidenceLogEvents {
    var events: [DiagnosticEvidenceLogEvent] = []
}

@MainActor
private final class EvidenceCaptureCoordinatorTarget {
    weak var coordinator: CaptureCoordinator?
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
