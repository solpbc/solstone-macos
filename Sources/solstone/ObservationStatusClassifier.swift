// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SolstoneCore
import UpdateKit

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

internal enum AttentionReason: Equatable, CaseIterable {
    case permissions, journal, updateAvailable, updateCheckFailed
}

internal struct MenubarPresentation: Equatable {
    let observation: MenubarStatusRowState
    let attention: AttentionReason?

    var icon: MenubarIconState { observation.iconState }
    var showsAttentionBadge: Bool { attention != nil }

    var overlayState: MenubarIconOverlayState {
        showsAttentionBadge ? .attention : .none
    }
}

internal func classifyMenubarPresentation(
    observation: MenubarStatusRowState,
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus
) -> MenubarPresentation {
    MenubarPresentation(
        observation: observation,
        attention: firstAttentionReason(
            permissionsNeedAttention: permissionsNeedAttention,
            journalNeedsAttention: journalNeedsAttention,
            durableUpdateStatus: durableUpdateStatus
        )
    )
}

private func firstAttentionReason(
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus
) -> AttentionReason? {
    if permissionsNeedAttention { return .permissions }
    if journalNeedsAttention { return .journal }
    return updateAttentionReason(for: durableUpdateStatus)
}

internal func updateAttentionReason(for status: DurableUpdateStatus) -> AttentionReason? {
    switch status {
    case .deferred, .staged, .failedWithAvailable, .available:
        return .updateAvailable
    case .failed:
        return .updateCheckFailed
    case .upToDate, .idle:
        return nil
    }
}

internal func attentionToSurface(
    _ reason: AttentionReason?,
    alreadySaidBy observation: MenubarStatusRowState
) -> AttentionReason? {
    guard let reason else { return nil }
    switch reason {
    case .permissions:
        return observation == .permissions ? nil : reason
    case .journal:
        return observation == .journalMigrationNeeded || observation == .localOnly ? nil : reason
    case .updateAvailable, .updateCheckFailed:
        return reason
    }
}

internal func attentionSuffix(_ reason: AttentionReason) -> String {
    switch reason {
    case .permissions: return UICopy.SETTINGS_ATTENTION_PERMISSIONS
    case .journal: return UICopy.SETTINGS_ATTENTION_JOURNAL
    case .updateAvailable: return UICopy.SETTINGS_ATTENTION_UPDATE_AVAILABLE
    case .updateCheckFailed: return UICopy.SETTINGS_ATTENTION_UPDATE_CHECK_FAILED
    }
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

    internal func menubarPresentation(durableUpdateStatus: DurableUpdateStatus) -> MenubarPresentation {
        classifyMenubarPresentation(
            observation: observationRowState,
            permissionsNeedAttention: permissionsNeedAttention,
            journalNeedsAttention: serviceNeedsAttention,
            durableUpdateStatus: durableUpdateStatus
        )
    }
}
