// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The single authority for when an audio source is tried again.
///
/// Sources never retry on their own: a microphone or the system transport that
/// stops reports it, and capture asks here before each restart. Every source is
/// always retried while the owner wants it, on a backoff that a healthy run
/// forgives. Nothing waits for an owner action, and churn stays bounded.
@MainActor
final class AudioRecoveryManager {
    enum Kind { case microphone, system }

    /// Wait after the n-th consecutive attempt before the next (n counts from 1).
    /// The last value repeats. A system rebuild stutters playback, so it waits longer.
    static let microphoneDelays: [TimeInterval] = [0.2, 0.5, 1, 2, 5, 15, 30, 60]
    static let systemDelays: [TimeInterval] = [60, 120, 300]
    /// A source that has stayed healthy this long starts its backoff over.
    static let healthyResetSeconds: TimeInterval = 30

    private struct SourceState {
        var attempts = 0
        var nextAttempt: TimeInterval = 0
        var healthySince: TimeInterval?
    }

    private var states: [String: SourceState] = [:]
    private let now: () -> TimeInterval
    private let scheduleWake: (TimeInterval, @escaping @MainActor () -> Void) -> any PauseExpiryTimer
    private var wakeTimer: (any PauseExpiryTimer)?
    private var wakeAt: TimeInterval?
    private var wakeGeneration: UInt64 = 0
    /// Called when a scheduled attempt becomes due.
    var onWake: (@MainActor () -> Void)?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         scheduleWake: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> any PauseExpiryTimer = { delay, fire in
             CaptureTimer.schedule(interval: max(0.01, delay), repeats: false) { _ in Task { @MainActor in fire() } }
         }) {
        self.now = now
        self.scheduleWake = scheduleWake
    }

    /// Whether the source may be tried now. A source never seen before always may.
    func canAttempt(_ id: String) -> Bool {
        now() >= (states[id]?.nextAttempt ?? 0)
    }

    /// Records an attempt and sets when the next one is allowed.
    func noteAttempt(_ id: String, kind: Kind) {
        var state = states[id] ?? SourceState()
        state.attempts += 1
        state.healthySince = nil
        let delays = kind == .system ? Self.systemDelays : Self.microphoneDelays
        state.nextAttempt = now() + delays[min(state.attempts, delays.count) - 1]
        states[id] = state
        armWake(at: state.nextAttempt)
    }

    /// Observed working. After a long enough healthy run the backoff starts over.
    func noteHealthy(_ id: String) {
        guard var state = states[id], state.attempts > 0 else { return }
        let current = now()
        if let since = state.healthySince {
            if current - since >= Self.healthyResetSeconds { state = SourceState() }
        } else {
            state.healthySince = current
        }
        states[id] = state
    }

    /// Observed not working; a healthy run must start over.
    func noteUnhealthy(_ id: String) {
        states[id]?.healthySince = nil
    }

    /// An owner action (turning a source on, resuming, starting) gets an immediate try.
    func reset(_ ids: Set<String>? = nil) {
        if let ids { for id in ids { states.removeValue(forKey: id) } } else { states.removeAll() }
    }

    /// Seconds until the source may be tried, for tests and diagnostics.
    func secondsUntilAttempt(_ id: String) -> TimeInterval {
        max(0, (states[id]?.nextAttempt ?? 0) - now())
    }

    func cancelWake() {
        wakeGeneration &+= 1
        wakeTimer?.invalidate(); wakeTimer = nil; wakeAt = nil
    }

    /// Keeps one timer, for the earliest attempt still in the future.
    private func armWake(at time: TimeInterval) {
        let current = now()
        guard time > current else { return }
        // An earlier pending wake covers this one; a past one is stale.
        if let wakeAt, wakeAt <= time, wakeAt > current { return }
        wakeTimer?.invalidate()
        wakeGeneration &+= 1
        let generation = wakeGeneration
        wakeAt = time
        wakeTimer = scheduleWake(time - current) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.wakeTimer = nil; self.wakeAt = nil
            self.onWake?()
            // Attempts that were due later than this wake still need one.
            let current = self.now()
            if let next = self.states.values.map(\.nextAttempt).filter({ $0 > current }).min() { self.armWake(at: next) }
        }
    }
}
