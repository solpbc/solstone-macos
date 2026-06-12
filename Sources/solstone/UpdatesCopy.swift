import Foundation

enum UpdatesCopy {
    static let tabTitle = "updates"

    static let checkingTitle = "checking for updates"
    static let checkingSubtitle = "looking for the latest version now."
    static let checkingInline = "checking…"

    static let errorTitle = "update check failed"
    static func errorMessage() -> String { "we couldn't check right now." }

    static func errorWithAvailableMessage(version: String) -> String {
        "we couldn't check right now. version \(version) was found earlier."
    }

    static let unavailableTitle = "updates unavailable"
    static let unavailableSubtitle = "this build can't check for updates on its own. download the latest from solstone.app."

    static let releaseNotesTitle = "what's new"
    static let releaseNotesOnlineLinkLabel = "read the full notes online"
    static let releaseNotesOnlineURL = URL(string: "https://solstone.app/releases/macos")!
    static let finalizingSuffix = "finalizing"

    static let actionCheckNow = "check now"
    static let actionCheckAgain = "check again"
    static let actionDownload = "download"
    static let actionInstall = "install"
    static let actionCancel = "cancel"
    static let actionDismiss = "dismiss"
    static let actionRetry = "retry"

    static let autoUpdateGroupTitle = "automatic updates"
    static let autoCheckToggleLabel = "check for updates automatically"
    static let autoDownloadToggleLabel = "download updates in the background"
    static let frequencyPickerLabel = "how often"
    static let frequencyDay = "every day"
    static let frequencyWeek = "every week"
    static let frequencyMonth = "every month"

    static let lastCheckedNever = "never checked for updates"
    static let privacyFootnote = "solstone never sends usage data. update checks only fetch the version manifest."

    static func appHeader(version: String) -> String {
        "solstone \(version)"
    }

    static func lastCheckedUpToDate(relative: String) -> String {
        "last checked \(relative) — solstone is up to date"
    }

    static func lastCheckedUpdateFound(relative: String, version: String) -> String {
        "last checked \(relative) — version \(version) found"
    }

    static func lastCheckedFailed(relative: String) -> String {
        "last checked \(relative) — check failed"
    }

    static func lastCheckedGeneric(relative: String) -> String {
        "last checked \(relative)"
    }

    static func updateAvailableTitle(version: String) -> String {
        "version \(version) is available"
    }

    static func updateAvailableSubtitle(version: String) -> String {
        "solstone \(version) is ready to download."
    }

    static func deferredTitle(version: String) -> String {
        version.isEmpty ? "deferred update" : "deferred update \(version)"
    }

    static let deferredSubtitle = "deferred — will continue after journal setup."

    static func downloadingTitle(version: String) -> String {
        "downloading \(version)"
    }

    static func downloadingSubtitle(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
        byteProgress(receivedBytes: receivedBytes, totalBytes: totalBytes)
    }

    static func extractingTitle(version: String) -> String {
        "downloading \(version)"
    }

    static let extractingSubtitle = "download complete — \(finalizingSuffix)."

    static func readyToInstallTitle(version: String) -> String {
        "ready to install \(version)"
    }

    static let readyToInstallSubtitle = "the update is downloaded and ready when you are."

    static func installingTitle(version: String) -> String {
        "installing \(version)"
    }

    static let installingSubtitle = "solstone is handing off to the installer."

    static func byteProgress(receivedBytes: UInt64, totalBytes: UInt64?) -> String {
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
