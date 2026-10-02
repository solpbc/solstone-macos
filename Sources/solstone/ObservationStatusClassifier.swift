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
    isPairedIngestReady: Bool,
    uploadStatus: UploadCoordinator.Status,
    hasJournalOnRecord: Bool = true,
    journalConnectionAXToken: String? = nil,
    journalFailureCause: JournalConnectionFailureCause? = nil,
    browserIntakePermitted: Bool = false,
    browserIntakePaused: Bool = false,
    browserOnlyIntake: Bool = false,
    journalMarkHeld: Bool = false
) -> MenubarStatusRowState {
    let mediaActive = isRecording || isPaused
    let suppressPermissionGate = browserOnlyIntake && browserIntakePermitted && !mediaActive
    if permissionsNeedAttention && !suppressPermissionGate {
        return .permissions
    }
    if errorMessage != nil {
        return .error
    }
    if !initialPermissionCheckComplete && !suppressPermissionGate {
        return .starting
    }
    if serviceMode == .bundled {
        return .journalMigrationNeeded
    }
    if !isRecording && !isPaused {
        if browserIntakePaused { return .paused }
        if browserIntakePermitted { return .observing }
        return .stopped
    }
    if isPaused {
        return .paused
    }
    if syncPaused {
        return .syncPaused
    }
    if !hasJournalOnRecord {
        return .localOnly
    }
    if journalMarkHeld {
        return .awaitingMarkConfirmation
    }
    if !isPairedIngestReady {
        if journalConnectionAXToken == PairingConnectionAXState.connecting.axToken {
            return .connectionWaiting
        }
        if journalFailureCause != nil {
            return .offline
        }
    }
    switch uploadStatus {
    case .synced, .syncing, .uploading:
        return .observing
    case .notSynced where isPairedIngestReady, .retrying where isPairedIngestReady:
        // Connected and the first pass hasn't run yet, as right after the mark is
        // answered, or an upload is being tried again over a working connection:
        // nothing is offline. A pass that cannot reach the journal reports offline.
        return .observing
    case .awaitingTunnel:
        return .connectionWaiting
    case .notSynced, .retrying, .offline:
        return .offline
    }
}

internal enum AttentionReason: Equatable, CaseIterable {
    case permissions, privateWindows, journal, updateAvailable, updateCheckFailed
}

internal struct MenubarPresentation: Equatable {
    let observation: MenubarStatusRowState
    let attention: AttentionReason?

    var icon: MenubarIconState { observation.iconState }
    var showsAttentionBadge: Bool { attention != nil || observation == .awaitingMarkConfirmation }

    var overlayState: MenubarIconOverlayState {
        showsAttentionBadge ? .attention : .none
    }
}

internal func classifyMenubarPresentation(
    observation: MenubarStatusRowState,
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus,
    privateWindowsNeedAttention: Bool = false
) -> MenubarPresentation {
    MenubarPresentation(
        observation: observation,
        attention: firstAttentionReason(
            permissionsNeedAttention: permissionsNeedAttention,
            journalNeedsAttention: journalNeedsAttention,
            durableUpdateStatus: durableUpdateStatus,
            privateWindowsNeedAttention: privateWindowsNeedAttention
        )
    )
}

private func firstAttentionReason(
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus,
    privateWindowsNeedAttention: Bool
) -> AttentionReason? {
    if permissionsNeedAttention { return .permissions }
    if privateWindowsNeedAttention { return .privateWindows }
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
    alreadySaidBy observation: MenubarStatusRowState,
    journalFailureCause: JournalConnectionFailureCause? = nil
) -> AttentionReason? {
    guard let reason else { return nil }
    switch reason {
    case .permissions:
        return observation == .permissions ? nil : reason
    case .journal:
        if observation == .journalMigrationNeeded || observation == .localOnly {
            return nil
        }
        if observation == .connectionWaiting {
            return nil
        }
        if observation == .offline, let journalFailureCause {
            switch journalFailureCause {
            case .noRoute, .unreachable:
                return nil
            case .revoked, .keychainUnavailable, .notEntitled, .loopbackUnavailable, .mismatch, .notServing:
                return reason
            }
        }
        return reason
    case .privateWindows, .updateAvailable, .updateCheckFailed:
        return reason
    }
}

internal func attentionSuffix(
    _ reason: AttentionReason,
    verdict: JournalConnectionVerdict? = nil
) -> String {
    switch reason {
    case .permissions: return UICopy.SETTINGS_ATTENTION_PERMISSIONS
    case .privateWindows: return UICopy.SETTINGS_ATTENTION_PRIVATE_WINDOWS
    case .journal:
        if let verdict, verdict.failureCause != nil {
            return verdict.message
        }
        return UICopy.SETTINGS_ATTENTION_JOURNAL
    case .updateAvailable: return UICopy.SETTINGS_ATTENTION_UPDATE_AVAILABLE
    case .updateCheckFailed: return UICopy.SETTINGS_ATTENTION_UPDATE_CHECK_FAILED
    }
}

internal struct SettingsRowLabel: Equatable, Sendable {
    let title: String
    let showsAttentionIcon: Bool
}

internal func settingsRowLabel(
    observation: MenubarStatusRowState,
    attention: AttentionReason?,
    verdict: JournalConnectionVerdict?
) -> SettingsRowLabel {
    let surfacedReason: AttentionReason?
    if attention == .journal, observation == .offline, let cause = verdict?.failureCause {
        switch cause {
        case .noRoute, .unreachable:
            surfacedReason = .journal
        case .revoked, .keychainUnavailable, .notEntitled, .loopbackUnavailable, .mismatch, .notServing:
            surfacedReason = attentionToSurface(
                attention,
                alreadySaidBy: observation,
                journalFailureCause: cause
            )
        }
    } else {
        surfacedReason = attentionToSurface(
            attention,
            alreadySaidBy: observation,
            journalFailureCause: verdict?.failureCause
        )
    }

    if let reason = surfacedReason {
        return SettingsRowLabel(
            title: "settings… · \(attentionSuffix(reason, verdict: verdict))",
            showsAttentionIcon: true
        )
    } else {
        return SettingsRowLabel(
            title: "settings…",
            showsAttentionIcon: false
        )
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
        let verdict = tunnelLifecycleOwner.connectionVerdict
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
        let browserOnly = config.selectedSources.isEmpty && config.isBrowserIntakeEnabled
#else
        let browserOnly = false
#endif
        return classifyObservationRowState(
            permissionsNeedAttention: permissionsNeedAttention,
            errorMessage: errorMessage,
            initialPermissionCheckComplete: initialPermissionCheckComplete,
            isRecording: isRecording,
            isPaused: isPaused,
            serviceMode: config.serviceMode,
            syncPaused: config.syncPaused,
            isPairedIngestReady: isPairedIngestReady,
            uploadStatus: uploadCoordinator.status,
            hasJournalOnRecord: tunnelLifecycleOwner.pairingIdentityRead != .absent
                || config.isUploadConfigured,
            journalConnectionAXToken: verdict.axToken,
            journalFailureCause: verdict.failureCause,
            browserIntakePermitted: browserRowPermitted,
            browserIntakePaused: browserRowPaused,
            browserOnlyIntake: browserOnly,
            journalMarkHeld: needsJournalMarkConfirmation
        )
    }

    internal func menubarPresentation(durableUpdateStatus: DurableUpdateStatus) -> MenubarPresentation {
        classifyMenubarPresentation(
            observation: observationRowState,
            permissionsNeedAttention: permissionsNeedAttention,
            journalNeedsAttention: serviceNeedsAttention,
            durableUpdateStatus: durableUpdateStatus,
            privateWindowsNeedAttention: privateWindowAccessibilityEnabled
                && privateWindowAccessibilityMonitor.needsAttention
        )
    }
}
