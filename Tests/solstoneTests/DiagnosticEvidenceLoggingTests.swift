// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Diagnostic evidence logging")
@MainActor
struct DiagnosticEvidenceLoggingTests {
    @Test func adapterMapsOnlyTheTwoPayloadFreeEvents() {
        var events: [DiagnosticEvidenceLogEvent] = []
        let adapter = DiagnosticEvidenceLoggingAdapter { events.append($0) }

        adapter.screenRecordingCDHashMismatch()
        adapter.permissionAutoStartSkipped()

        #expect(events == [.screenRecordingCDHashMismatch, .permissionAutoStartSkipped])
    }

    @Test func liveMappingUsesExactSetupTokens() throws {
        let source = try readWireUpSource("Sources/solstone/DiagnosticEvidenceLoggingAdapter.swift")
        #expect(wireUpContains(source, "Logger.setup.notice(\"screen_recording.cdhash_mismatch\")"))
        #expect(wireUpContains(source, "Logger.setup.debug(\"permission.auto_start_skipped\")"))
    }

    @Test func mismatchBranchHasNoticeDeltasPlusOneZeroZeroPlusOne() async throws {
        let harness = DiagnosticEvidenceHarness()
        let values = MutableScreenPermissionValues()
        let events = DiagnosticLoggingEvents()
        let provider = ScreenRecordingPermissionProvider(
            hasPrompted: { values.prompted },
            preflight: { values.preflight },
            checkScreenRecording: { values.granted },
            resetPromptedFlag: {}
        )
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: provider,
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .denied }

        values.granted = false
        await coordinator.checkPermissionsAndAutoStart()
        let afterMismatch = events.events.count
        values.granted = true
        await coordinator.checkPermissionsAndAutoStart()
        let afterSuccess = events.events.count
        values.preflight = false
        await coordinator.checkPermissionsAndAutoStart()
        let afterPreflight = events.events.count
        values.preflight = true
        values.granted = false
        await coordinator.checkPermissionsAndAutoStart()
        let afterSecondMismatch = events.events.count

        let deltas: [Int] = [
            afterMismatch,
            afterSuccess - afterMismatch,
            afterPreflight - afterSuccess,
            afterSecondMismatch - afterPreflight,
        ]
        #expect(deltas == [1, 0, 0, 1])
    }

    @Test func terminatingSkipsLogEveryOccurrenceWhileEvidenceCoalesces() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = DiagnosticLoggingEvents()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            isTerminating: { true },
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        coordinator.microphoneAuthorizationReader = { .authorized }

        let passes = 3
        for _ in 0..<passes {
            harness.clock.now = harness.clock.now.addingTimeInterval(1)
            await coordinator.checkPermissionsAndAutoStart()
        }

        let entries = await harness.entries()
        #expect(events.events == Array(repeating: .permissionAutoStartSkipped, count: passes))
        #expect(evidenceCodes(entries) == [.screenRecordingGranted, .microphoneGranted, .permissionAutoStartSkipped])
        #expect(entries[2].repeatCount == passes)
    }

    @Test func ordinaryOutcomesDoNotReachTheDiagnosticAdapter() async throws {
        let harness = DiagnosticEvidenceHarness()
        let events = DiagnosticLoggingEvents()
        let target = DiagnosticLoggingCaptureTarget()
        let (coordinator, root) = try makeEvidenceCoordinator(
            recorder: harness.recorder,
            screenPermissionProvider: makeScreenPermissionProvider(),
            startOperation: { _, _ in
                target.coordinator?.captureManager.onStateChanged?(.recording)
                return .committed
            },
            logAdapter: DiagnosticEvidenceLoggingAdapter { events.events.append($0) }
        )
        defer { try? FileManager.default.removeItem(at: root) }
        target.coordinator = coordinator
        coordinator.captureManager.onStateChanged = { [weak coordinator] state in
            coordinator?.handleCaptureStateChange(state)
        }
        coordinator.microphoneAuthorizationReader = { .authorized }

        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        harness.recorder.enqueue(.appLaunch)
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        await coordinator.checkPermissionsAndAutoStart()
        harness.clock.now = harness.clock.now.addingTimeInterval(1)
        coordinator.captureManager.onStateChanged?(.paused(reasons: [.user]))
        _ = await harness.entries()

        #expect(events.events.isEmpty)
    }

    @Test func existingProductLogsRemainOutsideTheDiagnosticAdapter() throws {
        let coordinator = try readWireUpSource("Sources/solstone/CaptureCoordinator.swift")
        let adapter = try readWireUpSource("Sources/solstone/DiagnosticEvidenceLoggingAdapter.swift")

        #expect(wireUpContains(coordinator, "Logger.general.info(\"[Permissions] all granted, auto-starting observation\")"))
        #expect(wireUpContains(coordinator, "Logger.general.info(\"startRecording() ignored because app is terminating\")"))
        #expect(wireUpContains(coordinator, "Logger.general.info(\"startRecording() vetoed\")"))
        #expect(wireUpContains(coordinator, "Logger.general.info(\"startRecording() dropped\")"))
        #expect(wireUpContains(coordinator, "Logger.general.info(\"[Permissions] Recording denied, screen recording permission not granted\")"))
        #expect(wireUpContains(coordinator, "Logger.general.error(\"Recording failed to start:"))
        #expect(!adapter.contains("Logger.general"))
        #expect(adapter.components(separatedBy: "Logger.setup.").count == 3)
    }
}

@MainActor
private final class MutableScreenPermissionValues {
    var prompted = true
    var preflight = true
    var granted = false
}

@MainActor
private final class DiagnosticLoggingEvents {
    var events: [DiagnosticEvidenceLogEvent] = []
}

@MainActor
private final class DiagnosticLoggingCaptureTarget {
    weak var coordinator: CaptureCoordinator?
}
