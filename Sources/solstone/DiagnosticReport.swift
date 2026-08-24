// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal enum DiagnosticReportRowID: CaseIterable, Hashable, Sendable {
    case appVersion
    case screenRecording
    case microphone
    case screenAndAudio
    case lastDelivery
    case lastJournalConnection
    case recentStateCodes
}

internal struct DiagnosticReportRow: Equatable, Identifiable, Sendable {
    let id: DiagnosticReportRowID
    let label: String
    let value: String
}

internal struct DiagnosticReport: Equatable, Sendable {
    let rows: [DiagnosticReportRow]
    let screenRecordingState: AXPermissionState
    let microphoneState: AXPermissionState
    let captureState: DiagnosticCaptureAXState
    let lastDeliveryState: LastJournalDeliveryAXState
    let lastDeliveryTimestamp: Date?
    let lastJournalContactState: LastJournalContactAXState
    let lastJournalContactTimestamp: Date?

    var text: String {
        rows.map { row in
            let continuationPrefix = String(repeating: " ", count: row.label.count + 2)
            let value = row.value.replacingOccurrences(of: "\n", with: "\n\(continuationPrefix)")
            return "\(row.label): \(value)"
        }.joined(separator: "\n")
    }
}

internal struct DiagnosticReportInput: Equatable, Sendable {
    let appVersion: String
    let screenRecording: PermissionOutcome
    let microphone: PermissionOutcome
    let isRecording: Bool
    let isPaused: Bool
    let hasError: Bool
    let lastDelivery: LastJournalDeliveryOutcome
    let lastJournalContact: SetupLastSyncOutcome
    let evidence: DiagnosticEvidenceRead
    let now: Date
}

internal enum DiagnosticCopyFeedback: Equatable, Sendable {
    case copied
    case failed

    var text: String {
        switch self {
        case .copied:
            return UICopy.SETTINGS_DIAGNOSTICS_COPIED
        case .failed:
            return UICopy.SETTINGS_DIAGNOSTICS_COPY_FAILED
        }
    }

    var axState: DiagnosticCopyAXState {
        switch self {
        case .copied:
            return .copied
        case .failed:
            return .failed
        }
    }
}

internal func buildDiagnosticReport(_ input: DiagnosticReportInput) -> DiagnosticReport {
    DiagnosticReport(rows: [
        DiagnosticReportRow(
            id: .appVersion,
            label: UICopy.SETTINGS_DIAGNOSTICS_APP_VERSION,
            value: input.appVersion
        ),
        DiagnosticReportRow(
            id: .screenRecording,
            label: UICopy.SETTINGS_DIAGNOSTICS_SCREEN_RECORDING,
            value: diagnosticPermissionValue(input.screenRecording)
        ),
        DiagnosticReportRow(
            id: .microphone,
            label: UICopy.SETTINGS_DIAGNOSTICS_MICROPHONE,
            value: diagnosticPermissionValue(input.microphone)
        ),
        DiagnosticReportRow(
            id: .screenAndAudio,
            label: UICopy.SETTINGS_DIAGNOSTICS_SCREEN_AND_AUDIO,
            value: diagnosticCaptureValue(
                isRecording: input.isRecording,
                isPaused: input.isPaused,
                hasError: input.hasError
            )
        ),
        DiagnosticReportRow(
            id: .lastDelivery,
            label: UICopy.SETTINGS_LAST_DELIVERY_LABEL,
            value: diagnosticDeliveryValue(input.lastDelivery, now: input.now)
        ),
        DiagnosticReportRow(
            id: .lastJournalConnection,
            label: UICopy.SETTINGS_DIAGNOSTICS_LAST_JOURNAL_CONNECTION,
            value: diagnosticContactValue(input.lastJournalContact, now: input.now)
        ),
        DiagnosticReportRow(
            id: .recentStateCodes,
            label: UICopy.SETTINGS_DIAGNOSTICS_RECENT_STATE_CODES,
            value: diagnosticEvidenceValue(input.evidence)
        )
    ],
    screenRecordingState: input.screenRecording.diagnosticAXState,
    microphoneState: input.microphone.diagnosticAXState,
    captureState: diagnosticCaptureAXState(
        isRecording: input.isRecording,
        isPaused: input.isPaused,
        hasError: input.hasError
    ),
    lastDeliveryState: input.lastDelivery.diagnosticAXState,
    lastDeliveryTimestamp: input.lastDelivery.deliveredAt,
    lastJournalContactState: input.lastJournalContact.diagnosticAXState,
    lastJournalContactTimestamp: input.lastJournalContact.connectedAt)
}

internal func performDiagnosticCopy(
    _ report: DiagnosticReport,
    write: (String) -> Bool,
    announce: (String) -> Void
) -> DiagnosticCopyFeedback {
    guard write(report.text) else {
        return .failed
    }
    announce(UICopy.SETTINGS_DIAGNOSTICS_COPY_ANNOUNCEMENT)
    return .copied
}

internal func diagnosticPermissionValue(_ outcome: PermissionOutcome) -> String {
    switch outcome {
    case .checking:
        return UICopy.SETTINGS_DIAGNOSTICS_CHECKING
    case .granted:
        return UICopy.SETTINGS_DIAGNOSTICS_GRANTED
    case .notGranted:
        return UICopy.SETTINGS_DIAGNOSTICS_NOT_GRANTED
    case .unavailable:
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    }
}

extension PermissionOutcome {
    var diagnosticAXState: AXPermissionState {
        switch self {
        case .checking:
            return .waiting
        case .granted:
            return .granted
        case .notGranted:
            return .denied
        case .unavailable:
            return .unavailable
        }
    }
}

extension LastJournalDeliveryOutcome {
    var diagnosticAXState: LastJournalDeliveryAXState {
        switch self {
        case .delivered:
            return .delivered
        case .noDeliveryYet:
            return .noDeliveryYet
        case .notLinked:
            return .notLinked
        case .unavailable:
            return .unavailable
        }
    }

    var deliveredAt: Date? {
        guard case .delivered(let date) = self else { return nil }
        return date
    }
}

extension SetupLastSyncOutcome {
    var diagnosticAXState: LastJournalContactAXState {
        switch self {
        case .synced:
            return .connected
        case .noSyncYet:
            return .noConnectionYet
        case .notLinked:
            return .notLinked
        case .couldNotCheck:
            return .unavailable
        }
    }

    var connectedAt: Date? {
        guard case .synced(let date) = self else { return nil }
        return date
    }
}

internal func diagnosticCaptureAXState(
    isRecording: Bool,
    isPaused: Bool,
    hasError: Bool
) -> DiagnosticCaptureAXState {
    if hasError { return .error }
    if isPaused { return .paused }
    return isRecording ? .on : .off
}

internal func diagnosticCaptureValue(isRecording: Bool, isPaused: Bool, hasError: Bool) -> String {
    if hasError {
        return UICopy.SETTINGS_DIAGNOSTICS_ERROR
    }
    if isPaused {
        return UICopy.SETTINGS_DIAGNOSTICS_PAUSED
    }
    return isRecording ? UICopy.SETTINGS_DIAGNOSTICS_ON : UICopy.SETTINGS_DIAGNOSTICS_OFF
}

internal func diagnosticDeliveryValue(_ outcome: LastJournalDeliveryOutcome, now: Date) -> String {
    switch outcome {
    case .delivered(let date):
        return coarseRelativeTime(date, now: now)
    case .noDeliveryYet:
        return UICopy.SETTINGS_LAST_DELIVERY_NEVER
    case .notLinked:
        return UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED
    case .unavailable:
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    }
}

internal func diagnosticContactValue(_ outcome: SetupLastSyncOutcome, now: Date) -> String {
    switch outcome {
    case .synced(let date):
        return coarseRelativeTime(date, now: now)
    case .noSyncYet:
        return UICopy.SETTINGS_DIAGNOSTICS_NO_CONNECTION
    case .notLinked:
        return UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED
    case .couldNotCheck:
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    }
}

internal func diagnosticEvidenceValue(_ read: DiagnosticEvidenceRead) -> String {
    switch read {
    case .unavailable:
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    case .available(let envelope):
        guard !envelope.entries.isEmpty else {
            return UICopy.SETTINGS_DIAGNOSTICS_NO_RECENT_CODES
        }
        return envelope.entries.map { entry in
            "\(entry.code.rawValue) · first \(diagnosticUTCString(entry.firstAt)) · last \(diagnosticUTCString(entry.lastAt)) · repeat \(entry.repeatCount)"
        }.joined(separator: "\n")
    }
}

internal func diagnosticUTCString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

internal func shouldShowScreenRecordingResetHint(
    hasPromptedScreenRecording: Bool,
    sckFailedAfterPositivePreflight: Bool,
    restartCountdown: Int?
) -> Bool {
    (hasPromptedScreenRecording || sckFailedAfterPositivePreflight) && restartCountdown == nil
}

internal func shouldPublishDiagnosticLoad(
    _ generation: UInt,
    activeGeneration: UInt,
    diagnosticsExpanded: Bool
) -> Bool {
    diagnosticsExpanded && generation == activeGeneration
}
