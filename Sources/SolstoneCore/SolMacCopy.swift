import Foundation

// Locked CLI copy. INSTALL_* and TRANSLOCATION_* are imported by Lode 4 and unused in Lode 3.
public enum SolMacCopy {
    public static let appNotRunning = "solstone is not running"
    public static let stopNoop = "solstone is not recording"
    public static let alreadyRecording = "solstone is already recording"
    public static let ipcTimeout = "ipc timeout"

    public static func versionMismatch(serverVersion: Int, clientVersion: Int) -> String {
        "protocol version skew: cli v\(clientVersion) → app v\(serverVersion). update one to match."
    }

    public static let installSuccess = "sol-mac installed to /usr/local/bin/sol-mac"
    public static let installNeedsAuth = "installation requires admin access. re-run with sudo, or use the settings UI."
    public static let translocationDetected = "solstone is running from a quarantined location (App Translocation). drag it into /Applications and re-launch."
    public static let translocationRemedy = "move solstone.app to /Applications, then re-launch."
}
