// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

struct SegmentNamingLocaleTests {
    @Test func repeatedHourCannotReuseAnIncompleteSegment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(baseDirectory: root)
        let zone = try #require(TimeZone(identifier: "America/Denver"))
        let first = try #require(ISO8601DateFormatter().date(from: "2026-11-01T07:15:00Z"))
        let (directory, prefix) = try storage.createSegmentDirectory(segmentStartTime: first, timeZone: zone)
        #expect(prefix == "011500")
        #expect(directory.lastPathComponent == "011500.incomplete")
        let media = directory.appendingPathComponent("audio.m4a")
        try Data("first hour".utf8).write(to: media)
        let zoneURL = directory.appendingPathComponent(StorageManager.captureZoneFileName)
        let savedZone = try Data(contentsOf: zoneURL)

        let (secondDirectory, secondPrefix) = try storage.createSegmentDirectory(segmentStartTime: first.addingTimeInterval(3600), timeZone: zone)
        #expect(secondPrefix == "011501")
        #expect(secondDirectory.lastPathComponent == "011501.incomplete")
        #expect(try Data(contentsOf: media) == Data("first hour".utf8))
        #expect(try Data(contentsOf: zoneURL) == savedZone)
    }

    @Test func segmentFormattingOverridesLocaleAndCalendarPreferences() throws {
        let hostileSettings: [(String, Calendar.Identifier)] = [
            ("ar_SA", .gregorian), ("fa_IR", .gregorian),
            ("th_TH", .buddhist), ("ja_JP", .japanese),
        ]
        let cases = [
            ("2026-09-29T23:58:00Z", "Asia/Tokyo", "20260930085800", 32400),
            ("2026-11-01T07:15:00Z", "America/Denver", "20261101011500", -21600),
            ("2026-11-01T08:15:00Z", "America/Denver", "20261101011500", -25200),
            ("2026-03-08T09:05:00Z", "America/Denver", "20260308030500", -21600),
            ("2026-01-15T06:30:00Z", "Asia/Kolkata", "20260115120000", 19800),
        ]
        for (locale, calendar) in hostileSettings {
            for (instant, zoneID, expected, offset) in cases {
                let start = try #require(ISO8601DateFormatter().date(from: instant))
                let zone = try #require(TimeZone(identifier: zoneID))
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: locale)
                formatter.calendar = Calendar(identifier: calendar)
                formatter.timeZone = zone
                formatter.dateFormat = "yyyyMMddHHmmss"
                #expect(formatter.string(from: start) != expected)
                StorageManager.configureSegmentFormatter(formatter)
                formatter.dateFormat = "yyyyMMddHHmmss"
                #expect(formatter.string(from: start) == expected)
                #expect(zone.secondsFromGMT(for: start) == offset)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let (url, clock) = try StorageManager(baseDirectory: root).createSegmentDirectory(
                    segmentStartTime: start, timeZone: zone
                )
                let day = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "-", with: "")
                #expect(day + clock == expected)
            }
        }
    }
}
