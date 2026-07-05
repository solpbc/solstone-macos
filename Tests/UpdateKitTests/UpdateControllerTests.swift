import Foundation
import Sparkle
import Testing
@testable import UpdateKit

@Suite("UpdateController", .serialized)
@MainActor
struct UpdateControllerTests {
    private let validFeedURL = "https://updates.solstone.app/solstone-macos/appcast.xml"
    private let validPublicKey = "11qYAYKxCrfVS/7TyWQHOg7hcvPa9jIlrwIaaPcHUho="
    private let statusKey = "solstone.updates.status"
    private let feedURLOverrideKey = "solstone.updates.feedURLOverride"
    private let legacyLastCheckedAtKey = "solstone.updates.lastCheckedAt"
    private let legacyLastCheckResultKey = "solstone.updates.lastCheckResult"
    private let isolatedDefaults = IsolatedUserDefaults()

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

    @Test func feedURLOverrideReturnsNilWhenUnset() {
        clearDefaults()
        defer { clearDefaults() }

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsNilWhenEmpty() {
        clearDefaults()
        defer { clearDefaults() }
        isolatedDefaults.defaults.set("", forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsNilWhenWhitespaceOnly() {
        clearDefaults()
        defer { clearDefaults() }
        isolatedDefaults.defaults.set("   ", forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsNilWhenMalformedWithInternalSpace() {
        clearDefaults()
        defer { clearDefaults() }
        isolatedDefaults.defaults.set("https:// updates.solstone.app", forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsNilWhenNonHTTPS() {
        clearDefaults()
        defer { clearDefaults() }
        isolatedDefaults.defaults.set("http://updates.solstone.app/appcast.xml", forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsNilWhenFileScheme() {
        clearDefaults()
        defer { clearDefaults() }
        isolatedDefaults.defaults.set("file:///tmp/appcast.xml", forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == nil)
    }

    @Test func feedURLOverrideReturnsValidHTTPSStagingURL() {
        clearDefaults()
        defer { clearDefaults() }
        let stagingFeedURL = "https://staging.updates.solstone.app/solstone-macos/appcast.xml"
        isolatedDefaults.defaults.set(stagingFeedURL, forKey: feedURLOverrideKey)

        #expect(UpdateController.feedURLOverride(from: isolatedDefaults.defaults) == stagingFeedURL)
    }

    @Test func canCheckForUpdatesUsesBundledConfigWhenOverrideUnset() {
        clearDefaults()
        defer { clearDefaults() }

        let controller = makeController()

        #expect(controller.canCheckForUpdates)
    }

    @Test func canCheckForUpdatesIgnoresFeedURLOverride() {
        clearDefaults()
        defer { clearDefaults() }
        let baseline = makeController().canCheckForUpdates
        #expect(baseline)

        let stagingFeedURL = "https://staging.updates.solstone.app/solstone-macos/appcast.xml"
        isolatedDefaults.defaults.set(stagingFeedURL, forKey: feedURLOverrideKey)

        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }

        #expect(controller.canCheckForUpdates == baseline)
    }

    @Test func validConfigAttemptsUpdaterConstruction() {
        clearDefaults()
        defer { clearDefaults() }
        var attempts = 0

        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            attempts += 1
            return nil
        }

        #expect(attempts == 1)
        #expect(controller.canCheckForUpdates)
        #expect(controller.activity == .idle)
    }

    @Test func updaterSettingsWritesReachSparkleUpdater() {
        clearDefaults()
        defer { clearDefaults() }
        let spy = SpyUpdater(
            automaticallyChecksForUpdates: false,
            updateCheckInterval: 3_600,
            automaticallyDownloadsUpdates: true
        )

        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            spy
        }

        #expect(spy.startCallCount == 1)
        #expect(controller.automaticChecksEnabled == false)
        #expect(controller.updateCheckInterval == 3_600)
        #expect(controller.automaticDownloadsEnabled == true)

        controller.automaticChecksEnabled = true
        controller.updateCheckInterval = 604_800
        controller.automaticDownloadsEnabled = false

        #expect(spy.automaticallyChecksForUpdates)
        #expect(spy.updateCheckInterval == 604_800)
        #expect(!spy.automaticallyDownloadsUpdates)
        #expect(controller.automaticChecksEnabled)
        #expect(controller.updateCheckInterval == 604_800)
        #expect(!controller.automaticDownloadsEnabled)
    }

    @Test func updaterSettingsNilUpdaterReadsSparkleDefaultsAndIgnoresWrites() {
        clearDefaults()
        defer { clearDefaults() }

        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            nil
        }

        #expect(controller.automaticChecksEnabled)
        #expect(controller.updateCheckInterval == 86_400)
        #expect(!controller.automaticDownloadsEnabled)

        controller.automaticChecksEnabled = false
        controller.updateCheckInterval = 604_800
        controller.automaticDownloadsEnabled = true

        #expect(controller.automaticChecksEnabled)
        #expect(controller.updateCheckInterval == 86_400)
        #expect(!controller.automaticDownloadsEnabled)
    }

    @Test func checkForUpdatesRoutesThroughSpyAndHonorsSessionGuard() {
        clearDefaults()
        defer { clearDefaults() }
        let spy = SpyUpdater()
        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            spy
        }

        spy.sessionInProgress = true
        controller.checkForUpdates()
        #expect(spy.checkForUpdatesCallCount == 0)

        spy.sessionInProgress = false
        controller.checkForUpdates()
        #expect(spy.checkForUpdatesCallCount == 1)
    }

    @Test func canStartManualCheckReflectsIdleLiveAndRestoredStagedStates() {
        let now = Date()
        let idleController = makeController()
        idleController.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .upToDate)
        )
        #expect(idleController.canStartManualCheck)

        clearDefaults()
        defer { clearDefaults() }
        let spy = SpyUpdater()
        let liveController = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            spy
        }
        spy.sessionInProgress = true
        #expect(!liveController.canStartManualCheck)

        let stagedController = makeController()
        stagedController.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.4.0", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
        )
        #expect(stagedController.updateIsStaged)
        #expect(stagedController.activity == .idle)
        #expect(!stagedController.hasLiveUpdateReply)
        #expect(stagedController.canStartManualCheck)
    }

    @Test func manualCheckStartsCheckingThroughBeginAndThenNoOpsWhileLive() {
        let controller = makeController()
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .upToDate)
        )

        controller.checkForUpdates()

        #expect(checks == 1)
        #expect(controller.activity == .checking)

        controller.checkForUpdates()

        #expect(checks == 1)
        #expect(controller.activity == .checking)
    }

    @Test func lastCheckedRelativeUsesJustNowThreshold() {
        let base = Date()

        #expect(
            UpdatesCopy(provider: .solstone).lastCheckedRelative(checkedAt: base, now: base.addingTimeInterval(59))
                == UpdatesCopy(provider: .solstone).lastCheckedJustNow
        )
        #expect(
            UpdatesCopy(provider: .solstone).lastCheckedRelative(checkedAt: base, now: base.addingTimeInterval(60))
                != UpdatesCopy(provider: .solstone).lastCheckedJustNow
        )
    }

    @Test func lastCheckedRelativeAdvancesWithInjectedNow() {
        let base = Date()
        let initial = UpdatesCopy(provider: .solstone).lastCheckedRelative(checkedAt: base, now: base)
        let fiveMinutesLater = UpdatesCopy(provider: .solstone).lastCheckedRelative(
            checkedAt: base,
            now: base.addingTimeInterval(300)
        )
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let expectedFiveMinutesLater = formatter.localizedString(
            for: base,
            relativeTo: base.addingTimeInterval(300)
        )

        #expect(initial == UpdatesCopy(provider: .solstone).lastCheckedJustNow)
        #expect(fiveMinutesLater != initial)
        #expect(fiveMinutesLater != UpdatesCopy(provider: .solstone).lastCheckedJustNow)
        #expect(fiveMinutesLater == expectedFiveMinutesLater)
    }

    @Test func perControlActionabilityReflectsLiveStateAndDirectDownloadException() {
        let now = Date()
        let update = AvailableUpdate(version: "1.4.0", releaseNotes: nil)

        let retryEnabledController = makeController()
        retryEnabledController.applyDebugFixture(
            activity: .idle,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
        )
        #expect(retryEnabledController.canRetry)

        let retryDisabledController = makeController()
        retryDisabledController.applyDebugFixture(
            activity: .checking,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .failed)
        )
        #expect(!retryDisabledController.canRetry)

        let directDownloadController = makeController()
        directDownloadController.applyDebugFixture(
            activity: .idle,
            availableUpdate: update,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
            hasLiveChoiceReply: true
        )
        #expect(directDownloadController.canActOnAvailableUpdateDirectly)
        #expect(directDownloadController.canDownload)

        let downloadDisabledController = makeController()
        downloadDisabledController.applyDebugFixture(
            activity: .downloading(version: "1.4.0", receivedBytes: 0, totalBytes: nil),
            availableUpdate: update,
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found)
        )
        #expect(!downloadDisabledController.canActOnAvailableUpdateDirectly)
        #expect(!downloadDisabledController.canDownload)

        let deferredEnabledController = makeController()
        deferredEnabledController.applyDebugFixture(
            activity: .idle,
            deferredInstallIntent: DeferredInstallIntent(version: "1.4.0", requestedAt: now)
        )
        #expect(deferredEnabledController.canCheckAgainFromDeferred)

        let deferredDisabledController = makeController()
        deferredDisabledController.applyDebugFixture(
            activity: .checking,
            deferredInstallIntent: DeferredInstallIntent(version: "1.4.0", requestedAt: now)
        )
        #expect(!deferredDisabledController.canCheckAgainFromDeferred)
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

    @Test func presentUpdaterErrorPreservesDurableAvailableFact() {
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
        #expect(controller.reconciledStatus.lastCheck?.outcome == .found)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func presentNoUpdateFoundPreservesDurableAvailableFact() {
        let controller = makeController()
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.presentNoUpdateFound()

        #expect(controller.activity == .idle)
        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.reconciledStatus.availableVersion == "1.3.9")
        #expect(controller.reconciledStatus.lastCheck?.outcome == .found)
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
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .staged)
        )
        #expect(controller.updateIsStaged)
        #expect(controller.stagedVersion == "1.3.9")
        #expect(controller.statusAXToken == "staged_ready")

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

    @Test func statusAXTokenReportsBackgroundDownloadOnlyWhenIdle() {
        let controller = makeController()
        let now = Date()

        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
            backgroundDownload: .downloading(version: "1.3.9")
        )
        #expect(controller.statusAXToken == "downloading_background")

        controller.applyDebugFixture(
            activity: .extracting(version: "1.3.9", progress: 0.5),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: now, outcome: .found),
            backgroundDownload: .finishingUp(version: "1.3.9")
        )
        #expect(controller.statusAXToken == "extracting")
    }

    @Test func updatesPaneBlockSelectionPrioritizesInteractiveThenBackgroundThenDurable() {
        #expect(updatesPaneBlock(
            status: .available(version: "1.3.9", releaseNotes: nil),
            activity: .downloading(version: "1.3.9", receivedBytes: 1, totalBytes: 2),
            backgroundDownload: .finishingUp(version: "1.3.9"),
            stagedBlockSuppressed: false
        ) == .downloading)
        #expect(updatesPaneBlock(
            status: .available(version: "1.3.9", releaseNotes: nil),
            activity: .extracting(version: "1.3.9", progress: 0.5),
            backgroundDownload: .downloading(version: "1.3.9"),
            stagedBlockSuppressed: false
        ) == .extracting)
        #expect(updatesPaneBlock(
            status: .available(version: "1.3.9", releaseNotes: nil),
            activity: .idle,
            backgroundDownload: .downloading(version: "1.3.9"),
            stagedBlockSuppressed: false
        ) == .backgroundDownloading)
        #expect(updatesPaneBlock(
            status: .staged(version: "1.3.9", releaseNotes: nil),
            activity: .idle,
            backgroundDownload: nil,
            stagedBlockSuppressed: true
        ) == .empty)
    }

    @Test func updatesPaneReasonsCoverDisabledPrimaryActions() {
        let idle = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let unavailable = UpdatesPaneLiveness(
            canCheckForUpdates: false,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let liveSessionNoReply = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: true,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let pendingReply = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: true,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let pendingCancellation = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: true,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let checking = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .checking,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: false
        )
        let finalizing = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: true,
            installFinalizationCommitted: false
        )
        let committed = UpdatesPaneLiveness(
            canCheckForUpdates: true,
            sparkleSessionInProgress: false,
            activity: .idle,
            hasPendingChoiceReply: false,
            hasPendingCancellation: false,
            installFinalizationInFlight: false,
            installFinalizationCommitted: true
        )

        let disabledCases: [(String, BackgroundDownloadPhase?, UpdatesPaneLiveness)] = [
            ("updates unavailable", nil, unavailable),
            ("found-to-willDownload live session", nil, liveSessionNoReply),
            ("background downloading", .downloading(version: "1.3.9"), liveSessionNoReply),
            ("background finishing", .finishingUp(version: "1.3.9"), liveSessionNoReply),
            ("pending choice reply", nil, pendingReply),
            ("pending cancellation", nil, pendingCancellation),
            ("interactive activity", nil, checking),
            ("install finalization in flight", nil, finalizing),
            ("install finalization committed", nil, committed)
        ]

        for (name, backgroundDownload, liveness) in disabledCases {
            let reason = updatesPaneReason(
                isEnabled: false,
                backgroundDownload: backgroundDownload,
                liveness: liveness,
                copy: UpdatesCopy(provider: .solstone)
            )
            #expect(reason?.isEmpty == false, "expected disabled reason for \(name)")
        }

        #expect(updatesPaneReason(
            isEnabled: true,
            backgroundDownload: .downloading(version: "1.3.9"),
            liveness: idle,
            copy: UpdatesCopy(provider: .solstone)
        ) == nil)

        clearDefaults()
        defer { clearDefaults() }
        let spy = SpyUpdater(sessionInProgress: true)
        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            spy
        }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        #expect(!controller.canDownload)
        #expect(updatesPaneReason(
            isEnabled: controller.canDownload,
            backgroundDownload: controller.backgroundDownload,
            liveness: controller.updatesPaneLiveness,
            copy: UpdatesCopy(provider: .solstone)
        )?.isEmpty == false)
    }

    @Test func backgroundCopyUsesVersionAndVersionlessFallbacksWithoutTrailingSpaces() {
        #expect(UpdatesCopy(provider: .solstone).backgroundDownloadingTitle(version: "1.3.9") == "downloading 1.3.9 in the background…")
        #expect(UpdatesCopy(provider: .solstone).backgroundDownloadingTitle(version: nil) == "downloading an update in the background…")
        #expect(UpdatesCopy(provider: .solstone).backgroundFinishingTitle(version: "1.3.9") == "finishing up 1.3.9 in the background…")
        #expect(UpdatesCopy(provider: .solstone).backgroundFinishingTitle(version: nil) == "finishing up in the background…")
        #expect(!UpdatesCopy(provider: .solstone).backgroundDownloadingTitle(version: nil).hasSuffix(" "))
        #expect(!UpdatesCopy(provider: .solstone).backgroundFinishingTitle(version: nil).hasSuffix(" "))
    }

    @Test func suppressingStagedBlockHidesOnlyPaneBlockAndKeepsDurableAttention() {
        let controller = makeController()
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .staged)
        )

        controller.suppressStagedBlock()

        #expect(controller.stagedBlockSuppressed)
        #expect(controller.durableUpdateStatus == .staged(version: "1.3.9", releaseNotes: nil))
        #expect(controller.updatesNeedAttention)
        #expect(controller.statusAXToken == "staged_ready")
        #expect(updatesPaneBlock(
            status: controller.durableUpdateStatus,
            activity: controller.activity,
            backgroundDownload: controller.backgroundDownload,
            stagedBlockSuppressed: controller.stagedBlockSuppressed
        ) == .empty)
    }

    @Test func recheckFromStagedUsesNormalCheckAndSameVersionRefindPreservesStaged() {
        clearDefaults()
        defer { clearDefaults() }
        let spy = SpyUpdater()
        let controller = UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in
            spy
        }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "old notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .staged)
        )

        #expect(controller.canStartManualCheck)
        controller.checkForUpdates()
        #expect(spy.checkForUpdatesCallCount == 1)
        #expect(controller.activity == .idle)

        controller.ingestFoundUpdate(version: "1.3.9", releaseNotes: "new notes")
        #expect(controller.updateIsStaged)
        #expect(controller.durableUpdateStatus == .staged(version: "1.3.9", releaseNotes: "new notes"))

        controller.ingestFoundUpdate(version: "1.4.0", releaseNotes: nil)
        #expect(!controller.updateIsStaged)
        #expect(controller.durableUpdateStatus == .available(version: "1.4.0", releaseNotes: nil))

        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .staged)
        )
        controller.ingestCycleFinished(error: sparkleError(.noUpdateError))
        #expect(controller.activity == .idle)
        #expect(!controller.updateIsStaged)
        #expect(controller.durableUpdateStatus == .upToDate)
    }

    @Test func absentExclusivityProviderDefaultsToNeverExclusive() {
        let controller = makeController()

        #expect(!controller.exclusiveOperationInProgress)
    }

    private func makeController() -> UpdateController {
        clearDefaults()
        return UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            log: updateKitTestLog,
            errorDomain: updateKitTestErrorDomain,
            defaults: isolatedDefaults.defaults
        ) { _, _ in nil }
    }

    private func clearDefaults() {
        isolatedDefaults.clear()
    }

    private func sparkleError(_ code: SUError) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue))
    }
}
