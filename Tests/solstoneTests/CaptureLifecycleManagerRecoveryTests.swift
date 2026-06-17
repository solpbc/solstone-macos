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

    private func makeManager(
        scheduler: FakeRecoveryScheduler,
        delegate: FakeLifecycleDelegate
    ) -> CaptureLifecycleManager {
        let manager = CaptureLifecycleManager(
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        manager.configure(delegate: delegate)
        return manager
    }
}

private struct SyntheticLifecycleRecoveryError: Error {}

@MainActor
private final class FakeLifecycleDelegate: CaptureLifecycleDelegate {
    enum ResumeBehavior {
        case succeed
        case fail
    }

    var lifecycleCurrentState: CaptureManager.State
    var resumeBehavior: ResumeBehavior = .succeed
    private(set) var resumeTriggers: [String] = []

    init(state: CaptureManager.State) {
        self.lifecycleCurrentState = state
    }

    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL? {
        nil
    }

    func lifecycleResumeCapture(trigger: String) async throws {
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
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {}
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
