// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import AppKit
import Testing
@testable import solstone

@MainActor
@Suite("CaptureLifecycleManager recovery")
struct CaptureLifecycleManagerRecoveryTests {
    @Test func recoveryDelayUsesInitialBackoffThenFallback() {
        #expect(CaptureLifecycleManager.recoveryDelay(forRetryCount: 0) == 5)
        #expect(CaptureLifecycleManager.recoveryDelay(forRetryCount: 1) == 30)
        #expect(CaptureLifecycleManager.recoveryDelay(forRetryCount: 2) == 60)
        #expect(CaptureLifecycleManager.recoveryDelay(forRetryCount: 3) == 300)
        #expect(CaptureLifecycleManager.recoveryDelay(forRetryCount: 20) == 300)
    }

    @Test func displayChangeAttemptsRecoveryImmediatelyAndResetsBackoff() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)
        #expect(scheduler.scheduledDelays == [5])

        delegate.resumeBehavior = .succeed
        await manager.noteDisplayChange()

        #expect(scheduler.invalidatedCount == 1)
        #expect(delegate.resumeTriggers == ["recovery"])
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(manager.retryCountForTesting == 0)
    }

    @Test func displayChangeRearmsRecoveryAfterMaxRetryGiveUp() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        delegate.resumeBehavior = .fail
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)

        for _ in 0..<20 {
            await scheduler.fireNext()
        }

        #expect(delegate.resumeTriggers.count == 20)
        #expect(!scheduler.hasActiveToken)
        #expect(manager.retryCountForTesting == 20)

        delegate.lifecycleCurrentState = .error("all displays disconnected")
        delegate.resumeBehavior = .succeed

        await manager.noteDisplayChange()

        #expect(delegate.resumeTriggers.count == 21)
        #expect(delegate.resumeTriggers.last == "recovery")
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(manager.retryCountForTesting == 0)
    }

    @Test func resetStopRecoveryCancelsScheduledRecovery() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)
        #expect(scheduler.hasActiveToken)

        manager.reset(stopRecovery: true)

        #expect(scheduler.invalidatedCount == 1)
        #expect(manager.retryCountForTesting == 0)

        await scheduler.fireNext()

        #expect(delegate.resumeTriggers.isEmpty)
    }

    @Test func noDisplayRecoveryDoesNotSetSuspendedForRecoveryOrDoubleResume() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)

        #expect(!manager.suspendedForRecovery)

        delegate.resumeBehavior = .succeed
        await manager.noteDisplayChange()

        #expect(!manager.suspendedForRecovery)
        #expect(delegate.resumeTriggers == ["recovery"])
    }

    @Test func screenUnlockWaitsForLockPauseToSettleBeforeResume() async throws {
        let delay = GatedUnlockResumeDelay()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(
            delegate: delegate,
            unlockResumeDelay: { try await delay.wait() }
        )

        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        await delegate.waitForEvent(.pauseStarted("lock"))
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(manager.inFlightIntentForTesting == IntentSnapshot(kind: .pause(.lock), stopAudio: true))

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(1)
        delay.releaseNext()
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .resume(.unlock), stopAudio: false))
        }

        #expect(!delegate.events.contains(.resumeStarted("unlock")))

        delegate.releasePause()
        await delegate.waitForEvent(.resumeCompleted("unlock"))
        try await waitUntilMain(timeout: .seconds(5)) {
            !manager.suspendedForRecovery
        }
        await lockTask.value

        let pauseCompleted = try #require(delegate.index(of: .pauseCompleted("lock")))
        let resumeStarted = try #require(delegate.index(of: .resumeStarted("unlock")))
        #expect(pauseCompleted < resumeStarted)
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func didWakeWaitsForSleepPauseToSettleBeforeResume() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate)

        let sleepTask = Task { @MainActor in
            await manager.handleWillSleep()
        }
        await delegate.waitForEvent(.pauseStarted("sleep"))
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(manager.inFlightIntentForTesting == IntentSnapshot(kind: .pause(.sleep), stopAudio: false))

        let wakeTask = Task { @MainActor in
            await manager.handleDidWake()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .resume(.wake), stopAudio: false))
        }

        #expect(!delegate.events.contains(.resumeStarted("wake")))

        delegate.releasePause()
        await delegate.waitForEvent(.resumeCompleted("wake"))
        await sleepTask.value
        await wakeTask.value

        let pauseCompleted = try #require(delegate.index(of: .pauseCompleted("sleep")))
        let resumeStarted = try #require(delegate.index(of: .resumeStarted("wake")))
        #expect(pauseCompleted < resumeStarted)
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func willSleepNotificationDeliveredThroughInjectedWorkspaceCenter() async {
        let center = NotificationCenter()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, workspaceCenter: center)

        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)

        await delegate.waitForEvent(.pauseStarted("sleep"))
        delegate.releasePause()
        await delegate.waitForEvent(.pauseCompleted("sleep"))
        withExtendedLifetime(manager) {}
    }

    @Test func didWakeNotificationDeliveredThroughInjectedWorkspaceCenter() async {
        let center = NotificationCenter()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, workspaceCenter: center)

        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        await delegate.waitForEvent(.pauseStarted("sleep"))
        delegate.releasePause()
        await delegate.waitForEvent(.pauseCompleted("sleep"))
        #expect(manager.suspendedForRecovery)

        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        await delegate.waitForEvent(.resumeStarted("wake"))
        await delegate.waitForEvent(.resumeCompleted("wake"))
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func sleepWakeObserversIgnoreDefaultCenter() async throws {
        let center = NotificationCenter()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, workspaceCenter: center)

        NotificationCenter.default.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!delegate.events.contains(.pauseStarted("sleep")))

        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        await delegate.waitForEvent(.pauseStarted("sleep"))
        delegate.releasePause()
        await delegate.waitForEvent(.pauseCompleted("sleep"))
        withExtendedLifetime(manager) {}
    }

    @Test func rapidRelockCancelsDebouncedUnlockAndCoalescesPause() async throws {
        let delay = GatedUnlockResumeDelay()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(
            delegate: delegate,
            unlockResumeDelay: { try await delay.wait() }
        )

        let firstLockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        await delegate.waitForEvent(.pauseStarted("lock"))

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(1)

        let secondLockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
        }
        #expect(!manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .resume(.unlock), stopAudio: false)))

        delay.releaseNext()
        await Task.yield()
        #expect(!delegate.events.contains(.resumeStarted("unlock")))

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(2)
        delay.releaseNext()
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .resume(.unlock), stopAudio: false))
        }
        #expect(!delegate.events.contains(.resumeStarted("unlock")))

        delegate.releasePause()
        await delegate.waitForEvent(.resumeCompleted("unlock"))
        try await waitUntilMain(timeout: .seconds(5)) {
            !manager.suspendedForRecovery
        }
        await firstLockTask.value
        await secondLockTask.value

        #expect(delegate.pauseCalls.contains { $0.trigger == "lock" && $0.stopAudio && $0.stateLabel == "paused" })
        #expect(delegate.count(.resumeStarted("unlock")) == 1)
        let pauseCompleted = try #require(delegate.index(of: .pauseCompleted("lock")))
        let resumeStarted = try #require(delegate.index(of: .resumeStarted("unlock")))
        #expect(pauseCompleted < resumeStarted)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func resetClearsQueuedAndInFlightTransitions() async throws {
        let delay = GatedUnlockResumeDelay()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(
            delegate: delegate,
            unlockResumeDelay: { try await delay.wait() }
        )

        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        await delegate.waitForEvent(.pauseStarted("lock"))

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(1)
        delay.releaseNext()
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentCountForTesting == 1
        }

        manager.reset(stopRecovery: true)

        #expect(!manager.suspendedForRecovery)
        #expect(manager.queuedIntentCountForTesting == 0)

        delegate.releasePause()
        await lockTask.value
        await Task.yield()

        #expect(!delegate.events.contains(.resumeStarted("unlock")))
    }

    @Test func screenLockDuringInFlightResumeVetoesCommit() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, unlockResumeDelay: {})
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.armResumeGate()
        await manager.handleScreenUnlocked()
        await delegate.waitForEvent(.resumeStarted("unlock"))
        #expect(manager.inFlightIntentForTesting == IntentSnapshot(kind: .resume(.unlock), stopAudio: false))

        let relockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
        }
        delegate.releaseResume()
        await delegate.waitForEvent(.resumeAborted("unlock"))
        await relockTask.value

        #expect(!delegate.events.contains(.resumeCompleted("unlock")))
        #expect(delegate.lifecycleCurrentState.isPaused)
        #expect(manager.suspendedForRecovery)
        #expect(manager.lastVetoReasonForTesting == .queuedPause)
    }

    @Test func willSleepDuringInFlightResumeVetoesCommit() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, unlockResumeDelay: {})
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.armResumeGate()
        await manager.handleScreenUnlocked()
        await delegate.waitForEvent(.resumeStarted("unlock"))
        #expect(manager.inFlightIntentForTesting == IntentSnapshot(kind: .resume(.unlock), stopAudio: false))

        let sleepTask = Task { @MainActor in
            await manager.handleWillSleep()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.sleep), stopAudio: false))
        }
        delegate.releaseResume()
        await delegate.waitForEvent(.resumeAborted("unlock"))
        await sleepTask.value

        #expect(!delegate.events.contains(.resumeCompleted("unlock")))
        #expect(delegate.lifecycleCurrentState.isPaused)
        #expect(manager.suspendedForRecovery)
        #expect(manager.lastVetoReasonForTesting == .queuedPause)
    }

    @Test func resumeThrowDuringLockSettlesToErrorWithoutPauseOverwrite() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, unlockResumeDelay: {})
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.resumePrepareShouldThrow = true
        delegate.armResumeGate()
        await manager.handleScreenUnlocked()
        await delegate.waitForEvent(.resumeStarted("unlock"))

        let relockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
        }
        delegate.releaseResume()
        await delegate.waitForEvent(.transitionToError("unlock_failed"))
        await relockTask.value

        #expect(delegate.lifecycleCurrentState.isError)
        #expect(!delegate.events.contains(.resumeCompleted("unlock")))
        #expect(!delegate.events.contains(.resumeAborted("unlock")))
        #expect(delegate.count(.pauseStarted("lock")) == 1)
    }

    @Test func lockDuringRecoveryResumeUsesLiveLockVeto() async throws {
        let locked = LockedValue<Bool>()
        locked.set(true)
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        let manager = makeManager(
            delegate: delegate,
            isScreenLocked: { locked.current ?? false }
        )

        delegate.armResumeGate()
        let recoveryTask = Task { @MainActor in
            await manager.attemptRecovery()
        }
        await delegate.waitForEvent(.resumeStarted("recovery"))

        delegate.releaseResume()
        await delegate.waitForEvent(.resumeAborted("recovery"))
        await recoveryTask.value

        #expect(delegate.lifecycleCurrentState.isPaused)
        #expect(manager.suspendedForRecovery)
        #expect(manager.retryCountForTesting == 0)
        #expect(!delegate.events.contains(.resumeCompleted("recovery")))
        #expect(manager.lastVetoReasonForTesting == .screenLocked)
    }

    @Test func recoveryDoubleCommitProducesSingleCommit() async {
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        let manager = makeManager(delegate: delegate)

        delegate.armResumeGate()
        let first = Task { @MainActor in
            await manager.attemptRecovery()
        }
        await delegate.waitForEvent(.resumeStarted("recovery"))

        let second = Task { @MainActor in
            await manager.attemptRecovery()
        }
        try? await Task.sleep(for: .milliseconds(20))

        delegate.releaseResume()
        await first.value
        await second.value

        #expect(delegate.count(.resumeCompleted("recovery")) == 1)
        #expect(delegate.lifecycleCurrentState.isRecording)
    }

    @Test func stopAudioUpgradeStopsAudioAfterQueueDrain() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate)

        let sleepTask = Task { @MainActor in
            await manager.handleWillSleep()
        }
        await delegate.waitForEvent(.pauseStarted("sleep"))

        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
        }

        delegate.releasePause()
        try await waitUntilMain(timeout: .seconds(5)) {
            delegate.pauseCalls.contains { $0.trigger == "lock" && $0.stopAudio && $0.stateLabel == "paused" }
        }
        await sleepTask.value
        await lockTask.value

        #expect(delegate.pauseCalls.contains { $0.trigger == "lock" && $0.stopAudio && $0.stateLabel == "paused" })
        #expect(delegate.lifecycleCurrentState.isPaused)
    }

    @Test func unlockDuringUserPauseClearsEnvironmentalReasonOnly() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, unlockResumeDelay: {})
        delegate.releasePause()

        let userPause = await manager.enqueue(.pause(reason: .user, stopAudio: true))
        guard case .committed = userPause else {
            Issue.record("expected user pause to commit")
            return
        }

        await manager.handleScreenLocked()
        #expect(delegate.lifecycleCurrentState.pausedReasons == [.user, .lock])

        await manager.handleScreenUnlocked()
        try await waitUntilMain(timeout: .seconds(5)) {
            delegate.lifecycleCurrentState.pausedReasons == [.user]
        }

        #expect(!delegate.events.contains(.resumeStarted("unlock")))
        #expect(manager.suspendedForRecovery)

        let userResume = await manager.enqueue(.resume(reason: .user))
        guard case .committed = userResume else {
            Issue.record("expected user resume to commit")
            return
        }

        #expect(delegate.events.contains(.resumeCompleted("user")))
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func environmentalClearRoundTripsCompositeReasons() async throws {
        let sleepThenLock = FakeLifecycleDelegate(state: .recording)
        let sleepThenLockManager = makeManager(delegate: sleepThenLock, unlockResumeDelay: {})
        sleepThenLock.releasePause()

        await sleepThenLockManager.handleWillSleep()
        await sleepThenLockManager.handleScreenLocked()
        #expect(sleepThenLock.lifecycleCurrentState.pausedReasons == [.sleep, .lock])

        await sleepThenLockManager.handleScreenUnlocked()
        await sleepThenLock.waitForEvent(.resumeCompleted("unlock"))
        #expect(sleepThenLock.lifecycleCurrentState.isRecording)
        #expect(!sleepThenLockManager.suspendedForRecovery)

        let userThenSleep = FakeLifecycleDelegate(state: .recording)
        let userThenSleepManager = makeManager(delegate: userThenSleep)
        userThenSleep.releasePause()

        _ = await userThenSleepManager.enqueue(.pause(reason: .user, stopAudio: true))
        await userThenSleepManager.handleWillSleep()
        #expect(userThenSleep.lifecycleCurrentState.pausedReasons == [.user, .sleep])

        await userThenSleepManager.handleDidWake()
        try await waitUntilMain(timeout: .seconds(5)) {
            userThenSleep.lifecycleCurrentState.pausedReasons == [.user]
        }
        #expect(!userThenSleep.events.contains(.resumeStarted("wake")))
        #expect(userThenSleepManager.suspendedForRecovery)

        let lockThenSleep = FakeLifecycleDelegate(state: .recording)
        let lockThenSleepManager = makeManager(delegate: lockThenSleep, unlockResumeDelay: {})
        lockThenSleep.releasePause()

        await lockThenSleepManager.handleScreenLocked()
        await lockThenSleepManager.handleWillSleep()
        #expect(lockThenSleep.lifecycleCurrentState.pausedReasons == [.lock, .sleep])

        await lockThenSleepManager.handleScreenUnlocked()
        await lockThenSleep.waitForEvent(.resumeCompleted("unlock"))
        #expect(lockThenSleep.lifecycleCurrentState.isRecording)
        #expect(!lockThenSleepManager.suspendedForRecovery)
    }

    @Test func abortedResumeRestoresPreRemovalReasons() async {
        let locked = LockedValue<Bool>()
        locked.set(false)
        let delegate = FakeLifecycleDelegate(state: .paused(reasons: [.lock]))
        let executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { locked.current ?? false },
            unlockResumeDelay: {}
        )
        executor.markSuspendedForRecovery()
        delegate.armResumeGate()

        let resumeTask = Task { @MainActor in
            await executor.enqueue(.resume(reason: .unlock))
        }
        await delegate.waitForEvent(.resumeStarted("unlock"))

        locked.set(true)
        delegate.releaseResume()

        let outcome = await resumeTask.value
        guard case .vetoed = outcome else {
            Issue.record("expected unlock resume to be vetoed")
            return
        }

        #expect(delegate.events.contains(.resumeAborted("unlock")))
        #expect(delegate.lifecycleCurrentState.pausedReasons == [.lock])
        #expect(delegate.lifecycleCurrentState.pausedReasons.isEmpty == false)
    }

    @Test func lockThenUnlockDuringResumeSettlesToRecording() async throws {
        let locked = LockedValue<Bool>()
        locked.set(false)
        let delay = GatedUnlockResumeDelay()
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(
            delegate: delegate,
            isScreenLocked: { locked.current ?? false },
            unlockResumeDelay: { try await delay.wait() }
        )
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.armResumeGate()
        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(1)
        delay.releaseNext()
        await delegate.waitForEvent(.resumeStarted("unlock"))

        locked.set(true)
        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
        }

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(2)

        delegate.releaseResume()
        await delegate.waitForEvent(.resumeAborted("unlock"))
        try await waitUntilMain(timeout: .seconds(5)) {
            delegate.count(.pauseCompleted("lock")) >= 2
        }
        #expect(!delegate.events.contains(.resumeCompleted("unlock")))

        locked.set(false)
        delay.releaseNext()
        await delegate.waitForEvent(.resumeCompleted("unlock"))
        await lockTask.value

        #expect(delegate.count(.resumeAborted("unlock")) == 1)
        #expect(delegate.count(.resumeCompleted("unlock")) == 1)
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func resetDuringResumeAbortsInFlightAndNeverCommits() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate)
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.armResumeGate()
        let wakeTask = Task { @MainActor in
            await manager.handleDidWake()
        }
        await delegate.waitForEvent(.resumeStarted("wake"))
        #expect(manager.inFlightIntentForTesting == IntentSnapshot(kind: .resume(.wake), stopAudio: false))

        manager.reset(stopRecovery: true)
        delegate.releaseResume()
        await delegate.waitForEvent(.resumeAborted("wake"))
        await wakeTask.value

        #expect(!delegate.events.contains(.resumeCompleted("wake")))
        #expect(delegate.events.contains(.resumeAborted("wake")))
        #expect(manager.queuedIntentCountForTesting == 0)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func hungResumeAbortsAndQueuedPauseRunsToCompletion() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(delegate: delegate, transitionTimeoutSeconds: 0.2)
        await pauseForLock(manager: manager, delegate: delegate)

        delegate.armResumeGate()
        let wakeTask = Task { @MainActor in
            await manager.handleDidWake()
        }
        await delegate.waitForEvent(.resumeStarted("wake"))

        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }

        try await waitUntilMain(timeout: .seconds(5)) {
            delegate.events.contains(.resumeAborted("wake"))
                && delegate.count(.pauseCompleted("lock")) >= 2
        }
        await wakeTask.value
        await lockTask.value

        #expect(manager.lastVetoReasonForTesting == .timedOut)
        #expect(delegate.events.contains(.resumeAborted("wake")))
        #expect(delegate.count(.pauseCompleted("lock")) >= 2)
        #expect(delegate.lifecycleCurrentState.isPaused)
    }

    @Test func entryPreconditionDropsQueuedPauseOnIdleAndResumeOnNonPaused() async {
        let delegate = FakeLifecycleDelegate(state: .idle)
        let executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        delegate.releasePause()
        let pauseOutcome = await executor.enqueue(.pause(reason: .lock, stopAudio: true))
        guard case .dropped = pauseOutcome else {
            Issue.record("expected pause on idle to drop")
            return
        }
        #expect(!delegate.events.contains(.pauseStarted("lock")))
        #expect(executor.queuedIntentCountForTesting == 0)

        delegate.lifecycleCurrentState = .recording
        let resumeOutcome = await executor.enqueue(.resume(reason: .wake))
        guard case .dropped = resumeOutcome else {
            Issue.record("expected resume on non-paused state to drop")
            return
        }
        #expect(!delegate.events.contains(.resumeStarted("wake")))
        #expect(executor.queuedIntentCountForTesting == 0)
    }

    @Test func startFailureReturnsThrownWithoutTransitioningToError() async {
        let delegate = FakeLifecycleDelegate(state: .idle)
        delegate.startFailure = TransitionFailure(message: "start failed", isPermissionError: false)
        let executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let outcome = await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .threw(let failure) = outcome else {
            Issue.record("expected start failure to return .threw")
            return
        }
        #expect(failure.message == "start failed")
        #expect(delegate.lifecycleCurrentState.isIdle)
        #expect(!delegate.events.contains(.transitionToError("user_failed")))
    }

    @Test func startFromErrorResetsThenCommitsWithoutIdleCommit() async {
        let delegate = FakeLifecycleDelegate(state: .error("permission denied"))
        let executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let outcome = await executor.enqueue(.start(reason: .autoStart, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .committed = outcome else {
            Issue.record("expected start from error to commit")
            return
        }
        #expect(delegate.events == [
            .resetForRestartFromError,
            .startStarted("autoStart"),
            .startCompleted("autoStart")
        ])
        #expect(delegate.lifecycleCurrentState.isRecording)
    }

    @Test func startFromErrorFailureRearmsRecoveryForTransientError() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("transient"))
        delegate.startFailure = TransitionFailure(message: "start failed", isPermissionError: false)
        let manager = makeManager(scheduler: scheduler, delegate: delegate)
        delegate.onStartFromErrorFailed = { failure in
            manager.noteStartFromErrorFailed(isPermissionError: failure.isPermissionError)
        }

        let outcome = await manager.enqueue(.start(reason: .autoStart, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .threw(let failure) = outcome else {
            Issue.record("expected start from error failure to throw")
            return
        }
        #expect(failure.message == "start failed")
        #expect(scheduler.scheduledDelays == [5])
        #expect(manager.isRecoveryScheduled)
        #expect(manager.retryCountForTesting == 0)
        #expect(delegate.startFromErrorFailurePermissionFlags == [false])
    }

    @Test func startFromErrorPermissionFailureDefersToPermissionPoll() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("permission denied"))
        delegate.startFailure = TransitionFailure(message: "permission denied", isPermissionError: true)
        let manager = makeManager(scheduler: scheduler, delegate: delegate)
        delegate.onStartFromErrorFailed = { failure in
            manager.noteStartFromErrorFailed(isPermissionError: failure.isPermissionError)
        }

        let outcome = await manager.enqueue(.start(reason: .autoStart, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .threw(let failure) = outcome else {
            Issue.record("expected permission start failure to throw")
            return
        }
        #expect(failure.isPermissionError)
        #expect(scheduler.scheduledDelays.isEmpty)
        #expect(!manager.isRecoveryScheduled)
        #expect(delegate.startFromErrorFailurePermissionFlags == [true])
    }

    @Test func exhaustedRecoveryStillAcceptsExplicitStartFromError() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        delegate.resumeBehavior = .fail
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)
        for _ in 0..<20 {
            await scheduler.fireNext()
        }
        #expect(manager.retryCountForTesting == 20)
        #expect(!manager.isRecoveryScheduled)

        delegate.startFailure = nil
        let outcome = await manager.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .committed = outcome else {
            Issue.record("expected explicit start after exhaustion to commit")
            return
        }
        #expect(delegate.events.contains(.resetForRestartFromError))
        #expect(delegate.lifecycleCurrentState.isRecording)
    }

    @Test func startFromErrorTransientFailureAfterExhaustionRearmsFreshLadder() async {
        let scheduler = FakeRecoveryScheduler()
        let delegate = FakeLifecycleDelegate(state: .error("all displays disconnected"))
        delegate.resumeBehavior = .fail
        let manager = makeManager(scheduler: scheduler, delegate: delegate)

        manager.startRecoveryIfNeeded(error: CaptureManager.CaptureError.noDisplaysAvailable)
        for _ in 0..<20 {
            await scheduler.fireNext()
        }
        #expect(manager.retryCountForTesting == 20)
        #expect(!manager.isRecoveryScheduled)

        delegate.startFailure = TransitionFailure(message: "new transient", isPermissionError: false)
        delegate.onStartFromErrorFailed = { failure in
            manager.noteStartFromErrorFailed(isPermissionError: failure.isPermissionError)
        }
        let outcome = await manager.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .threw(let failure) = outcome else {
            Issue.record("expected explicit start failure after exhaustion to throw")
            return
        }
        #expect(failure.message == "new transient")
        #expect(manager.retryCountForTesting == 0)
        #expect(manager.isRecoveryScheduled)
        #expect(scheduler.scheduledDelays.last == 5)
    }

    @Test func rotateTimeoutAndFailureReturnThrownOutcome() async {
        let timeoutDelegate = FakeLifecycleDelegate(state: .recording)
        timeoutDelegate.rotationResult = .timedOut
        let timeoutExecutor = CaptureExecutor(
            delegate: timeoutDelegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let timeoutOutcome = await timeoutExecutor.enqueue(.rotate(reason: .boundary))

        guard case .threw(let timeoutFailure) = timeoutOutcome else {
            Issue.record("expected timed-out rotate to throw")
            return
        }
        #expect(timeoutFailure.message == "Segment rotation timed out")
        #expect(!timeoutFailure.isPermissionError)

        let failure = TransitionFailure(message: "rotate failed", isPermissionError: false)
        let failedDelegate = FakeLifecycleDelegate(state: .recording)
        failedDelegate.rotationResult = .failed(failure)
        let failedExecutor = CaptureExecutor(
            delegate: failedDelegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let failedOutcome = await failedExecutor.enqueue(.rotate(reason: .boundary))

        guard case .threw(let returnedFailure) = failedOutcome else {
            Issue.record("expected failed rotate to throw")
            return
        }
        #expect(returnedFailure.message == "rotate failed")
        #expect(!returnedFailure.isPermissionError)
    }

    @Test func startFromPausedClearsSuspendedSoLaterUnlockResumeDrops() async {
        let delegate = FakeLifecycleDelegate(state: .paused(reasons: [.lock]))
        var executor: CaptureExecutor!
        executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        delegate.onStart = {
            executor.resetLifecyclePendingState()
        }
        executor.markSuspendedForRecovery()

        let startOutcome = await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = startOutcome else {
            Issue.record("expected start from paused to commit")
            return
        }
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(!executor.suspendedForRecovery)

        let resumeOutcome = await executor.enqueue(.resume(reason: .unlock))
        guard case .dropped = resumeOutcome else {
            Issue.record("expected unlock resume to drop after start cleared suspension")
            return
        }
        #expect(!delegate.events.contains(.resumeStarted("unlock")))
    }

    @Test func resetLifecyclePendingStateDuringStartKeepsQueuedStop() async throws {
        let delegate = FakeLifecycleDelegate(state: .idle)
        delegate.armStartGate()
        var executor: CaptureExecutor!
        executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        delegate.onStart = {
            executor.resetLifecyclePendingState()
        }

        let startTask = Task { @MainActor in
            await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))
        }
        await delegate.waitForEvent(.startStarted("user"))

        let stopTask = Task { @MainActor in
            await executor.enqueue(.stop(reason: .user))
        }
        try await waitUntilMain(timeout: .seconds(5)) {
            executor.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .stop(.user), stopAudio: false))
        }

        delegate.releaseStart()
        let startOutcome = await startTask.value
        let stopOutcome = await stopTask.value

        guard case .committed = startOutcome else {
            Issue.record("expected start to commit")
            return
        }
        guard case .committed = stopOutcome else {
            Issue.record("expected queued stop to survive start reset")
            return
        }
        #expect(delegate.events.contains(.stopCompleted("user")))
        #expect(delegate.lifecycleCurrentState.isIdle)
    }

    @Test func stopResetClearsSuspendedSoLaterUnlockResumeDrops() async {
        let delegate = FakeLifecycleDelegate(state: .recording)
        var executor: CaptureExecutor!
        executor = CaptureExecutor(
            delegate: delegate,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        delegate.onStop = {
            executor.resetLifecyclePendingState()
        }
        executor.markSuspendedForRecovery()

        let stopOutcome = await executor.enqueue(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop to commit")
            return
        }
        #expect(delegate.lifecycleCurrentState.isIdle)
        #expect(!executor.suspendedForRecovery)

        let resumeOutcome = await executor.enqueue(.resume(reason: .unlock))
        guard case .dropped = resumeOutcome else {
            Issue.record("expected unlock resume to drop after stop cleared suspension")
            return
        }
        #expect(!delegate.events.contains(.resumeStarted("unlock")))
    }

    private func makeManager(
        scheduler: FakeRecoveryScheduler = FakeRecoveryScheduler(),
        delegate: FakeLifecycleDelegate,
        isScreenLocked: @escaping @MainActor () -> Bool = { false },
        unlockResumeDelay: @escaping @MainActor @Sendable () async throws -> Void = {},
        transitionTimeoutSeconds: TimeInterval = 30,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) -> CaptureLifecycleManager {
        let manager = CaptureLifecycleManager(
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: isScreenLocked,
            unlockResumeDelay: unlockResumeDelay,
            transitionTimeoutSeconds: transitionTimeoutSeconds,
            workspaceCenter: workspaceCenter
        )
        manager.configure(delegate: delegate)
        return manager
    }

    private func pauseForLock(manager: CaptureLifecycleManager, delegate: FakeLifecycleDelegate) async {
        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        await delegate.waitForEvent(.pauseStarted("lock"))
        delegate.releasePause()
        await lockTask.value
    }

    private func waitUntilMain(
        timeout: Duration,
        poll: Duration = .milliseconds(10),
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: poll)
        }
        #expect(predicate())
    }
}

private struct SyntheticLifecycleRecoveryError: Error {}

@MainActor
private final class FakeLifecycleDelegate: CaptureLifecycleDelegate {
    enum ResumeBehavior {
        case succeed
        case fail
    }

    enum Event: Equatable {
        case startStarted(String)
        case startCompleted(String)
        case resetForRestartFromError
        case stopStarted(String)
        case stopCompleted(String)
        case rotateStarted(String)
        case pauseStarted(String)
        case pauseCompleted(String)
        case resumeStarted(String)
        case resumeCompleted(String)
        case resumeAborted(String)
        case transitionToError(String)
        case processSegment(String, Bool)
    }

    struct PauseCall: Equatable {
        let trigger: String
        let stopAudio: Bool
        let stateLabel: String
    }

    var lifecycleCurrentState: CaptureManager.State
    var resumeBehavior: ResumeBehavior = .succeed
    var resumePrepareShouldThrow = false
    var startFailure: TransitionFailure?
    var startResult: StartResult = .committed
    var rotationResult: RotationResult = .committed
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onStartFromErrorFailed: ((TransitionFailure) -> Void)?
    var pauseResultURL: URL?
    private(set) var resumeTriggers: [String] = []
    private(set) var events: [Event] = []
    private(set) var pauseCalls: [PauseCall] = []
    private(set) var startFromErrorFailurePermissionFlags: [Bool] = []
    private var startGateArmed = false
    private var startReleaseContinuation: CheckedContinuation<Void, Never>?
    private var pauseReleased = false
    private var pauseReleaseContinuation: CheckedContinuation<Void, Never>?
    private var resumeGateArmed = false
    private var resumeReleaseContinuation: CheckedContinuation<Void, Never>?
    private var eventWaiters: [((Event) -> Bool, CheckedContinuation<Void, Never>)] = []

    init(state: CaptureManager.State, pauseResultURL: URL? = nil) {
        self.lifecycleCurrentState = state
        self.pauseResultURL = pauseResultURL
    }

    func lifecycleStartCapture(
        reason: StartReason,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async throws -> StartResult {
        appendEvent(.startStarted(reason.trigger))
        await waitForStartRelease()
        if let startFailure {
            throw startFailure
        }
        onStart?()
        switch startResult {
        case .committed:
            lifecycleCurrentState = .recording
            appendEvent(.startCompleted(reason.trigger))
        case .vetoedScreenLocked:
            appendEvent(.startCompleted(reason.trigger))
        }
        return startResult
    }

    func lifecycleResetForRestartFromError() async {
        appendEvent(.resetForRestartFromError)
    }

    func lifecycleStartFromErrorFailed(_ failure: TransitionFailure) {
        startFromErrorFailurePermissionFlags.append(failure.isPermissionError)
        onStartFromErrorFailed?(failure)
    }

    func lifecycleStopCapture(reason: StopReason) async {
        appendEvent(.stopStarted(reason.trigger))
        onStop?()
        lifecycleCurrentState = .idle
        appendEvent(.stopCompleted(reason.trigger))
    }

    func lifecycleRotateSegment(
        reason: RotateReason,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async -> RotationResult {
        appendEvent(.rotateStarted(reason.trigger))
        return rotationResult
    }

    func lifecyclePauseCapture(reason: PauseReason, stopAudio: Bool) async -> URL? {
        pauseCalls.append(PauseCall(trigger: reason.trigger, stopAudio: stopAudio, stateLabel: lifecycleCurrentState.label))
        appendEvent(.pauseStarted(reason.trigger))
        await waitForPauseRelease()
        lifecycleCurrentState = .paused(reasons: lifecycleCurrentState.pausedReasons.union([reason]))
        appendEvent(.pauseCompleted(reason.trigger))
        return pauseResultURL
    }

    func lifecycleApplyResumeReason(_ reason: ResumeReason) -> ResumeResolution {
        let current = lifecycleCurrentState.pausedReasons
        let remaining = current.subtracting(reason.clearsPauseReasons)
        if remaining.isEmpty {
            return .readyToResume(restore: current)
        }
        lifecycleCurrentState = .paused(reasons: remaining)
        return .stayedPaused
    }

    func lifecyclePrepareResume(trigger: String) async throws {
        appendEvent(.resumeStarted(trigger))
        resumeTriggers.append(trigger)
        await waitForResumeRelease()
        if resumePrepareShouldThrow {
            throw SyntheticLifecycleRecoveryError()
        }
        switch resumeBehavior {
        case .succeed:
            return
        case .fail:
            throw SyntheticLifecycleRecoveryError()
        }
    }

    func lifecycleCommitResume(trigger: String) {
        lifecycleCurrentState = .recording
        appendEvent(.resumeCompleted(trigger))
    }

    func lifecycleAbortPreparedResume(restore: Set<PauseReason>?, trigger: String) async {
        let reasons = restore?.isEmpty == false ? restore! : Set<PauseReason>([.lock])
        lifecycleCurrentState = .paused(reasons: reasons)
        appendEvent(.resumeAborted(trigger))
    }

    func lifecycleTransitionToError(message: String, error: Error, trigger: String) {
        lifecycleCurrentState = .error(message)
        appendEvent(.transitionToError(trigger))
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {
        appendEvent(.processSegment(url.lastPathComponent, useSleepActivity))
    }

    func releasePause() {
        pauseReleased = true
        let continuation = pauseReleaseContinuation
        pauseReleaseContinuation = nil
        continuation?.resume()
    }

    func armStartGate() {
        startGateArmed = true
    }

    func releaseStart() {
        startGateArmed = false
        let continuation = startReleaseContinuation
        startReleaseContinuation = nil
        continuation?.resume()
    }

    func armResumeGate() {
        resumeGateArmed = true
    }

    func releaseResume() {
        resumeGateArmed = false
        let continuation = resumeReleaseContinuation
        resumeReleaseContinuation = nil
        continuation?.resume()
    }

    func waitForEvent(_ expected: Event) async {
        await waitForEvent { $0 == expected }
    }

    func waitForEvent(where predicate: @escaping (Event) -> Bool) async {
        if events.contains(where: predicate) {
            return
        }

        await withCheckedContinuation { continuation in
            eventWaiters.append((predicate, continuation))
        }
    }

    func count(_ event: Event) -> Int {
        events.filter { $0 == event }.count
    }

    func index(of event: Event) -> Int? {
        events.firstIndex(of: event)
    }

    private func waitForPauseRelease() async {
        if pauseReleased {
            return
        }

        await withCheckedContinuation { continuation in
            pauseReleaseContinuation = continuation
        }
    }

    private func waitForStartRelease() async {
        if !startGateArmed {
            return
        }

        await withCheckedContinuation { continuation in
            startReleaseContinuation = continuation
        }
    }

    private func waitForResumeRelease() async {
        if !resumeGateArmed {
            return
        }

        await withCheckedContinuation { continuation in
            resumeReleaseContinuation = continuation
        }
    }

    private func appendEvent(_ event: Event) {
        events.append(event)

        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [((Event) -> Bool, CheckedContinuation<Void, Never>)] = []
        for waiter in eventWaiters {
            if waiter.0(event) {
                ready.append(waiter.1)
            } else {
                pending.append(waiter)
            }
        }
        eventWaiters = pending

        for continuation in ready {
            continuation.resume()
        }
    }
}

@MainActor
private final class GatedUnlockResumeDelay {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var callCount = 0

    func wait() async throws {
        callCount += 1
        resumeCallCountWaiters()
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !continuations.isEmpty else {
            Issue.record("expected a pending unlock resume delay")
            return
        }
        continuations.removeFirst().resume()
    }

    func waitUntilCallCount(_ target: Int) async {
        if callCount >= target {
            return
        }

        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    private func resumeCallCountWaiters() {
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if callCount >= waiter.0 {
                ready.append(waiter.1)
            } else {
                pending.append(waiter)
            }
        }
        callCountWaiters = pending

        for continuation in ready {
            continuation.resume()
        }
    }
}

@MainActor
private final class FakeRecoveryScheduler {
    private(set) var scheduledDelays: [TimeInterval] = []
    private(set) var invalidatedCount = 0
    private var activeToken: FakeRecoveryTimerToken?

    var hasActiveToken: Bool {
        guard let activeToken else { return false }
        return !activeToken.isInvalidated
    }

    func schedule(
        delay: TimeInterval,
        fire: @escaping @MainActor @Sendable () async -> Void
    ) -> any RecoveryTimerToken {
        let token = FakeRecoveryTimerToken(
            fire: fire,
            onInvalidate: { [weak self] in
                self?.invalidatedCount += 1
            }
        )
        scheduledDelays.append(delay)
        activeToken = token
        return token
    }

    func fireNext() async {
        guard let token = activeToken else { return }
        activeToken = nil
        await token.fireIfValid()
    }
}

@MainActor
private final class FakeRecoveryTimerToken: RecoveryTimerToken {
    private let fire: @MainActor @Sendable () async -> Void
    private let onInvalidate: @MainActor () -> Void
    private(set) var isInvalidated = false

    init(
        fire: @escaping @MainActor @Sendable () async -> Void,
        onInvalidate: @escaping @MainActor () -> Void
    ) {
        self.fire = fire
        self.onInvalidate = onInvalidate
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        onInvalidate()
    }

    func fireIfValid() async {
        guard !isInvalidated else { return }
        await fire()
    }
}
