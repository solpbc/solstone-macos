// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

internal enum DiagnosticReportRowID: CaseIterable, Hashable, Sendable {
    case appVersion
    case screenRecording
    case microphone
    case screenAndAudio
    case lastDelivery
    case lastJournalConnection
    case ingestReason
    case ingestRoute
    case journalLink
    case journalAddresses
    case relay
    case addressesTried
    case connectedThrough
    case localCaptures
    case recentStateCodes
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    case browserPages
    case browsersSeen
    case browserSetup
#endif
}

internal struct DiagnosticReportRow: Equatable, Identifiable, Sendable {
    let id: DiagnosticReportRowID
    let label: String
    let value: String
    var machineValue: String? = nil
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
    /// When this report was read. The copied text leads with it, so two copies can be told apart.
    var checkedAt: Date? = nil

    var text: String {
        let header = checkedAt.map { ["\(UICopy.SETTINGS_DIAGNOSTICS_CHECKED_AT): \(diagnosticUTCString($0))"] } ?? []
        return (header + rows.map { row in
            let continuationPrefix = String(repeating: " ", count: row.label.count + 2)
            let value = (row.machineValue ?? row.value).replacingOccurrences(of: "\n", with: "\n\(continuationPrefix)")
            return "\(row.label): \(value)"
        }).joined(separator: "\n")
    }
}

internal struct DiagnosticReportInput: Equatable, Sendable {
    let appVersion: String
    let screenRecording: PermissionOutcome
    let microphone: PermissionOutcome
    let isRecording: Bool
    let isPaused: Bool
    var ownerPauseHeldIdle: Bool = false
    let hasError: Bool
    let lastDelivery: LastJournalDeliveryOutcome
    let lastJournalContact: SetupLastSyncOutcome
    let evidence: DiagnosticEvidenceRead
    let ingestReason: String?
    let ingestRoute: String?
    let now: Date
    var activeSources: CaptureSources? = nil
    var connection: DiagnosticConnectionInput = .unpaired
    var backlog: SyncService.DiagnosticBacklog? = nil
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    var browserRows: [BrowserDiagnosticRow]? = nil
#endif
}

/// What the app holds and has done to reach the journal. Addresses, the relay's
/// host and the winning route only: never an instance ID, a token or a key.
internal struct DiagnosticConnectionInput: Equatable, Sendable {
    let isPaired: Bool
    let pairedAddresses: [String]
    let dialableRelayHost: String?
    let triedAddresses: [String]
    let connectedThrough: JournalConnectedThrough?

    static let unpaired = DiagnosticConnectionInput(
        isPaired: false,
        pairedAddresses: [],
        dialableRelayHost: nil,
        triedAddresses: [],
        connectedThrough: nil
    )
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
    let connection = input.connection
    var connectionRows: [DiagnosticReportRow] = []
    if connection.isPaired, !connection.pairedAddresses.isEmpty {
        connectionRows.append(DiagnosticReportRow(
            id: .journalAddresses,
            label: UICopy.JOURNAL_ADDRESSES_LABEL,
            value: connection.pairedAddresses.joined(separator: "\n")
        ))
    }
    if connection.isPaired {
        connectionRows.append(DiagnosticReportRow(
            id: .relay,
            label: UICopy.JOURNAL_RELAY_LABEL,
            value: journalRelayValue(dialableRelayHost: connection.dialableRelayHost)
        ))
    }
    if connection.connectedThrough == nil, !connection.triedAddresses.isEmpty {
        connectionRows.append(DiagnosticReportRow(
            id: .addressesTried,
            label: UICopy.JOURNAL_ADDRESSES_TRIED_LABEL,
            value: connection.triedAddresses.joined(separator: "\n")
        ))
    }
    if let connectedThrough = connection.connectedThrough {
        connectionRows.append(DiagnosticReportRow(
            id: .connectedThrough,
            label: UICopy.JOURNAL_CONNECTED_THROUGH_LABEL,
            value: connectedThrough.text
        ))
    }
    let baseRows = [
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
            value: input.activeSources.map {
                input.isRecording || input.isPaused ? UICopy.sourceStatus($0, isPaused: input.isPaused) : UICopy.SOURCES_OFF
            } ?? diagnosticCaptureValue(
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
            id: .ingestReason,
            label: UICopy.SETTINGS_DIAGNOSTICS_INGEST_REASON,
            value: diagnosticIngestTokenValue(input.ingestReason)
        ),
        DiagnosticReportRow(
            id: .ingestRoute,
            label: UICopy.SETTINGS_DIAGNOSTICS_INGEST_ROUTE,
            value: diagnosticIngestTokenValue(input.ingestRoute)
        ),
        DiagnosticReportRow(
            id: .journalLink,
            label: UICopy.SETTINGS_DIAGNOSTICS_JOURNAL_LINK,
            value: diagnosticJournalLinkValue(input.evidence)
        )
    ] + connectionRows + [
        DiagnosticReportRow(
            id: .localCaptures,
            label: "segments on this mac",
            value: diagnosticBacklogValue(input.backlog, now: input.now)
        ),
        DiagnosticReportRow(
            id: .recentStateCodes,
            label: UICopy.SETTINGS_DIAGNOSTICS_RECENT_STATE_CODES,
            value: diagnosticEvidenceValue(input.evidence)
        )
    ]
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
    var browserDiagnosticRows: [DiagnosticReportRow] = []
    if let browserRows = input.browserRows {
        for row in browserRows {
            let rowID: DiagnosticReportRowID
            switch row.label {
            case UICopy.DIAGNOSTICS_BROWSER_PAGES_LABEL:
                rowID = .browserPages
            case UICopy.DIAGNOSTICS_BROWSERS_SEEN_LABEL:
                rowID = .browsersSeen
            default:
                rowID = .browserSetup
            }
            browserDiagnosticRows.append(DiagnosticReportRow(
                id: rowID,
                label: row.label,
                value: row.humanValue,
                machineValue: row.machineValue
            ))
        }
    }
    let allRows = baseRows + browserDiagnosticRows
#else
    let allRows = baseRows
#endif
    return DiagnosticReport(
        rows: allRows,
        screenRecordingState: input.screenRecording.diagnosticAXState,
        microphoneState: input.microphone.diagnosticAXState,
        captureState: diagnosticCaptureAXState(
            isRecording: input.isRecording,
            isPaused: input.isPaused,
            ownerPauseHeldIdle: input.ownerPauseHeldIdle,
            hasError: input.hasError
        ),
        lastDeliveryState: input.lastDelivery.diagnosticAXState,
        lastDeliveryTimestamp: input.lastDelivery.deliveredAt,
        lastJournalContactState: input.lastJournalContact.diagnosticAXState,
        lastJournalContactTimestamp: input.lastJournalContact.connectedAt,
        checkedAt: input.now
    )
}

internal func diagnosticBacklogValue(_ backlog: SyncService.DiagnosticBacklog?, now: Date) -> String {
    guard let backlog, let count = backlog.pendingCaptures,
          let preserved = backlog.preservedFailureFolders else { return "unavailable" }
    let age = backlog.oldestPendingFolder.map { String(Int(max(0, now.timeIntervalSince($0)))) } ?? "unavailable"
    return "pending=\(count) · oldest_pending_folder_age_s=\(age) · preserved_failure_folders=\(preserved) (delivery unknown)"
}

internal func performDiagnosticCopy(
    _ report: DiagnosticReport,
    write: (String) -> Bool,
    announce: (String) -> Void
) -> DiagnosticCopyFeedback {
    performDiagnosticCopy(text: report.text, write: write, announce: announce)
}

internal func performDiagnosticCopy(
    text: String,
    write: (String) -> Bool,
    announce: (String) -> Void
) -> DiagnosticCopyFeedback {
    guard write(text) else {
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
    ownerPauseHeldIdle: Bool = false,
    hasError: Bool
) -> DiagnosticCaptureAXState {
    if hasError { return .error }
    if isPaused || ownerPauseHeldIdle { return .paused }
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

internal func diagnosticIngestTokenValue(_ value: String?) -> String {
    guard let value, !value.isEmpty else {
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    }
    return value
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

/// Says, in a sentence, whether the journal has been refusing this Mac's
/// streams — the one failure that is otherwise indistinguishable from the
/// network dropping, because both arrive as `url_error_-1005`.
///
/// Read from the persisted evidence rather than the live tunnel: the tunnel's
/// own counters restart on every reconnect, which is exactly the moment an
/// owner goes looking.
internal func diagnosticJournalLinkValue(_ read: DiagnosticEvidenceRead) -> String {
    guard case .available(let envelope) = read else {
        return UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK
    }
    let refusals = envelope.entries.first { $0.code == .tunnelStreamLimitRefused }
    let resets = envelope.entries.first { $0.code == .tunnelStreamReset }
    var clauses: [String] = []
    if let refusals {
        clauses.append(UICopy.diagnosticsStreamLimitRefused(
            count: refusals.repeatCount,
            last: diagnosticUTCString(refusals.lastAt)
        ))
    }
    if let resets {
        clauses.append(UICopy.diagnosticsStreamDropped(
            count: resets.repeatCount,
            last: diagnosticUTCString(resets.lastAt)
        ))
    }
    return clauses.isEmpty ? UICopy.SETTINGS_DIAGNOSTICS_NO_LINK_REFUSALS : clauses.joined(separator: "\n")
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
