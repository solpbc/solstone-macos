// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore
import Testing

@Suite("SetupCapabilityPlist")
struct SetupCapabilityPlistTests {
    // The shipped bundle advertises the native setup sequence to a same-Mac
    // journal app. An older journal app without it keeps the browser route,
    // which SetupModelTests covers with bundles that omit the key.
    @Test func shippedInfoPlistAdvertisesTheSetupSequence() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/solstone/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let capabilities = try #require(plist["SolstoneSetupCapabilities"] as? [String])
        #expect(journalSupportsSetupSequence(capabilities))
    }
}
