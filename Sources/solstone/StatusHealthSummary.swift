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
        return "just now"
    }
    if interval < 3_600 {
        return "\(Int(interval / 60))m ago"
    }
    if interval < 86_400 {
        return "\(Int(interval / 3_600))h ago"
    }
    return "\(Int(interval / 86_400))d ago"
}

internal func bundledStatusFooterText(permissionsGranted: Bool, microphoneCount: Int) -> String {
    let permissions = permissionsGranted ? "permissions granted" : "permissions need attention"
    let microphones = microphoneCount == 1 ? "1 microphone" : "\(microphoneCount) microphones"
    return "everything stays on this mac · \(permissions) · \(microphones)"
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
        permittedSources: CaptureSources = .all,
        errorMessage: String? = nil,
        setupVerdict: SetupGroupVerdict? = nil,
        lastHealthReason: ObserverHealthFailureReason? = nil,
        isPairedIngestReady: Bool = true,
        journalConnectionAXToken: String? = nil
    ) -> StatusHealthSummary {
        // A migrated Mac can retain successful delivery and mark-confirmation records
        // after its device-bound pairing is gone. Absence leads every connection state.
        if !hasPersistedPairing {
            let waiting = pendingCount > 0
                ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting on this mac. "
                : ""
            return .init(
                severity: isRecording || pendingCount > 0 ? .attention : .calm,
                title: UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED,
                subtitle: waiting + "re-link in journal settings to resume syncing.",
                axValue: "external_not_linked",
                action: StatusHealthAction(
                    label: "open journal settings",
                    settingsTab: "service",
                    reasksJournalMark: false
                )
            )
        }
        // The owner turning every source off is a choice, not a fault — but it is also the one
        // state in which nothing reaches the journal at all, so it leads the card and says why.
        // It outranks the setup rollup below, which reads green precisely BECAUSE an unselected
        // source cannot fail a setup check.
        if !isRecording, !isPaused, selectedSources.isEmpty {
            return .init(
                severity: .calm,
                title: UICopy.SOURCES_NONE,
                subtitle: UICopy.SOURCES_NONE_REASON,
                axValue: "sources_off",
                action: StatusHealthAction(label: UICopy.SOURCES_OPEN_ACTION, settingsTab: "sources", reasksJournalMark: false)
            )
        }

        if !isRecording, !isPaused, selectedSources.intersection(permittedSources).isEmpty {
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

        let operational = makeOperational(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            ownerPauseHeldIdle: ownerPauseHeldIdle,
            held: held,
            uploadStatus: statusForCurrentConnection(
                uploadStatus,
                ready: isPairedIngestReady,
                axToken: journalConnectionAXToken
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
                title: "your journal needs a new link",
                subtitle: "open your journal panel to connect this mac again",
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
                    subtitle: "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") kept on this mac",
                    axValue: "external_blocked"
                )
            case .awaitingTunnel:
                let subtitle = pendingCount > 0
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting here"
                    : "sync resumes when the journal connection is ready"
                return .init(
                    severity: .warn,
                    title: "connecting to your journal…",
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
                        ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting here · kept on this mac until your journal can read that day"
                        : "sync resumes once your journal can read that day"
                    return .init(
                        severity: .attention,
                        title: "your journal couldn't read \(ownerDayLabel(day))",
                        subtitle: subtitle,
                        axValue: "external_offline"
                    )
                }
                let subtitle = pendingCount > 0
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting here · nothing is lost, sync resumes when it's back"
                    : "nothing is lost · sync resumes when it's back"
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
                    title: "can't reach your journal",
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
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting"
                    : "retrying the last upload"
                return .init(
                    severity: .warn,
                    title: "catching up · retrying an upload",
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
                    title: "catching up · \(checked) of \(total) segments",
                    subtitle: "syncing to your journal",
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
                let subtitle = pendingCount > 0 ? "\(pendingCount) more waiting" : "syncing to your journal"
                return .init(
                    severity: .warn,
                    title: "catching up · sending the latest",
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
                return .init(
                    severity: .warn,
                    title: "connecting…",
                    subtitle: "reaching your journal",
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
                let waiting = pendingCount == 0 ? " · nothing waiting" : " · \(pendingCount) waiting"
                switch lastDeliveryOutcome {
                case .delivered(let date):
                    return .init(
                        severity: .good,
                        title: "all good · on, synced to \(journalSlot)",
                        subtitle: "\(UICopy.SETTINGS_LAST_DELIVERY_LABEL) \(coarseRelativeTime(date, now: now))\(waiting)",
                        axValue: "external_synced"
                    )
                case .noDeliveryYet:
                    return .init(
                        severity: .calm,
                        title: UICopy.SETTINGS_OBSERVATION_OBSERVING,
                        subtitle: "\(UICopy.SETTINGS_LAST_DELIVERY_NEVER)\(waiting)",
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

    private static func statusForCurrentConnection(
        _ status: UploadCoordinator.Status,
        ready: Bool,
        axToken: String?
    ) -> UploadCoordinator.Status {
        switch classifyJournalConnection(isPairedIngestReady: ready, uploadStatus: status, journalConnectionAXToken: axToken) {
        case .connectionWaiting: return .awaitingTunnel
        case .offline: return .offline("connection unavailable")
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
                ? "journal healthy on this mac"
                : (isSynced ? "synced to \(journalSlot)" : "paused · \(journalSlot)")
            return StatusHealthSummary(
                severity: .warn,
                title: "solstone is paused",
                subtitle: subtitle,
                axValue: "paused"
            )
        }
        if !isRecording {
            return StatusHealthSummary(
                severity: .calm,
                title: UICopy.MENUBAR_STARTING,
                subtitle: isBundled
                    ? "your journal is fine"
                    : "nothing is reaching your journal yet",
                axValue: "off"
            )
        }
        return nil
    }
}
