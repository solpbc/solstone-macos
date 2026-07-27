import Foundation

public enum ReloadSemantic: String, Sendable {
    case live
    case restartRequired
    case appRestart
}

public enum SettingsReloadSemantics {
    public static let semantic: [String: ReloadSemantic] = [
        // live: applied through AppState.updateConfig / handleExternalDefaultsChange; microphone authorization re-read via CaptureCoordinator.refreshMicrophoneAuthorization(), no relaunch
        "serverURL": .live,
        "serverKey": .live,
        "serviceMode": .live,
        "journalPath": .live,
        "cacheRetentionDays": .live,
        "microphoneGain": .live,
        "microphoneGranted": .live,
        "silenceMusic": .live,
        "solInitiatedChatNotificationsEnabled": .live,
        "microphonePriority": .live,
        "excludedApps": .live,
        "excludedTitlePatterns": .live,
        "excludePrivateBrowsing": .live,
        "syncPaused": .live,
        "debugSegments": .live,
        "debugKeepRejectedAudio": .live,
        "observerName": .live,
        "loginItemEnabled": .live,
        // app-restart: screen recording grant requires host-process relaunch
        "screenRecordingGranted": .appRestart,
    ]
}
