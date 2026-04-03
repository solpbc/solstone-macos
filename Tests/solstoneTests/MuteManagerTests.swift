// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("MuteManager")
@MainActor
struct MuteManagerTests {
    private func makeDate(hour: Int, minute: Int, second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 1
        components.hour = hour
        components.minute = minute
        components.second = second
        return Calendar.current.date(from: components)!
    }

    // MARK: - nextQuarterHour

    @Test func nextQuarterHourNormalCase() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 14, minute: 32))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 14)
        #expect(components.minute == 45)
        #expect(components.second == 0)
    }

    @Test func nextQuarterHourNearBoundary() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 14, minute: 44))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 14)
        #expect(components.minute == 45)
    }

    @Test func nextQuarterHourOnBoundary() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 14, minute: 45))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 15)
        #expect(components.minute == 0)
    }

    @Test func nextQuarterHourNearHour() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 14, minute: 50))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 15)
        #expect(components.minute == 0)
    }

    @Test func nextQuarterHourHourRollover() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 23, minute: 50))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
    }

    @Test func nextQuarterHourAtZero() {
        let result = MuteManager.nextQuarterHour(after: makeDate(hour: 14, minute: 0))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 14)
        #expect(components.minute == 15)
    }

    // MARK: - secondQuarterHour

    @Test func secondQuarterHourNormal() {
        let result = MuteManager.secondQuarterHour(after: makeDate(hour: 14, minute: 32))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 15)
        #expect(components.minute == 0)
    }

    @Test func secondQuarterHourRollover() {
        let result = MuteManager.secondQuarterHour(after: makeDate(hour: 23, minute: 50))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 0)
        #expect(components.minute == 15)
    }

    // MARK: - nextFullHour

    @Test func nextFullHourAlwaysNextHour() {
        let result = MuteManager.nextFullHour(after: makeDate(hour: 15, minute: 32))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 17)
        #expect(components.minute == 0)
    }

    @Test func nextFullHourFromNearEndOfHour() {
        let result = MuteManager.nextFullHour(after: makeDate(hour: 15, minute: 55))
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result)
        #expect(components.hour == 17)
        #expect(components.minute == 0)
    }
}
