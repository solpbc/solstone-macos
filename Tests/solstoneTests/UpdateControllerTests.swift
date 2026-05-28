import Foundation
import Testing
@testable import solstone

@Suite("UpdateController")
@MainActor
struct UpdateControllerTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="

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
        var attempts = 0

        let controller = UpdateController(feedURL: validFeedURL, publicKey: validPublicKey) { _ in
            attempts += 1
            return nil
        }

        #expect(attempts == 1)
        #expect(controller.canCheckForUpdates == true)
        #expect(controller.state == .idle)
    }

    @Test func updateIsAvailableReflectsAvailableStates() {
        let controller = makeController()

        controller.state = .updateAvailable(version: "1", releaseNotes: nil)
        #expect(controller.updateIsAvailable)

        controller.state = .readyToInstall(version: "1", releaseNotes: nil)
        #expect(controller.updateIsAvailable)

        controller.state = .idle
        #expect(!controller.updateIsAvailable)
        controller.state = .checking
        #expect(!controller.updateIsAvailable)
        controller.state = .downloading(version: "1", receivedBytes: 0, totalBytes: nil)
        #expect(!controller.updateIsAvailable)
        controller.state = .extracting(version: "1", progress: 0)
        #expect(!controller.updateIsAvailable)
        controller.state = .installing(version: "1")
        #expect(!controller.updateIsAvailable)
        controller.state = .noUpdateAvailable
        #expect(!controller.updateIsAvailable)
        controller.state = .error(message: "failed")
        #expect(!controller.updateIsAvailable)
    }

    @Test func updateCheckFailedReflectsLastCheckResult() {
        let controller = makeController()

        #expect(!controller.updateCheckFailed)

        controller.updateLastCheck(.upToDate)
        #expect(!controller.updateCheckFailed)

        controller.updateLastCheck(.updateFound(version: "1"))
        #expect(!controller.updateCheckFailed)

        controller.updateLastCheck(.failed)
        #expect(controller.updateCheckFailed)
    }

    @Test func updatesNeedAttentionWhenUpdateAvailableOrCheckFailed() {
        let controller = makeController()

        controller.state = .idle
        controller.updateLastCheck(.upToDate)
        #expect(!controller.updatesNeedAttention)

        controller.state = .updateAvailable(version: "1", releaseNotes: nil)
        controller.updateLastCheck(.upToDate)
        #expect(controller.updatesNeedAttention)

        controller.state = .idle
        controller.updateLastCheck(.failed)
        #expect(controller.updatesNeedAttention)
    }

    @Test func updatesAreCurrentReflectsUpToDateLastCheckResult() {
        let controller = makeController()

        #expect(!controller.updatesAreCurrent)

        controller.updateLastCheck(.failed)
        #expect(!controller.updatesAreCurrent)

        controller.updateLastCheck(.updateFound(version: "1"))
        #expect(!controller.updatesAreCurrent)

        controller.updateLastCheck(.upToDate)
        #expect(controller.updatesAreCurrent)
    }

    private func makeController() -> UpdateController {
        UserDefaults.standard.removeObject(forKey: "solstone.updates.lastCheckedAt")
        UserDefaults.standard.removeObject(forKey: "solstone.updates.lastCheckResult")
        return UpdateController(feedURL: validFeedURL, publicKey: validPublicKey) { _ in nil }
    }
}
