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

internal struct StatusHealthSummary: Equatable, Sendable {
    let severity: StatusDotSeverity
    let title: String
    let subtitle: String?
    let axValue: String
}

internal func journalHost(_ serverURL: String?) -> String {
    guard let serverURL, !serverURL.isEmpty else {
        return "your journal"
    }

    let parseableURL = serverURL.contains("://") ? serverURL : "http://\(serverURL)"
    if let host = URL(string: parseableURL)?.host, !host.isEmpty {
        return host
    }
    return serverURL
}

internal func encryptionClause(_ serverURL: String?) -> String {
    serverURL?.hasPrefix("https://") == true ? ", encrypted" : ""
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
    return "everything stays on this Mac · \(permissions) · \(microphones)"
}

internal func externalStatusFooterText(serverURL: String?, permissionsGranted: Bool) -> String {
    let permissions = permissionsGranted ? "permissions granted" : "permissions need attention"
    return "sol is on · your journal lives on \(journalHost(serverURL))\(encryptionClause(serverURL)) · \(permissions)"
}

extension StatusHealthSummary {
    static func make(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastDeliveryOutcome: LastJournalDeliveryOutcome,
        serverURL: String?,
        now: Date,
        setupVerdict: SetupGroupVerdict? = nil
    ) -> StatusHealthSummary {
        let operational = makeOperational(
            serviceMode: serviceMode,
            isRecording: isRecording,
            isPaused: isPaused,
            uploadStatus: uploadStatus,
            pendingCount: pendingCount,
            lastDeliveryOutcome: lastDeliveryOutcome,
            serverURL: serverURL,
            now: now
        )
        guard let setupVerdict, setupVerdict.severity == .attention else {
            return operational
        }
        return StatusHealthSummary(
            severity: .attention,
            title: setupVerdict.text,
            subtitle: operational.title,
            axValue: setupVerdict.axState.axToken
        )
    }

    private static func makeOperational(
        serviceMode: ServiceMode?,
        isRecording: Bool,
        isPaused: Bool,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastDeliveryOutcome: LastJournalDeliveryOutcome,
        serverURL: String?,
        now: Date
    ) -> StatusHealthSummary {
        let host = journalHost(serverURL)
        let isBundled = serviceMode == .bundled

        if isBundled {
            return .init(
                severity: .attention,
                title: "your journal needs a new link",
                subtitle: "open your journal panel to connect this Mac again",
                axValue: MenubarStatusRowState.journalMigrationNeeded.axToken
            )
        } else {
            switch uploadStatus {
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
                let subtitle = pendingCount > 0
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting here · nothing is lost, sync resumes when it's back"
                    : "nothing is lost · sync resumes when it's back"
                return .init(
                    severity: .attention,
                    title: "can't reach \(host)",
                    subtitle: subtitle,
                    axValue: "external_offline"
                )
            case .retrying:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    isBundled: false,
                    host: host,
                    isSynced: false
                ) {
                    return summary
                }
                let subtitle = pendingCount > 0
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting"
                    : "retrying the last upload"
                return .init(
                    severity: .warn,
                    title: "trouble reaching \(host) · retrying",
                    subtitle: subtitle,
                    axValue: "external_retrying"
                )
            case .syncing(let checked, let total):
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    isBundled: false,
                    host: host,
                    isSynced: false
                ) {
                    return summary
                }
                return .init(
                    severity: .warn,
                    title: "catching up · \(checked) of \(total) segments",
                    subtitle: "syncing to \(host)",
                    axValue: "external_syncing"
                )
            case .uploading:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    isBundled: false,
                    host: host,
                    isSynced: false
                ) {
                    return summary
                }
                let subtitle = pendingCount > 0 ? "\(pendingCount) more waiting" : "syncing to \(host)"
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
                    isBundled: false,
                    host: host,
                    isSynced: false
                ) {
                    return summary
                }
                return .init(
                    severity: .warn,
                    title: "connecting…",
                    subtitle: "reaching \(host)",
                    axValue: "external_connecting"
                )
            case .synced:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    isBundled: false,
                    host: host,
                    isSynced: true
                ) {
                    return summary
                }
                let waiting = pendingCount == 0 ? " · nothing waiting" : " · \(pendingCount) waiting"
                switch lastDeliveryOutcome {
                case .delivered(let date):
                    return .init(
                        severity: .good,
                        title: "all good · on, synced to \(host)",
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

    private static func captureFlagSummary(
        isRecording: Bool,
        isPaused: Bool,
        isBundled: Bool,
        host: String,
        isSynced: Bool
    ) -> StatusHealthSummary? {
        if !isRecording {
            return StatusHealthSummary(
                severity: .warn,
                title: "sol is off",
                subtitle: isBundled
                    ? "your journal is fine. turn sol back on to keep building memory"
                    : "nothing is reaching \(host) while sol is off",
                axValue: "off"
            )
        }
        if isPaused {
            let subtitle = isBundled
                ? "journal healthy on this Mac"
                : (isSynced ? "synced to \(host)" : "paused · \(host)")
            return StatusHealthSummary(
                severity: .warn,
                title: "sol is paused",
                subtitle: subtitle,
                axValue: "paused"
            )
        }
        return nil
    }
}
