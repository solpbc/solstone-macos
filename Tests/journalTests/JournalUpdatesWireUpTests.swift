// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UpdateKit

@MainActor
@Suite("JournalUpdatesWireUp")
struct JournalUpdatesWireUpTests {
    @Test func journalInfoPlistCarriesValidSparkleFeed() throws {
        let plistURL = repoRoot().appendingPathComponent("Sources/journal/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let feedURL = try #require(plist["SUFeedURL"] as? String)
        let publicKey = try #require(plist["SUPublicEDKey"] as? String)

        #expect(feedURL == "https://updates.solstone.app/journal-macos/appcast.xml")
        #expect(UpdateController.validateSparkleConfig(feedURL: feedURL, publicKey: publicKey))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
