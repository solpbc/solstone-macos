// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Owner diagnostics report")
struct DiagnosticReportTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func reportUsesOnlyTheSevenFixedRowsAndDeterministicEvidence() throws {
        let report = buildDiagnosticReport(input(
            evidence: .available(DiagnosticEvidenceEnvelope(
                schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                entries: [
                    DiagnosticEvidenceEntry(
                        code: .appLaunch,
                        firstAt: Date(timeIntervalSince1970: 900),
                        lastAt: Date(timeIntervalSince1970: 950),
                        repeatCount: 3
                    )
                ]
            ))
        ))

        #expect(report.rows.map(\.id) == DiagnosticReportRowID.allCases)
        #expect(report.text == """
        app version: 1.2.3
        screen recording: granted
        microphone: not granted
        screen and audio: on
        last added to your journal: 2m ago
        last journal connection: just now
        recent state codes: app.launch · first 1970-01-01T00:15:00.000Z · last 1970-01-01T00:15:50.000Z · repeat 3
        """)
        #expect(report.screenRecordingState == .granted)
        #expect(report.microphoneState == .denied)
        #expect(report.captureState == .on)
        #expect(report.lastDeliveryState == .delivered)
        #expect(report.lastDeliveryTimestamp == now.addingTimeInterval(-120))
        #expect(report.lastJournalContactState == .connected)
        #expect(report.lastJournalContactTimestamp == now.addingTimeInterval(-30))

        for excluded in [
            "https://private.example",
            "secret-key",
            "/Users/owner/private.mov",
            "window title",
            "free-form error"
        ] {
            #expect(!report.text.contains(excluded))
        }
    }

    @Test func permissionCaptureDeliveryContactAndEvidenceFallbacksAreExplicit() {
        #expect(diagnosticPermissionValue(.checking) == "checking")
        #expect(diagnosticPermissionValue(.granted) == "granted")
        #expect(diagnosticPermissionValue(.notGranted) == "not granted")
        #expect(diagnosticPermissionValue(.unavailable) == "couldn't check")

        #expect(diagnosticCaptureValue(isRecording: true, isPaused: false, hasError: false) == "on")
        #expect(diagnosticCaptureValue(isRecording: true, isPaused: true, hasError: false) == "paused")
        #expect(diagnosticCaptureValue(isRecording: false, isPaused: false, hasError: false) == "off")
        #expect(diagnosticCaptureValue(isRecording: true, isPaused: true, hasError: true) == "error")

        #expect(diagnosticDeliveryValue(.noDeliveryYet, now: now) == "nothing added yet")
        #expect(diagnosticDeliveryValue(.notLinked, now: now) == "your journal isn't linked")
        #expect(diagnosticDeliveryValue(.unavailable, now: now) == "couldn't check")
        #expect(diagnosticContactValue(.noSyncYet, now: now) == "no connection yet")
        #expect(diagnosticContactValue(.notLinked, now: now) == "your journal isn't linked")
        #expect(diagnosticContactValue(.couldNotCheck, now: now) == "couldn't check")

        #expect(diagnosticEvidenceValue(.available(DiagnosticEvidenceEnvelope(
            schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
            entries: []
        ))) == "no recent state codes")
        #expect(diagnosticEvidenceValue(.unavailable) == "couldn't check")
    }

    @Test func copyUsesExactPreviewAndAnnouncesOnlyConfirmedSuccess() {
        let report = buildDiagnosticReport(input())
        var written: String?
        var announcements: [String] = []

        let success = performDiagnosticCopy(
            report,
            write: { written = $0; return true },
            announce: { announcements.append($0) }
        )
        #expect(success == .copied)
        #expect(written == report.text)
        #expect(announcements == ["diagnostics copied to the clipboard"])

        written = nil
        announcements = []
        let failure = performDiagnosticCopy(
            report,
            write: { written = $0; return false },
            announce: { announcements.append($0) }
        )
        #expect(failure == .failed)
        #expect(written == report.text)
        #expect(announcements.isEmpty)
    }

    @Test func cdHashFailureKeepsResetHintVisibleUnlessRestartIsUnderway() {
        #expect(shouldShowScreenRecordingResetHint(
            hasPromptedScreenRecording: false,
            sckFailedAfterPositivePreflight: true,
            restartCountdown: nil
        ))
        #expect(shouldShowScreenRecordingResetHint(
            hasPromptedScreenRecording: true,
            sckFailedAfterPositivePreflight: false,
            restartCountdown: nil
        ))
        #expect(!shouldShowScreenRecordingResetHint(
            hasPromptedScreenRecording: false,
            sckFailedAfterPositivePreflight: false,
            restartCountdown: nil
        ))
        #expect(!shouldShowScreenRecordingResetHint(
            hasPromptedScreenRecording: true,
            sckFailedAfterPositivePreflight: true,
            restartCountdown: 3
        ))
    }

    @Test func staleDiagnosticReadCannotPublishAfterCloseOrReopen() {
        #expect(shouldPublishDiagnosticLoad(
            2,
            activeGeneration: 2,
            diagnosticsExpanded: true
        ))
        #expect(!shouldPublishDiagnosticLoad(
            2,
            activeGeneration: 3,
            diagnosticsExpanded: true
        ))
        #expect(!shouldPublishDiagnosticLoad(
            2,
            activeGeneration: 2,
            diagnosticsExpanded: false
        ))
    }

    private func input(
        evidence: DiagnosticEvidenceRead = .available(DiagnosticEvidenceEnvelope(
            schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
            entries: []
        ))
    ) -> DiagnosticReportInput {
        DiagnosticReportInput(
            appVersion: "1.2.3",
            screenRecording: .granted,
            microphone: .notGranted,
            isRecording: true,
            isPaused: false,
            hasError: false,
            lastDelivery: .delivered(now.addingTimeInterval(-120)),
            lastJournalContact: .synced(now.addingTimeInterval(-30)),
            evidence: evidence,
            now: now
        )
    }
}
