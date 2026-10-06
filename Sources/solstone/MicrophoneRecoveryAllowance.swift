// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Shared by a selected UID across automatic engine and capture replacement.
internal final class MicrophoneRecoveryAllowance: @unchecked Sendable {
    static let replacementLimit = 6
    static let stableSeconds: TimeInterval = 10
    static let maximumArrivalGap: TimeInterval = 0.5
    private let lock = NSLock()
    private var initialAttemptUsed = false
    private var replacements = 0
    private var parked = false
    private var stableStart: TimeInterval?
    private var lastArrival: TimeInterval?

    var canAttempt: Bool {
        lock.withLock { !parked && (!initialAttemptUsed || replacements < Self.replacementLimit) }
    }
    func admitAttempt() -> Bool {
        lock.withLock {
            guard !parked else { return false }
            stableStart = nil; lastArrival = nil
            if !initialAttemptUsed { initialAttemptUsed = true; return true }
            guard replacements < Self.replacementLimit else { parked = true; return false }
            replacements += 1
            return true
        }
    }
    func park() { lock.withLock { parked = true; stableStart = nil; lastArrival = nil } }
    func breakContinuity() { lock.withLock { stableStart = nil; lastArrival = nil } }
    func acceptPCM(arrival: TimeInterval, continuous: Bool) {
        lock.withLock {
            guard !parked, arrival.isFinite else { return }
            if !continuous || lastArrival == nil || arrival < lastArrival! ||
                arrival - lastArrival! > Self.maximumArrivalGap {
                stableStart = arrival
            }
            lastArrival = arrival
            if let stableStart, arrival - stableStart >= Self.stableSeconds {
                replacements = 0
            }
        }
    }
}
