// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

internal func classifyObservationRowState(
    permissionsNeedAttention: Bool,
    errorMessage: String?,
    initialPermissionCheckComplete: Bool,
    isRecording: Bool,
    isPaused: Bool,
    captureQueuedForJournalReadiness: Bool,
    bundledJournalStatusAvailable: Bool,
    journalRuntimeStatus: JournalRuntimeStatus,
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
    if !isRecording && !isPaused {
        return .error
    }
    if isPaused {
        return .paused
    }
    if captureQueuedForJournalReadiness {
        return .journalWaiting
    }
    if bundledJournalStatusAvailable {
        switch journalRuntimeStatus {
        case .running:
            return .observing
        case .setupNeeded:
            return .journalSetupNeeded
        case .restarting:
            return .journalRestarting
        case .stopped:
            return .journalStopped
        case .unknown:
            return .journalUnknown
        case .stoppedByUser:
            return .journalStoppedByUser
        }
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
        return .journalWaiting
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
            captureQueuedForJournalReadiness: captureQueuedForJournalReadiness,
            bundledJournalStatusAvailable: bundledJournalStatusAvailable,
            journalRuntimeStatus: journalRuntimeStatus,
            syncPaused: config.syncPaused,
            isUploadConfigured: config.isUploadConfigured,
            uploadStatus: uploadCoordinator.status
        )
    }
}
