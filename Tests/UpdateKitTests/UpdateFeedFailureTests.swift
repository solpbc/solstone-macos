import Foundation
import Testing
@testable import UpdateKit

@MainActor
@Suite("UpdateFeedFailure")
struct UpdateFeedFailureTests {
    @Test(arguments: ["solstone-macos", "journal-macos"])
    func missingFeedRecordsFailedCheck(appcastPathComponent: String) {
        let defaults = IsolatedUserDefaults()
        defer { defaults.clear() }
        let controller = UpdateController(
            feedURL: "https://updates.solstone.app/\(appcastPathComponent)/appcast.xml",
            publicKey: publicKey(for: appcastPathComponent),
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: defaults.defaults
        ) { _, _ in SpyUpdater() }

        controller.ingestCycleFinished(error: NSError(domain: NSURLErrorDomain, code: 404))

        #expect(controller.reconciledStatus.availableVersion == nil)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(controller.durableUpdateStatus == .failed)
        #expect(controller.statusAXToken == "error")
    }

    private func publicKey(for pathComponent: String) -> String {
        switch pathComponent {
        case "journal-macos":
            return "5EP/CLtfMrN2qC8zWsHeIWcPVPjqFH7hW4m8cGX7Qg0="
        default:
            return "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
        }
    }
}
