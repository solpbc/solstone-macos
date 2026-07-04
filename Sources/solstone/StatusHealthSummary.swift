import Foundation
import SwiftUI
import SolstoneCore

internal enum StatusDotSeverity: Equatable, Sendable {
    case good, warn, attention

    var color: Color {
        switch self {
        case .good:
            return .green
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
        journalRuntimeStatus: JournalRuntimeStatus,
        uploadStatus: UploadCoordinator.Status,
        pendingCount: Int,
        lastSyncedAt: Date?,
        serverURL: String?,
        now: Date
    ) -> StatusHealthSummary {
        let host = journalHost(serverURL)
        let isBundled = serviceMode == .bundled

        if isBundled {
            switch journalRuntimeStatus {
            case .unobserved:
                return .init(
                    severity: .warn,
                    title: "checking journal…",
                    subtitle: nil,
                    axValue: MenubarStatusRowState.starting.axToken
                )
            case .stopped, .unknown:
                return .init(
                    severity: .attention,
                    title: "your journal needs attention",
                    subtitle: "sol is still on — new memory is safe on this Mac until the journal is back",
                    axValue: "bundled_needs_attention"
                )
            case .setupNeeded:
                return .init(
                    severity: .warn,
                    title: "one step left to finish setup",
                    subtitle: "sol is ready — your journal just needs to finish installing",
                    axValue: "bundled_setup_needed"
                )
            case .stoppedByUser:
                return .init(
                    severity: .warn,
                    title: "journal stopped",
                    subtitle: "you stopped the journal — start it again to resume",
                    axValue: "bundled_stopped_by_user"
                )
            case .restarting:
                return .init(
                    severity: .warn,
                    title: "journal restarting…",
                    subtitle: nil,
                    axValue: "bundled_restarting"
                )
            case .running:
                if let summary = captureFlagSummary(
                    isRecording: isRecording,
                    isPaused: isPaused,
                    isBundled: true,
                    host: host,
                    isSynced: false
                ) {
                    return summary
                }
                return .init(
                    severity: .good,
                    title: "all good — on, journal healthy",
                    subtitle: "everything stays on this Mac",
                    axValue: "bundled_healthy"
                )
            }
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
                    ? "\(pendingCount) segment\(pendingCount == 1 ? "" : "s") waiting here — nothing is lost, sync resumes when it's back"
                    : "nothing is lost — sync resumes when it's back"
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
                    title: "trouble reaching \(host) — retrying",
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
                    title: "catching up — \(checked) of \(total) segments",
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
                    title: "catching up — sending the latest",
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
                let subtitle: String
                if let lastSyncedAt {
                    subtitle = "last synced \(coarseRelativeTime(lastSyncedAt, now: now))"
                        + (pendingCount == 0 ? " · nothing waiting" : " · \(pendingCount) waiting")
                } else {
                    subtitle = "just connected to \(host)"
                }
                return .init(
                    severity: .good,
                    title: "all good — on, synced to \(host)",
                    subtitle: subtitle,
                    axValue: "external_synced"
                )
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
                    ? "your journal is fine — turn sol back on to keep building memory"
                    : "nothing is reaching \(host) while sol is off",
                axValue: "observing_off"
            )
        }
        if isPaused {
            let subtitle = isBundled
                ? "journal healthy on this Mac"
                : (isSynced ? "synced to \(host)" : "paused — \(host)")
            return StatusHealthSummary(
                severity: .warn,
                title: "sol is paused",
                subtitle: subtitle,
                axValue: "observing_paused"
            )
        }
        return nil
    }
}
