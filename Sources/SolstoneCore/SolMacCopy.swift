import Foundation

public enum SolMacCopy {
    public static let APP_NOT_RUNNING =
        "solstone is not running. run 'sol-mac start' to launch it."

    public static let STOP_NOOP =
        "solstone is not running"

    public static let INSTALL_SUCCESS_LOG =
        "installed sol-mac at ~/.local/bin/sol-mac"

    public static let INSTALL_SKIP_LOG =
        "~/.local/bin/sol-mac exists and isn't ours, skipping"

    public static let INSTALL_FAILURE_LOG =
        "failed to install sol-mac at ~/.local/bin/sol-mac"

    public static let TRANSLOCATION_MODAL_TITLE =
        "solstone needs to be moved"

    public static let TRANSLOCATION_MODAL_BODY =
        "solstone is running from a temporary location. Move solstone.app to /Applications and re-launch."

    public static let TRANSLOCATION_MODAL_BUTTON =
        "Quit solstone"

    public static func versionMismatch(cliVersion: String, appVersion: String) -> String {
        "sol-mac \(cliVersion) → solstone \(appVersion): version_mismatch — re-install the latest sol-mac via the .app's auto-install (re-launch solstone)"
    }
}
