// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

func overlayIngestOnConnectionVerdict(
    tunnel: JournalConnectionVerdict,
    pairingMismatch: Bool,
    healthReason: ObserverHealthFailureReason?
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

    guard tunnel.axToken == PairingConnectionAXState.connected.axToken,
          let healthReason else {
        return tunnel
    }

    switch healthReason {
    case .httpStatus(404):
        return JournalConnectionVerdict(
            severity: .attention,
            message: classifiedObserverHealthOwnerCopy(healthReason),
            caption: nil,
            axToken: PairingConnectionAXState.notServing.axToken,
            failureCause: .notServing
        )
    case .httpStatus(403):
        return JournalConnectionVerdict(
            severity: .attention,
            message: "pairing was revoked. pair again to reconnect.",
            caption: nil,
            axToken: PairingConnectionAXState.revoked.axToken,
            failureCause: .revoked
        )
    case .urlErrorCode:
        return JournalConnectionVerdict(
            severity: .attention,
            message: "can't reach your journal right now",
            caption: nil,
            axToken: PairingConnectionAXState.unreachable.axToken,
            failureCause: .unreachable(nil)
        )
    default:
        return tunnel
    }
}

func classifiedObserverHealthOwnerCopy(_ reason: ObserverHealthFailureReason) -> String {
    switch reason {
    case .httpStatus(404):
        return "your journal isn't serving this Mac"
    case .httpStatus(403):
        return "this Mac is disabled"
    case .httpStatus(let statusCode):
        return "your journal returned an error (\(statusCode))"
    case .urlErrorCode:
        return "can't reach your journal"
    case .uploadInvalidURL:
        return "invalid journal address"
    case .uploadNoFiles:
        return "No files to upload"
    case .uploadInvalidResponse:
        return "invalid journal response"
    case .configChanged:
        return "journal connection changed"
    case .notConfigured:
        return "Not configured"
    case .uploadFailed:
        return "couldn't send this recording to your journal"
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
