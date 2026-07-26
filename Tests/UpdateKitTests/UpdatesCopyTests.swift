import Foundation
import Testing
@testable import UpdateKit

@Suite("UpdatesCopy")
struct UpdatesCopyTests {
    @Test func updateAvailableTitleString() {
        #expect(UpdatesCopy(provider: .solstone).updateAvailableTitle(version: "1.1.0") == "version 1.1.0 is available")
    }

    @Test func updateAvailableSubtitleString() {
        #expect(UpdatesCopy(provider: .solstone).updateAvailableSubtitle(version: "1.1.0") == "sol 1.1.0 is ready to download.")
    }

    @Test func updateNotificationCopyUsesProviderDisplayName() {
        #expect(UpdatesCopy(provider: .solstone).updateNotificationTitle(version: "1.1.0") == "sol 1.1.0 is ready when you are")
        #expect(UpdatesCopy(provider: .solstone).updateNotificationBody == "it'll be applied the next time you quit and reopen sol.")
        #expect(UpdatesCopy(provider: .journal).updateNotificationTitle(version: "1.1.0") == "journal 1.1.0 is ready when you are")
        #expect(UpdatesCopy(provider: .journal).updateNotificationBody == "it'll be applied the next time you quit and reopen journal.")
    }

    @Test func downloadingTitleString() {
        #expect(UpdatesCopy(provider: .solstone).downloadingTitle(version: "1.1.0") == "downloading 1.1.0")
    }

    @Test func readyToInstallTitleString() {
        #expect(UpdatesCopy(provider: .solstone).readyToInstallTitle(version: "1.1.0") == "ready to install 1.1.0")
    }

    @Test func readyToInstallSubtitleString() {
        #expect(UpdatesCopy(provider: .solstone).readyToInstallSubtitle == "the update is downloaded and ready when you are.")
    }

    @Test func stagedReadyStrings() {
        #expect(UpdatesCopy(provider: .solstone).stagedReadyTitle(version: "1.1.0") == "ready to install v1.1.0")
        #expect(UpdatesCopy(provider: .solstone).stagedReadySubtitle == "the update is downloaded and will install when sol relaunches.")
        #expect(UpdatesCopy(provider: .solstone).actionRelaunchToInstall == "relaunch to install")
        #expect(
            UpdatesCopy(provider: .solstone).lastCheckedStaged(relative: "just now", version: "1.1.0")
                == "last checked just now — version 1.1.0 ready to install"
        )
    }

    @Test func installingTitleString() {
        #expect(UpdatesCopy(provider: .solstone).installingTitle(version: "1.1.0") == "installing 1.1.0")
    }

    @Test func installingSubtitleString() {
        #expect(UpdatesCopy(provider: .solstone).installingSubtitle == "sol is handing off to the installer.")
    }

    @Test func extractingSubtitleString() {
        #expect(UpdatesCopy(provider: .solstone).extractingSubtitle == "download complete — finalizing.")
    }

    @Test func byteProgressWithTotalString() {
        #expect(UpdatesCopy(provider: .solstone).byteProgress(receivedBytes: 1_024, totalBytes: 2_048) == "1 KB of 2 KB downloaded.")
    }

    @Test func byteProgressWithoutTotalString() {
        #expect(UpdatesCopy(provider: .solstone).byteProgress(receivedBytes: 1_024, totalBytes: nil) == "1 KB downloaded.")
    }

    @Test func errorMessageString() {
        #expect(UpdatesCopy(provider: .solstone).errorMessage() == "we couldn't check right now.")
    }

    @Test func errorWithAvailableMessageString() {
        #expect(
            UpdatesCopy(provider: .solstone).errorWithAvailableMessage(version: "1.1.0")
                == "we couldn't check right now. version 1.1.0 was found earlier."
        )
    }

    @Test func notRunningStringsAreProviderIndependent() {
        #expect(UpdatesCopy(provider: .solstone).actionRetrying == "retrying…")
        #expect(UpdatesCopy(provider: .journal).actionRetrying == "retrying…")
        #expect(UpdatesCopy(provider: .solstone).updateChecksNotRunningTitle == "update checks aren't running right now")
        #expect(UpdatesCopy(provider: .journal).updateChecksNotRunningTitle == "update checks aren't running right now")
    }

    @Test func lastCheckedUpToDateString() {
        #expect(UpdatesCopy(provider: .solstone).lastCheckedUpToDate(relative: "just now") == "last checked just now — sol is up to date")
    }

    @Test func deferredStrings() {
        #expect(UpdatesCopy(provider: .solstone).deferredTitle(version: "1.1.0") == "deferred update 1.1.0")
        #expect(UpdatesCopy(provider: .solstone).deferredSubtitle == "deferred — will continue after journal setup.")
    }

    @Test func privacyFootnoteString() {
        #expect(UpdatesCopy(provider: .solstone).privacyFootnote == "no usage data is ever sent. update checks fetch the version list, then download the update itself in the background.")
    }

    @Test func releaseNotesOnlineLinkLabelString() {
        #expect(UpdatesCopy(provider: .solstone).releaseNotesOnlineLinkLabel == "read the full notes online")
    }

    @Test func releaseNotesOnlineURLString() {
        #expect(UpdatesCopy(provider: .solstone).releaseNotesOnlineURL == URL(string: "https://solstone.app/releases/macos")!)
    }
}
