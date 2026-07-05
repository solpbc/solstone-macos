// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing

@Suite("JournalHandoff")
struct JournalHandoffTests {
    @Test func urlUsesInjectedApplicationSupportBase() {
        let base = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)

        let url = JournalHandoffFile.url(applicationSupportBaseURL: base)

        #expect(url.path == "/tmp/app-support/sol/journal-handoff.json")
    }

    @Test func codableRoundTripPreservesFieldsAndISO8601TimestampString() throws {
        let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-05T18:30:00Z"))
        let handoff = JournalHandoff(
            journalRootPath: "/Users/example/journal",
            observerName: "macbook",
            provenance: "solstone-macos",
            timestamp: timestamp
        )

        let data = try JSONEncoder().encode(handoff)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timestampString = try #require(object["timestamp"] as? String)
        let decoded = try JSONDecoder().decode(JournalHandoff.self, from: data)

        #expect(object["journalRootPath"] as? String == "/Users/example/journal")
        #expect(object["observerName"] as? String == "macbook")
        #expect(object["provenance"] as? String == "solstone-macos")
        #expect(timestampString.hasPrefix("2026-07-05T18:30:00"))
        #expect(decoded == handoff)
    }

    @Test func handWrittenCamelCaseFixtureDecodes() throws {
        let fixture = """
        {
          "journalRootPath": "/Users/example/journal",
          "observerName": "studio mac",
          "provenance": "manual-test",
          "timestamp": "2026-07-05T18:30:00Z"
        }
        """

        let decoded = try JSONDecoder().decode(JournalHandoff.self, from: Data(fixture.utf8))

        #expect(decoded.journalRootPath == "/Users/example/journal")
        #expect(decoded.observerName == "studio mac")
        #expect(decoded.provenance == "manual-test")
        #expect(ISO8601DateFormatter().string(from: decoded.timestamp) == "2026-07-05T18:30:00Z")
    }
}
