import Foundation
import Testing
@testable import solstone

@Suite("UpdatesCopy")
struct UpdatesCopyTests {
    @Test func updateAvailableTitleString() {
        #expect(UpdatesCopy.updateAvailableTitle(version: "1.1.0") == "version 1.1.0 is available")
    }

    @Test func updateAvailableSubtitleString() {
        #expect(UpdatesCopy.updateAvailableSubtitle(version: "1.1.0") == "solstone observer 1.1.0 is ready to download.")
    }

    @Test func downloadingTitleString() {
        #expect(UpdatesCopy.downloadingTitle(version: "1.1.0") == "downloading 1.1.0")
    }

    @Test func readyToInstallTitleString() {
        #expect(UpdatesCopy.readyToInstallTitle(version: "1.1.0") == "ready to install 1.1.0")
    }

    @Test func readyToInstallSubtitleString() {
        #expect(UpdatesCopy.readyToInstallSubtitle == "the update is downloaded and ready when you are.")
    }

    @Test func installingTitleString() {
        #expect(UpdatesCopy.installingTitle(version: "1.1.0") == "installing 1.1.0")
    }

    @Test func installingSubtitleString() {
        #expect(UpdatesCopy.installingSubtitle == "solstone observer is handing off to the installer.")
    }

    @Test func extractingSubtitleString() {
        #expect(UpdatesCopy.extractingSubtitle == "download complete — finalizing.")
    }

    @Test func byteProgressWithTotalString() {
        #expect(UpdatesCopy.byteProgress(receivedBytes: 1_024, totalBytes: 2_048) == "1 KB of 2 KB downloaded.")
    }

    @Test func byteProgressWithoutTotalString() {
        #expect(UpdatesCopy.byteProgress(receivedBytes: 1_024, totalBytes: nil) == "1 KB downloaded.")
    }

    @Test func errorMessageString() {
        #expect(UpdatesCopy.errorMessage() == "we couldn't check right now.")
    }

    @Test func privacyFootnoteString() {
        #expect(UpdatesCopy.privacyFootnote == "solstone never sends usage data. update checks only fetch the version manifest.")
    }

    @Test func releaseNotesOnlineLinkLabelString() {
        #expect(UpdatesCopy.releaseNotesOnlineLinkLabel == "read the full notes online")
    }

    @Test func releaseNotesOnlineURLString() {
        #expect(UpdatesCopy.releaseNotesOnlineURL == URL(string: "https://solstone.app/releases/macos")!)
    }
}
