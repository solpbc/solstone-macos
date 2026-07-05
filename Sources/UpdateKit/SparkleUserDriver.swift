import Foundation
import Sparkle
import os

@MainActor
public final class SparkleUserDriver: NSObject, SPUUserDriver {
    private unowned var controller: UpdateController!
    private let log: Logger

    init(log: Logger) {
        self.log = log
        super.init()
    }

    func attach(to controller: UpdateController) {
        self.controller = controller
    }

    public func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: true,
                automaticUpdateDownloading: NSNumber(value: false),
                sendSystemProfile: false
            )
        )
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller.beginUserInitiatedCheck(cancellation: cancellation)
    }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.presentUpdateFound(
            version: appcastItem.displayVersionString,
            releaseNotes: appcastItem.itemDescription,
            state: state,
            reply: reply
        )
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let releaseNotes = String(data: downloadData.data as Data, encoding: .utf8)
            ?? String(decoding: downloadData.data as Data, as: UTF8.self)
        controller.updateReleaseNotes(releaseNotes)
    }

    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        log.error("Sparkle release notes download failed: \(String(describing: error), privacy: .public)")
    }

    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log.info("Sparkle no-update result: \(String(describing: error), privacy: .public)")
        controller.presentNoUpdateFound()
        acknowledgement()
    }

    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller.presentUpdaterError(error)
        acknowledgement()
    }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller.beginDownload(cancellation: cancellation)
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller.recordExpectedContentLength(expectedContentLength)
    }

    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller.appendDownloadedBytes(length)
    }

    public func showDownloadDidStartExtractingUpdate() {
        controller.beginExtracting()
    }

    public func showExtractionReceivedProgress(_ progress: Double) {
        controller.updateExtractionProgress(progress)
    }

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.readyToInstall(reply: reply)
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        controller.installingUpdate()
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller.updateInstalledAndRelaunched()
        acknowledgement()
    }

    public func dismissUpdateInstallation() {
        controller.dismissUpdateInstallation()
    }

    public func showUpdateInFocus() {
        // SPUUserDriver protocol: no-op by design because the user is already in the Updates tab and we do not retarget focus from the settings window.
    }

    public func showUpdateNotFound(acknowledgement: @escaping () -> Void) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    public func showUpdateInstallationDidFinish(acknowledgement: @escaping () -> Void) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    public func dismissUserInitiatedUpdateCheck() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    public func showInstallingUpdate() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    public func showSendingTerminationSignal() {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool) {
        // SPUUserDriver protocol: no-op by design because this is deprecated Sparkle 1.x compatibility; modern Sparkle 2 flow uses the non-deprecated variant we already implement.
    }
}
