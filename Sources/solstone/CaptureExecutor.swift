// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

enum PauseReason: Sendable, Equatable {
    case sleep
    case lock

    var trigger: String {
        switch self {
        case .sleep: "sleep"
        case .lock: "lock"
        }
    }
}

enum ResumeReason: Sendable, Equatable {
    case wake
    case unlock
    case recovery

    var trigger: String {
        switch self {
        case .wake: "wake"
        case .unlock: "unlock"
        case .recovery: "recovery"
        }
    }
}

enum CaptureIntent: Sendable, Equatable {
    case pause(reason: PauseReason, stopAudio: Bool)
    case resume(reason: ResumeReason)

    var kind: IntentKind {
        switch self {
        case .pause(let reason, _):
            .pause(reason)
        case .resume(let reason):
            .resume(reason)
        }
    }

    var isResume: Bool {
        if case .resume = self { return true }
        return false
    }

    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }

    var snapshot: IntentSnapshot {
        switch self {
        case .pause(let reason, let stopAudio):
            IntentSnapshot(kind: .pause(reason), stopAudio: stopAudio)
        case .resume(let reason):
            IntentSnapshot(kind: .resume(reason), stopAudio: false)
        }
    }

    var logDescription: String {
        switch self {
        case .pause(let reason, let stopAudio):
            "pause(\(reason.trigger), stopAudio:\(stopAudio))"
        case .resume(let reason):
            "resume(\(reason.trigger))"
        }
    }

    func hasSameKindAndReason(as other: CaptureIntent) -> Bool {
        switch (self, other) {
        case (.pause(let lhs, _), .pause(let rhs, _)):
            lhs == rhs
        case (.resume(let lhs), .resume(let rhs)):
            lhs == rhs
        default:
            false
        }
    }

    mutating func mergeSameKindAndReason(with other: CaptureIntent) {
        guard hasSameKindAndReason(as: other) else { return }
        if case .pause(let reason, let stopAudio) = self,
           case .pause(_, let otherStopAudio) = other {
            self = .pause(reason: reason, stopAudio: stopAudio || otherStopAudio)
        }
    }
}

enum TransitionOutcome: Sendable {
    case committed
    case vetoed
    case threw(ResumeFailure)
    case dropped
}

enum VetoReason: Sendable, Equatable {
    case queuedPause
    case screenLocked
    case stateChanged
    case notSuspended
    case timedOut
    case reset
    case aborted
}

struct ResumeFailure: Sendable {
    let message: String
    let isPermissionError: Bool
}

enum IntentKind: Sendable, Equatable {
    case pause(PauseReason)
    case resume(ResumeReason)
}

struct IntentSnapshot: Sendable, Equatable {
    let kind: IntentKind
    let stopAudio: Bool
}

@MainActor
final class CaptureExecutor {
    private struct QueuedIntent {
        var intent: CaptureIntent
        var waiters: [CheckedContinuation<TransitionOutcome, Never>]
    }

    weak var delegate: (any CaptureLifecycleDelegate)?

    private var queue: [QueuedIntent] = []
    private var inFlight: (snapshot: IntentSnapshot, task: Task<TransitionOutcome, Never>)?
    private var isPumping = false
    private var delayedUnlockTask: Task<Void, Never>?
    private let isScreenLocked: @MainActor () -> Bool
    private let unlockResumeDelay: @MainActor @Sendable () async throws -> Void
    private let preResumeSettle: @MainActor () async -> Void
    private let transitionTimeoutSeconds: TimeInterval
    private(set) var suspendedForRecovery = false
    private(set) var lastVetoReason: VetoReason?

    init(
        delegate: (any CaptureLifecycleDelegate)? = nil,
        isScreenLocked: @escaping @MainActor () -> Bool,
        unlockResumeDelay: @escaping @MainActor @Sendable () async throws -> Void,
        preResumeSettle: @escaping @MainActor () async -> Void = {},
        transitionTimeoutSeconds: TimeInterval = 30
    ) {
        self.delegate = delegate
        self.isScreenLocked = isScreenLocked
        self.unlockResumeDelay = unlockResumeDelay
        self.preResumeSettle = preResumeSettle
        self.transitionTimeoutSeconds = transitionTimeoutSeconds
    }

    internal var queuedIntentSnapshotForTesting: [IntentSnapshot] {
        queue.map(\.intent.snapshot)
    }

    internal var queuedIntentCountForTesting: Int {
        queue.count
    }

    internal var inFlightIntentForTesting: IntentSnapshot? {
        guard let inFlight else { return nil }
        return inFlight.snapshot
    }

    internal var lastVetoReasonForTesting: VetoReason? {
        lastVetoReason
    }

    func markSuspendedForRecovery() {
        suspendedForRecovery = true
    }

    @discardableResult
    func enqueue(_ intent: CaptureIntent) async -> TransitionOutcome {
        await withCheckedContinuation { continuation in
            enqueue(intent, continuation: continuation)
        }
    }

    func scheduleUnlockResume() {
        delayedUnlockTask?.cancel()
        delayedUnlockTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.unlockResumeDelay()
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.delayedUnlockTask = nil
            _ = await self.enqueue(.resume(reason: .unlock))
        }
    }

    func reset() {
        delayedUnlockTask?.cancel()
        delayedUnlockTask = nil
        for entry in queue {
            resume(entry.waiters, with: .dropped)
        }
        queue.removeAll()
        inFlight?.task.cancel()
        suspendedForRecovery = false
    }

    private func enqueue(
        _ intent: CaptureIntent,
        continuation: CheckedContinuation<TransitionOutcome, Never>
    ) {
        if intent.isPause {
            delayedUnlockTask?.cancel()
            delayedUnlockTask = nil
            dropQueuedResumes()
        }

        if let lastIndex = queue.indices.last,
           queue[lastIndex].intent.hasSameKindAndReason(as: intent) {
            queue[lastIndex].intent.mergeSameKindAndReason(with: intent)
            queue[lastIndex].waiters.append(continuation)
        } else {
            queue.append(QueuedIntent(intent: intent, waiters: [continuation]))
        }

        if !isPumping {
            startPump()
        }
    }

    private func dropQueuedResumes() {
        var kept: [QueuedIntent] = []
        for entry in queue {
            if entry.intent.isResume {
                lastVetoReason = .queuedPause
                resume(entry.waiters, with: .dropped)
            } else {
                kept.append(entry)
            }
        }
        queue = kept
    }

    private func startPump() {
        isPumping = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty {
                let entry = self.queue.removeFirst()
                let outcome = await self.runTransition(entry.intent)
                self.resume(entry.waiters, with: outcome)
            }
            self.isPumping = false
        }
    }

    private func runTransition(_ intent: CaptureIntent) async -> TransitionOutcome {
        let task = Task<TransitionOutcome, Never> { @MainActor [weak self] in
            guard let self else { return .dropped }
            switch intent {
            case .pause(let reason, let stopAudio):
                return await self.runPause(reason, stopAudio: stopAudio)
            case .resume(let reason):
                return await self.runResume(reason)
            }
        }
        inFlight = (snapshot: intent.snapshot, task: task)
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func runPause(_ reason: PauseReason, stopAudio: Bool) async -> TransitionOutcome {
        guard let delegate else {
            Logger.capture.info("[Executor] drop pause(\(reason.trigger, privacy: .public)) with no delegate")
            return .dropped
        }

        let state = delegate.lifecycleCurrentState
        let stateLabel = state.label
        guard state.isRecording || state.isPaused else {
            Logger.capture.info("[Executor] drop pause(\(reason.trigger, privacy: .public)) on \(stateLabel, privacy: .public)")
            return .dropped
        }

        let createdPause = state.isRecording
        if state.isPaused && !stopAudio {
            Logger.capture.info("[Executor] drop pause(\(reason.trigger, privacy: .public)) upgrade without audio stop")
            return .dropped
        }

        // Pause runs unbounded: lifecyclePauseCapture owns pauseTransitionActive across finalize,
        // and withTimeout cancels while leaving the operation running. Resume prepare is the hang risk.
        let completedURL = await delegate.lifecyclePauseCapture(trigger: reason.trigger, stopAudio: stopAudio)

        // Already-paused upgrades intentionally re-emit .paused through the delegate;
        // coordinator state ingestion is idempotent. Only a newly finalized segment is processed.
        if createdPause, let completedURL {
            delegate.lifecycleProcessSegment(completedURL, useSleepActivity: reason == .sleep)
        }
        Logger.capture.info("[Executor] pause(\(reason.trigger, privacy: .public)) committed")
        return .committed
    }

    private func runResume(_ reason: ResumeReason) async -> TransitionOutcome {
        guard let delegate else {
            Logger.capture.info("[Executor] drop resume(\(reason.trigger, privacy: .public)) with no delegate")
            return .dropped
        }

        let state = delegate.lifecycleCurrentState
        switch reason {
        case .wake, .unlock:
            guard state.isPaused else {
                lastVetoReason = .stateChanged
                Logger.capture.info("[Executor] drop resume(\(reason.trigger, privacy: .public)) on \(state.label, privacy: .public)")
                return .dropped
            }
            guard suspendedForRecovery else {
                lastVetoReason = .notSuspended
                Logger.capture.info("[Executor] drop resume(\(reason.trigger, privacy: .public)) because not suspended")
                return .dropped
            }
        case .recovery:
            guard state.isError else {
                lastVetoReason = .stateChanged
                Logger.capture.info("[Executor] drop resume(recovery) on \(state.label, privacy: .public)")
                return .dropped
            }
        }

        if reason != .recovery {
            await preResumeSettle()
        }

        do {
            try await withTimeout(seconds: transitionTimeoutSeconds) { @MainActor [weak self] in
                guard let self, let delegate = self.delegate else { return }
                try await delegate.lifecyclePrepareResume(trigger: reason.trigger)
            }
        } catch let error as TimeoutError {
            lastVetoReason = .timedOut
            await shieldedAbort(reason.trigger)
            Logger.capture.warning("[Executor] resume(\(reason.trigger, privacy: .public)) timed out")
            _ = error
            return .vetoed
        } catch is CancellationError {
            lastVetoReason = .reset
            await shieldedAbort(reason.trigger)
            Logger.capture.info("[Executor] resume(\(reason.trigger, privacy: .public)) cancelled")
            return .vetoed
        } catch {
            let failure = ResumeFailure(
                message: error.localizedDescription,
                isPermissionError: isPermissionError(error)
            )
            delegate.lifecycleTransitionToError(
                message: "Failed to resume after \(reason.trigger): \(failure.message)",
                error: error,
                trigger: "\(reason.trigger)_failed"
            )
            Logger.capture.error("Failed to prepare resume after \(reason.trigger, privacy: .public): \(error, privacy: .public)")
            return .threw(failure)
        }

        if Task.isCancelled {
            lastVetoReason = .reset
            await shieldedAbort(reason.trigger)
            return .vetoed
        }

        if queue.contains(where: { $0.intent.isPause }) {
            lastVetoReason = .queuedPause
            await shieldedAbort(reason.trigger)
            suspendedForRecovery = true
            return .vetoed
        }

        if isScreenLocked() {
            lastVetoReason = .screenLocked
            await shieldedAbort(reason.trigger)
            suspendedForRecovery = true
            return .vetoed
        }

        switch reason {
        case .wake, .unlock:
            guard delegate.lifecycleCurrentState.isPaused else {
                lastVetoReason = .stateChanged
                await shieldedAbort(reason.trigger)
                return .vetoed
            }
            guard suspendedForRecovery else {
                lastVetoReason = .notSuspended
                await shieldedAbort(reason.trigger)
                return .vetoed
            }
        case .recovery:
            break
        }

        delegate.lifecycleCommitResume(trigger: reason.trigger)
        suspendedForRecovery = false
        Logger.capture.info("[Executor] resume(\(reason.trigger, privacy: .public)) committed")
        return .committed
    }

    private func shieldedAbort(_ trigger: String) async {
        await Task { @MainActor [weak self] in
            await self?.delegate?.lifecycleAbortPreparedResume(trigger: trigger)
        }.value
    }

    private func resume(
        _ waiters: [CheckedContinuation<TransitionOutcome, Never>],
        with outcome: TransitionOutcome
    ) {
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }
}
