// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

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
