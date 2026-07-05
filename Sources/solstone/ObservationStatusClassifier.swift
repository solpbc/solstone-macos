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
