// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

internal enum SetupTopology: Equatable, Sendable {
    case local
    case remote
    case undecided
}

internal func classifySetupTopology(
    serviceMode: ServiceMode?,
    serverURL: String?,
    isTunnelManaged: Bool,
    isPairedHome: Bool
) -> SetupTopology {
    if isPairedHome {
        return .local
    }
    // A managed tunnel is the authoritative remote journal identity even when
    // the runtime URL is loopback or stale config still says bundled.
    if isTunnelManaged {
        return .remote
    }
    if serviceMode == .bundled {
        return .local
    }
    guard let serverURL,
          !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .undecided
    }

    let parseableURL = serverURL.contains("://") ? serverURL : "http://\(serverURL)"
    return LoopbackHost.isLoopbackURL(parseableURL) ? .local : .remote
}

internal enum MicrophoneAuthorizationCause: CaseIterable, Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown

    var permissionAXState: AXPermissionState {
        switch self {
        case .authorized:
            return .granted
        case .notDetermined:
            return .waiting
        case .denied, .restricted:
            return .denied
        case .unknown:
            return .unavailable
        }
    }
}

internal enum PermissionOutcome: Equatable, Sendable {
    case checking
    case granted
    case notGranted
    case unavailable

    static func screenRecording(
        initialPermissionCheckComplete: Bool,
        screenRecordingGranted: Bool,
        hasPromptedScreenRecording: Bool,
        preflightSucceeded: Bool?,
        sckFailedAfterPositivePreflight: Bool
    ) -> PermissionOutcome {
        guard initialPermissionCheckComplete else { return .checking }
        if screenRecordingGranted { return .granted }
        if sckFailedAfterPositivePreflight { return .unavailable }
        if preflightSucceeded == true { return .granted }
        if preflightSucceeded == false { return .notGranted }
        return hasPromptedScreenRecording ? .notGranted : .unavailable
    }

    static func microphone(
        initialPermissionCheckComplete: Bool,
        cause: MicrophoneAuthorizationCause
    ) -> PermissionOutcome {
        guard initialPermissionCheckComplete else { return .checking }

        switch cause {
        case .authorized:
            return .granted
        case .notDetermined, .denied, .restricted:
            return .notGranted
        case .unknown:
            return .unavailable
        }
    }
}

internal enum SetupProbeOutcome: Equatable, Sendable {
    case ready
    case needsAttention
    case checking
    case unavailable

    var rowState: SetupCheckRowAXState {
        switch self {
        case .ready:
            return .ready
        case .needsAttention:
            return .needsAttention
        case .checking:
            return .checking
        case .unavailable:
            return .unavailable
        }
    }
}

internal enum SetupLastSyncOutcome: Equatable, Sendable {
    case synced(Date)
    case noSyncYet
    case notLinked
    case couldNotCheck
}

internal enum SetupCheckRowID: CaseIterable, Hashable, Sendable {
    case solApp
    case journalApp
    case journalLink
    case commandLineTools
    case screenRecording
    case microphone
    case lastSync
}

internal enum SetupCheckAction: Equatable, Sendable {
    case openApplications
    case openJournalSettings
    case connectJournal
    case grantPermission
}

internal enum SetupGroupVerdict: Equatable, Sendable {
    case ready
    case needsAttention(count: Int)
    case someUnavailable

    var axState: SetupGroupVerdictAXState {
        switch self {
        case .ready:
            return .ready
        case .needsAttention:
            return .needsAttention
        case .someUnavailable:
            return .someUnavailable
        }
    }

    var severity: StatusDotSeverity {
        switch self {
        case .ready:
            return .good
        case .needsAttention, .someUnavailable:
            return .attention
        }
    }

    var text: String {
        switch self {
        case .ready:
            return UICopy.SETTINGS_SETUP_VERDICT_READY
        case .needsAttention(let count):
            return UICopy.settingsSetupVerdictNeedsAttention(count)
        case .someUnavailable:
            return UICopy.SETTINGS_SETUP_VERDICT_UNAVAILABLE
        }
    }
}

internal struct SetupCheckRow: Equatable, Sendable, Identifiable {
    let id: SetupCheckRowID
    let label: String
    let value: String
    let state: SetupCheckRowAXState
    let systemImage: String
    let action: SetupCheckAction?
    let actionLabel: String?
    let votes: Bool
}

internal struct SetupSnapshotInput: Equatable, Sendable {
    let topology: SetupTopology
    let solAppPlacement: SetupProbeOutcome
    let journalAppInstalled: SetupProbeOutcome
    let serviceIsDone: Bool
    let solWrapperExecutable: SetupProbeOutcome
    let journalWrapperExecutable: SetupProbeOutcome
    let screenRecording: PermissionOutcome
    let microphone: PermissionOutcome
    let lastSyncOutcome: SetupLastSyncOutcome
    let now: Date
}

internal struct SetupProbeSnapshot: Equatable, Sendable {
    var solAppPlacement: SetupProbeOutcome
    var journalAppInstalled: SetupProbeOutcome
    var solWrapperExecutable: SetupProbeOutcome
    var journalWrapperExecutable: SetupProbeOutcome
    var hasPromptedScreenRecording: Bool
    var screenDiagnostic: ScreenRecordingPermissionDiagnostic?

    static let checking = SetupProbeSnapshot(
        solAppPlacement: .checking,
        journalAppInstalled: .checking,
        solWrapperExecutable: .checking,
        journalWrapperExecutable: .checking,
        hasPromptedScreenRecording: false,
        screenDiagnostic: nil
    )
}

internal struct SetupSnapshotPresentation: Equatable, Sendable {
    let verdict: SetupGroupVerdict
    let rows: [SetupCheckRow]
}

internal func buildSetupSnapshot(_ input: SetupSnapshotInput) -> SetupSnapshotPresentation {
    let localArtifactsRequired = input.serviceIsDone && input.topology == .local

    let rows: [SetupCheckRow] = [
        probeRow(
            id: .solApp,
            label: UICopy.SETTINGS_SETUP_SOL_APP_LABEL,
            readyText: UICopy.SETTINGS_SETUP_SOL_APP_READY,
            needsText: UICopy.SETTINGS_SETUP_SOL_APP_NEEDS_ATTENTION,
            unavailableText: UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK,
            outcome: input.solAppPlacement,
            votes: true,
            action: .openApplications,
            actionLabel: UICopy.SETTINGS_SETUP_SOL_APP_ACTION
        ),
        journalLinkRow(serviceIsDone: input.serviceIsDone),
        probeRow(
            id: .journalApp,
            label: UICopy.SETTINGS_SETUP_JOURNAL_APP_LABEL,
            readyText: UICopy.SETTINGS_SETUP_JOURNAL_APP_READY,
            needsText: UICopy.SETTINGS_SETUP_JOURNAL_APP_NEEDS_ATTENTION,
            unavailableText: UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK,
            outcome: localArtifactsRequired ? input.journalAppInstalled : .ready,
            votes: localArtifactsRequired,
            action: .openJournalSettings,
            actionLabel: UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION,
            notRequiredText: localArtifactsRequired ? nil : UICopy.SETTINGS_SETUP_SHARED_NOT_REQUIRED
        ),
        commandLineToolsRow(
            solWrapperExecutable: input.solWrapperExecutable,
            journalWrapperExecutable: input.journalWrapperExecutable,
            required: localArtifactsRequired
        ),
        permissionRow(
            id: .screenRecording,
            label: UICopy.SETTINGS_SETUP_SCREEN_RECORDING_LABEL,
            outcome: input.screenRecording,
            actionLabel: UICopy.SETTINGS_SETUP_SCREEN_RECORDING_ACTION
        ),
        permissionRow(
            id: .microphone,
            label: UICopy.SETTINGS_SETUP_MICROPHONE_LABEL,
            outcome: input.microphone,
            actionLabel: UICopy.SETTINGS_SETUP_MICROPHONE_ACTION
        ),
        lastSyncRow(input.lastSyncOutcome, now: input.now)
    ]

    return SetupSnapshotPresentation(verdict: rollupVerdict(rows), rows: rows)
}

private func rollupVerdict(_ rows: [SetupCheckRow]) -> SetupGroupVerdict {
    let votingRows = rows.filter(\.votes)
    if votingRows.contains(where: { $0.state == .unavailable || $0.state == .checking }) {
        return .someUnavailable
    }

    let attentionCount = votingRows.filter { $0.state == .needsAttention }.count
    if attentionCount > 0 {
        return .needsAttention(count: attentionCount)
    }

    return .ready
}

private func journalLinkRow(serviceIsDone: Bool) -> SetupCheckRow {
    if serviceIsDone {
        return SetupCheckRow(
            id: .journalLink,
            label: UICopy.SETTINGS_SETUP_JOURNAL_LINK_LABEL,
            value: UICopy.SETTINGS_SETUP_JOURNAL_LINK_READY,
            state: .ready,
            systemImage: setupSystemImage(for: .ready),
            action: nil,
            actionLabel: nil,
            votes: true
        )
    }

    return SetupCheckRow(
        id: .journalLink,
        label: UICopy.SETTINGS_SETUP_JOURNAL_LINK_LABEL,
        value: UICopy.SETTINGS_SETUP_JOURNAL_LINK_NEEDS_ATTENTION,
        state: .needsAttention,
        systemImage: setupSystemImage(for: .needsAttention),
        action: .connectJournal,
        actionLabel: UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION,
        votes: true
    )
}

private func probeRow(
    id: SetupCheckRowID,
    label: String,
    readyText: String,
    needsText: String,
    unavailableText: String,
    outcome: SetupProbeOutcome,
    votes: Bool,
    action: SetupCheckAction,
    actionLabel: String,
    notRequiredText: String? = nil
) -> SetupCheckRow {
    if let notRequiredText {
        return SetupCheckRow(
            id: id,
            label: label,
            value: notRequiredText,
            state: .notRequired,
            systemImage: setupSystemImage(for: .notRequired),
            action: nil,
            actionLabel: nil,
            votes: false
        )
    }

    let state = outcome.rowState
    let value: String
    switch outcome {
    case .ready:
        value = readyText
    case .needsAttention:
        value = needsText
    case .checking:
        value = UICopy.SETTINGS_SETUP_SHARED_CHECKING
    case .unavailable:
        value = unavailableText
    }

    return SetupCheckRow(
        id: id,
        label: label,
        value: value,
        state: state,
        systemImage: setupSystemImage(for: state),
        action: state == .needsAttention ? action : nil,
        actionLabel: state == .needsAttention ? actionLabel : nil,
        votes: votes
    )
}

private func commandLineToolsRow(
    solWrapperExecutable: SetupProbeOutcome,
    journalWrapperExecutable: SetupProbeOutcome,
    required: Bool
) -> SetupCheckRow {
    guard required else {
        return SetupCheckRow(
            id: .commandLineTools,
            label: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_LABEL,
            value: UICopy.SETTINGS_SETUP_SHARED_NOT_REQUIRED,
            state: .notRequired,
            systemImage: setupSystemImage(for: .notRequired),
            action: nil,
            actionLabel: nil,
            votes: false
        )
    }

    let outcome: SetupProbeOutcome
    if solWrapperExecutable == .unavailable || journalWrapperExecutable == .unavailable {
        outcome = .unavailable
    } else if solWrapperExecutable == .checking || journalWrapperExecutable == .checking {
        outcome = .checking
    } else if solWrapperExecutable == .needsAttention || journalWrapperExecutable == .needsAttention {
        outcome = .needsAttention
    } else {
        outcome = .ready
    }

    let row = probeRow(
        id: .commandLineTools,
        label: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_LABEL,
        readyText: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_READY,
        needsText: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_NEEDS_ATTENTION,
        unavailableText: UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK,
        outcome: outcome,
        votes: true,
        action: .openJournalSettings,
        actionLabel: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_ACTION
    )
    let hasKnownMissingWrapper = solWrapperExecutable == .needsAttention || journalWrapperExecutable == .needsAttention
    if hasKnownMissingWrapper, row.action == nil {
        return SetupCheckRow(
            id: row.id,
            label: row.label,
            value: row.value,
            state: row.state,
            systemImage: row.systemImage,
            action: .openJournalSettings,
            actionLabel: UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_ACTION,
            votes: row.votes
        )
    }
    return row
}

private func permissionRow(
    id: SetupCheckRowID,
    label: String,
    outcome: PermissionOutcome,
    actionLabel: String
) -> SetupCheckRow {
    let state: SetupCheckRowAXState
    let value: String
    switch outcome {
    case .checking:
        state = .checking
        value = UICopy.SETTINGS_SETUP_SHARED_CHECKING
    case .granted:
        state = .ready
        value = UICopy.SETTINGS_SETUP_SHARED_GRANTED
    case .notGranted:
        state = .needsAttention
        value = UICopy.SETTINGS_SETUP_SHARED_NOT_GRANTED
    case .unavailable:
        state = .unavailable
        value = UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK
    }

    return SetupCheckRow(
        id: id,
        label: label,
        value: value,
        state: state,
        systemImage: setupSystemImage(for: state),
        action: state == .needsAttention ? .grantPermission : nil,
        actionLabel: state == .needsAttention ? actionLabel : nil,
        votes: true
    )
}

private func lastSyncRow(_ outcome: SetupLastSyncOutcome, now: Date) -> SetupCheckRow {
    let value: String
    let state: SetupCheckRowAXState
    switch outcome {
    case .synced(let date):
        value = coarseRelativeTime(date, now: now)
        state = .ready
    case .noSyncYet:
        value = UICopy.SETTINGS_SETUP_LAST_SYNC_NEVER
        state = .notRequired
    case .notLinked:
        value = UICopy.SETTINGS_SETUP_LAST_SYNC_NOT_LINKED
        state = .notRequired
    case .couldNotCheck:
        value = UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK
        state = .unavailable
    }

    return SetupCheckRow(
        id: .lastSync,
        label: UICopy.SETTINGS_SETUP_LAST_SYNC_LABEL,
        value: value,
        state: state,
        systemImage: setupSystemImage(for: state),
        action: nil,
        actionLabel: nil,
        votes: false
    )
}

internal func setupSystemImage(for state: SetupCheckRowAXState) -> String {
    switch state {
    case .ready:
        return "checkmark.circle.fill"
    case .needsAttention:
        return "exclamationmark.triangle.fill"
    case .notRequired:
        return "minus.circle"
    case .checking:
        return "clock"
    case .unavailable:
        return "questionmark.circle.fill"
    }
}
