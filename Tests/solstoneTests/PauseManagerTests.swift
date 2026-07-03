// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@MainActor
final class FakePauseExpiryScheduler {
    private var onExpire: (@MainActor @Sendable () -> Void)?

    var scheduler: PauseExpiryScheduler {
        { [weak self] _, onExpire in
            self?.onExpire = onExpire
            return FakePauseExpiryTimer { [weak self] in self?.onExpire = nil }
        }
    }

    /// Deterministically fire the armed expiry.
    func fire() { onExpire?() }
}

final class FakePauseExpiryTimer: PauseExpiryTimer {
    private let onInvalidate: () -> Void
    init(onInvalidate: @escaping () -> Void) { self.onInvalidate = onInvalidate }
    func invalidate() { onInvalidate() }
}

@Suite("PauseManager")
@MainActor
struct PauseManagerTests {
    @Test func pauseForMinutesSetsExpiration() {
        let manager = PauseManager()
        let before = Date()
        manager.pause(for: .minutes(15))
        let after = Date()

        #expect(manager.isPaused)
        #expect(manager.pauseState.expirationDate != nil)

        let expiration = manager.pauseState.expirationDate!
        #expect(expiration.timeIntervalSince(before) >= 15 * 60 - 1)
        #expect(expiration.timeIntervalSince(after) <= 15 * 60 + 1)
    }

    @Test func pauseIndefinitelyHasNoExpiration() {
        let manager = PauseManager()
        manager.pause(for: .indefinite)

        #expect(manager.isPaused)
        #expect(manager.pauseState.expirationDate == nil)
        #expect(manager.pauseState.isIndefinite)
    }

    @Test func resumeClearsPauseState() {
        let manager = PauseManager()
        manager.pause(for: .minutes(30))
        #expect(manager.isPaused)

        manager.resume()
        #expect(!manager.isPaused)
        #expect(manager.pauseState.expirationDate == nil)
    }

    @Test func silentClearDoesNotFireResumeCallback() {
        let manager = PauseManager()
        var resumeCallbackCount = 0
        manager.onResume = {
            resumeCallbackCount += 1
        }
        manager.pause(for: .minutes(30))
        #expect(manager.isPaused)

        manager.clearPolicyStateSilently()

        #expect(!manager.isPaused)
        #expect(manager.pauseState.expirationDate == nil)
        #expect(manager.refreshTick == 0)
        #expect(resumeCallbackCount == 0)
    }

    @Test func timedPauseAutoResumesAtExpiry() async throws {
        let scheduler = FakePauseExpiryScheduler()
        let manager = PauseManager(expiryScheduler: scheduler.scheduler)
        let pauseCallbackCount = LockedCounter()
        let resumeCallbackCount = LockedCounter()
        manager.onPause = {
            pauseCallbackCount.increment()
        }
        manager.onResume = {
            resumeCallbackCount.increment()
        }

        manager.pause(for: .seconds(1))
        scheduler.fire()

        try await withTimeout(seconds: 3) {
            await resumeCallbackCount.waitUntilCount(1)
        }
        #expect(!manager.isPaused)
        #expect(pauseCallbackCount.count == 1)
    }

    @Test func indefinitePauseDoesNotAutoResume() async throws {
        let manager = PauseManager()
        let resumeCallbackCount = LockedCounter()
        manager.onResume = {
            resumeCallbackCount.increment()
        }

        manager.pause(for: .indefinite)
        try await Task.sleep(for: .milliseconds(250))

        #expect(manager.isPaused)
        #expect(resumeCallbackCount.count == 0)
    }

    @Test func formatTimeRemainingShowsMinutes() {
        let manager = PauseManager()
        manager.pause(for: .minutes(15))

        let text = manager.formatTimeRemaining()
        #expect(text != nil)
        #expect(text!.contains("min"))
    }

    @Test func formatTimeRemainingNilWhenIndefinite() {
        let manager = PauseManager()
        manager.pause(for: .indefinite)

        #expect(manager.formatTimeRemaining() == nil)
    }

    @Test func formatTimeRemainingNilWhenNotPaused() {
        let manager = PauseManager()
        #expect(manager.formatTimeRemaining() == nil)
    }

    @Test func durationExpirationDates() {
        let before = Date()
        let fiveMin = PauseManager.PauseDuration.minutes(5).expirationDate
        let twoHour = PauseManager.PauseDuration.minutes(120).expirationDate
        let indefinite = PauseManager.PauseDuration.indefinite.expirationDate

        #expect(fiveMin != nil)
        #expect(fiveMin!.timeIntervalSince(before) >= 5 * 60 - 1)
        #expect(fiveMin!.timeIntervalSince(before) <= 5 * 60 + 1)

        #expect(twoHour != nil)
        #expect(twoHour!.timeIntervalSince(before) >= 120 * 60 - 1)
        #expect(twoHour!.timeIntervalSince(before) <= 120 * 60 + 1)

        #expect(indefinite == nil)
    }
}
