// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

func journalConnectionVerdictPresentation(
    tunnel: JournalConnectionVerdict,
    pairingMismatch: Bool
) -> JournalConnectionVerdict {
    if pairingMismatch {
        return JournalConnectionVerdict(
            severity: .attention,
            message: MacStrings.macos_app_cantreachyourjournalrightnow(),
            caption: nil,
            axToken: PairingConnectionAXState.mismatch.axToken,
            failureCause: .mismatch
        )
    }

    return tunnel
}

func classifiedObserverHealthOwnerCopy(_ reason: ObserverHealthFailureReason) -> String {
    switch reason {
    case .pairingRevoked, .httpStatus(403):
        return MacStrings.macos_app_pairingwasrevokedpairagaintoreconnect()
    case .journalNotServing, .httpStatus(404), .httpStatus(426):
        return MacStrings.macos_app_yourjournalisnttakingthisin()
    case .journalRefused:
        return MacStrings.macos_app_yourjournalrefusedthissync()
    case .journalRejectedDay(let day, _):
        return MacStrings.macos_app_yourjournalcouldntread("\(ownerDayLabel(day))")
    case .httpStatus:
        return MacStrings.macos_app_journalconnectionerror()
    case .urlErrorCode:
        return MacStrings.macos_desktop_shared_app_offlinetitle()
    case .uploadInvalidURL:
        return MacStrings.macos_app_invalidjournaladdress()
    case .uploadNoFiles:
        return MacStrings.macos_app_nothingtoaddyet()
    case .uploadInvalidResponse:
        return MacStrings.macos_app_couldntunderstandyourjournal()
    case .configChanged:
        return MacStrings.macos_app_settingschangedstartingover()
    case .notConfigured:
        return MacStrings.macos_app_settingslastdeliverynotlinked()
    case .uploadFailed:
        return MacStrings.macos_app_couldntaddthistoyourjournal()
    }
}

/// `20260915` reads as `2026-09-15` to an owner; anything else is shown as sent.
func ownerDayLabel(_ day: String) -> String {
    guard day.count == 8, day.allSatisfy(\.isNumber) else { return day }
    let year = day.prefix(4)
    let month = day.dropFirst(4).prefix(2)
    let dayOfMonth = day.suffix(2)
    return "\(year)-\(month)-\(dayOfMonth)"
}

enum JournalPanelRemedy: Equatable {
    case pairing
    case openJournal
    case tunnelRetry
    case none
}

struct JournalPanelAffordances: Equatable {
    let showRelink: Bool
    let showOpenJournal: Bool
    let showPairingForm: Bool
    let showTunnelRetry: Bool
}

func journalPanelRemedy(
    failureCause: JournalConnectionFailureCause?,
    axToken: String
) -> JournalPanelRemedy {
    if failureCause == .notServing {
        return .openJournal
    }
    if failureCause == nil, axToken == PairingConnectionAXState.disconnected.axToken {
        return .pairing
    }
    switch failureCause {
    case .revoked, .keychainUnavailable:
        return .pairing
    case .noRoute, .unreachable, .loopbackUnavailable:
        return .tunnelRetry
    default:
        return .none
    }
}

func journalPanelAffordances(for remedy: JournalPanelRemedy) -> JournalPanelAffordances {
    switch remedy {
    case .openJournal:
        return JournalPanelAffordances(
            showRelink: false,
            showOpenJournal: true,
            showPairingForm: false,
            showTunnelRetry: false
        )
    case .pairing:
        return JournalPanelAffordances(
            showRelink: true,
            showOpenJournal: false,
            showPairingForm: true,
            showTunnelRetry: false
        )
    case .tunnelRetry:
        return JournalPanelAffordances(
            showRelink: true,
            showOpenJournal: false,
            showPairingForm: false,
            showTunnelRetry: true
        )
    case .none:
        return JournalPanelAffordances(
            showRelink: true,
            showOpenJournal: false,
            showPairingForm: true,
            showTunnelRetry: false
        )
    }
}

struct JournalSyncStatusSymbol: Equatable, Sendable {
    let systemName: String
    let usesSecondaryStyle: Bool
}

/// Activity describes this sync pass; only the delivery receipt proves an addition.
func journalSyncStatusText(_ status: UploadCoordinator.Status, paused: Bool, ready: Bool, held: Bool) -> String {
    if paused { return MacStrings.macos_app_syncpaused() }
    if held { return UICopy.JOURNAL_MARK_HELD }
    if !ready { return MacStrings.macos_app_waitingforaconnection() }
    switch status {
    case .notSynced:
        return MacStrings.macos_app_synchasntcheckedyet()
    case .synced:
        return MacStrings.macos_app_synccheckcomplete()
    case .syncing, .uploading:
        return MacStrings.macos_app_syncingtoyourjournal2()
    case .retrying:
        return MacStrings.macos_app_waitingtoretry()
    case .awaitingTunnel:
        return MacStrings.macos_app_waitingforaconnection()
    case .offline(let error):
        return error
    case .blocked(let reason):
        return reason
    }
}

func journalSyncStatusSymbol(_ status: UploadCoordinator.Status, paused: Bool, ready: Bool, held: Bool) -> JournalSyncStatusSymbol {
    if paused {
        return JournalSyncStatusSymbol(systemName: "pause.circle", usesSecondaryStyle: true)
    }
    if held {
        return JournalSyncStatusSymbol(systemName: "hand.raised.circle", usesSecondaryStyle: true)
    }
    if !ready {
        return JournalSyncStatusSymbol(systemName: "pause.circle", usesSecondaryStyle: true)
    }
    let systemName = switch status {
    case .notSynced:
        "questionmark.circle"
    case .synced:
        "checkmark.circle"
    case .syncing:
        "arrow.triangle.2.circlepath"
    case .uploading:
        "arrow.up.circle"
    case .retrying:
        "exclamationmark.triangle"
    case .awaitingTunnel:
        "arrow.triangle.2.circlepath"
    case .offline:
        "xmark.circle"
    case .blocked:
        "exclamationmark.triangle"
    }
    return JournalSyncStatusSymbol(systemName: systemName, usesSecondaryStyle: false)
}
