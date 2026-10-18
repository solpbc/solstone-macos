// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import os
import JournalMarkKit
import MacTestSupport
import SolstoneCore
import SPLTunnel
import Testing
@testable import solstone

@MainActor
private final class TestRunningJournalController: RunningJournalController {
    var installed: URL? = nil
    var running = false
    var launchCount = 0

    func installedURL() -> URL? {
        installed
    }

    func runningPID() -> pid_t? {
        running ? 1234 : nil
    }

    func terminateRunningJournal() -> Bool {
        false
    }

    func launchJournal(at url: URL) throws {}
    func launchJournalActivating(at url: URL) throws { launchCount += 1 }
}

@MainActor
private final class TestTrustVerifier: TrustVerifier {
    func verifyJournalApp(at url: URL) async throws {}
}

@Suite("Setup model")
@MainActor
struct SetupModelTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("setup-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let sampleFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


    @Test func disabledPreparationIgnoresProgressAndHandoffWithoutChangingEither() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .screen))
        let mailbox = SetupMailboxStore(directory: dir)
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5, journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance", expectedCAFingerprint: sampleFingerprint)
        try mailbox.writeStep5(handoff)
        let progressBefore = try Data(contentsOf: store.fileURL)
        var prompts = 0
        var restarts = 0
        let state = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: true))
        state.configSaver = { _ in Issue.record("disabled setup changed owner configuration") }
        let model = SetupModel(
            enabled: false,
            continuationStore: store,
            mailboxStore: mailbox,
            freshFlow: FreshJournalFlow(dependencies: .inert()),
            requestMicrophone: { prompts += 1 },
            requestScreen: { prompts += 1 },
            appState: state
        )
        #expect(model.phase == nil)
        #expect(model.continuation == nil)
        #expect(!model.isPeerSupportingSetup)
        model.activate()
        model.ingestStep5IfNeeded()
        #expect(!model.setPhase(.microphone))
        #expect(!model.switchToOwnerComparison())
        await model.turnOnMicrophone().value
        await model.turnOnScreen().value
        await model.notNowMicrophone().value
        await model.notNowScreen().value
        model.prepareScreenRestart { restarts += 1 }
        model.performSetupFinalOpen()
        #expect(prompts == 0)
        #expect(restarts == 0)
        #expect(!state.config.isScreenCaptureEnabled)
        #expect(state.config.isMicrophoneCaptureEnabled)
        #expect(model.phase == nil)
        #expect(model.continuation == nil)
        #expect(!model.isPeerSupportingSetup)
        #expect(model.acknowledgementError == nil)
        #expect(try Data(contentsOf: store.fileURL) == progressBefore)
        #expect(mailbox.loadStep5() == .ready(handoff))
        #expect(try mailbox.readStep5Receipt() == nil)
    }

    @Test func setupSourceActionsRebuildRunningSourcesAfterGrantAndPreservePause() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var screenGranted = false
        var starts: [CaptureSources] = []
        var state: AppState!
        state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false),
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { true }, preflight: { screenGranted },
                checkScreenRecording: { screenGranted }, resetPromptedFlag: {}
            ),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler,
            captureStartOperation: { _, sources, _ in
                starts.append(sources)
                state.captureManager.seedRecordingForTesting(
                    currentSegment: FakeCaptureSegment(outputDirectory: dir.appendingPathComponent(UUID().uuidString)),
                    sources: sources
                )
                state.capture.handleCaptureStateChange(.recording)
                return .committed
            }
        )
        state.configSaver = { _ in }
        state.capture.activate()
        state.capture.microphoneAuthorizationReader = { .authorized }
        var microphonePrompts = 0
        var screenPrompts = 0
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            requestMicrophone: { microphonePrompts += 1 },
            requestScreen: { screenPrompts += 1 }, appState: state
        )
        await model.turnOnMicrophone().value
        #expect(microphonePrompts == 1)
        #expect(starts == [.microphone])
        await model.turnOnScreen().value
        #expect(screenPrompts == 1)
        #expect(starts == [.microphone])
        #expect(state.captureManager.activeSources == .microphone)

        // Returning from System Settings must add screen to the already-running microphone.
        screenGranted = true
        await model.reconcileSourcePermissions()
        #expect(starts == [.microphone, .all])
        #expect(state.captureManager.activeSources == .all)
        await model.notNowScreen().value
        #expect(state.captureManager.activeSources == .microphone)
        await state.stopRecording()
        let startsAfterOwnerStop = starts.count
        // Declining screen must not restart the still-selected and granted microphone.
        await model.notNowScreen().value
        #expect(state.config.isMicrophoneCaptureEnabled)
        #expect(state.capture.isExplicitlyStopped)
        #expect(!state.isRecording)
        #expect(starts.count == startsAfterOwnerStop)
        await model.notNowMicrophone().value
        #expect(state.captureManager.activeSources.isEmpty)
        #expect(!state.isRecording)

        #expect(state.capture.isExplicitlyStopped)
        await model.reconcileSourcePermissions()
        #expect(state.capture.isExplicitlyStopped)
        #expect(!state.isRecording)
        state.pauseManager.pause(for: .indefinite)
        let startsBeforePause = starts.count
        await model.turnOnScreen().value
        #expect(state.pauseManager.isPaused)
        #expect(starts.count == startsBeforePause)
        state.pauseManager.resume()
        try await waitUntil { starts.count == startsBeforePause + 1 }
        #expect(state.captureManager.activeSources == .screen)
        await state.stopRecording()
        state = nil
    }

    @Test func newerOwnerStopWinsWhileMicrophonePermissionRequestIsPending() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let prompts = LockedCounter()
        let starts = LockedCounter()
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false),
            screenPermissionProvider: ScreenRecordingPermissionProvider(
                hasPrompted: { false }, preflight: { false },
                checkScreenRecording: { false }, resetPromptedFlag: {}
            ),
            permissionPollScheduler: PermissionPollTestScheduler().scheduler,
            captureStartOperation: { _, _, _ in starts.increment(); return .committed }
        )
        state.configSaver = { _ in }
        state.capture.microphoneAuthorizationReader = { .authorized }
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            requestMicrophone: { prompts.increment(); await gate.wait() },
            requestScreen: {}, appState: state
        )
        let pending = model.turnOnMicrophone()
        try await waitUntil { prompts.count == 1 }
        await state.stopRecording()
        #expect(state.capture.isExplicitlyStopped)
        gate.release()
        await pending.value
        #expect(state.config.isMicrophoneCaptureEnabled)
        #expect(state.capture.isExplicitlyStopped)
        #expect(!state.capture.isRecording)
        #expect(starts.count == 0)
    }

    @Test func screenFailureDiscardsOldPreviewWhileMicrophoneContinues() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: true, isMicrophoneCaptureEnabled: true))
        state.capture.publishScreenRecordingPermission(.granted)
        state.captureManager.seedRecordingForTesting(
            currentSegment: FakeCaptureSegment(outputDirectory: dir), sources: .all
        )
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let frame = try #require(context.makeImage())
        let previousEpoch = state.previewEpoch
        state.updateLatestFrame(frame, epoch: previousEpoch)
        #expect(state.latestFrame != nil)
        state.captureManager.recordScreenFailure(.stopped)
        #expect(state.captureManager.activeSources.contains(.microphone))
        #expect(state.captureManager.state.isRecording)
        #expect(state.latestFrame == nil)
        #expect(state.previewEpoch != previousEpoch)
        state.captureManager.clearScreenFailure()
        #expect(state.latestFrame == nil)
        state.updateLatestFrame(frame, epoch: previousEpoch)
        #expect(state.latestFrame == nil)
        state.updateLatestFrame(frame, epoch: state.previewEpoch)
        #expect(state.latestFrame != nil)
    }

    @Test func busyHandoffLockShowsFailureAndRetryAcceptsWithoutLosingPayload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        let mailbox = model.mailboxStore
        let handoffID = UUID()
        try mailbox.writeStep5(SetupHandoff(handoffID: handoffID, stepIndex: 5, journalRootPath: "/fixture/journal",
            expectedInstanceID: "inst-1", expectedCAFingerprint: sampleFingerprint))
        let lockFD = open(dir.appendingPathComponent("solstone-setup-handoff.lock").path, O_RDWR | O_CREAT, 0o600)
        try #require(lockFD >= 0)
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        try #require(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        model.ingestStep5IfNeeded()
        #expect(model.acknowledgementError != nil)
        #expect(model.phase == .journal)
        #expect(store.load()?.accepted == nil)
        #expect(mailbox.loadStep5() == .ready(SetupHandoff(handoffID: handoffID, stepIndex: 5,
            journalRootPath: "/fixture/journal", expectedInstanceID: "inst-1", expectedCAFingerprint: sampleFingerprint)))
        flock(lockFD, LOCK_UN)
        model.ingestStep5IfNeeded()
        #expect(model.acknowledgementError == nil)
        #expect(model.phase == .microphone)
        #expect(store.load()?.accepted?.handoffID == handoffID)
        #expect(try mailbox.readStep5Receipt()?.handoffID == handoffID)

        // A later duplicate receipt attempt also reports a busy lock and keeps its phase.
        try #require(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        model.ingestStep5IfNeeded()
        #expect(model.acknowledgementError != nil)
        #expect(model.phase == .microphone)
        flock(lockFD, LOCK_UN)
        model.ingestStep5IfNeeded()
        #expect(model.acknowledgementError == nil)
        #expect(model.phase == .microphone)
    }

    @Test func remoteChoiceFencesPendingAcquisitionAndRestoredJournalPhase() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let acquisitionStarts = LockedCounter()
        let controller = TestRunningJournalController()
        let flow = FreshJournalFlow(
            dependencies: .inert(runningJournal: controller),
            resolveTrustedJournalOverride: {
                acquisitionStarts.increment()
                await gate.wait()
                return bundle
            }
        )
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        let pending = Task { await model.runJournalPhase() }
        try await waitUntil { acquisitionStarts.count == 1 }
        #expect(model.switchToOwnerComparison())
        gate.release()
        await pending.value
        #expect(controller.launchCount == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal-setup-handoff.json").path))
        let restored = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        #expect(restored.phase == .journal)
        #expect(restored.continuation?.mode == .ownerComparison)
        restored.activate()
        await restored.runJournalPhase()
        await Task.yield()
        #expect(acquisitionStarts.count == 1)
        #expect(controller.launchCount == 0)
    }

    @Test func uncommittedIsDistinctFromAbsentFailedAndCommitted() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Older peer path where evaluatePeerSupport returns false (Info.plist lacks setup capabilities)
        let mockOlderJournal = try createMockBundle(capabilities: nil)
        let controller = TestRunningJournalController()
        controller.installed = mockOlderJournal

        let resolutionLock = OSAllocatedUnfairLock(initialState: JournalIdentityResolution.uncommitted(instanceID: "inst-1"))

        let freshFlow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies(
                runningJournal: controller,
                trustVerifier: TestTrustVerifier()
            )
        )

        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: freshFlow,
            resolveIdentity: { _, _ in resolutionLock.withLock { $0 } },
            sleepDuration: .milliseconds(10)
        )

        _ = model.setPhase(.journal)

        // Wait for the result, not a timing assumption about actor scheduling.
        try await waitUntil { model.journalPollingText == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP }
        #expect(model.journalPollingText == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP)
        #expect(model.journalPollingError == nil)

        resolutionLock.withLock { $0 = .absent }
        try await waitUntil { model.journalPollingText == UICopy.SETUP_OPENING_YOUR_JOURNAL }
        #expect(model.journalPollingText == UICopy.SETUP_OPENING_YOUR_JOURNAL)
        #expect(model.journalPollingError == nil)

        resolutionLock.withLock { $0 = .failed(.httpStatus(500)) }
        try await waitUntil { model.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL }
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)

        let mark = JournalMark.uiTestSample
        resolutionLock.withLock { $0 = .mark(mark, instanceID: "inst-1") }
        try await waitUntil { model.olderDiscoveredMark == mark }
        #expect(model.olderDiscoveredMark == mark)
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == nil)

        model.stopJournalPolling()
    }

    @Test func step1ReceiptDoesNotMoveThePhase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            sleepDuration: .seconds(10)
        )

        _ = model.setPhase(.journal)
        #expect(model.phase == .journal)

        // Write step1 receipt into mailbox
        let receipt = SetupHandoffReceipt(handoffID: UUID(), stepIndex: 1)
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: dir.appendingPathComponent("journal-setup-handoff-accepted.json"))

        model.ingestStep5IfNeeded()
        #expect(model.phase == .journal)
    }

    @Test func olderPeerDoesNotWriteStep1() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let controller = TestRunningJournalController()
        controller.installed = nil // Not supporting setup sequence

        let freshFlow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies(
                runningJournal: controller,
                trustVerifier: TestTrustVerifier()
            )
        )
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: freshFlow,
            resolveIdentity: { _, _ in .absent },
            sleepDuration: .milliseconds(100)
        )

        _ = model.setPhase(.journal)
        try await Task.sleep(for: .milliseconds(30))

        #expect(!model.isPeerSupportingSetup)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(!FileManager.default.fileExists(atPath: step1File.path))

        model.stopJournalPolling()
    }

    @Test func step5ForNilPhaseDoesNotSetThePhase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir
        )

        #expect(model.phase == nil)

        // Write a valid step 5 handoff
        let handoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(handoff).write(to: dir.appendingPathComponent("solstone-setup-handoff.json"))

        model.ingestStep5IfNeeded()

        #expect(model.phase == nil)
        #expect(model.continuation?.accepted == nil)
    }

    @Test func heldHomeRejectsNewID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Configure AppState with held home
        let appState = AppState.forSnapshot(initialTunnelPairing: pairing())

        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            appState: appState
        )

        _ = model.setPhase(.journal)

        let handoff = SetupHandoff(
            handoffID: UUID(),
            stepIndex: 5,
            journalRootPath: "/test/root",
            expectedInstanceID: "new-home-id",
            expectedCAFingerprint: sampleFingerprint
        )
        try JSONEncoder().encode(handoff).write(to: dir.appendingPathComponent("solstone-setup-handoff.json"))

        model.ingestStep5IfNeeded()

        #expect(model.phase == .journal)
        #expect(model.continuation?.accepted == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("solstone-setup-handoff-accepted.json").path))
    }

    @Test func adoptionFlagRemainsFalseAroundAppStateWrapper() async {
        let appState = AppState.forSnapshot()
        #expect(!appState.isAdoptingSameMachineHomeAutomatically)

        _ = await appState.verifySupportingConnectionFromHandoff(
            expectedHandoffID: UUID(),
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        )

        #expect(!appState.isAdoptingSameMachineHomeAutomatically)
    }

    @Test func finishWithBothSourcesFalseClearsPhaseAndDoesNotInvokeOpener() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState.forSnapshot(config: AppConfig(
            isScreenCaptureEnabled: false,
            isMicrophoneCaptureEnabled: false
        ))

        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: appState)
        _ = model.setPhase(.connection)

        // Unverified call does not clear phase and does not open
        var openerCalled = false
        let unverifiedResult = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { false },
            fetchTunnelIdentity: { .absent },
            fetchDirectIdentity: { .absent },
            openURL: { _ in openerCalled = true; return true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!unverifiedResult)
        #expect(model.phase == .connection)
        #expect(!openerCalled)

        // Fully verified open with both sources off clears phase
        let mark = JournalMark.uiTestSample
        let verifiedResult = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(mark, instanceID: "inst-1") },
            openURL: { _ in openerCalled = true; return true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(verifiedResult)
        #expect(openerCalled)
        #expect(model.phase == nil)
        #expect(!appState.capture.isRecording)
    }

    @Test func notNowLeavesSourceFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState.forSnapshot()

        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: appState)
        _ = model.setPhase(.microphone)

        model.notNowMicrophone()
        #expect(!appState.config.isMicrophoneCaptureEnabled)
        #expect(model.phase == .screen)

        model.notNowScreen()
        #expect(!appState.config.isScreenCaptureEnabled)
        #expect(model.phase == .connection)
    }

    @Test func prepareScreenRestartSavesPhaseScreenAndChoiceBeforeRequestRestartRuns() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let appState = AppState.forSnapshot(config: AppConfig(isScreenCaptureEnabled: false))

        let model = SetupModel(enabled: true, continuationStore: store, mailboxDirectory: dir, appState: appState)
        _ = model.setPhase(.microphone)

        var phaseAtRestart: SetupPhase?
        var choiceAtRestart: Bool?

        model.prepareScreenRestart {
            phaseAtRestart = model.phase
            choiceAtRestart = appState.config.isScreenCaptureEnabled
        }

        #expect(phaseAtRestart == .screen)
        #expect(choiceAtRestart == true)
        #expect(store.load()?.phase == .screen)
    }

    @Test func pauseStaysPausedAcrossStepChange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState.forSnapshot(setupModel: SetupModel(enabled: true, mailboxDirectory: dir))
        appState.pauseManager.pause(for: .minutes(5))
        #expect(appState.pauseManager.isPaused)

        let model = appState.setupModel
        _ = model.setPhase(.microphone)
        #expect(appState.pauseManager.isPaused)

        model.continueFromMicrophone()
        #expect(model.phase == .screen)
        #expect(appState.pauseManager.isPaused)

        model.continueFromScreen()
        #expect(model.phase == .connection)
        #expect(appState.pauseManager.isPaused)
    }

    @Test func nonLiveGateHidesTheImage() {
        let appState = AppState.forSnapshot()
        // When not recording, latestFrame must be nil
        #expect(!appState.capture.isRecording)
        #expect(appState.latestFrame == nil)

        // Type check: latestFrame is an in-memory CGImage?, not a file URL
        let frame: CGImage? = appState.latestFrame
        #expect(frame == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func restoredSupportingConnectionWaitsForTunnelAndVerifiesRetainedCredential(alreadyConfirmed: Bool, readinessDuringFetch: Bool) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fingerprint = CertChain.sha256Fingerprint(of: try #require(CertChain.certificates(fromPEM: testCACertPEM).first))
        let retained = pairing(fingerprint: fingerprint)
        let pairingStore = PairingStore(pairing: retained)
        let transport = FakeTunnelTransport(connection: .init(localPort: 18321, via: .lan))
        transport.armConnectGate()
        let factory = FakeTransportFactory([transport])
        let protocolStore = ObserverURLProtocolStore()
        protocolStore.registerRoute(matching: { _ in true }, statusCode: 503)
        let session = URLSession(configuration: observerURLProtocolConfiguration(store: protocolStore))
        defer { session.invalidateAndCancel() }
        let owner = TunnelLifecycleOwner(
            keychainStore: pairingStore,
            loadPairing: { try pairingStore.load() },
            tokenRefresher: FakeTokenRefresher().seam,
            makeTransport: { factory.make() },
            pathMonitoringSource: NoopPathMonitoringSource(),
            probe: { _, _ in true },
            loopbackSession: session,
            unlockNotificationCenter: NotificationCenter()
        )
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .connection, accepted: SetupAcceptedStep5Snapshot(
            handoffID: UUID(), journalRootPath: "/fixture/journal",
            expectedInstanceID: retained.instanceID, expectedCAFingerprint: fingerprint
        ), mode: .supporting))
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        let fetched = LockedArray<String>([])
        let identityGate = OneShotContinuationGate()
        defer { identityGate.release(); transport.releasePendingConnect() }
        let pairStarts = LockedCounter()
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false),
            initialTunnelPairing: retained,
            setupModel: model, tunnelLifecycleOwner: owner,
            supportingIdentityResolver: { base, instance in
                fetched.append(base)
                #expect(instance == retained.instanceID)
                if readinessDuringFetch && fetched.all.count == 1 {
                    model.handleTunnelConnected()
                    await identityGate.wait()
                    #expect(!Task.isCancelled)
                    return .failed(.httpStatus(503))
                }
                await identityGate.wait()
                return .mark(.uiTestSample, instanceID: retained.instanceID)
            },
            sameMachinePairStart: { _, _ in
                pairStarts.increment()
                return .failure(SameMachinePairStartFailure(kind: .transport))
            },
            triggerTunnelConnectedSync: { _ in }, journalURLOpener: { _ in false },
            journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(
                confirmedJournal: alreadyConfirmed ? journalMarkConfirmationIdentity(for: retained) : nil, settled: true
            ),
            pairingLoad: { try pairingStore.load() }
        )
        state.configSaver = { _ in }
        model.activate()
        state.startTunnelLifecycleOwner()
        do {
            try await waitUntil { transport.pendingConnectCount == 1 }
            #expect(state.isJournalMarkConfirmed == alreadyConfirmed)
            #expect(state.confirmedMark == nil)
            #expect(fetched.all.isEmpty)
            transport.releaseNextConnect()
            try await waitUntil { fetched.all.count == 1 }
            #expect(state.isJournalMarkConfirmed == alreadyConfirmed)
            #expect(state.confirmedMark == nil)
            #expect(model.connectionStepState == .connecting)
            identityGate.release()
            try await waitUntil { model.connectionStepState == .connected(.uiTestSample) }
            #expect(state.isJournalMarkConfirmed)
            #expect(state.confirmedMark == .uiTestSample)
            #expect(state.currentDurablePairingRevision == PairingCredentialRevision(from: retained))
            #expect(fetched.all == Array(repeating: "http://127.0.0.1:18321", count: readinessDuringFetch ? 2 : 1))
            #expect(pairStarts.count == 0)
            #expect(pairingStore.saveCount == 0)
            #expect(pairingStore.deleteCount == 0)
            #expect(!state.config.isScreenCaptureEnabled)
            #expect(!state.config.isMicrophoneCaptureEnabled)
            #expect(!state.capture.isRecording)
            // Completion retains receipt recovery without retaining exclusive confirmation ownership.
            let completedSnapshot = try #require(model.continuation?.accepted)
            #expect(model.setPhase(nil))
            #expect(!model.isPeerSupportingSetup)
            let completedModel = SetupModel(enabled: true, mailboxDirectory: dir)
            #expect(completedModel.phase == nil)
            #expect(completedModel.continuation?.completed == true)
            #expect(completedModel.continuation?.accepted == completedSnapshot)
            #expect(!completedModel.isPeerSupportingSetup)
            try completedModel.mailboxStore.writeStep5(SetupHandoff(
                handoffID: completedSnapshot.handoffID, stepIndex: 5,
                journalRootPath: completedSnapshot.journalRootPath,
                expectedInstanceID: completedSnapshot.expectedInstanceID,
                expectedCAFingerprint: completedSnapshot.expectedCAFingerprint
            ))
            completedModel.ingestStep5IfNeeded()
            #expect(try completedModel.mailboxStore.readStep5Receipt()?.handoffID == completedSnapshot.handoffID)
            #expect(completedModel.phase == nil)
            #expect(!completedModel.isPeerSupportingSetup)
            let completedState = AppState.forSnapshot(
                config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false),
                initialTunnelPairing: retained,
                setupModel: completedModel, tunnelLifecycleOwner: owner,
                triggerTunnelConnectedSync: { _ in }, journalURLOpener: { _ in false },
                journalMarkConfirmationStore: InMemoryJournalMarkConfirmationStore(settled: true),
                pairingLoad: { try pairingStore.load() }
            )
            completedState.beginOwnerPairingAttempt()
            let ordinaryRevision = try #require(completedState.beginJournalMarkConfirmationAttempt())
            #expect(completedState.recordJournalMarkConfirmed(mark: .uiTestSample, expectedRevision: ordinaryRevision))
            #expect(completedState.isJournalMarkConfirmed)
            // Continue the existing remote-choice check from an active source phase.
            #expect(model.setPhase(.screen))
            // Explicit remote pairing can continue without discovering a local journal.
            let accepted = model.continuation?.accepted
            #expect(model.switchToOwnerComparison())
            #expect(model.continuation?.accepted == accepted)
            #expect(model.setPhase(.journal))
            model.stopJournalPolling()
            #expect(model.olderDiscoveredMark == nil)
            model.continueFromOlderJournal()
            #expect(model.phase == .microphone)
        } catch {
            identityGate.release()
            transport.releasePendingConnect()
            state.stopTunnelLifecycleOwner()
            await owner.stop()
            throw error
        }
        state.stopTunnelLifecycleOwner()
        await owner.stop()
    }

    private final class MockThrowingRunningJournal: RunningJournalController {
        var shouldThrow = false
        var launched = false
        var installed: URL? = nil
        func installedURL() -> URL? { installed }
        func runningPID() -> pid_t? { nil }
        func terminateRunningJournal() -> Bool { false }
        func launchJournal(at url: URL) throws {
            if shouldThrow { struct LaunchError: Error {}; throw LaunchError() }
            launched = true
        }
        func launchJournalActivating(at url: URL) throws {
            if shouldThrow { struct LaunchError: Error {}; throw LaunchError() }
            launched = true
        }
    }

    private func createMockBundle(capabilities: Any?) throws -> URL {
        let dir = try makeTempDir()
        let appBundle = dir.appendingPathComponent("MockJournal.app", isDirectory: true)
        let contents = appBundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plistDict: [String: Any] = [
            "CFBundleIdentifier": "com.solstone.journal",
            "CFBundleExecutable": "MockJournal"
        ]
        if let capabilities {
            plistDict["SolstoneSetupCapabilities"] = capabilities
        }
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        return appBundle
    }

    @Test func acquiredBundleWithExactOrSupersetCapabilitiesWritesStep1AndLaunches() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Exact capabilities ["setup-sequence-v1"]
        let exactBundle = try createMockBundle(capabilities: ["setup-sequence-v1"])

        let runnerExact = MockThrowingRunningJournal()
        let freshFlowExact = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(runningJournal: runnerExact),
            resolveTrustedJournalOverride: { exactBundle }
        )

        let modelExact = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: freshFlowExact,
            resolveIdentity: { _, _ in .absent },
            sleepDuration: .milliseconds(50)
        )

        _ = modelExact.setPhase(.journal)
        try await Task.sleep(for: .milliseconds(80))
        modelExact.stopJournalPolling()

        #expect(!modelExact.isPeerSupportingSetup)
        #expect(runnerExact.launched)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(FileManager.default.fileExists(atPath: step1File.path))

        try? FileManager.default.removeItem(at: step1File)

        // 2. Superset capabilities ["setup-sequence-v1", "other"]
        let supersetBundle = try createMockBundle(capabilities: ["setup-sequence-v1", "other"])

        let runnerSuperset = MockThrowingRunningJournal()
        let freshFlowSuperset = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(runningJournal: runnerSuperset),
            resolveTrustedJournalOverride: { supersetBundle }
        )

        let modelSuperset = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: freshFlowSuperset,
            resolveIdentity: { _, _ in .absent },
            sleepDuration: .milliseconds(50)
        )

        _ = modelSuperset.setPhase(.journal)
        try await Task.sleep(for: .milliseconds(80))
        modelSuperset.stopJournalPolling()

        #expect(!modelSuperset.isPeerSupportingSetup)
        #expect(runnerSuperset.launched)
        #expect(FileManager.default.fileExists(atPath: step1File.path))
    }

    @Test func journalPhaseFailuresSurfaceRetryAndStayOnJournal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Acquire throws
        let flowAcqThrow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(runningJournal: MockThrowingRunningJournal()),
            resolveTrustedJournalOverride: {
                struct AcqError: Error {}
                throw AcqError()
            }
        )
        let modelAcq = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: flowAcqThrow
        )
        _ = modelAcq.setPhase(.journal)
        await modelAcq.runJournalPhase()
        #expect(modelAcq.phase == SetupPhase.journal)
        #expect(modelAcq.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)

        // 2. Launch throws
        let exactBundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let launchThrowingRunner = MockThrowingRunningJournal()
        launchThrowingRunner.shouldThrow = true
        let flowLaunchThrow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(runningJournal: launchThrowingRunner),
            resolveTrustedJournalOverride: { exactBundle }
        )
        let modelLaunch = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: flowLaunchThrow
        )
        _ = modelLaunch.setPhase(.journal)
        await modelLaunch.runJournalPhase()
        #expect(modelLaunch.phase == SetupPhase.journal)
        #expect(modelLaunch.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)
    }

    @Test func observationTrackingAndFailingDefaultsWriterLeavesStoredPhaseUnchanged() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        let cont = SetupContinuation(phase: .microphone)
        try store.save(cont)

        let model = SetupModel(enabled: true, continuationStore: store, mailboxDirectory: dir)
        #expect(model.phase == SetupPhase.microphone)

        var observedPhases: [SetupPhase?] = []
        withObservationTracking {
            observedPhases.append(model.phase)
        } onChange: {
            // Observed change
        }

        model.continueFromMicrophone()
        #expect(model.phase == SetupPhase.screen)

        // Failing store
        struct SaveError: Error {}
        let failingStore = SetupContinuationStore(directory: dir, replace: { _, _ in throw SaveError() })
        let failingModel = SetupModel(enabled: true, continuationStore: failingStore, mailboxDirectory: dir)
        #expect(failingModel.phase == SetupPhase.screen)
        _ = failingModel.setPhase(.microphone)
        #expect(failingModel.phase == SetupPhase.screen)
    }

    @Test func discoveredOlderMarkDoesNotChangePhaseAndContinueNoOpsUntilConfirmed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appState = AppState.forSnapshot()
        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: appState)
        _ = model.setPhase(.journal)

        let mark = JournalMark.uiTestSample
        model.olderDiscoveredMark = mark
        #expect(model.phase == SetupPhase.journal)

        // continueFromOlderJournal no-ops until mark is confirmed and admission ready
        model.continueFromOlderJournal()
        #expect(model.phase == SetupPhase.journal)

        // Set confirmed mark
        appState.setConfirmedMark(mark)
        model.continueFromOlderJournal()
        #expect(model.phase == SetupPhase.journal)
        #expect(!appState.isAdoptingSameMachineHomeAutomatically)
    }

    @Test func remoteFinalOpenRequiresIdentityAndObservedWindowButNeverLocalEndpoint() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        var opened = 0
        var allowOpen = false
        var allowSave = false
        var identityFetches = 0
        func attempt() async -> Bool {
            await model.executeSetupFinalOpen(
                expectedInstanceID: "remote", expectedMark: .uiTestSample, isOlderPeer: true,
                isRemotePeer: true,
                openPairedJournal: { opened += 1; return allowOpen },
                checkAdmission: { true },
                fetchTunnelIdentity: { identityFetches += 1; return .mark(.uiTestSample, instanceID: "remote") },
                fetchDirectIdentity: { Issue.record("remote setup must not require a local Journal endpoint"); return .absent },
                openURL: { _ in Issue.record("remote setup must not export its authenticated tunnel to a browser"); return false },
                persistFinish: { allowSave }
            )
        }
        #expect(await attempt() == false)
        #expect(!model.journalOpenedPendingCompletion)
        allowOpen = true
        #expect(await attempt() == false)
        #expect(model.journalOpenedPendingCompletion)
        #expect(opened == 2)
        allowSave = true
        #expect(await attempt())
        #expect(!model.journalOpenedPendingCompletion)
        #expect(opened == 2)
        #expect(identityFetches == 2)
    }

    @Test func finalOpenSecondCallWhileFirstSuspendedReturnsFalse() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        let barrier = OSAllocatedUnfairLock(initialState: false)

        let task1 = Task { @MainActor in
            await model.executeSetupFinalOpen(
                expectedInstanceID: "inst-1",
                checkAdmission: { true },
                fetchTunnelIdentity: {
                    barrier.withLock { $0 = true }
                    try? await Task.sleep(for: .milliseconds(100))
                    return .mark(JournalMark.uiTestSample, instanceID: "inst-1")
                },
                fetchDirectIdentity: {
                    .mark(JournalMark.uiTestSample, instanceID: "inst-1")
                },
                openURL: { _ in true },
                persistFinish: { model.setPhase(nil) }
            )
        }

        while !barrier.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let call2 = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { fatalError("Should not be called") },
            fetchDirectIdentity: { fatalError("Should not be called") },
            openURL: { _ in fatalError("Should not be called") },
            persistFinish: { false }
        )

        #expect(!call2)
        _ = await task1.value
    }

    @Test func finalOpenAdmissionFailsAfterTunnelFetchStopsBeforeDirectFetch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        var checkCount = 0
        var directCalled = false

        let result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: {
                checkCount += 1
                return checkCount <= 1
            },
            fetchTunnelIdentity: { .mark(JournalMark.uiTestSample, instanceID: "inst-1") },
            fetchDirectIdentity: { directCalled = true; return .mark(JournalMark.uiTestSample, instanceID: "inst-1") },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )

        #expect(!result)
        #expect(!directCalled)
        #expect(model.phase == .connection)
    }

    @Test func finalOpenAdmissionFailsAfterDirectFetchStopsBeforeOpener() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        var checkCount = 0
        var openerCalled = false

        let result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: {
                checkCount += 1
                return checkCount <= 2
            },
            fetchTunnelIdentity: { .mark(JournalMark.uiTestSample, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(JournalMark.uiTestSample, instanceID: "inst-1") },
            openURL: { _ in openerCalled = true; return true },
            persistFinish: { model.setPhase(nil) }
        )

        #expect(!result)
        #expect(!openerCalled)
        #expect(model.phase == .connection)
    }

    @Test func finalOpenDirectResultUncommittedOrDifferentMarkOrAbsentFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        let mark1 = JournalMark.uiTestSample
        let mark2 = JournalMark(icon1: mark1.icon1, icon2: mark1.icon2, words: ["different", "mark"])

        // 1. Uncommitted
        var result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark1, instanceID: "inst-1") },
            fetchDirectIdentity: { .uncommitted(instanceID: "inst-1") },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)
        #expect(model.phase == .connection)

        // 2. Different mark
        result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark1, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(mark2, instanceID: "inst-1") },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)
        #expect(model.phase == .connection)

        // 3. Absent
        result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark1, instanceID: "inst-1") },
            fetchDirectIdentity: { .absent },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)
        #expect(model.phase == .connection)
    }

    @Test func finalOpenOpenerReturnsFalseLeavesPhaseAndFlagFalse() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        let mark = JournalMark.uiTestSample
        let result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(mark, instanceID: "inst-1") },
            openURL: { _ in false },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)
        #expect(model.phase == .connection)
    }

    @Test func finalOpenSaveFailureLeavesFlagTrueAndRetriesSaveOnly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        let mark = JournalMark.uiTestSample
        var fetchCount = 0
        var openCount = 0
        var saveAllowed = false

        let result1 = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { fetchCount += 1; return .mark(mark, instanceID: "inst-1") },
            fetchDirectIdentity: { fetchCount += 1; return .mark(mark, instanceID: "inst-1") },
            openURL: { _ in openCount += 1; return true },
            persistFinish: { saveAllowed }
        )
        #expect(!result1)
        #expect(model.phase == .connection)
        #expect(fetchCount == 2)
        #expect(openCount == 1)

        saveAllowed = true
        let result2 = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            checkAdmission: { true },
            fetchTunnelIdentity: { fatalError("Should not fetch") },
            fetchDirectIdentity: { fatalError("Should not fetch") },
            openURL: { _ in fatalError("Should not open") },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(result2)
        #expect(model.phase == nil)
        #expect(fetchCount == 2)
        #expect(openCount == 1)
    }

    @Test func finalOpenOlderPeerWithoutConfirmedMarkOrMismatchedMarksFails() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.connection)

        let mark = JournalMark.uiTestSample
        let otherMark = JournalMark(icon1: mark.icon1, icon2: mark.icon2, words: ["different", "words"])

        // 1. No confirmed mark
        var result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            expectedMark: nil,
            isOlderPeer: true,
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(mark, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(mark, instanceID: "inst-1") },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)

        // 2. Fetched marks don't match confirmed mark
        result = await model.executeSetupFinalOpen(
            expectedInstanceID: "inst-1",
            expectedMark: mark,
            isOlderPeer: true,
            checkAdmission: { true },
            fetchTunnelIdentity: { .mark(otherMark, instanceID: "inst-1") },
            fetchDirectIdentity: { .mark(otherMark, instanceID: "inst-1") },
            openURL: { _ in true },
            persistFinish: { model.setPhase(nil) }
        )
        #expect(!result)
    }

    @Test func newSetupModelInitDoesNotCallOpener() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var openerCalled = false
        let appState = AppState.forSnapshot(journalURLOpener: { _ in
            openerCalled = true
            return true
        })

        _ = SetupModel(enabled: true, mailboxDirectory: dir, appState: appState)
        #expect(!openerCalled)
    }
}
