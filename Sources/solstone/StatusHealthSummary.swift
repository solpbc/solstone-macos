import Foundation
import SwiftUI
import SolstoneCore

internal enum StatusDotSeverity: Equatable, Sendable {
    case good, calm, warn, attention

    var color: Color {
        switch self {
        case .good:
            return .green
        case .calm:
            return .secondary
        case .warn:
            return .orange
        case .attention:
            return .red
        }
    }
}

/// The single recovery action a health callout may carry. A callout the owner can do
/// nothing with is noise, so a non-green verdict names the one place that fixes it.
internal struct StatusHealthAction: Equatable, Sendable {
    let label: String
    let settingsTab: String
    let reasksJournalMark: Bool
}

internal struct StatusHealthSummary: Equatable, Sendable {
    let severity: StatusDotSeverity
    let title: String
    let subtitle: String?
    let axValue: String
    let action: StatusHealthAction?

    init(
        severity: StatusDotSeverity,
        title: String,
        subtitle: String?,
        axValue: String,
        action: StatusHealthAction? = nil
    ) {
        self.severity = severity
        self.title = title
        self.subtitle = subtitle
        self.axValue = axValue
        self.action = action
    }
}

internal func coarseRelativeTime(_ date: Date, now: Date) -> String {
    let interval = now.timeIntervalSince(date)
    if interval < 60 {
        return MacStrings.macos_desktop_shared_app_justnow()
    }
    if interval < 3_600 {
        return MacStrings.macos_app_mago(MacStrings.number(Int(interval / 60)))
    }
    if interval < 86_400 {
        return MacStrings.macos_app_hago(MacStrings.number(Int(interval / 3_600)))
    }
    return MacStrings.macos_app_dago(MacStrings.number(Int(interval / 86_400)))
}

internal func bundledStatusFooterText(permissionsGranted: Bool, microphoneCount: Int) -> String {
    return permissionsGranted
        ? MacStrings.macos_status_footergranted(microphoneCount)
        : MacStrings.macos_status_footerattention(microphoneCount)
}

extension StatusHealthSummary {
    static func make(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
        ownerPauseHeldIdle: Bool = false,
        held: Bool,
        hasPersistedPairing: Bool,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastDeliveryOutcome: LastJournalDeliveryOutcome,
        journalSlot: String,
        now: Date,
        selectedSources: CaptureSources = .all,
        otherSourceOn: Bool = false,
        permittedSources: CaptureSources = .all,
        errorMessage: String? = nil,
        setupVerdict: SetupGroupVerdict? = nil,
        lastHealthReason: ObserverHealthFailureReason? = nil,
        isPairedIngestReady: Bool = true,
        presentedConnection: PresentedJournalConnection = .connected,
        startDeferredForProtectedVideo: Bool = false,
        screenFailure: ScreenFailureKind? = nil
    ) -> StatusHealthSummary {
        // A migrated Mac can retain successful delivery and mark-confirmation records
        // after its device-bound pairing is gone. Absence leads every connection state.
        if !hasPersistedPairing {
            return .init(
                severity: isRecording || pendingCount > 0 ? .attention : .calm,
                title: UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED,
                subtitle: pendingCount > 0 ? MacStrings.macos_status_relinkwaiting(pendingCount) : MacStrings.macos_app_relinkinjournalsettingstoresume(),
                axValue: "external_not_linked",
                action: StatusHealthAction(
                    label: MacStrings.macos_app_openjournalsettings(),
                    settingsTab: "service",
                    reasksJournalMark: false
                )
            )
        }
        // The owner turning every source off is a choice, not a fault — but it is also the one
        // state in which nothing reaches the journal at all, so it leads the card and says why.
        // It outranks the setup rollup below, which reads green precisely BECAUSE an unselected
        // source cannot fail a setup check.
        if !isRecording, !isPaused, selectedSources.isEmpty, !otherSourceOn {
            return .init(
                severity: .calm,
                title: UICopy.SOURCES_NONE,
                subtitle: UICopy.SOURCES_NONE_REASON,
                axValue: "sources_off",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false)
            )
        }

        if !isRecording, !isPaused, !startDeferredForProtectedVideo, !otherSourceOn, selectedSources.intersection(permittedSources).isEmpty {
            return .init(
                severity: .attention,
                title: UICopy.SOURCES_NONE_GRANTED,
                subtitle: UICopy.SOURCES_GRANT_OR_CHANGE,
                axValue: "sources_unavailable",
                // The label has to name where the click actually lands. This routes to
                // solstone's own permissions pane, not to macOS System Settings.
                action: StatusHealthAction(
                    label: UICopy.PERMISSIONS_OPEN_ACTION,
                    settingsTab: "permissions",
                    reasksJournalMark: false
                )
            )
        }

        // A capture that FAILED is not a capture that is starting. The menubar has always
        // known this — its classifier takes errorMessage and renders a red error row — while
        // this card took no error input at all and fell through to the calm "starting…" that
        // every not-recording state shares. Two renderers of one truth, one of them blind.
        // Ordered after the source branches to match the menubar's own precedence
        // (a configuration fault outranks a run fault), and before the operational summary,
        // which cannot see an error either.
        if let errorMessage, !errorMessage.isEmpty, !isRecording, !isPaused {
            return .init(
                severity: .attention,
                title: UICopy.STATUS_CAPTURE_ERROR_TITLE,
                subtitle: errorMessage,
                axValue: "capture_error"
            )
        }

        if let screenFailure {
            return .init(
                severity: .attention,
                title: screenFailure == .couldNotStart ? UICopy.SCREEN_INTAKE_COULD_NOT_START : UICopy.SCREEN_INTAKE_STOPPED,
                subtitle: nil,
                axValue: AXID.Settings.Status.screenIntake,
                action: StatusHealthAction(
                    label: UICopy.SOURCES_OPEN_ACTION,
                    settingsTab: "sources",
                    reasksJournalMark: false
                )
            )
        }

        let operational = makeOperational(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            ownerPauseHeldIdle: ownerPauseHeldIdle,
            held: held,
            uploadStatus: statusForCurrentConnection(
                uploadStatus,
                ready: isPairedIngestReady,
                presented: presentedConnection,
                lastHealthReason: lastHealthReason
            ),
            pendingCount: pendingCount,
            lastDeliveryOutcome: lastDeliveryOutcome,
            journalSlot: journalSlot,
            now: now,
            lastHealthReason: lastHealthReason
        )
        guard let setupVerdict, setupVerdict.severity == .attention else {
            return operational
        }
        return StatusHealthSummary(
            severity: .attention,
            title: setupVerdict.text,
            subtitle: operational.title,
            axValue: setupVerdict.axState.axToken,
            action: operational.action
        )
    }

    private static func makeOperational(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
        ownerPauseHeldIdle: Bool,
        held: Bool,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastDeliveryOutcome: LastJournalDeliveryOutcome,
        journalSlot: String,
        now: Date,
        lastHealthReason: ObserverHealthFailureReason? = nil
    ) -> StatusHealthSummary {
        let isBundled = serviceMode == .bundled

        if isBundled {
            return .init(
                severity: .attention,
                title: MacStrings.macos_app_yourjournalneedsanewlink(),
                subtitle: MacStrings.macos_app_openyourjournalpaneltoconnectthis(),
                axValue: MenubarStatusRowState.journalMigrationNeeded.axToken
            )
        } else {
            if ownerPauseHeldIdle, let summary = captureFlagSummary(
                isRecording: isRecording,
                isPaused: isPaused,
                ownerPauseHeldIdle: true,
                isBundled: false,
                journalSlot: journalSlot,
                isSynced: false
            ) {
                return summary
            }
            if held {
                // isSynced: false so a stale .synced cannot name a journal that received nothing.
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: false
                ) {
                    return summary
                }
                return StatusHealthSummary(
                    severity: .calm,
                    title: UICopy.JOURNAL_MARK_HELD,
                    subtitle: UICopy.JOURNAL_MARK_HELD_CAPTION,
                    axValue: "external_awaiting_mark_confirmation",
                    action: StatusHealthAction(
                        label: UICopy.JOURNAL_MARK_CONFIRM_ACTION,
                        settingsTab: "service",
                        reasksJournalMark: true
                    )
                )
            }
            switch uploadStatus {
            case .blocked(let reason):
                return .init(
                    severity: .attention,
                    title: reason,
                    subtitle: MacStrings.macos_app_segmentkeptonthismac_native_plural(pendingCount),
                    axValue: "external_blocked"
                )
            case .awaitingTunnel:
                let subtitle = pendingCount > 0
                    ? MacStrings.macos_statushealthsummary_segmentwaitinghere_plural(pendingCount)
                    : MacStrings.macos_statushealthsummary_syncresumeswhenthejournalconnectionisready()
                return .init(
                    severity: .warn,
                    title: MacStrings.macos_app_setupconnectingtoyourjournal(),
                    subtitle: subtitle,
                    axValue: "external_awaiting_tunnel"
                )
            case .offline:
                if case .journalRejectedDay(let day, _)? = lastHealthReason {
                    // The journal is reachable and said it cannot read one day. Sending the
                    // owner to their network here would be wrong twice over.
                    // No "nothing is lost" here: the journal has reported a day it cannot read, and
                    // this app can vouch only for what is still on this mac.
                    let subtitle = pendingCount > 0
                        ? MacStrings.macos_statushealthsummary_segmentwaitingherekeptonthismacuntilyourjourn_plural(pendingCount)
                        : MacStrings.macos_statushealthsummary_syncresumesonceyourjournalcanreadthatday()
                    return .init(
                        severity: .attention,
                        title: MacStrings.macos_app_yourjournalcouldntread("\(ownerDayLabel(day))"),
                        subtitle: subtitle,
                        axValue: "external_offline"
                    )
                }
                let subtitle = pendingCount > 0
                    ? MacStrings.macos_statushealthsummary_segmentwaitingherenothingislostsyncresumeswhe_plural(pendingCount)
                    : MacStrings.macos_statushealthsummary_nothingislostsyncresumeswhenitsback()
                if let reason = lastHealthReason {
                    switch reason {
                    case .pairingRevoked, .journalNotServing, .journalRefused,
                         .httpStatus(403), .httpStatus(404), .httpStatus(426):
                        return .init(
                            severity: .attention,
                            title: classifiedObserverHealthOwnerCopy(reason),
                            subtitle: subtitle,
                            axValue: "external_offline"
                        )
                    default:
                        break
                    }
                }
                return .init(
                    severity: .attention,
                    title: MacStrings.macos_desktop_shared_app_offlinetitle(),
                    subtitle: subtitle,
                    axValue: "external_offline"
                )
            case .retrying:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: false
                ) {
                    return summary
                }
                let subtitle = pendingCount > 0
                    ? MacStrings.macos_statushealthsummary_segmentwaiting_plural(pendingCount)
                    : MacStrings.macos_statushealthsummary_retryingthelastupload()
                return .init(
                    severity: .warn,
                    title: MacStrings.macos_app_catchingupretryinganupload(),
                    subtitle: subtitle,
                    axValue: "external_retrying"
                )
            case .syncing(let checked, let total):
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: false
                ) {
                    return summary
                }
                return .init(
                    severity: .warn,
                    title: MacStrings.macos_app_catchingupofsegments(MacStrings.number(checked), MacStrings.number(total)),
                    subtitle: MacStrings.macos_app_syncingtoyourjournal(),
                    axValue: "external_syncing"
                )
            case .uploading:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: false
                ) {
                    return summary
                }
                let subtitle = pendingCount > 0 ? MacStrings.macos_statushealthsummary_morewaiting(MacStrings.number(pendingCount)) : MacStrings.macos_app_syncingtoyourjournal()
                return .init(
                    severity: .warn,
                    title: MacStrings.macos_app_catchingupsendingthelatest(),
                    subtitle: subtitle,
                    axValue: "external_uploading"
                )
            case .notSynced:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: false
                ) {
                    return summary
                }
                // Only reached while connected: the first pass has not reported yet.
                return .init(
                    severity: .calm,
                    title: UICopy.SETTINGS_OBSERVATION_OBSERVING,
                    subtitle: nil,
                    axValue: "external_connecting"
                )
            case .synced:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    ownerPauseHeldIdle: ownerPauseHeldIdle,
                    isBundled: false,
                    journalSlot: journalSlot,
                    isSynced: true
                ) {
                    return summary
                }
                switch lastDeliveryOutcome {
                case .delivered(let date):
                    return .init(
                        severity: .good,
                        title: MacStrings.macos_app_allgoodonsyncedto("\(journalSlot)"),
                        subtitle: pendingCount == 0 ? MacStrings.macos_status_deliveredempty(coarseRelativeTime(date, now: now)) : MacStrings.macos_status_deliveredwaiting(coarseRelativeTime(date, now: now), String(pendingCount)),
                        axValue: "external_synced"
                    )
                case .noDeliveryYet:
                    return .init(
                        severity: .calm,
                        title: UICopy.SETTINGS_OBSERVATION_OBSERVING,
                        subtitle: pendingCount == 0 ? MacStrings.macos_status_neverempty() : MacStrings.macos_status_neverwaiting(String(pendingCount)),
                        axValue: "external_no_delivery_yet"
                    )
                case .notLinked:
                    return .init(
                        severity: .calm,
                        title: UICopy.SETTINGS_OBSERVATION_OBSERVING,
                        subtitle: UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED,
                        axValue: "external_delivery_not_linked"
                    )
                case .unavailable:
                    return .init(
                        severity: .warn,
                        title: UICopy.SETTINGS_OBSERVATION_OBSERVING,
                        subtitle: UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK,
                        axValue: "external_delivery_unavailable"
                    )
                }
            }
        }
    }

    /// The upload status as the menu reads it, so the card never contradicts the
    /// menu about the connection.
    private static func statusForCurrentConnection(
        _ status: UploadCoordinator.Status,
        ready: Bool,
        presented: PresentedJournalConnection,
        lastHealthReason: ObserverHealthFailureReason?
    ) -> UploadCoordinator.Status {
        switch classifyJournalConnection(
            isPairedIngestReady: ready,
            presentedConnection: presented,
            uploadStatus: status,
            lastHealthReason: lastHealthReason
        ) {
        case .connectionWaiting: return .awaitingTunnel
        case .offline: return .offline(MacStrings.macos_app_connectionunavailable())
        case .observing:
            switch status {
            // Connected, and an upload that could not get through waits for its retry.
            case .offline: return .retrying(segment: "", attempts: 0)
            // Connected, and the first pass has not reported yet.
            case .awaitingTunnel: return .notSynced
            default: return status
            }
        default: return status
        }
    }

    private static func captureFlagSummary(
        isRecording: Bool,
        isPaused: Bool,
        ownerPauseHeldIdle: Bool,
        isBundled: Bool,
        journalSlot: String,
        isSynced: Bool
    ) -> StatusHealthSummary? {
        if isPaused || ownerPauseHeldIdle {
            let subtitle = isBundled
                ? MacStrings.macos_app_journalhealthyonthismac()
                : (isSynced ? MacStrings.macos_statushealthsummary_syncedto("\(journalSlot)") : MacStrings.macos_statushealthsummary_paused("\(journalSlot)"))
            return StatusHealthSummary(
                severity: .warn,
                title: MacStrings.macos_app_solstoneispaused(),
                subtitle: subtitle,
                axValue: "paused"
            )
        }
        if !isRecording {
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.MENUBAR_STARTING,
                subtitle: isBundled
                    ? MacStrings.macos_statushealthsummary_yourjournalisfine()
                    : MacStrings.macos_statushealthsummary_nothingisreachingyourjournalyet(),
                axValue: "off"
            )
        }
        return nil
    }
}
