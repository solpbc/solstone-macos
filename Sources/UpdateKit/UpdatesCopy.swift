import Foundation

public struct UpdatesCopyProvider: Sendable {
    public let appDisplayName: String
    public let releaseNotesURL: URL
    public let deferralLine: String

    public init(appDisplayName: String, releaseNotesURL: URL, deferralLine: String) {
        self.appDisplayName = appDisplayName
        self.releaseNotesURL = releaseNotesURL
        self.deferralLine = deferralLine
    }
}

public extension UpdatesCopyProvider {
    static let solstone = UpdatesCopyProvider(
        appDisplayName: "sol",
        releaseNotesURL: URL(string: "https://solstone.app/releases/macos")!,
        deferralLine: "deferred — will continue after journal setup."
    )

    static let journal = UpdatesCopyProvider(
        appDisplayName: "journal",
        releaseNotesURL: URL(string: "https://solstone.app/releases/macos")!,
        deferralLine: "deferred — will continue after your journal is ready."
    )
}

public struct UpdatesCopy: Sendable {
    public let provider: UpdatesCopyProvider

    public init(provider: UpdatesCopyProvider) {
        self.provider = provider
    }

    public var tabTitle: String { "updates" }

    public var checkingTitle: String { "checking for updates" }
    public var checkingSubtitle: String { "looking for the latest version now." }
    public var checkingInline: String { "checking…" }

    public var errorTitle: String { "update check failed" }
    public func errorMessage() -> String { "we couldn't check right now." }

    public func errorWithAvailableMessage(version: String) -> String {
        "we couldn't check right now. version \(version) was found earlier."
    }

    public var unavailableTitle: String { "updates unavailable" }
    public var unavailableSubtitle: String {
        let host = provider.releaseNotesURL.host ?? "solstone.app"
        return "this build can't check for updates on its own. download the latest from \(host)."
    }

    public var releaseNotesTitle: String { "what's new" }
    public var releaseNotesOnlineLinkLabel: String { "read the full notes online" }
    public var releaseNotesOnlineURL: URL { provider.releaseNotesURL }
    public var finalizingSuffix: String { "finalizing" }

    public var actionCheckNow: String { "check now" }
    public var actionCheckAgain: String { "check again" }
    public var actionDownload: String { "download" }
    public var actionInstall: String { "install" }
    public var actionRelaunchToInstall: String { "relaunch to install" }
    public var actionCancel: String { "cancel" }
    public var actionDismiss: String { "dismiss" }
    public var actionRetry: String { "retry" }
    public var actionRetrying: String { "retrying…" }

    public var autoUpdateGroupTitle: String { "automatic updates" }
    public var autoCheckToggleLabel: String { "check for updates automatically" }
    public var autoDownloadToggleLabel: String { "download updates in the background" }
    public var frequencyPickerLabel: String { "how often" }
    public var frequencyDay: String { "every day" }
    public var frequencyWeek: String { "every week" }
    public var frequencyMonth: String { "every month" }

    public var lastCheckedNever: String { "never checked for updates" }
    public var lastCheckedJustNow: String { "just now" }
    public var privacyFootnote: String { "no usage data is ever sent. update checks only fetch the version manifest." }
    public var updateChecksNotRunningTitle: String { "update checks aren't running right now" }

    public func appHeader(version: String) -> String {
        "\(provider.appDisplayName) \(version)"
    }

    public func lastCheckedUpToDate(relative: String) -> String {
        "last checked \(relative) — \(provider.appDisplayName) is up to date"
    }

    public func lastCheckedUpdateFound(relative: String, version: String) -> String {
        "last checked \(relative) — version \(version) found"
    }

    public func lastCheckedStaged(relative: String, version: String) -> String {
        "last checked \(relative) — version \(version) ready to install"
    }

    public func lastCheckedFailed(relative: String) -> String {
        "last checked \(relative) — check failed"
    }

    public func lastCheckedGeneric(relative: String) -> String {
        "last checked \(relative)"
    }

    public func lastCheckedRelative(checkedAt: Date, now: Date) -> String {
        if now.timeIntervalSince(checkedAt) < 60 {
            return lastCheckedJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: checkedAt, relativeTo: now)
    }

    public func updateAvailableTitle(version: String) -> String {
        "version \(version) is available"
    }

    public func updateAvailableSubtitle(version: String) -> String {
        "\(provider.appDisplayName) \(version) is ready to download."
    }

    public func updateNotificationTitle(version: String) -> String {
        "\(provider.appDisplayName) \(version) is ready when you are"
    }

    public var updateNotificationBody: String {
        "it'll be applied the next time you quit and reopen \(provider.appDisplayName)."
    }

    public func deferredTitle(version: String) -> String {
        version.isEmpty ? "deferred update" : "deferred update \(version)"
    }

    public var deferredSubtitle: String { provider.deferralLine }

    public func downloadingTitle(version: String) -> String {
        "downloading \(version)"
    }

    public func downloadingSubtitle(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
        byteProgress(receivedBytes: receivedBytes, totalBytes: totalBytes)
    }

    public func backgroundDownloadingTitle(version: String?) -> String {
        if let version, !version.isEmpty {
            return "downloading \(version) in the background…"
        }
        return "downloading an update in the background…"
    }

    public func backgroundFinishingTitle(version: String?) -> String {
        if let version, !version.isEmpty {
            return "finishing up \(version) in the background…"
        }
        return "finishing up in the background…"
    }

    public var backgroundDownloadSubtitle: String {
        "\(provider.appDisplayName) will let you know when the update is ready to install."
    }

    public func extractingTitle(version: String) -> String {
        "downloading \(version)"
    }

    public var extractingSubtitle: String {
        "download complete — \(finalizingSuffix)."
    }

    public func readyToInstallTitle(version: String) -> String {
        "ready to install \(version)"
    }

    public func stagedReadyTitle(version: String) -> String {
        "ready to install v\(version)"
    }

    public var readyToInstallSubtitle: String { "the update is downloaded and ready when you are." }

    public var stagedReadySubtitle: String {
        "the update is downloaded and will install when \(provider.appDisplayName) relaunches."
    }

    public func installingTitle(version: String) -> String {
        "installing \(version)"
    }

    public var installingSubtitle: String {
        "\(provider.appDisplayName) is handing off to the installer."
    }

    public var actionReasonUpdatesUnavailable: String { "updates are unavailable in this build" }
    public var actionReasonDownloadInProgress: String { "a download is already in progress" }
    public var actionReasonDownloadFinishing: String { "a download is finishing up" }
    public var actionReasonInstallHandoff: String { "an install handoff is already in progress" }
    public var actionReasonUpdateChoicePending: String { "an update needs a choice first" }
    public var actionReasonUpdateInProgress: String { "an update is already in progress" }

    public func byteProgress(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true

        let received = formatter.string(fromByteCount: Int64(receivedBytes))
        guard let totalBytes else {
            return "\(received) downloaded."
        }

        let total = formatter.string(fromByteCount: Int64(totalBytes))
        return "\(received) of \(total) downloaded."
    }
}
