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
    private let isolatedDefaults = IsolatedUserDefaults()

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
        await yieldUntil { installed }

        #expect(installed)
        #expect(controller.deferredInstallIntent == nil)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func directInstallAwaitsPreInstallFinalizerBeforeReply() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(exclusivity: signal, preInstallFinalizer: gate.run)
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: "notes"),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }

        #expect(gate.events == ["finalizer-start"])

        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        #expect(gate.events == ["finalizer-start", "finalizer-end", "sparkle-install"])
    }

    @Test func deferredInstallAwaitsPreInstallFinalizerBeforeReply() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(exclusivity: signal, preInstallFinalizer: gate.run)
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: "notes"),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: "notes"),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        await setExclusive(signal, to: true, controller: controller)
        controller.install()
        await Task.yield()

        #expect(gate.events.isEmpty)

        await setExclusive(signal, to: false, controller: controller)
        await yieldUntil { gate.started }

        #expect(gate.events == ["finalizer-start"])

        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        #expect(gate.events == ["finalizer-start", "finalizer-end", "sparkle-install"])
    }

    @Test func notDownloadedDownloadReplySkipsPreInstallFinalizer() async throws {
        let signal = ExclusiveSignal()
        var finalizerInvocations = 0
        var recoveryCalls = 0
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: {
                finalizerInvocations += 1
            },
            installFailureRecovery: {
                recoveryCalls += 1
            }
        )
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        controller.download()
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
            }
        )
        await yieldUntil { replies.count == 1 }
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await Task.yield()

        #expect(checks == 1)
        #expect(replies == [.install])
        #expect(finalizerInvocations == 0)
        #expect(recoveryCalls == 0)
    }

    @Test func notDownloadedDownloadCanCancelWithoutRecoveryOrFinalizer() async throws {
        let signal = ExclusiveSignal()
        var finalizerInvocations = 0
        var recoveryCalls = 0
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: {
                finalizerInvocations += 1
            },
            installFailureRecovery: {
                recoveryCalls += 1
            }
        )
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        var cancellationInvoked = false
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        controller.download()
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
            }
        )
        await yieldUntil { replies.count == 1 }
        controller.beginDownload {
            cancellationInvoked = true
        }
        controller.cancel()
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await Task.yield()

        #expect(checks == 1)
        #expect(replies == [.install])
        #expect(cancellationInvoked)
        #expect(finalizerInvocations == 0)
        #expect(recoveryCalls == 0)
    }

    @Test func downloadedUpdateFoundAwaitsPreInstallFinalizerBeforeReply() async throws {
        try await assertUpdateFoundStageAwaitsPreInstallFinalizer(.downloaded)
    }

    @Test func installingUpdateFoundAwaitsPreInstallFinalizerBeforeReply() async throws {
        try await assertUpdateFoundStageAwaitsPreInstallFinalizer(.installing)
    }

    @Test func nonInstallActionsDoNotRunPreInstallFinalizer() {
        let signal = ExclusiveSignal()
        var finalizerInvocations = 0
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: {
                finalizerInvocations += 1
            }
        )
        var dismissed = false
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                dismissed = choice == .dismiss
            }
        )

        controller.dismiss()

        #expect(dismissed)
        #expect(finalizerInvocations == 0)

        var cancelReplied = false
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { _ in
                cancelReplied = true
            }
        )

        controller.cancel()

        #expect(!cancelReplied)
        #expect(finalizerInvocations == 0)

        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.presentNoUpdateFound()

        #expect(finalizerInvocations == 0)

        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: true
        )

        controller.presentUpdaterError(NSError(domain: "test", code: 1))

        #expect(finalizerInvocations == 0)
    }

    @Test func installDuringPreInstallFinalizerRepliesOnce() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(exclusivity: signal, preInstallFinalizer: gate.run)
        var installReplyCount = 0
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    installReplyCount += 1
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }

        controller.install()
        controller.dismiss()
        controller.cancel()

        #expect(installReplyCount == 0)
        #expect(controller.availableUpdate?.version == "1.3.9")
        #expect(controller.activity == .readyToInstall(version: "1.3.9", releaseNotes: nil))

        gate.release()
        await yieldUntil { installReplyCount == 1 }

        #expect(installReplyCount == 1)
    }

    @Test func recoveryFiresOnErrorAfterCommittedInstall() async throws {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.checkForUpdatesInterceptor = {}
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )
        controller.download()
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await yieldUntil { gate.events.contains("recovery") }

        var replies: [SPUUserUpdateChoice] = []
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
                Issue.record("unexpected \(choice) reply after recovery error")
            }
        )
        await Task.yield()

        #expect(gate.events == ["finalizer-start", "finalizer-end", "sparkle-install", "recovery"])
        #expect(replies.isEmpty)
    }

    @Test func recoveryFiresOnErrorAfterInstallingUpdate() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.installingUpdate()
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await yieldUntil { gate.events.contains("recovery") }

        #expect(gate.events == ["finalizer-start", "finalizer-end", "sparkle-install", "recovery"])
    }

    @Test func recoveryDoesNotFireBeforeInstallFinalization() async {
        let signal = ExclusiveSignal()
        var recoveryCalls = 0
        let controller = makeController(
            exclusivity: signal,
            installFailureRecovery: {
                recoveryCalls += 1
            }
        )

        controller.cancel()
        controller.dismiss()
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(recoveryCalls == 0)
    }

    @Test func recoveryFiresOnceOnCancelAfterCommittedInstall() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.cancel()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(gate.events.contains("recovery"))
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await Task.yield()

        #expect(count(gate.events, "recovery") == 1)
    }

    @Test func recoveryFiresOnceOnDismissAfterCommittedInstall() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.dismiss()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(gate.events.contains("recovery"))
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await Task.yield()

        #expect(count(gate.events, "recovery") == 1)
    }

    @Test func committedInstallRecoveryFiresAtMostOnceAcrossTerminalCallbacks() async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await yieldUntil { gate.events.contains("recovery") }
        controller.presentUpdaterError(NSError(domain: "test", code: 2))
        controller.updateInstalledAndRelaunched()
        controller.dismissUpdateInstallation()
        controller.cancel()
        controller.dismiss()
        await Task.yield()

        #expect(count(gate.events, "recovery") == 1)
    }

    @Test func successfulInstallTerminalsClearCommittedInstallWithoutRecovery() async {
        await assertSuccessfulTerminalClearsCommittedInstall { controller in
            controller.updateInstalledAndRelaunched()
        }
        await assertSuccessfulTerminalClearsCommittedInstall { controller in
            controller.dismissUpdateInstallation()
        }
    }

    @Test func durableAvailableWithoutLiveReplyDownloadStartsCheck() {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: false
        )

        controller.download()

        #expect(checks == 1)
        #expect(controller.activity == .checking)
    }

    @Test func incidentShapeCheckForUpdatesIsNoOpWhenSessionInProgress() {
        let signal = ExclusiveSignal()
        let sessionLive = true
        let controller = makeController(exclusivity: signal, sessionInProgress: { sessionLive })
        var checks = 0
        controller.applyDebugFixture(activity: .idle)
        #expect(!controller.hasLiveUpdateReply)
        controller.checkForUpdatesInterceptor = { checks += 1 }

        controller.checkForUpdates()

        #expect(checks == 0)
        #expect(controller.activity == .idle)
        #expect(!controller.hasLiveUpdateReply)
    }

    @Test func absorbedCheckLeavesNoSpinnerThenInFlightSessionDrivesUI() async throws {
        let signal = ExclusiveSignal()
        let sessionLive = true
        let controller = makeController(exclusivity: signal, sessionInProgress: { sessionLive })
        var checks = 0
        controller.applyDebugFixture(activity: .idle)
        controller.checkForUpdatesInterceptor = { checks += 1 }

        controller.checkForUpdates()

        #expect(checks == 0)
        #expect(controller.activity == .idle)

        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .downloaded),
            reply: { _ in }
        )

        #expect(controller.activity == .readyToInstall(version: "1.3.9", releaseNotes: nil))
    }

    @Test func downloadDuringLiveSessionLeavesNoStrandedIntent() async throws {
        let signal = ExclusiveSignal()
        let sessionLive = true
        let controller = makeController(exclusivity: signal, sessionInProgress: { sessionLive })
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: false
        )
        controller.checkForUpdatesInterceptor = { checks += 1 }

        controller.download()

        #expect(checks == 0)

        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
                Issue.record("unexpected \(choice) reply after live session download")
            }
        )
        await Task.yield()

        #expect(replies.isEmpty)
    }

    @Test func rehydratedUpdateFoundWithDownloadIntentRepliesInstallOnce() async throws {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            hasLiveChoiceReply: false
        )

        controller.download()
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
            }
        )
        await yieldUntil { replies.count == 1 }

        #expect(checks == 1)
        #expect(replies == [.install])
    }

    @Test func terminalOutcomesClearDownloadIntentBeforeLaterUpdateFound() async throws {
        enum TerminalOutcome: CaseIterable {
            case error
            case noUpdate
            case cancel
            case dismiss
        }

        for outcome in TerminalOutcome.allCases {
            let signal = ExclusiveSignal()
            let controller = makeController(exclusivity: signal)
            var checks = 0
            var replies: [SPUUserUpdateChoice] = []
            controller.checkForUpdatesInterceptor = { checks += 1 }
            controller.applyDebugFixture(
                activity: .idle,
                availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
                lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
                hasLiveChoiceReply: false
            )

            controller.download()

            switch outcome {
            case .error:
                controller.presentUpdaterError(NSError(domain: "test", code: 1))
            case .noUpdate:
                controller.presentNoUpdateFound()
            case .cancel:
                controller.cancel()
            case .dismiss:
                controller.dismiss()
            }

            controller.presentUpdateFound(
                version: "1.3.9",
                releaseNotes: nil,
                state: try userUpdateState(stage: .notDownloaded),
                reply: { choice in
                    replies.append(choice)
                    Issue.record("unexpected \(choice) reply after \(outcome)")
                }
            )
            await Task.yield()

            #expect(checks == 1)
            #expect(replies.isEmpty)
        }
    }

    @Test func duplicateFailedCheckClearsDownloadIntentBeforeLaterUpdateFound() async throws {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .failed),
            hasLiveChoiceReply: false
        )

        controller.download()
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
                Issue.record("unexpected \(choice) reply after duplicate failed check")
            }
        )
        await Task.yield()

        #expect(checks == 1)
        #expect(replies.isEmpty)
        #expect(controller.reconciledStatus.lastCheck?.outcome == .failed)
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

    @Test func exclusiveClearPreservesFinalizationDecisionForPendingReply() async throws {
        let downloadedSignal = ExclusiveSignal()
        let downloadedGate = PreInstallFinalizerGate()
        let downloadedController = makeController(
            exclusivity: downloadedSignal,
            preInstallFinalizer: downloadedGate.run
        )
        await setExclusive(downloadedSignal, to: true, controller: downloadedController)
        downloadedController.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .downloaded),
            reply: { choice in
                if choice == .install {
                    downloadedGate.events.append("sparkle-install")
                }
            }
        )

        downloadedController.install()
        #expect(downloadedController.deferredInstallIntent?.version == "1.3.9")
        await setExclusive(downloadedSignal, to: false, controller: downloadedController)
        await yieldUntil { downloadedGate.started }

        #expect(downloadedGate.events == ["finalizer-start"])

        downloadedGate.release()
        await yieldUntil { downloadedGate.events.contains("sparkle-install") }

        #expect(downloadedGate.events == ["finalizer-start", "finalizer-end", "sparkle-install"])

        let notDownloadedSignal = ExclusiveSignal()
        let notDownloadedGate = PreInstallFinalizerGate()
        let notDownloadedController = makeController(
            exclusivity: notDownloadedSignal,
            preInstallFinalizer: notDownloadedGate.run
        )
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        notDownloadedController.checkForUpdatesInterceptor = { checks += 1 }
        notDownloadedController.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        await setExclusive(notDownloadedSignal, to: true, controller: notDownloadedController)
        notDownloadedController.download()
        notDownloadedController.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: .notDownloaded),
            reply: { choice in
                replies.append(choice)
            }
        )

        #expect(notDownloadedController.deferredInstallIntent?.version == "1.3.9")

        await setExclusive(notDownloadedSignal, to: false, controller: notDownloadedController)
        await Task.yield()

        #expect(checks == 1)
        #expect(replies == [.install])
        #expect(notDownloadedGate.events.isEmpty)
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

    @Test func exclusiveClearDuringLiveSessionDoesNotRecheck() async {
        let signal = ExclusiveSignal()
        let sessionLive = true
        let controller = makeController(exclusivity: signal, sessionInProgress: { sessionLive })
        var checks = 0
        controller.checkForUpdatesInterceptor = { checks += 1 }
        controller.applyDebugFixture(
            activity: .idle,
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found)
        )

        await setExclusive(signal, to: true, controller: controller)
        await setExclusive(signal, to: false, controller: controller)

        #expect(checks == 0)
        #expect(controller.activity == .idle)
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

    @Test func userInitiatedCheckEntersCheckingWhenNoSession() {
        let signal = ExclusiveSignal()
        let controller = makeController(exclusivity: signal)

        controller.beginUserInitiatedCheck(cancellation: {})

        #expect(controller.activity == .checking)
    }

    private func makeController(
        exclusivity signal: ExclusiveSignal,
        sessionInProgress: UpdateController.SessionLivenessProvider? = nil,
        preInstallFinalizer: UpdateController.PreInstallFinalizer? = nil,
        installFailureRecovery: UpdateController.InstallFailureRecovery? = nil
    ) -> UpdateController {
        clearDefaults()
        return UpdateController(
            feedURL: validFeedURL,
            publicKey: validPublicKey,
            exclusivity: { signal.value },
            sessionInProgress: sessionInProgress,
            preInstallFinalizer: preInstallFinalizer,
            installFailureRecovery: installFailureRecovery,
            defaults: isolatedDefaults.defaults
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

    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<20 {
            await Task.yield()
            if condition() {
                break
            }
        }
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

    private func assertUpdateFoundStageAwaitsPreInstallFinalizer(_ stage: SPUUserUpdateStage) async throws {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(exclusivity: signal, preInstallFinalizer: gate.run)
        controller.presentUpdateFound(
            version: "1.3.9",
            releaseNotes: nil,
            state: try userUpdateState(stage: stage),
            reply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }

        #expect(gate.events == ["finalizer-start"])

        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        #expect(gate.events == ["finalizer-start", "finalizer-end", "sparkle-install"])
    }

    private func assertSuccessfulTerminalClearsCommittedInstall(
        _ terminal: (UpdateController) -> Void
    ) async {
        let signal = ExclusiveSignal()
        let gate = PreInstallFinalizerGate()
        let controller = makeController(
            exclusivity: signal,
            preInstallFinalizer: gate.run,
            installFailureRecovery: {
                gate.events.append("recovery")
            }
        )
        controller.applyDebugFixture(
            activity: .readyToInstall(version: "1.3.9", releaseNotes: nil),
            availableUpdate: AvailableUpdate(version: "1.3.9", releaseNotes: nil),
            lastCheck: ReconciledUpdateStatus.LastCheck(checkedAt: Date(), outcome: .found),
            choiceReply: { choice in
                if choice == .install {
                    gate.events.append("sparkle-install")
                }
            }
        )

        controller.install()
        await yieldUntil { gate.started }
        gate.release()
        await yieldUntil { gate.events.contains("sparkle-install") }

        controller.installingUpdate()
        terminal(controller)
        controller.presentUpdaterError(NSError(domain: "test", code: 1))
        await Task.yield()

        #expect(!gate.events.contains("recovery"))
    }

    private func clearDefaults() {
        isolatedDefaults.clear()
    }
}

private func count(_ events: [String], _ event: String) -> Int {
    events.count { $0 == event }
}

@MainActor
@Observable
private final class ExclusiveSignal {
    var value = false
}

@MainActor
private final class PreInstallFinalizerGate {
    var events: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var started: Bool {
        events.contains("finalizer-start")
    }

    func run() async {
        events.append("finalizer-start")
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        events.append("finalizer-end")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
