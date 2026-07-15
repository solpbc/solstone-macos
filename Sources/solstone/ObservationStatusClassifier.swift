// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore

internal func classifyObservationRowState(
    permissionsNeedAttention: Bool,
    errorMessage: String?,
    initialPermissionCheckComplete: Bool,
    isRecording: Bool,
    isPaused: Bool,
    serviceMode: ServiceMode?,
    syncPaused: Bool,
    isUploadConfigured: Bool,
    uploadStatus: UploadCoordinator.Status
) -> MenubarStatusRowState {
    if permissionsNeedAttention {
        return .permissions
    }
    if errorMessage != nil {
        return .error
    }
    if !initialPermissionCheckComplete {
        return .starting
    }
    if serviceMode == .bundled {
        return .journalMigrationNeeded
    }
    if !isRecording && !isPaused {
        return .error
    }
    if isPaused {
        return .paused
    }
    if syncPaused {
        return .syncPaused
    }
    if !isUploadConfigured {
        return .localOnly
    }
    switch uploadStatus {
    case .synced, .syncing, .uploading:
        return .observing
    case .awaitingTunnel:
        return .connectionWaiting
    case .notSynced, .retrying, .offline:
        return .offline
    }
}

/// Pure presentation for the menu-bar status-icon overlay badge.
/// `.localOnly` always paints the journal-setup badge — it wins over the
/// sol-chat inputs so the function stays total over the (production-unreachable)
/// `.localOnly` + sol-chat combinations. Every other row state reproduces the
/// view's historical overlay precedence exactly: stale, then pending, then none.
internal func menubarIconOverlayState(
    rowState: MenubarStatusRowState,
    solChatStale: Bool,
    solChatPending: Bool
) -> MenubarIconOverlayState {
    if rowState == .localOnly {
        return .journalSetup
    }
    if solChatStale {
        return .chatStale
    }
    if solChatPending {
        return .chatPending
    }
    return .none
}

internal struct ObservationRecoveryPresentation: Equatable {
    let reason: String
    let buttonLabel: String
    let buttonDisabled: Bool
}

/// Presentation for the Settings status-tab recovery affordance.
/// Returns nil when no "try again" affordance should render.
/// Gated on the raw 10-case `.error` (NOT the collapsed AX state) so
/// steady-state permission faults (which classify to `.permissions`) never show it.
internal func observationRecoveryPresentation(
    observationRowState: MenubarStatusRowState,
    errorMessage: String?,
    tryAgainInFlight: Bool
) -> ObservationRecoveryPresentation? {
    guard observationRowState == .error else { return nil }
    return ObservationRecoveryPresentation(
        reason: errorMessage ?? UICopy.SETTINGS_OBSERVATION_RECOVERY_FALLBACK,
        buttonLabel: tryAgainInFlight ? UICopy.SETTINGS_TRY_AGAIN_IN_FLIGHT : UICopy.SETTINGS_TRY_AGAIN,
        buttonDisabled: tryAgainInFlight
    )
}

extension AppState {
    internal var observationRowState: MenubarStatusRowState {
        classifyObservationRowState(
            permissionsNeedAttention: permissionsNeedAttention,
            errorMessage: errorMessage,
            initialPermissionCheckComplete: initialPermissionCheckComplete,
            isRecording: isRecording,
            isPaused: isPaused,
            serviceMode: config.serviceMode,
            syncPaused: config.syncPaused,
            isUploadConfigured: config.isUploadConfigured,
            uploadStatus: uploadCoordinator.status
        )
    }
}
