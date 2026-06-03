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
        controller.beginUserInitiatedCheck(cancellation: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.presentUpdateFound(
            version: appcastItem.displayVersionString,
            releaseNotes: appcastItem.itemDescription,
            state: state,
            reply: reply
        )
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
        controller.presentNoUpdateFound()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller.presentUpdaterError(error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller.beginDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller.recordExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller.appendDownloadedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller.beginExtracting()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller.updateExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.readyToInstall(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        controller.installingUpdate()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller.updateInstalledAndRelaunched()
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        controller.dismissUpdateInstallation()
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
