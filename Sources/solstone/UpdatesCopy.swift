import Foundation

enum UpdatesCopy {
    static let menuBarCheckForUpdates = "check for updates…"
    static let tabTitle = "updates"

    static let idleTitle = "updates"
    static let idleSubtitle = "check whether a newer version of solstone observer is available."

    static let checkingTitle = "checking for updates"
    static let checkingSubtitle = "looking for the latest version now."

    static let noUpdateAvailableTitle = "you're up to date"
    static let noUpdateAvailableSubtitle = "this mac already has the latest version."

    static let errorTitle = "update check failed"
    static func errorMessage() -> String { "we couldn't check right now." }

    static let unavailableTitle = "updates unavailable"
    static let unavailableSubtitle = "this build is missing a valid update feed or signing key."

    static let releaseNotesTitle = "what's new"
    static let finalizingSuffix = "finalizing"

    static let actionCheckNow = "check now"
    static let actionDownload = "download"
    static let actionInstall = "install"
    static let actionCancel = "cancel"
    static let actionDismiss = "dismiss"
    static let actionRetry = "retry"

    static let privacyFootnote = "solstone never sends usage data. update checks only fetch the version manifest."

    static func updateAvailableTitle(version: String) -> String {
        "version \(version) is available"
    }

    static func updateAvailableSubtitle(version: String) -> String {
        "solstone observer \(version) is ready to download."
    }

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

    static let installingSubtitle = "solstone observer is handing off to the installer."

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
