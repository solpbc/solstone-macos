import Foundation
import Sparkle
import os

@MainActor
final class SparkleUserDriver: NSObject, SPUUserDriver {
    private unowned var controller: UpdateController!

    override init() {
        super.init()
    }

    func attach(to controller: UpdateController) {
        self.controller = controller
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: true,
                automaticUpdateDownloading: NSNumber(value: false),
                sendSystemProfile: false
            )
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller.stashCancellation(cancellation)
        controller.state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        let releaseNotes = appcastItem.itemDescription
        controller.setLatestUpdate(version: version, releaseNotes: releaseNotes)
        controller.stashChoiceReply(reply)

        switch state.stage {
        case .notDownloaded:
            controller.state = .updateAvailable(version: version, releaseNotes: releaseNotes)
            controller.updateLastCheck(.updateFound(version: version))
        case .downloaded, .installing:
            controller.state = .readyToInstall(version: version, releaseNotes: releaseNotes)
            controller.updateLastCheck(.updateFound(version: version))
        @unknown default:
            controller.state = .readyToInstall(version: version, releaseNotes: releaseNotes)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let releaseNotes = String(data: downloadData.data as Data, encoding: .utf8)
            ?? String(decoding: downloadData.data as Data, as: UTF8.self)
        controller.updateReleaseNotes(releaseNotes)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Logger.setup.error("Sparkle release notes download failed: \(String(describing: error), privacy: .public)")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Logger.setup.error("Sparkle no-update result: \(String(describing: error), privacy: .public)")
        controller.clearPendingInteractions()
        controller.state = .noUpdateAvailable
        controller.updateLastCheck(.upToDate)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller.setOpaqueError(error)
        controller.updateLastCheck(.failed)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller.stashCancellation(cancellation)
        controller.state = .downloading(version: controller.latestVersion ?? "", receivedBytes: 0, totalBytes: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller.recordExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller.appendDownloadedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller.clearPendingCancellation()
        controller.state = .extracting(version: controller.latestVersion ?? "", progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller.state = .extracting(version: controller.latestVersion ?? "", progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.stashChoiceReply(reply)
        controller.state = .readyToInstall(
            version: controller.latestVersion ?? "",
            releaseNotes: controller.latestReleaseNotes
        )
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        controller.clearPendingCancellation()
        controller.state = .installing(version: controller.latestVersion ?? "")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller.clearPendingInteractions()
        controller.state = .idle
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        controller.clearPendingInteractions()
        controller.state = .idle
    }

    func showUpdateInFocus() {
        // SPUUserDriver protocol: no-op by design because the user is already in the Updates tab and we do not retarget focus from the settings window.
    }

    func showUpdateNotFound(acknowledgement: @escaping () -> Void) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    func showUpdateInstallationDidFinish(acknowledgement: @escaping () -> Void) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    func dismissUserInitiatedUpdateCheck() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    func showInstallingUpdate() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    func showSendingTerminationSignal() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }
}
