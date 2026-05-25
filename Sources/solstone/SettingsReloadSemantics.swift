import Foundation

public enum ReloadSemantic: String, Sendable {
    case live
    case restartRequired
    case appRestart
}

public enum SettingsReloadSemantics {
    public static let semantic: [String: ReloadSemantic] = [
        // restart-required: bundled-mode supervisor must restart to pick these up
        "serverURL": .restartRequired,
        "serverKey": .restartRequired,
        "serviceMode": .restartRequired,
        // live: applied to running captureManager via AppState.updateConfig
        "cacheRetentionDays": .live,
        "microphoneGain": .live,
        "silenceMusic": .live,
        "solInitiatedChatNotificationsEnabled": .live,
        "microphonePriority": .live,
        "excludedApps": .live,
        "excludedTitlePatterns": .live,
        "excludePrivateBrowsing": .live,
        "syncPaused": .live,
        "debugSegments": .live,
        "debugKeepRejectedAudio": .live,
        "loginItemEnabled": .live,
        // app-restart: macOS TCC grants require the host process to relaunch
        "screenRecordingGranted": .appRestart,
        "microphoneGranted": .appRestart,
    ]
}
