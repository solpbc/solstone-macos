public enum UpdatesAXID {
    public static let statusState = "updates.status.state"
    public static let unavailable = "updates.status.unavailable"
    public static let notRunning = "updates.status.notrunning"
    public static let notRunningRetry = "updates.status.notrunning.retry"
    public static let notRunningReason = "updates.status.notrunning.reason"
    public static let check = "updates.action.check"
    public static let checkState = "updates.action.check.state"
    public static let cancel = "updates.action.cancel"
    public static let download = "updates.action.download"
    public static let downloadState = "updates.action.download.state"
    public static let install = "updates.action.install"
    public static let dismiss = "updates.action.dismiss"
    public static let dismissStaged = "updates.action.dismissStaged"
    public static let retry = "updates.action.retry"
    public static let retryState = "updates.action.retry.state"
    public static let checkAgainState = "updates.action.checkAgain.state"
    public static let releaseNotes = "updates.releaseNotes.content"
    public static let releaseNotesOnline = "updates.releaseNotes.online"
    public static let downloadProgress = "updates.downloadProgress.state"
    public static let extractProgress = "updates.extractProgress.state"
    public static let deferredInstallState = "updates.deferredInstall.state"
    public static let automaticChecks = "updates.preferences.automaticChecks"
    public static let frequencyPicker = "updates.preferences.frequency"
    public static let frequencyState = "updates.preferences.frequency.state"
    public static let automaticDownloads = "updates.preferences.automaticDownloads"
    public static let debugStatePicker = "updates.debug.state"
}

public extension UpdateActivity {
    static let axTokens = [
        "idle",
        "checking",
        "downloading",
        "extracting",
        "ready_to_install",
        "installing"
    ]

    var axToken: String {
        switch self {
        case .idle:
            return "idle"
        case .checking:
            return "checking"
        case .downloading:
            return "downloading"
        case .extracting:
            return "extracting"
        case .readyToInstall:
            return "ready_to_install"
        case .installing:
            return "installing"
        }
    }
}

public enum UpdateStatus {
    public static let axTokens = UpdateActivity.axTokens + [
        "downloading_background",
        "deferred_install",
        "update_available",
        "up_to_date",
        "error",
        "staged_ready",
        "not_running"
    ]
}
