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
    var installedChecks = 0

    func installedURL() -> URL? {
        installedChecks += 1
        return installed
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
    var variants: [JournalAppTrustVariant] = []

    func verifyJournalApp(at url: URL, variant: JournalAppTrustVariant) async throws {
        variants.append(variant)
    }
}

@MainActor
private final class CountingFailingAppcastClient: AppcastClient {
    var calls = 0

    func fetchAppcast(from url: URL) async throws -> Data {
        calls += 1
        throw JournalHandoffFailure.appcastUnavailable("fixture")
    }
}

@MainActor
private final class GatedAppcastClient: AppcastClient {
    let gate: OneShotContinuationGate
    let counter: LockedCounter

    init(gate: OneShotContinuationGate, counter: LockedCounter = LockedCounter()) {
        self.gate = gate
        self.counter = counter
    }

    func fetchAppcast(from url: URL) async throws -> Data {
        counter.increment()
        await gate.wait()
        throw JournalHandoffFailure.appcastUnavailable("fixture")
    }
}

@MainActor
private final class AssertingDownloader: DMGDownloader {
    func downloadDMG(from url: URL, expectedLength: Int64, maxBytes: Int64) async throws -> URL {
        Issue.record("downloader must not be called")
        throw JournalHandoffFailure.cancelled
    }
}

@MainActor
private final class AssertingMounter: DiskImageMounter {
    func mount(dmgURL: URL) async throws -> MountedDiskImage {
        Issue.record("mounter must not be called")
        throw JournalHandoffFailure.mountFailed("fixture")
    }

    func detach(_ image: MountedDiskImage) async {
        Issue.record("mounter detach must not be called")
    }
}

@MainActor
private final class AssertingTrustVerifier: TrustVerifier {
    var variants: [JournalAppTrustVariant] = []

    func verifyJournalApp(at url: URL, variant: JournalAppTrustVariant) async throws {
        variants.append(variant)
        Issue.record("acquirer trust verifier must not be called")
        throw JournalHandoffFailure.trustFailed("fixture")
    }
}

@MainActor
private final class ThrowingCountingTrustVerifier: TrustVerifier {
    var calls = 0
    var variants: [JournalAppTrustVariant] = []

    func verifyJournalApp(at url: URL, variant: JournalAppTrustVariant) async throws {
        calls += 1
        variants.append(variant)
        struct VerifyError: Error {}
        throw VerifyError()
    }
}

@MainActor
private final class GatedCountingTrustVerifier: TrustVerifier {
    let gate: OneShotContinuationGate
    let entered = LockedCounter()

    init(gate: OneShotContinuationGate) {
        self.gate = gate
    }

    var variants: [JournalAppTrustVariant] = []

    func verifyJournalApp(at url: URL, variant: JournalAppTrustVariant) async throws {
        variants.append(variant)
        entered.increment()
        await gate.wait()
    }
}

@MainActor
private final class CallCounter: @unchecked Sendable {
    var count = 0
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

    @Test(arguments: [true, false])
    func step5AcceptanceAndDelayedJournalResolutionHaveOnePublicationOrder(acceptBeforeResolution: Bool) async throws {
        let dir = try makeTempDir()
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        }
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let mailbox = SetupMailboxStore(directory: dir)
        let model = SetupModel(enabled: true, continuationStore: store, mailboxDirectory: dir,
            freshFlow: FreshJournalFlow(dependencies: .inert(), resolveTrustedJournalOverride: {
                entered.increment()
                await gate.wait()
                return bundle
            }), resolveIdentity: { _, _ in .absent }, sleepDuration: .milliseconds(20))
        defer { model.stopSupportingTasks(); model.stopJournalPolling() }
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false), setupModel: model,
            sameMachinePairStart: { _, _ in .failure(.init(kind: .transport)) },
            triggerTunnelConnectedSync: { _ in }, journalURLOpener: { _ in false })
        state.configSaver = { _ in Issue.record("handoff changed source preferences") }
        let resolution = Task { await model.runJournalPhase() }
        defer { resolution.cancel() }
        try await waitUntil { entered.count == 1 }
        if !acceptBeforeResolution {
            gate.release()
            try await waitUntil { if case .ready = mailbox.loadStep1() { return true }; return false }
            #expect(try mailbox.readStep5Receipt() == nil)
        }
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5, journalRootPath: "/fixture/journal",
            expectedInstanceID: "fixture-instance", expectedCAFingerprint: sampleFingerprint)
        try mailbox.writeStep5(handoff)
        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(try mailbox.readStep5Receipt()?.handoffID == handoff.handoffID)
        if acceptBeforeResolution { gate.release() }
        await resolution.value
        if acceptBeforeResolution {
            #expect(mailbox.loadStep1() == .missing)
            #expect(store.load()?.pendingOutboundStep1ID == nil)
        } else {
            guard case .ready(let published) = mailbox.loadStep1() else {
                Issue.record("the already-published input must survive")
                return
            }
            #expect(published.handoffID == store.load()?.pendingOutboundStep1ID)
        }
        #expect(!state.config.isScreenCaptureEnabled)
        #expect(!state.config.isMicrophoneCaptureEnabled)
    }


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

    /// A journal mid-first-run answers the identity route with a 302 to its setup page (its
    /// session gate). Walked on minnie, 2026-10-20: the journal step read "couldn't reach your
    /// journal" for the whole of Journal.app's setup and was still showing it under macOS's
    /// local-network prompt after the hand-back. Both journal kinds; a real failure still shows.
    @Test(arguments: [["setup-sequence-v1"], nil] as [[String]?])
    func aJournalStillInItsFirstRunReadsAsBeingSetUpNotUnreachable(capabilities: [String]?) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try createMockBundle(capabilities: capabilities)
        let controller = TestRunningJournalController()
        controller.installed = bundle
        let freshFlow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies(
                runningJournal: controller,
                trustVerifier: TestTrustVerifier()
            )
        )
        let resolution = OSAllocatedUnfairLock(initialState: JournalIdentityResolution.failed(.httpStatus(302)))
        let polls = LockedCounter()
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: freshFlow,
            resolveIdentity: { _, _ in
                polls.increment()
                return resolution.withLock { $0 }
            },
            sleepDuration: .milliseconds(10)
        )

        _ = model.setPhase(.journal)
        try await waitUntil { polls.count >= 3 }
        #expect(model.journalPollingText == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP)
        #expect(model.journalPollingError == nil)

        resolution.withLock { $0 = .failed(.httpStatus(500)) }
        try await waitUntil { model.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL }
        #expect(model.journalPollingText == nil)

        resolution.withLock { $0 = .failed(.httpStatus(302)) }
        try await waitUntil { model.journalPollingError == nil }
        #expect(model.journalPollingText == UICopy.SETUP_JOURNAL_STILL_BEING_SET_UP)

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
        #expect(try SetupMailboxStore(directory: dir).readStep5Refusal() == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("solstone-setup-handoff.json").path))
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
        #expect(try SetupMailboxStore(directory: dir).readStep5Refusal()?.handoffID == handoff.handoffID)
        #expect(model.handoffRefusal == .heldPairing)
        #expect(model.acknowledgementError == nil)
        model.dismissHandoffRefusal()
        #expect(model.handoffRefusal == nil)
    }

    @Test(arguments: [false, true])
    func competingAndUnreadableContinuationPreserveExistingState(corrupt: Bool) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = SetupModel(enabled: true, mailboxDirectory: dir)
        _ = model.setPhase(.microphone)
        let continuationURL = dir.appendingPathComponent("solstone-setup-continuation.json")
        if corrupt { try Data("broken".utf8).write(to: continuationURL) }
        let before = try Data(contentsOf: continuationURL)
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5, journalRootPath: "/test/root",
            expectedInstanceID: "new-home", expectedCAFingerprint: sampleFingerprint)
        let payloadURL = dir.appendingPathComponent("solstone-setup-handoff.json")
        try JSONEncoder().encode(handoff).write(to: payloadURL)
        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(try Data(contentsOf: continuationURL) == before)
        let refusal = try SetupMailboxStore(directory: dir).readStep5Refusal()
        #expect(refusal?.reason == (corrupt ? nil : .continuationInProgress))
        #expect((model.acknowledgementError != nil) == corrupt)
        #expect(FileManager.default.fileExists(atPath: payloadURL.path) == corrupt)
    }

    @Test func heldPairingAtNilPhaseOpensNoticeWithoutChangingContinuation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState.forSnapshot(initialTunnelPairing: pairing())
        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: state)
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .openSettingsWindow, object: nil, queue: nil) { _ in
            requests.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let handoff = SetupHandoff(handoffID: UUID(), stepIndex: 5, journalRootPath: "/test/root",
            expectedInstanceID: "new-home", expectedCAFingerprint: sampleFingerprint)
        try JSONEncoder().encode(handoff).write(to: dir.appendingPathComponent("solstone-setup-handoff.json"))
        model.ingestStep5IfNeeded()
        #expect(model.phase == nil)
        #expect(model.handoffRefusal == .heldPairing)
        #expect(requests.withLock { $0 } > 0)
        #expect(model.continuation?.accepted == nil)
    }

    @Test func unreadablePairingBlocksNewDecisionButCanRepublishRecordedRefusal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState.forSnapshot(pairingLoad: { throw CocoaError(.fileReadUnknown) })
        #expect(state.tunnelLifecycleOwner.sameMachineStoredPairingState == .unavailable)
        let model = SetupModel(enabled: true, mailboxDirectory: dir, appState: state)
        let id = UUID()
        let handoff = SetupHandoff(handoffID: id, stepIndex: 5, journalRootPath: "/test/root",
            expectedInstanceID: "new-home", expectedCAFingerprint: sampleFingerprint)
        let payload = dir.appendingPathComponent("solstone-setup-handoff.json")
        try JSONEncoder().encode(handoff).write(to: payload)
        model.ingestStep5IfNeeded()
        let store = SetupMailboxStore(directory: dir)
        #expect(try store.readStep5Refusal() == nil)
        #expect(model.acknowledgementError != nil)
        #expect(FileManager.default.fileExists(atPath: payload.path))
        _ = try store.commitStep5(loadedID: id, alreadyAccepted: false, pairingBlocksNewAcceptance: true,
            refusalReason: .heldPairing, storeProgress: {})
        try FileManager.default.removeItem(at: dir.appendingPathComponent("solstone-setup-handoff-refused.json"))
        try JSONEncoder().encode(handoff).write(to: payload)
        model.ingestStep5IfNeeded()
        #expect(try store.readStep5Refusal()?.handoffID == id)
        #expect(model.handoffRefusal == .heldPairing)
        #expect(model.acknowledgementError == nil)
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
        try store.save(SetupContinuation(phase: .screen, accepted: SetupAcceptedStep5Snapshot(
            handoffID: UUID(), journalRootPath: "/fixture/journal",
            expectedInstanceID: retained.instanceID, expectedCAFingerprint: fingerprint
        ), mode: .supporting))
        let downloadReads = LockedCounter()
        let downloadValue = SetupDownloads(
            speech: .init(state: .downloading, attemptID: "speech", bytesDone: 10, bytesTotal: 100, error: nil),
            thinking: .init(state: .downloading, attemptID: "thinking", bytesDone: 20, bytesTotal: nil, error: nil)
        )
        let downloadProgress = SetupDownloadProgress(
            read: { _ in downloadReads.increment(); return downloadValue },
            sleep: { try await Task.sleep(for: .milliseconds(20)) }
        )
        let model = SetupModel(enabled: true, mailboxDirectory: dir, downloadProgress: downloadProgress)
        defer { model.stopSupportingTasks() }
        let fetched = LockedArray<String>([])
        let identityGate = OneShotContinuationGate()
        defer { identityGate.release(); transport.releasePendingConnect() }
        let pairStarts = LockedCounter()
        let state = AppState.forSnapshot(
            config: AppConfig(isScreenCaptureEnabled: false, isMicrophoneCaptureEnabled: false, serverURL: "http://127.0.0.1:18321"),
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
            #expect(model.phase == .screen)
            try await waitUntil { model.downloadProgress.downloads == downloadValue }
            #expect(downloadReads.count >= 1)
            #expect(model.downloadProgress.downloads == downloadValue)
            #expect(model.setPhase(.connection))
            #expect(model.downloadProgress.downloads == downloadValue)
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
        modelExact.stopJournalPolling()
        modelExact.retryJournalPhase()
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        try await waitUntil { runnerExact.launched && FileManager.default.fileExists(atPath: step1File.path) }
        modelExact.stopJournalPolling()

        #expect(!modelExact.isPeerSupportingSetup)
        #expect(runnerExact.launched)
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
        modelSuperset.stopJournalPolling()
        modelSuperset.retryJournalPhase()
        try await waitUntil { runnerSuperset.launched && FileManager.default.fileExists(atPath: step1File.path) }
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
        modelAcq.stopJournalPolling()
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
        modelLaunch.stopJournalPolling()
        await modelLaunch.runJournalPhase()
        #expect(modelLaunch.phase == SetupPhase.journal)
        #expect(modelLaunch.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)
        #expect(!modelLaunch.journalPollingOffersJournalAppDownload)
    }

    @Test func journalPhaseUnwritableApplicationsDirectorySurfacesInstallError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(),
            resolveTrustedJournalOverride: { throw JournalHandoffFailure.applicationsDirectoryUnwritable }
        )
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        _ = model.setPhase(.journal)
        model.stopJournalPolling()
        await model.runJournalPhase()
        #expect(model.phase == SetupPhase.journal)
        #expect(model.journalPollingError == UICopy.SETUP_COULDNT_INSTALL_JOURNAL_APP)
        #expect(model.journalPollingError != UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)
        #expect(model.journalPollingOffersJournalAppDownload)
    }

    @Test func journalPhaseRunningJournalWouldNotQuitSurfacesOwnerMessage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let failure = JournalHandoffFailure.runningJournalWouldNotQuit
        let flow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(),
            resolveTrustedJournalOverride: { throw failure }
        )
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        _ = model.setPhase(.journal)
        model.stopJournalPolling()
        await model.runJournalPhase()
        #expect(model.phase == SetupPhase.journal)
        #expect(model.journalPollingError == failure.ownerMessage)
    }

    @Test func journalPhaseApplicationsDirectoryUnavailableSurfacesGenericError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(),
            resolveTrustedJournalOverride: { throw JournalHandoffFailure.applicationsDirectoryUnavailable }
        )
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        _ = model.setPhase(.journal)
        model.stopJournalPolling()
        await model.runJournalPhase()
        #expect(model.phase == SetupPhase.journal)
        #expect(model.journalPollingError == UICopy.SETUP_COULDNT_REACH_YOUR_JOURNAL)
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

    @Test func automaticJournalPhaseDoesNotAcquireWithoutExplicitAction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = TestRunningJournalController()
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        _ = model.setPhase(.journal)

        try await waitUntil { controller.installedChecks > 0 }

        #expect(appcastClient.calls == 0)
        #expect(controller.launchCount == 0)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(!FileManager.default.fileExists(atPath: step1File.path))
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == nil)
        #expect(model.phase == .journal)
    }

    private final class UnwritableFileManager: FileManager, @unchecked Sendable {
        override func isWritableFile(atPath path: String) -> Bool {
            false
        }
    }

    @Test func acquirePreflightUnwritableApplicationsDirectoryFailsBeforeDownload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = TestRunningJournalController()
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: UnwritableFileManager(),
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )

        await #expect(throws: JournalHandoffFailure.applicationsDirectoryUnwritable) {
            _ = try await acquirer.acquire { _ in }
        }
        #expect(appcastClient.calls == 0)
    }

    @Test func explicitJournalPhaseAcquiresAndRetriesOnFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = TestRunningJournalController()
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        _ = model.setPhase(.journal)
        model.stopJournalPolling()

        await model.runJournalPhase()
        #expect(appcastClient.calls == 1)
        #expect(model.phase == .journal)
        #expect(model.journalPollingError != nil)
        #expect(controller.launchCount == 0)

        model.retryJournalPhase()
        try await waitUntil { appcastClient.calls == 2 }
        #expect(model.phase == .journal)
        #expect(model.journalPollingError != nil)
        #expect(controller.launchCount == 0)
    }

    @Test func explicitJournalPhaseAcquiringReflectsAcquirePhaseInStatus() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = TestRunningJournalController()
        let gate = OneShotContinuationGate()
        let counter = LockedCounter()
        let appcastClient = GatedAppcastClient(gate: gate, counter: counter)
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer {
            gate.release()
            model.stopJournalPolling()
        }

        _ = model.setPhase(.journal)
        model.stopJournalPolling()

        let task = Task {
            await model.runJournalPhase()
        }

        try await waitUntil { counter.count == 1 }

        #expect(model.freshFlow.state == .acquiring(.fetchingAppcast))
        #expect(
            SetupJournalStatus.caption(
                flowState: model.freshFlow.state,
                journalPollingText: model.journalPollingText
            ) == model.freshFlow.state.ownerStatusMessage
        )

        gate.release()
        await task.value
    }

    @Test func automaticJournalPhaseLaunchesTrustedInstalledBundleWithoutAcquiring() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let controller = TestRunningJournalController()
        controller.installed = bundle
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        _ = model.setPhase(.journal)

        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        try await waitUntil { controller.launchCount == 1 && FileManager.default.fileExists(atPath: step1File.path) }
        #expect(appcastClient.calls == 0)
        model.stopJournalPolling()
    }

    @Test func automaticJournalPhaseLaunchReflectsOpeningYourJournalCaption() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: nil)
        defer {
            try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        }

        let controller = TestRunningJournalController()
        controller.installed = bundle
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))

        let gate = OneShotContinuationGate()
        let counter = LockedCounter()
        defer {
            gate.release()
        }

        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            freshFlow: flow,
            resolveIdentity: { _, _ in
                counter.increment()
                await gate.wait()
                return .absent
            },
            sleepDuration: .milliseconds(10)
        )
        defer { model.stopJournalPolling() }

        _ = model.setPhase(.journal)

        try await waitUntil { controller.launchCount == 1 && flow.state == .waitingForJournal }

        let caption = SetupJournalStatus.caption(
            flowState: model.freshFlow.state,
            journalPollingText: model.journalPollingText
        )
        #expect(caption == UICopy.SETUP_OPENING_YOUR_JOURNAL)
        #expect(appcastClient.calls == 0)

        gate.release()
        model.stopJournalPolling()
    }

    @Test func installedURLWithThrowingVerifierDoesNotAcquireOrLaunch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let controller = TestRunningJournalController()
        controller.installed = bundle
        let verifier = ThrowingCountingTrustVerifier()
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: verifier
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        _ = model.setPhase(.journal)

        try await waitUntil { verifier.calls > 0 }
        #expect(appcastClient.calls == 0)
        #expect(controller.launchCount == 0)
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == nil)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(!FileManager.default.fileExists(atPath: step1File.path))
    }

    @Test func holdBeforeAutomaticStartSuppressesLaunchUntilResumed() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let controller = TestRunningJournalController()
        controller.installed = bundle
        let appcastClient = CountingFailingAppcastClient()
        let acquirer = JournalAppAcquirer(
            appcastFeedResolver: { JournalHandoffFeedSelection(url: JournalHandoffConstants.appcastURL, feed: .production) },
            appcastClient: appcastClient,
            downloader: AssertingDownloader(),
            mounter: AssertingMounter(),
            trustVerifier: AssertingTrustVerifier(),
            publicEDKeyBase64: "",
            maxDMGBytes: 100,
            applicationsURL: dir,
            fileManager: .default,
            runningJournal: controller,
            runningTerminationTimeout: .seconds(1),
            runningTerminationPollInterval: .milliseconds(10)
        )
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: acquirer,
            runningJournal: controller,
            trustVerifier: TestTrustVerifier()
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        model.setJournalPairingLinkHeld(true)
        _ = model.setPhase(.journal)

        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.launchCount == 0)
        #expect(!FileManager.default.fileExists(atPath: step1File.path))
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == nil)
        #expect(appcastClient.calls == 0)

        model.setJournalPairingLinkHeld(false)
        model.startJournalPhase()
        try await waitUntil { controller.launchCount == 1 && FileManager.default.fileExists(atPath: step1File.path) }
        model.stopJournalPolling()

        // Separately: switchToOwnerComparison(), setJournalPairingLinkHeld(false), startJournalPhase() does not launch
        model.switchToOwnerComparison()
        model.setJournalPairingLinkHeld(false)
        model.startJournalPhase()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.launchCount == 1)
        #expect(appcastClient.calls == 0)
    }

    @Test func linkDuringAutomaticVerifyAbortsStep1AndLaunch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let controller = TestRunningJournalController()
        controller.installed = bundle
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let verifier = GatedCountingTrustVerifier(gate: gate)
        let flow = FreshJournalFlow(dependencies: FreshJournalFlowDependencies(
            acquirer: nil,
            runningJournal: controller,
            trustVerifier: verifier
        ))
        let model = SetupModel(enabled: true, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }
        _ = model.setPhase(.journal)

        try await waitUntil { verifier.entered.count > 0 }
        model.setJournalPairingLinkHeld(true)
        gate.release()

        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.launchCount == 0)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(!FileManager.default.fileExists(atPath: step1File.path))
        #expect(model.journalPollingText == nil)
        #expect(model.journalPollingError == nil)
    }

    @Test func linkDuringExplicitResolveAbortsStep1AndLaunch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try createMockBundle(capabilities: ["setup-sequence-v1"])
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let entered = LockedCounter()
        let controller = TestRunningJournalController()
        let flow = FreshJournalFlow(
            dependencies: FreshJournalFlowDependencies.inert(runningJournal: controller),
            resolveTrustedJournalOverride: {
                entered.increment()
                await gate.wait()
                return bundle
            }
        )
        let model = SetupModel(enabled: true, continuationStore: store, mailboxDirectory: dir, freshFlow: flow)
        defer { model.stopJournalPolling() }

        model.retryJournalPhase()
        try await waitUntil { entered.count > 0 }
        model.setJournalPairingLinkHeld(true)
        gate.release()

        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.launchCount == 0)
        let step1File = dir.appendingPathComponent("journal-setup-handoff.json")
        #expect(!FileManager.default.fileExists(atPath: step1File.path))
    }

    @Test func ingestStep5MovesPhaseToMicrophoneAndBringsSolstoneToFrontOnce() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )
        let handoffID = UUID()
        try model.mailboxStore.writeStep5(SetupHandoff(
            handoffID: handoffID,
            stepIndex: 5,
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        ))
        #expect(model.phase == .journal)
        #expect(counter.count == 0)

        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(counter.count == 1)

        // Second ingest of that same handoff does not run it again
        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(counter.count == 1)
    }

    @Test func ingestStep5RetainingJournalPhaseDoesNotBringSolstoneToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )
        #expect(model.phase == .journal)

        // No handoff written
        model.ingestStep5IfNeeded()
        #expect(model.phase == .journal)
        #expect(counter.count == 0)
    }

    @Test func competingStep5PreservesMicrophonePhaseAndBringsRefusalToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )

        // setPhase(.microphone) does not run it
        _ = model.setPhase(.microphone)
        #expect(model.phase == .microphone)
        #expect(counter.count == 0)

        // A competing handoff now brings its terminal refusal to the owner.
        let handoffID = UUID()
        try model.mailboxStore.writeStep5(SetupHandoff(
            handoffID: handoffID,
            stepIndex: 5,
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        ))
        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(counter.count == 1)
        #expect(model.handoffRefusal == .continuationInProgress)
        #expect(try model.mailboxStore.readStep5Refusal()?.handoffID == handoffID)
    }

    @Test func continueFromOlderJournalDoesNotBringSolstoneToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )
        _ = model.setPhase(.journal)
        #expect(model.phase == .journal)

        model.continueFromOlderJournal()
        #expect(model.phase == .journal)
        #expect(counter.count == 0)
    }

    @Test func microphonePhaseTransitionsDoNotBringSolstoneToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )

        _ = model.setPhase(.microphone)
        #expect(model.phase == .microphone)
        #expect(counter.count == 0)

        model.continueFromMicrophone()
        #expect(model.phase == .screen)
        #expect(counter.count == 0)

        _ = model.setPhase(.microphone)
        #expect(model.phase == .microphone)
        _ = model.notNowMicrophone()
        #expect(model.phase == .screen)
        #expect(counter.count == 0)
    }

    @Test func disabledSetupModelIngestDoesNotBringSolstoneToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = CallCounter()
        let model = SetupModel(
            enabled: false,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )
        let handoffID = UUID()
        try model.mailboxStore.writeStep5(SetupHandoff(
            handoffID: handoffID,
            stepIndex: 5,
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        ))

        model.ingestStep5IfNeeded()
        #expect(model.phase == nil)
        #expect(counter.count == 0)
    }

    @Test func supportingHandoffBringsSolstoneToFrontWhenConnectionSettles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            requestMicrophone: {},
            requestScreen: {},
            bringSolstoneToFront: { counter.count += 1 }
        )
        defer { model.stopSupportingTasks() }
        let state = AppState.forSnapshot(
            setupModel: model,
            sameMachinePairStart: { _, _ in .failure(SameMachinePairStartFailure(kind: .transport)) },
            triggerTunnelConnectedSync: { _ in },
            journalURLOpener: { _ in false }
        )
        model.attach(state)

        let handoffID = UUID()
        try model.mailboxStore.writeStep5(SetupHandoff(
            handoffID: handoffID,
            stepIndex: 5,
            journalRootPath: "/fixture/journal",
            expectedInstanceID: "inst-1",
            expectedCAFingerprint: sampleFingerprint
        ))

        model.ingestStep5IfNeeded()
        #expect(model.phase == .microphone)
        #expect(model.connectionStepState == .connecting)
        #expect(counter.count == 1)

        try await waitUntil {
            model.connectionStepState == .failed(UICopy.SETUP_COULDNT_VERIFY_MARK)
        }
        #expect(model.connectionStepState == .failed(UICopy.SETUP_COULDNT_VERIFY_MARK))
        #expect(counter.count == 2)

        model.retryConnection()
        #expect(model.connectionStepState == .connecting)
        #expect(counter.count == 2)
        try await waitUntil {
            model.connectionStepState == .failed(UICopy.SETUP_COULDNT_VERIFY_MARK)
        }
        #expect(counter.count == 2)

        model.handleTunnelConnected()
        #expect(model.connectionStepState == .connecting)
        #expect(counter.count == 2)
        try await waitUntil {
            model.connectionStepState == .failed(UICopy.SETUP_COULDNT_VERIFY_MARK)
        }
        #expect(counter.count == 2)
    }

    @Test func switchToOwnerComparisonAloneDoesNotBringSolstoneToFront() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            bringSolstoneToFront: { counter.count += 1 }
        )
        #expect(model.switchToOwnerComparison())
        #expect(counter.count == 0)
        #expect(model.continuation?.mode == .ownerComparison)
    }

    @Test func failingPairingOperationLeavesSeamCountZeroOnSubmitAndLaterTunnelConnected() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            bringSolstoneToFront: { counter.count += 1 }
        )
        struct InjectedPairError: Error {}
        let state = AppState.forSnapshot(
            setupModel: model,
            triggerTunnelConnectedSync: { _ in },
            journalURLOpener: { _ in false },
            pairingOperation: { _, _, _ in throw InjectedPairError() }
        )
        model.attach(state)

        let link = "solstone://pair#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
        let outcome = await state.submitPairingInput(link)
        #expect(counter.count == 0)
        if case .failed = outcome {
            // expected
        } else {
            Issue.record("Expected .failed state")
        }
        #expect(state.pairingCoordinator.state == outcome)

        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 1, via: TunnelConnectionRoute.lan))
        #expect(counter.count == 0)
    }

    @Test func successfulPairingSubmitBringsSolstoneToFrontOnTunnelConnectedOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let pairingStore = InMemoryPairingStore()
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            bringSolstoneToFront: { counter.count += 1 }
        )
        let state = AppState.forSnapshot(
            setupModel: model,
            triggerTunnelConnectedSync: { _ in },
            journalURLOpener: { _ in false },
            pairingStoring: pairingStore,
            pairingOperation: { _, _, _ in pairing() },
            pairingSave: { try pairingStore.save($0) }
        )
        model.attach(state)

        let link = "solstone://pair#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
        let outcome = await state.submitPairingInput(link)
        #expect(counter.count == 0)
        #expect(outcome == PairingFlowState.paired)
        #expect(state.pairingCoordinator.state == PairingFlowState.paired)
        #expect(model.continuation?.mode == .ownerComparison)

        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 1, via: TunnelConnectionRoute.lan))
        #expect(counter.count == 1)

        model.handleTunnelConnected()
        #expect(counter.count == 1)

        state.handleTunnelLifecycleState(TunnelLifecycleState.disconnected)
        #expect(counter.count == 1)

        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 1, via: TunnelConnectionRoute.lan))
        #expect(counter.count == 1)
    }

    @Test func successfulPairingSubmitBringsSolstoneToFrontOnTunnelErrorOnce() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SetupContinuationStore(directory: dir)
        try store.save(SetupContinuation(phase: .journal))
        let pairingStore = InMemoryPairingStore()
        let counter = CallCounter()
        let model = SetupModel(
            enabled: true,
            continuationStore: store,
            mailboxDirectory: dir,
            bringSolstoneToFront: { counter.count += 1 }
        )
        let state = AppState.forSnapshot(
            setupModel: model,
            triggerTunnelConnectedSync: { _ in },
            journalURLOpener: { _ in false },
            pairingStoring: pairingStore,
            pairingOperation: { _, _, _ in pairing() },
            pairingSave: { try pairingStore.save($0) }
        )
        model.attach(state)

        let link = "solstone://pair#0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
        let outcome = await state.submitPairingInput(link)
        #expect(counter.count == 0)
        #expect(outcome == PairingFlowState.paired)

        state.handleTunnelLifecycleState(TunnelLifecycleState.error(TunnelLifecycleError.notEntitled))
        #expect(counter.count == 1)

        state.handleTunnelLifecycleState(TunnelLifecycleState.connected(localPort: 1, via: TunnelConnectionRoute.lan))
        #expect(counter.count == 1)
    }
}
