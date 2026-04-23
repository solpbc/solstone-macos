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
}
