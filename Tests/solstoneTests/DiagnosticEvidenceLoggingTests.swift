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
