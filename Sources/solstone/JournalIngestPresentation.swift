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
            message: "can't reach your journal right now",
            caption: nil,
            axToken: PairingConnectionAXState.mismatch.axToken,
            failureCause: .mismatch
        )
    }

    return tunnel
}

func classifiedObserverHealthOwnerCopy(_ reason: ObserverHealthFailureReason) -> String {
    switch reason {
    case .httpStatus(404):
        return "your journal isn't taking this in"
    case .httpStatus(403):
        return "pairing was revoked. pair again to reconnect."
    case .httpStatus:
        return "journal connection error"
    case .urlErrorCode:
        return "can't reach your journal"
    case .uploadInvalidURL:
        return "invalid journal address"
    case .uploadNoFiles:
        return "nothing to add yet"
    case .uploadInvalidResponse:
        return "couldn't understand your journal"
    case .configChanged:
        return "settings changed, starting over"
    case .notConfigured:
        return "your journal isn't linked"
    case .uploadFailed:
        return "couldn't add this to your journal"
    }
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

/// Activity describes this sync pass; only the delivery receipt proves an addition.
func journalSyncStatusText(_ status: UploadCoordinator.Status, paused: Bool, ready: Bool) -> String {
    if paused { return "sync paused" }
    if !ready { return "waiting for a connection" }
    switch status {
    case .notSynced:
        return "sync hasn't checked yet"
    case .synced:
        return "sync check complete"
    case .syncing, .uploading:
        return "syncing to your journal…"
    case .retrying:
        return "waiting to retry"
    case .awaitingTunnel:
        return "waiting for a connection"
    case .offline(let error):
        return error
    }
}
