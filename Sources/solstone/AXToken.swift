// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
//
// Accessibility identifiers and tokens are sourced from AXID.swift and this file.
// ax-contract.json is generated from those Swift sources with `make ax-contract`,
// and `make ci` gates drift. Consumers must import the generated contract instead
// of hardcoding identifiers or token lists.

import SwiftUI
import SolstoneCore

internal enum AXPermissionState: CaseIterable {
    case granted
    case denied
    case waiting
}

internal enum MenubarIconState: CaseIterable {
    case recording
    case offline
    case paused
    case error

    var iconName: String {
        switch self {
        case .recording:
            return "sol-ring-template"
        case .offline:
            return "sol-ring-icon-half-template"
        case .paused:
            return "sol-ring-icon-paused-template"
        case .error:
            return "sol-ring-icon-error-template"
        }
    }
}

internal enum MenubarIconOverlayState: CaseIterable {
    case none
    case journalSetup
    case chatStale
    case chatPending
}

internal enum MenubarStatusRowState: CaseIterable {
    case permissions
    case error
    case starting
    case journalMigrationNeeded
    case connectionWaiting
    case localOnly
    case syncPaused
    case offline
    case paused
    case observing
}

internal enum SettingsObservationAXState: CaseIterable {
    case observing
    case paused
    case starting
    case error

    init(_ rowState: MenubarStatusRowState) {
        switch rowState {
        case .starting:
            self = .starting
        case .paused:
            self = .paused
        default:
            switch rowState.iconState {
            case .error:
                self = .error
            case .paused:
                self = .paused
            case .recording, .offline:
                self = .observing
            }
        }
    }
}

internal enum SetupCheckRowAXState: CaseIterable {
    case ready
    case needsAttention
    case notRequired
    case checking
    case unavailable
}

internal enum SetupGroupVerdictAXState: CaseIterable {
    case ready
    case needsAttention
    case someUnavailable
}

internal enum PairingConnectionAXState: CaseIterable {
    case disconnected
    case connecting
    case connected
    case notEntitled
    case revoked
    case loopbackUnavailable
    case keychainUnavailable
}

internal enum PairingRelayAccessAXState: CaseIterable {
    case unavailable
}

internal enum JournalHandoffAXState: CaseIterable {
    case idle
    case acquiring
    case checkingRunningJournal
    case writingHandoff
    case launchingJournal
    case waitingForAdoption
    case authGate
    case flippingToExternal
    case triggeringSyncDrain
    case confirmingMarkBestEffort
    case completed
    case failed
    case aborted
}

internal enum FreshJournalAXState: CaseIterable {
    case idle
    case acquiring
    case launching
    case waitingForJournal
    case failed
}

internal enum LocalJournalDiscoveryAXState: CaseIterable {
    case searching
    case foundRunning
    case foundOnDisk
    case notFound
}

extension UploadCoordinator.Status {
    public static let axTokens = [
        "not_synced",
        "syncing",
        "synced",
        "uploading",
        "retrying",
        "awaiting_tunnel",
        "offline"
    ]

    var axToken: String {
        switch self {
        case .notSynced:
            return "not_synced"
        case .syncing:
            return "syncing"
        case .synced:
            return "synced"
        case .uploading:
            return "uploading"
        case .retrying:
            return "retrying"
        case .awaitingTunnel:
            return "awaiting_tunnel"
        case .offline:
            return "offline"
        }
    }
}

extension ConnectionTestState {
    public static let axTokens = [
        "idle",
        "testing",
        "success",
        "failure"
    ]

    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .testing:
            return "testing"
        case .success:
            return "success"
        case .failure:
            return "failure"
        }
    }
}

extension PairingFlowState {
    static let axTokens = [
        "idle",
        "pairing",
        "switch_confirm_pending",
        "paired",
        "already_connected",
        "switched",
        "save_failed",
        "failed"
    ]

    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .pairing:
            return "pairing"
        case .switchConfirmPending:
            return "switch_confirm_pending"
        case .paired:
            return "paired"
        case .alreadyConnected:
            return "already_connected"
        case .switched:
            return "switched"
        case .saveFailed:
            return "save_failed"
        case .failed:
            return "failed"
        }
    }
}

extension PairingFailure {
    static let axTokens = [
        "stale_link",
        "home_unreachable",
        "relay_unauthorized",
        "instance_mismatch",
        "network",
        "invalid_link",
        "local_setup"
    ]

    var axToken: String {
        switch self {
        case .staleLink:
            return "stale_link"
        case .homeUnreachable:
            return "home_unreachable"
        case .relayUnauthorized:
            return "relay_unauthorized"
        case .instanceMismatch:
            return "instance_mismatch"
        case .network:
            return "network"
        case .invalidLink:
            return "invalid_link"
        case .localSetup:
            return "local_setup"
        }
    }
}

extension PairingConnectionAXState {
    static let axTokens = [
        "disconnected",
        "connecting",
        "connected",
        "not_entitled",
        "revoked",
        "loopback_unavailable",
        "keychain_unavailable"
    ]

    var axToken: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .notEntitled:
            return "not_entitled"
        case .revoked:
            return "revoked"
        case .loopbackUnavailable:
            return "loopback_unavailable"
        case .keychainUnavailable:
            return "keychain_unavailable"
        }
    }
}

extension PairingRelayAccessAXState {
    static let axTokens = [
        "unavailable"
    ]

    var axToken: String {
        switch self {
        case .unavailable:
            return "unavailable"
        }
    }
}

extension JournalHandoffAXState {
    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .acquiring:
            return "acquiring"
        case .checkingRunningJournal:
            return "checking_running_journal"
        case .writingHandoff:
            return "writing_handoff"
        case .launchingJournal:
            return "launching_journal"
        case .waitingForAdoption:
            return "waiting_for_adoption"
        case .authGate:
            return "auth_gate"
        case .flippingToExternal:
            return "flipping_to_external"
        case .triggeringSyncDrain:
            return "triggering_sync_drain"
        case .confirmingMarkBestEffort:
            return "confirming_mark_best_effort"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .aborted:
            return "aborted"
        }
    }
}

extension FreshJournalAXState {
    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .acquiring:
            return "acquiring"
        case .launching:
            return "launching"
        case .waitingForJournal:
            return "waiting_for_journal"
        case .failed:
            return "failed"
        }
    }
}

extension LocalJournalDiscoveryAXState {
    var axToken: String {
        switch self {
        case .searching:
            return "searching"
        case .foundRunning:
            return "found_running"
        case .foundOnDisk:
            return "found_on_disk"
        case .notFound:
            return "not_found"
        }
    }
}

extension AXPermissionState {
    var axToken: String {
        switch self {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .waiting:
            return "waiting"
        }
    }
}

extension SetupCheckRowAXState {
    var axToken: String {
        switch self {
        case .ready:
            return "ready"
        case .needsAttention:
            return "needs_attention"
        case .notRequired:
            return "not_required"
        case .checking:
            return "checking"
        case .unavailable:
            return "unavailable"
        }
    }
}

extension SetupGroupVerdictAXState {
    var axToken: String {
        switch self {
        case .ready:
            return "ready"
        case .needsAttention:
            return "needs_attention"
        case .someUnavailable:
            return "some_unavailable"
        }
    }
}

extension MenubarIconState {
    var axToken: String {
        switch self {
        case .recording:
            return "recording"
        case .offline:
            return "offline"
        case .paused:
            return "paused"
        case .error:
            return "error"
        }
    }
}

extension MenubarIconOverlayState {
    var axToken: String {
        switch self {
        case .none:
            return "none"
        case .journalSetup:
            return "journal_setup"
        case .chatStale:
            return "chat_stale"
        case .chatPending:
            return "chat_pending"
        }
    }
}

extension MenubarStatusRowState {
    var iconState: MenubarIconState {
        switch self {
        case .permissions, .error:
            return .error
        case .starting,
             .journalMigrationNeeded,
             .connectionWaiting,
             .localOnly,
             .syncPaused,
             .offline:
            return .offline
        case .paused:
            return .paused
        case .observing:
            return .recording
        }
    }
}

extension MenubarStatusRowState {
    var axToken: String {
        switch self {
        case .permissions:
            return "permissions"
        case .error:
            return "error"
        case .starting:
            return "starting"
        case .journalMigrationNeeded:
            return "journal_migration_needed"
        case .connectionWaiting:
            return "connection_waiting"
        case .localOnly:
            return "local_only"
        case .syncPaused:
            return "sync_paused"
        case .offline:
            return "offline"
        case .paused:
            return "paused"
        case .observing:
            return "on"
        }
    }
}

extension SettingsObservationAXState {
    var axToken: String {
        switch self {
        case .observing:
            return "on"
        case .paused:
            return "paused"
        case .starting:
            return "starting"
        case .error:
            return "error"
        }
    }
}

extension SettingsView.SidebarBadgeState {
    var axToken: String {
        switch self {
        case .attention:
            return "attention"
        case .done:
            return "done"
        case .blank:
            return "none"
        }
    }
}

func axIntegerString(_ value: Int) -> String {
    String(value)
}
