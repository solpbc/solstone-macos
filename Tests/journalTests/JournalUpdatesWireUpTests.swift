// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import UpdateKit
@testable import journal

@MainActor
@Suite("JournalUpdatesWireUp")
struct JournalUpdatesWireUpTests {
    @Test func updateControllerUsesJournalLoggerAndDomain() throws {
        let source = try readSource("Sources/journal/JournalApp.swift")

        #expect(source.contains("log: Logger.updates"))
        #expect(source.contains("errorDomain: \"app.solstone.journal.updates\""))
        #expect(!source.contains("feedURL:"))
        #expect(!source.contains("publicKey:"))
    }

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

    @Test func updatesPaneUsesSharedViewAndJournalCopy() throws {
        let source = try readSource("Sources/journal/JournalSettingsWindow.swift")
        let provider = UpdatesCopyProvider.journal

        #expect(JournalPane.allCases.contains(.updates))
        #expect(JournalPane.updates.title == "updates")
        #expect(JournalPane.updates.systemImage == "arrow.down.circle")
        #expect(source.contains("UpdatesTabView(controller: updateController, copy: UpdatesCopy(provider: .journal))"))
        #expect(provider.appDisplayName == "journal")
        #expect(provider.deferralLine == "deferred, will continue after your journal is ready.")
        #expect(provider.releaseNotesURL.absoluteString == UpdatesCopyProvider.solstone.releaseNotesURL.absoluteString)
    }

    private func readSource(_ path: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
