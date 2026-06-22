import Foundation
import Sparkle
import Testing
@testable import solstone

@Suite("SparkleDelegateIngest", .serialized)
@MainActor
struct SparkleDelegateIngestTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let statusKey = "solstone.updates.status"
    private let isolatedDefaults = IsolatedUserDefaults()

    @Test func delegateFoundThenUserDriverFoundIsIdempotent() throws {
        clearDefaults()
        defer { clearDefaults() }
        let harness = try makeHarness()
        let item = try appcastItem(version: "1.3.9", notes: "release notes")

        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: item)
        let firstBlob = try persistedBlob()

        var choices: [SPUUserUpdateChoice] = []
        harness.userDriver.showUpdateFound(
            with: item,
            state: try userUpdateState(stage: .notDownloaded)
        ) { choice in
            choices.append(choice)
        }

        #expect(choices.isEmpty)
        #expect(harness.controller.activity == .idle)
        #expect(harness.controller.hasLiveUpdateReply)
        #expect(harness.controller.availableUpdate == AvailableUpdate(version: "1.3.9", releaseNotes: "release notes"))
        #expect(harness.controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(harness.controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(try persistedBlob() == firstBlob)
    }

    @Test func silentFoundDownloadExtractThenWillInstallStagesDurablyAndSurfacesAttention() throws {
        clearDefaults()
        defer { clearDefaults() }
        let harness = try makeHarness()
        let item = try appcastItem(version: "1.3.9", notes: "release notes")

        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: item)
        let foundBlob = try persistedBlob()
        #expect(harness.controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(harness.controller.activity == .idle)

        harness.delegate.updater?(harness.sparkleUpdater, didDownloadUpdate: item)
        harness.delegate.updater?(harness.sparkleUpdater, didExtractUpdate: item)
        #expect(harness.controller.activity == .idle)
        #expect(try persistedBlob() == foundBlob)

        let handled = try #require(harness.delegate.updater?(
            harness.sparkleUpdater,
            willInstallUpdateOnQuit: item,
            immediateInstallationBlock: {}
        ) as Bool?)

        #expect(!handled)
        #expect(harness.controller.activity == .idle)
        #expect(harness.controller.updateIsStaged)
        #expect(harness.controller.stagedVersion == "1.3.9")
        #expect(harness.controller.availableUpdate == AvailableUpdate(version: "1.3.9", releaseNotes: "release notes"))
        #expect(harness.controller.reconciledStatus.lastCheck?.outcome == .staged)
        #expect(harness.controller.statusAXToken == "staged_ready")

        assertUpdatesPaneStagedOutput(for: harness.controller)
        #expect(
            firstSettingsAttention(
                permissionsNeedAttention: false,
                journalNeedsAttention: false,
                updateIsAvailable: harness.controller.updateIsAvailable,
                updateCheckFailed: harness.controller.updateCheckFailed
            ) == .updateAvailable
        )
        #expect(settingsUpdatesBadgeAXToken(for: harness.controller) == SettingsView.SidebarBadgeState.attention.axToken)
    }

    @Test func stagedFactRestoresAcrossLaunchWhenVersionDiffersFromRunningVersion() throws {
        clearDefaults()
        defer { clearDefaults() }
        var harness: DelegateHarness? = try makeHarness(runningVersion: { "1.3.8" })
        let item = try appcastItem(version: "1.3.9", notes: "release notes")
        let seeded = try #require(harness)

        seeded.delegate.updater?(seeded.sparkleUpdater, didFindValidUpdate: item)
        _ = seeded.delegate.updater?(
            seeded.sparkleUpdater,
            willInstallUpdateOnQuit: item,
            immediateInstallationBlock: {}
        )
        #expect(seeded.controller.updateIsStaged)
        harness = nil

        let restored = try makeHarness(runningVersion: { "1.3.8" })
        #expect(restored.controller.activity == .idle)
        #expect(restored.controller.updateIsStaged)
        #expect(restored.controller.stagedVersion == "1.3.9")
        #expect(restored.controller.availableUpdate == AvailableUpdate(version: "1.3.9", releaseNotes: nil))
        #expect(restored.controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(restored.controller.reconciledStatus.lastCheck?.outcome == .staged)
        #expect(restored.controller.statusAXToken == "staged_ready")
    }

    @Test func stagedFactClearsAcrossLaunchWhenVersionMatchesRunningVersion() throws {
        clearDefaults()
        defer { clearDefaults() }
        var harness: DelegateHarness? = try makeHarness(runningVersion: { "1.3.8" })
        let item = try appcastItem(version: "1.3.9", notes: "release notes")
        let seeded = try #require(harness)

        seeded.delegate.updater?(seeded.sparkleUpdater, didFindValidUpdate: item)
        _ = seeded.delegate.updater?(
            seeded.sparkleUpdater,
            willInstallUpdateOnQuit: item,
            immediateInstallationBlock: {}
        )
        #expect(seeded.controller.updateIsStaged)
        harness = nil

        let restored = try makeHarness(runningVersion: { "1.3.9" })
        #expect(restored.controller.activity == .idle)
        #expect(!restored.controller.updateIsStaged)
        #expect(restored.controller.availableUpdate == nil)
        #expect(restored.controller.reconciledStatus.availableVersion == nil)
        #expect(restored.controller.reconciledStatus.lastCheck?.outcome == .upToDate)
        #expect(restored.controller.statusAXToken == "up_to_date")
    }

    @Test func cycleFinishClassifierMapsNilNoUpdateBenignAndFailedErrors() throws {
        clearDefaults()
        defer { clearDefaults() }

        let nilHarness = try makeHarness()
        let item = try appcastItem(version: "1.3.9", notes: "release notes")
        nilHarness.delegate.updater?(nilHarness.sparkleUpdater, didFindValidUpdate: item)
        let foundBlob = try persistedBlob()
        nilHarness.delegate.updater?(nilHarness.sparkleUpdater, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(try persistedBlob() == foundBlob)
        #expect(nilHarness.controller.reconciledStatus.lastCheck?.outcome == .found)

        clearDefaults()
        let noUpdateHarness = try makeHarness()
        noUpdateHarness.delegate.updater?(
            noUpdateHarness.sparkleUpdater,
            didFinishUpdateCycleFor: .updates,
            error: sparkleError(.noUpdateError)
        )
        #expect(noUpdateHarness.controller.availableUpdate == nil)
        #expect(noUpdateHarness.controller.reconciledStatus.availableVersion == nil)
        #expect(noUpdateHarness.controller.reconciledStatus.lastCheck?.outcome == .upToDate)
        #expect(noUpdateHarness.controller.statusAXToken == "up_to_date")

        clearDefaults()
        let canceledHarness = try makeHarness()
        canceledHarness.delegate.updater?(canceledHarness.sparkleUpdater, didFindValidUpdate: item)
        _ = canceledHarness.delegate.updater?(
            canceledHarness.sparkleUpdater,
            willInstallUpdateOnQuit: item,
            immediateInstallationBlock: {}
        )
        let stagedBlob = try persistedBlob()
        canceledHarness.delegate.updater?(
            canceledHarness.sparkleUpdater,
            didFinishUpdateCycleFor: .updates,
            error: sparkleError(.installationCanceledError)
        )
        canceledHarness.delegate.updater?(
            canceledHarness.sparkleUpdater,
            didFinishUpdateCycleFor: .updates,
            error: sparkleError(.installationAuthorizeLaterError)
        )
        #expect(try persistedBlob() == stagedBlob)
        #expect(canceledHarness.controller.reconciledStatus.lastCheck?.outcome == .staged)
        #expect(canceledHarness.controller.statusAXToken == "staged_ready")

        clearDefaults()
        let failedHarness = try makeHarness()
        failedHarness.delegate.updater?(failedHarness.sparkleUpdater, didFindValidUpdate: item)
        failedHarness.delegate.updater?(
            failedHarness.sparkleUpdater,
            failedToDownloadUpdate: item,
            error: sparkleError(.downloadError)
        )
        #expect(failedHarness.controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(failedHarness.controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(failedHarness.controller.updateCheckFailed)
        #expect(failedHarness.controller.updateIsAvailable)
        #expect(failedHarness.controller.statusAXToken == "error")

        clearDefaults()
        let abortedHarness = try makeHarness()
        abortedHarness.delegate.updater?(abortedHarness.sparkleUpdater, didAbortWithError: NSError(domain: "test", code: 1))
        #expect(abortedHarness.controller.reconciledStatus.lastCheck?.outcome == .failed)
        #expect(abortedHarness.controller.statusAXToken == "error")
    }

    @Test func userDriverFoundThenLateDelegateFoundKeepsLiveReadyToInstallState() throws {
        clearDefaults()
        defer { clearDefaults() }
        let harness = try makeHarness()
        let item = try appcastItem(version: "1.3.9", notes: "release notes")

        var choices: [SPUUserUpdateChoice] = []
        harness.userDriver.showUpdateFound(
            with: item,
            state: try userUpdateState(stage: .downloaded)
        ) { choice in
            choices.append(choice)
        }
        let firstBlob = try persistedBlob()

        harness.delegate.updater?(harness.sparkleUpdater, didFindValidUpdate: item)

        #expect(choices.isEmpty)
        #expect(harness.controller.activity == .readyToInstall(version: "1.3.9", releaseNotes: "release notes"))
        #expect(harness.controller.hasLiveUpdateReply)
        #expect(harness.controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(harness.controller.statusAXToken == "ready_to_install")
        #expect(try persistedBlob() == firstBlob)
    }

    private func makeHarness(
        runningVersion: @escaping UpdateController.RunningVersionProvider = { "1.3.8" }
    ) throws -> DelegateHarness {
        try DelegateHarness(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            defaults: isolatedDefaults.defaults,
            runningVersion: runningVersion
        )
    }

    private func appcastItem(
        version: String,
        buildVersion: String? = nil,
        notes: String? = nil
    ) throws -> SUAppcastItem {
        let buildVersion = buildVersion ?? version
        var dictionary: [String: Any] = [
            "title": "solstone \(version)",
            "sparkle:version": buildVersion,
            "sparkle:shortVersionString": version,
            "enclosure": [
                "url": "https://updates.solstone.app/solstone_\(buildVersion).zip",
                "length": "42",
                "sparkle:version": buildVersion,
                "sparkle:shortVersionString": version
            ]
        ]
        if let notes {
            dictionary["description"] = notes
        }

        return try #require(SUAppcastItem(dictionary: dictionary))
    }

    private func userUpdateState(stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        archiver.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }

        return try #require(SPUUserUpdateState(coder: unarchiver) as SPUUserUpdateState?)
    }

    private func persistedBlob() throws -> Data {
        try #require(isolatedDefaults.defaults.data(forKey: statusKey))
    }

    private func sparkleError(_ code: SUError) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue))
    }

    private func settingsUpdatesBadgeAXToken(for controller: UpdateController) -> String {
        let badge: SettingsView.SidebarBadgeState = controller.updatesNeedAttention
            ? .attention
            : (controller.updatesAreCurrent ? .done : .blank)
        return badge.axToken
    }

    private func assertUpdatesPaneStagedOutput(for controller: UpdateController) {
        #expect(controller.updateIsStaged)
        #expect(controller.stagedVersion == "1.3.9")
        #expect(UpdatesCopy.stagedReadyTitle(version: "1.3.9") == "ready to install v1.3.9")
        #expect(UpdatesCopy.actionRelaunchToInstall == "relaunch to install")
        #expect(UpdatesCopy.stagedReadySubtitle == "the update is downloaded and will install when solstone relaunches.")
    }

    private func clearDefaults() {
        isolatedDefaults.clear()
    }
}

@MainActor
private final class DelegateHarness {
    let spy: SpyUpdater
    let controller: UpdateController
    let userDriver: SparkleUserDriver
    let delegate: any SPUUpdaterDelegate
    let sparkleUpdater: SPUUpdater

    init(
        feedURL: String,
        publicKey: String,
        defaults: UserDefaults,
        runningVersion: @escaping UpdateController.RunningVersionProvider
    ) throws {
        let spy = SpyUpdater()
        var capturedUserDriver: SparkleUserDriver?
        var capturedDelegate: (any SPUUpdaterDelegate)?

        self.spy = spy
        self.controller = UpdateController(
            feedURL: feedURL,
            publicKey: publicKey,
            runningVersion: runningVersion,
            defaults: defaults
        ) { userDriver, delegate in
            capturedUserDriver = userDriver
            capturedDelegate = delegate
            return spy
        }
        self.userDriver = try #require(capturedUserDriver)
        self.delegate = try #require(capturedDelegate)
        self.sparkleUpdater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self.userDriver,
            delegate: self.delegate
        )
    }
}
