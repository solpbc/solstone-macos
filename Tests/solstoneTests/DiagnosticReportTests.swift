// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import Testing
@testable import solstone

@Suite("Owner diagnostics report")
struct DiagnosticReportTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func reportUsesOnlyTheFixedRowsAndDeterministicEvidence() throws {
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
        sources: on
        last added to your journal: 2m ago
        last journal connection: just now
        journal intake: http_404
        journal intake address: /app/devices/ingest
        journal link: nothing turned away or ended early
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

    @Test func ingestReasonAndRouteUseTokenAndPathWithoutHosts() {
        let report = buildDiagnosticReport(input())
        let reason = report.rows.first { $0.id == .ingestReason }
        let route = report.rows.first { $0.id == .ingestRoute }
        #expect(reason?.value == "http_404")
        #expect(route?.value == IngestProtocolV3.uploadPath)
        #expect(route?.value.contains("://") == false)
        #expect(!report.text.contains("https://"))
        #expect(!report.text.contains("ZZSENTINELZZ"))
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

    @Test func aStreamLimitRefusalAndATransportDeathReadDifferentlyToTheOwner() {
        // The whole item: both arrive as url_error_-1005, so the owner-reachable
        // diagnostic is the only place the two can be told apart.
        let refused = journalLinkValue(for: .tunnelStreamLimitRefused)
        let dropped = journalLinkValue(for: .tunnelStreamReset)

        #expect(refused == "your journal turned away 4 requests at its limit · last 1970-01-01T00:15:50.000Z")
        #expect(dropped == "your journal ended 4 requests early · last 1970-01-01T00:15:50.000Z")
        #expect(refused != dropped)
    }

    @Test func aLinkThatHasRefusedNothingSaysSoRatherThanGoingBlank() {
        // The negative control. An empty row would read the same as a row whose
        // producer never ran, which is the failure mode this item exists to fix.
        #expect(diagnosticJournalLinkValue(.available(DiagnosticEvidenceEnvelope(
            schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
            entries: []
        ))) == "nothing turned away or ended early")
        #expect(diagnosticJournalLinkValue(.unavailable) == "couldn't check")
    }

    @Test func bothRefusalClassesAreReportedTogetherWhenBothHappened() {
        let value = diagnosticJournalLinkValue(.available(DiagnosticEvidenceEnvelope(
            schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
            entries: [
                entry(.tunnelStreamReset, repeatCount: 2),
                entry(.tunnelStreamLimitRefused, repeatCount: 9)
            ]
        )))
        // Refusals lead regardless of entry order: it is the actionable one.
        #expect(value == """
        your journal turned away 9 requests at its limit · last 1970-01-01T00:15:50.000Z
        your journal ended 2 requests early · last 1970-01-01T00:15:50.000Z
        """)
    }

    @Test func everyPeerResetReasonMapsToExactlyOneEvidenceCode() {
        #expect(diagnosticEvidenceCode(forPeerStreamReset: .streamLimitExceeded) == .tunnelStreamLimitRefused)
        for other in [ResetReason.protocolError, .flowControlError, .internalError, .cancel, .unspecified] {
            #expect(diagnosticEvidenceCode(forPeerStreamReset: other) == .tunnelStreamReset)
        }
    }

    private func journalLinkValue(for code: DiagnosticEvidenceCode) -> String {
        let report = buildDiagnosticReport(input(
            evidence: .available(DiagnosticEvidenceEnvelope(
                schemaVersion: DiagnosticEvidenceEnvelope.currentSchemaVersion,
                entries: [entry(code, repeatCount: 4)]
            ))
        ))
        return report.rows.first { $0.id == .journalLink }?.value ?? ""
    }

    private func entry(_ code: DiagnosticEvidenceCode, repeatCount: Int) -> DiagnosticEvidenceEntry {
        DiagnosticEvidenceEntry(
            code: code,
            firstAt: Date(timeIntervalSince1970: 900),
            lastAt: Date(timeIntervalSince1970: 950),
            repeatCount: repeatCount
        )
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
            ingestReason: "http_404",
            ingestRoute: IngestProtocolV3.uploadPath,
            now: now
        )
    }
}
