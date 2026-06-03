import Foundation
import Testing
@testable import solstone

@Suite("UpdateController", .serialized)
@MainActor
struct UpdateControllerTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let statusKey = "solstone.updates.status"
    private let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"

    @Test func invalidWhenFeedURLMissing() {
        #expect(UpdateController.validateSparkleConfig(feedURL: nil, publicKey: validPublicKey) == false)
    }

    @Test func invalidWhenFeedURLIsMalformed() {
        #expect(UpdateController.validateSparkleConfig(feedURL: "https:// updates.solstone.app", publicKey: validPublicKey) == false)
    }

    @Test func invalidWhenPublicKeyMissing() {
        #expect(UpdateController.validateSparkleConfig(feedURL: validFeedURL, publicKey: nil) == false)
    }

    @Test func invalidWhenPublicKeyIsNotBase64() {
        #expect(UpdateController.validateSparkleConfig(feedURL: validFeedURL, publicKey: "!!!") == false)
    }

    @Test func invalidWhenPublicKeyHasWrongLength() {
        let shortKey = Data(repeating: 0, count: 31).base64EncodedString()
        #expect(UpdateController.validateSparkleConfig(feedURL: validFeedURL, publicKey: shortKey) == false)
    }

    @Test func validConfigAttemptsUpdaterConstruction() {
        clearDefaults()
        defer { clearDefaults() }
        var attempts = 0

        let controller = UpdateController(feedURL: validFeedURL, publicKey: validPublicKey) { _, _ in
            attempts += 1
            return nil
        }

        #expect(attempts == 1)
        #expect(controller.canCheckForUpdates)
        #expect(controller.activity == .idle)
    }

    @Test func surfacedFlagsReflectDurableStatusAndDeferredIntent() {
        let controller = makeController()
        let now = Date()

        controller.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
        )
        #expect(!controller.updateIsAvailable)
        #expect(!controller.updateCheckFailed)
        #expect(!controller.updatesNeedAttention)
        #expect(controller.updatesAreCurrent)

        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        )
        #expect(controller.updateIsAvailable)
        #expect(!controller.updateCheckFailed)
        #expect(controller.updatesNeedAttention)
        #expect(!controller.updatesAreCurrent)

        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
            hasLiveChoiceReply: true
        )
        #expect(controller.updateIsAvailable)
        #expect(controller.hasLiveUpdateReply)
        #expect(controller.canActOnAvailableUpdateDirectly == false)

        controller.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
        )
        #expect(!controller.updateIsAvailable)
        #expect(controller.updateCheckFailed)
        #expect(controller.updatesNeedAttention)
        #expect(!controller.updatesAreCurrent)

        controller.applyDebugFixture(
            activity: .idle,
            deferredInstallIntent: DeferredInstallIntent(version: "1.3.9", requestedAt: now)
        )
        #expect(!controller.updateIsAvailable)
        #expect(controller.updatesNeedAttention)
    }

    @Test func idleAvailableWithLiveReplyIsDirectlyActionable() {
        let controller = makeController()

        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        #expect(controller.hasLiveUpdateReply)
        #expect(controller.canActOnAvailableUpdateDirectly)
    }

    @Test func checkForUpdatesDoesNotEnterCheckingWhenLiveReplyExists() {
        let controller = makeController()
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.checkForUpdates()

        #expect(checks == 0)
        #expect(controller.activity == .idle)
        #expect(controller.hasLiveUpdateReply)
    }

    @Test func failedCheckPreservesDurableAvailableFact() {
        let controller = makeController()
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.presentUpdaterError(NSError(domain: "test", code: 1))

        #expect(controller.activity == .idle)
        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.availableUpdate?.releaseNotes == "notes")
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func definitiveUpToDateCheckClearsDurableAvailableFact() {
        let controller = makeController()
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.presentNoUpdateFound()

        #expect(controller.activity == .idle)
        #expect(controller.availableUpdate == nil)
        #expect(controller.reconciledStatus.availableVersion == nil)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .upToDate)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func cancelClearsTransientSessionOnlyAndPreservesDurableFact() {
        let controller = makeController()
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: "notes"),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.cancel()

        #expect(controller.activity == .idle)
        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(!controller.hasLiveUpdateReply)
        #expect(controller.deferredInstallIntent == nil)
    }

    @Test func statusAXTokenComposesActivityAndDurableStatus() {
        let controller = makeController()
        let now = Date()

        controller.applyDebugFixture(activity: .idle)
        #expect(controller.statusAXToken == "idle")

        controller.applyDebugFixture(activity: .checking)
        #expect(controller.statusAXToken == "checking")

        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        )
        #expect(controller.statusAXToken == "update_available")

        controller.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
        )
        #expect(controller.statusAXToken == "error")

        controller.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
        )
        #expect(controller.statusAXToken == "up_to_date")

        controller.applyDebugFixture(
            activity: .downloading(version: "1.3.9", receivedBytes: 1, totalBytes: 2),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        )
        #expect(controller.statusAXToken == "downloading")

        controller.applyDebugFixture(
            activity: .idle,
            deferredInstallIntent: DeferredInstallIntent(version: "1.3.9", requestedAt: now)
        )
        #expect(controller.statusAXToken == "deferred_install")

        controller.applyDebugFixture(
            activity: .checking,
            deferredInstallIntent: DeferredInstallIntent(version: "1.3.9", requestedAt: now)
        )
        #expect(controller.statusAXToken == "checking")
    }

    @Test func absentExclusivityProviderDefaultsToNeverExclusive() {
        let controller = makeController()

        #expect(!controller.exclusiveOperationInProgress)
    }

    private func makeController() -> UpdateController {
        clearDefaults()
        return UpdateController(feedURL: validFeedURL, publicKey: validPublicKey) { _, _ in nil }
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: statusKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckResultKey)
    }
}
