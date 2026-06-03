import Foundation
import Sparkle
import Testing
@testable import solstone

@Suite("Sparkle deferral", .serialized)
@MainActor
struct SparkleDeferralTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let statusKey = "solstone.updates.status"
    private let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"

    @Test func delegateGateAllowsManualChecksAndBlocksAutomaticAndProbeChecksDuringExclusive() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)

        await setExclusive(signal, to: true, controller: controller)

        #expect(controller.shouldAllowSparkleUpdateCheck(.updates))
        #expect(!controller.shouldAllowSparkleUpdateCheck(.updatesInBackground))
        #expect(!controller.shouldAllowSparkleUpdateCheck(.updateInformation))
    }

    @Test func installDuringExclusiveDefersLiveReplyUntilSignalClears() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var installed = false
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: "notes"),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                installed = choice == .install
            }
        )

        await setExclusive(signal, to: true, controller: controller)
        controller.install()

        #expect(!installed)
        #expect(controller.deferredInstallIntent?.version == "1.3.9")
        #expect(controller.hasLiveUpdateReply)
        #expect(controller.activity == .idle)

        await setExclusive(signal, to: false, controller: controller)

        #expect(installed)
        #expect(controller.deferredInstallIntent == nil)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func deferredIntentWithMissingReplyFallsBackToCheckWhenSignalClears() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        await setExclusive(signal, to: true, controller: controller)
        controller.install()
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 1)
        #expect(controller.activity == .checking)
        #expect(controller.deferredInstallIntent == nil)
    }

    @Test func signalClearWithDurableAvailableFactAndNoLiveReplyTriggersCheck() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        await setExclusive(signal, to: true, controller: controller)
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 1)
        #expect(controller.activity == .checking)
    }

    @Test func signalClearWithLiveReplyDoesNotStartRedundantCheck() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        await setExclusive(signal, to: true, controller: controller)
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 0)
        #expect(controller.activity == .idle)
        #expect(controller.hasLiveUpdateReply)
    }

    @Test func blockedBackgroundCheckTriggersOneCheckOnSignalClear() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }

        await setExclusive(signal, to: true, controller: controller)
        #expect(!controller.shouldAllowSparkleUpdateCheck(.updatesInBackground))
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 1)
        #expect(controller.activity == .checking)

        controller.applyDebugFixture(activity: .idle)
        await setExclusive(signal, to: true, controller: controller)
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 1)
    }

    @Test func noDurableFactNoBlockedCheckAndNoDeferredIntentDoesNothingOnSignalClear() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(activity: .idle)

        await setExclusive(signal, to: true, controller: controller)
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 0)
        #expect(controller.activity == .idle)
    }

    @Test func stuckExclusiveSignalKeepsDeferredIntentQueryable() async {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var installed = false
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                installed = choice == .install
            }
        )

        await setExclusive(signal, to: true, controller: controller)
        controller.install()
        await Task.yield()

        #expect(!installed)
        #expect(controller.deferredInstallIntent?.version == "1.3.9")
        #expect(controller.updatesNeedAttention)
        #expect(controller.statusAXToken == "deferred_install")
    }

    private func makeController(exclusivity signal: ExclusiveSignal) -> UpdateController {
        clearDefaults()
        return UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            exclusivity: { signal.value }
        ) { _, _ in
            nil
        }
    }

    private func setExclusive(
        _ signal: ExclusiveSignal,
        to value: Bool,
        controller: UpdateController
    ) async {
        var observed = false
        controller.onExclusivityReevaluated = { newValue in
            if newValue == value {
                observed = true
            }
        }

        signal.value = value

        for _ in 0..<20 {
            await Task.yield()
            if observed, controller.exclusiveOperationInProgress == value {
                break
            }
        }

        controller.onExclusivityReevaluated = nil
        #expect(observed)
        #expect(controller.exclusiveOperationInProgress == value)
    }

    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: statusKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckedAtKey)
        UserDefaults.standard.removeObject(forKey: legacyLastCheckResultKey)
    }
}

@MainActor
@Observable
private final class ExclusiveSignal {
    var value = false
}
