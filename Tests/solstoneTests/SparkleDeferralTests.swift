import Foundation
import Testing
@testable import solstone

@Suite("Sparkle deferral", .serialized)
@MainActor
struct SparkleDeferralTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let stashKey = "solstone.installer.preInstallerAutoCheckPreference"

    @Test func installerStartDisablesThenRestoresAutomaticChecks() {
        clearStash()
        defer { clearStash() }
        let controller = makeController()

        controller.installerDidStart()
        #expect(controller.automaticChecksEnabled == false)

        controller.installerDidFinish()
        #expect(controller.automaticChecksEnabled == true)
    }

    @Test func installerFinishRestoresPriorDisabledPreference() {
        clearStash()
        defer { clearStash() }
        let controller = makeController()
        controller.automaticChecksEnabled = false

        controller.installerDidStart()
        #expect(controller.automaticChecksEnabled == false)

        controller.installerDidFinish()
        #expect(controller.automaticChecksEnabled == false)
    }

    @Test func installerStartCancelsPendingUpdateCheck() {
        clearStash()
        defer { clearStash() }
        let controller = makeController()
        var didCancel = false
        controller.stashCancellation {
            didCancel = true
        }
        controller.state = .checking

        controller.installerDidStart()

        #expect(didCancel)
        #expect(controller.state == .idle)
        #expect(controller.automaticChecksEnabled == false)
    }

    @Test func doubleStartDoesNotClobberStashedPreference() {
        clearStash()
        defer { clearStash() }
        let controller = makeController()

        controller.installerDidStart()
        controller.installerDidStart()
        controller.installerDidFinish()

        #expect(controller.automaticChecksEnabled == true)
    }

    @Test("preference restored on next launch when prior install was interrupted")
    func persistedStashRecoveryOnInit() {
        clearStash()
        defer { clearStash() }

        UserDefaults.standard.set(true, forKey: stashKey)

        let controller = makeController()

        #expect(controller.automaticChecksEnabled == true)
        #expect(UserDefaults.standard.object(forKey: stashKey) == nil)
    }

    private func makeController() -> UpdateController {
        UpdateController(feedURL: validFeedURL, publicKey: validPublicKey) { _ in nil }
    }

    private func clearStash() {
        UserDefaults.standard.removeObject(forKey: stashKey)
    }
}
