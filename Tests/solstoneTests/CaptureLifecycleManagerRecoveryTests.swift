// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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

    private func makeManager(
        scheduler: FakeRecoveryScheduler = FakeRecoveryScheduler(),
        delegate: FakeLifecycleDelegate,
        isScreenLocked: @escaping @MainActor () -> Bool = { false },
        unlockResumeDelay: @escaping @MainActor @Sendable () async throws -> Void = {},
        transitionTimeoutSeconds: TimeInterval = 30
    ) -> CaptureLifecycleManager {
        let manager = CaptureLifecycleManager(
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: isScreenLocked,
            unlockResumeDelay: unlockResumeDelay,
            transitionTimeoutSeconds: transitionTimeoutSeconds
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
    var pauseResultURL: URL?
    private(set) var resumeTriggers: [String] = []
    private(set) var events: [Event] = []
    private(set) var pauseCalls: [PauseCall] = []
    private var pauseReleased = false
    private var pauseReleaseContinuation: CheckedContinuation<Void, Never>?
    private var resumeGateArmed = false
    private var resumeReleaseContinuation: CheckedContinuation<Void, Never>?
    private var eventWaiters: [((Event) -> Bool, CheckedContinuation<Void, Never>)] = []

    init(state: CaptureManager.State, pauseResultURL: URL? = nil) {
        self.lifecycleCurrentState = state
        self.pauseResultURL = pauseResultURL
    }

    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL? {
        pauseCalls.append(PauseCall(trigger: trigger, stopAudio: stopAudio, stateLabel: lifecycleCurrentState.label))
        appendEvent(.pauseStarted(trigger))
        await waitForPauseRelease()
        lifecycleCurrentState = .paused
        appendEvent(.pauseCompleted(trigger))
        return pauseResultURL
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

    func lifecycleAbortPreparedResume(trigger: String) async {
        lifecycleCurrentState = .paused
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
