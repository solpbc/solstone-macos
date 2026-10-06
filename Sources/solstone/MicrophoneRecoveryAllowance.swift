// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Shared by a selected UID across automatic engine and capture replacement.
/// A burst of replacements is allowed; after that the source cools down with
/// backoff and is offered one attempt each time the cooldown ends. Stable PCM
/// resets both. A selected microphone is therefore never parked for good.
internal final class MicrophoneRecoveryAllowance: @unchecked Sendable {
    static let replacementLimit = 6
    static let stableSeconds: TimeInterval = 10
    /// Low-rate devices can deliver half-second buffers; continuity tolerates that.
    static let maximumArrivalGap: TimeInterval = 1.5
    static let cooldowns: [TimeInterval] = [15, 30, 60]
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var initialAttemptUsed = false
    private var replacements = 0
    private var parkedUntil: TimeInterval?
    private var cooldownLevel = 0
    private var stableStart: TimeInterval?
    private var lastArrival: TimeInterval?

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Ends an expired cooldown with exactly one attempt left. Caller holds the lock.
    private func releaseExpiredCooldownLocked() {
        guard let until = parkedUntil, now() >= until else { return }
        parkedUntil = nil
        initialAttemptUsed = true
        replacements = Self.replacementLimit - 1
    }
    var canAttempt: Bool {
        lock.withLock {
            releaseExpiredCooldownLocked()
            return parkedUntil == nil && (!initialAttemptUsed || replacements < Self.replacementLimit)
        }
    }
    var isCoolingDown: Bool { lock.withLock { releaseExpiredCooldownLocked(); return parkedUntil != nil } }
    func admitAttempt() -> Bool {
        lock.withLock {
            releaseExpiredCooldownLocked()
            guard parkedUntil == nil else { return false }
            stableStart = nil; lastArrival = nil
            if !initialAttemptUsed { initialAttemptUsed = true; return true }
            guard replacements < Self.replacementLimit else { parkLocked(); return false }
            replacements += 1
            return true
        }
    }
    /// Starts (or keeps) a cooldown. Repeated calls during one cooldown do not extend it.
    func park() { lock.withLock { parkLocked() } }
    private func parkLocked() {
        stableStart = nil; lastArrival = nil
        releaseExpiredCooldownLocked()
        guard parkedUntil == nil else { return }
        parkedUntil = now() + Self.cooldowns[min(cooldownLevel, Self.cooldowns.count - 1)]
        cooldownLevel += 1
    }
    func breakContinuity() { lock.withLock { stableStart = nil; lastArrival = nil } }
    func acceptPCM(arrival: TimeInterval, continuous: Bool) {
        lock.withLock {
            guard parkedUntil == nil, arrival.isFinite else { return }
            if !continuous || lastArrival == nil || arrival < lastArrival! ||
                arrival - lastArrival! > Self.maximumArrivalGap {
                stableStart = arrival
            }
            lastArrival = arrival
            if let stableStart, arrival - stableStart >= Self.stableSeconds {
                replacements = 0
                cooldownLevel = 0
            }
        }
    }
}
