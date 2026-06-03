// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("About WireUp")
struct AboutWireUpTests {
    // Proves registry wire-up presence, not live AX-tree attachment; device-phase AX dumps cover that.
    @Test func aboutViewReferencesExpectedAXIDs() throws {
        let source = try readWireUpSource("Sources/solstone/AboutView.swift")
        let references = [
            "AXID.About.logo",
            "AXID.About.title",
            "AXID.About.versionState",
            "AXID.About.sourceCode",
            "AXID.About.website"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }
    }
}
