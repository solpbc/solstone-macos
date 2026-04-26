import Testing
import SolstoneCore

@Suite("SolMacCopy")
struct SolMacCopyTests {
    @Test func appNotRunningLiteralIsLocked() {
        #expect(SolMacCopy.APP_NOT_RUNNING == "solstone is not running. run 'sol-mac start' to launch it.")
    }

    @Test func stopNoopLiteralIsLocked() {
        #expect(SolMacCopy.STOP_NOOP == "solstone is not running")
    }

    @Test func installLogLiteralsAreLocked() {
        #expect(SolMacCopy.INSTALL_SUCCESS_LOG == "installed sol-mac at ~/.local/bin/sol-mac")
        #expect(SolMacCopy.INSTALL_SKIP_LOG == "~/.local/bin/sol-mac exists and isn't ours, skipping")
        #expect(SolMacCopy.INSTALL_FAILURE_LOG == "failed to install sol-mac at ~/.local/bin/sol-mac")
    }

    @Test func translocationModalLiteralsAreLocked() {
        #expect(SolMacCopy.TRANSLOCATION_MODAL_TITLE == "solstone needs to be moved")
        #expect(SolMacCopy.TRANSLOCATION_MODAL_BODY == "solstone is running from a temporary location. Move solstone.app to /Applications and re-launch.")
        #expect(SolMacCopy.TRANSLOCATION_MODAL_BUTTON == "Quit solstone")
    }

    @Test func versionMismatchFormatsAsLocked() {
        let actual = SolMacCopy.versionMismatch(cliVersion: "1.2", appVersion: "1.3")
        #expect(actual == "sol-mac 1.2 → solstone 1.3: version_mismatch — re-install the latest sol-mac via the .app's auto-install (re-launch solstone)")
    }
}
