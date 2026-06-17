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

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(1)
        delay.releaseNext()
        await Task.yield()

        #expect(!delegate.events.contains(.resumeStarted("unlock")))
        #expect(manager.hasPendingResumeTaskForTesting)

        delegate.releasePause()
        await delegate.waitForEvent(.resumeStarted("unlock"))
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

        let wakeTask = Task { @MainActor in
            await manager.handleDidWake()
        }
        await Task.yield()

        #expect(!delegate.events.contains(.resumeStarted("wake")))

        delegate.releasePause()
        await delegate.waitForEvent(.resumeStarted("wake"))
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
        await Task.yield()

        #expect(delegate.count(.pauseStarted("lock")) == 1)
        #expect(!manager.hasPendingResumeTaskForTesting)

        delay.releaseNext()
        await Task.yield()
        #expect(!delegate.events.contains(.resumeStarted("unlock")))

        await manager.handleScreenUnlocked()
        await delay.waitUntilCallCount(2)
        delay.releaseNext()
        await Task.yield()
        #expect(!delegate.events.contains(.resumeStarted("unlock")))

        delegate.releasePause()
        await delegate.waitForEvent(.resumeStarted("unlock"))
        await firstLockTask.value
        await secondLockTask.value

        #expect(delegate.count(.pauseStarted("lock")) == 1)
        #expect(delegate.count(.resumeStarted("unlock")) == 1)
        let pauseCompleted = try #require(delegate.index(of: .pauseCompleted("lock")))
        let resumeStarted = try #require(delegate.index(of: .resumeStarted("unlock")))
        #expect(pauseCompleted < resumeStarted)
        #expect(!manager.suspendedForRecovery)
    }

    @Test func pauseSettleTimeoutSkipsResumeAndReturns() async throws {
        let delegate = FakeLifecycleDelegate(state: .recording)
        let manager = makeManager(
            delegate: delegate,
            unlockResumeDelay: {},
            pauseSettleTimeoutSeconds: 0.01
        )

        let lockTask = Task { @MainActor in
            await manager.handleScreenLocked()
        }
        await delegate.waitForEvent(.pauseStarted("lock"))

        await manager.handleScreenUnlocked()
        try await waitUntilMain(timeout: .seconds(1)) {
            !manager.hasPendingResumeTaskForTesting
        }

        #expect(!delegate.events.contains(.resumeStarted("unlock")))
        #expect(manager.suspendedForRecovery)
        #expect(delegate.lifecycleCurrentState.isRecording)
        #expect(manager.hasInFlightPauseForTesting)

        delegate.releasePause()
        await lockTask.value
    }

    @Test func resetCancelsInFlightPauseAndPendingResume() async throws {
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

        #expect(manager.hasPendingResumeTaskForTesting)
        #expect(manager.hasInFlightPauseForTesting)

        manager.reset(stopRecovery: true)

        #expect(!manager.suspendedForRecovery)
        #expect(!manager.hasPendingResumeTaskForTesting)
        #expect(!manager.hasInFlightPauseForTesting)

        delay.releaseNext()
        delegate.releasePause()
        await lockTask.value
        await Task.yield()

        #expect(!delegate.events.contains(.resumeStarted("unlock")))
    }

    private func makeManager(
        scheduler: FakeRecoveryScheduler = FakeRecoveryScheduler(),
        delegate: FakeLifecycleDelegate,
        isScreenLocked: @escaping @MainActor () -> Bool = { false },
        unlockResumeDelay: @escaping @MainActor @Sendable () async throws -> Void = {},
        pauseSettleTimeoutSeconds: TimeInterval = 30
    ) -> CaptureLifecycleManager {
        let manager = CaptureLifecycleManager(
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: isScreenLocked,
            unlockResumeDelay: unlockResumeDelay,
            pauseSettleTimeoutSeconds: pauseSettleTimeoutSeconds
        )
        manager.configure(delegate: delegate)
        return manager
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
        case transitionToError(String)
        case processSegment(String, Bool)
    }

    var lifecycleCurrentState: CaptureManager.State
    var resumeBehavior: ResumeBehavior = .succeed
    var pauseResultURL: URL?
    private(set) var resumeTriggers: [String] = []
    private(set) var events: [Event] = []
    private var pauseReleased = false
    private var pauseReleaseContinuation: CheckedContinuation<Void, Never>?
    private var eventWaiters: [((Event) -> Bool, CheckedContinuation<Void, Never>)] = []

    init(state: CaptureManager.State, pauseResultURL: URL? = nil) {
        self.lifecycleCurrentState = state
        self.pauseResultURL = pauseResultURL
    }

    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL? {
        appendEvent(.pauseStarted(trigger))
        await waitForPauseRelease()
        lifecycleCurrentState = .paused
        appendEvent(.pauseCompleted(trigger))
        return pauseResultURL
    }

    func lifecycleResumeCapture(trigger: String) async throws {
        appendEvent(.resumeStarted(trigger))
        resumeTriggers.append(trigger)
        switch resumeBehavior {
        case .succeed:
            lifecycleCurrentState = .recording
        case .fail:
            throw SyntheticLifecycleRecoveryError()
        }
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
