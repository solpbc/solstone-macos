// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing

@Suite("AXStateCompanion WireUp")
struct AXStateCompanionWireUpTests {
    @Test func companionUsesValueBearingLabeledCarrier() throws {
        let source = try readWireUpSource("Sources/SolstoneCore/AXSupport.swift")
        let references = [
            "Text(value)",
            ".accessibilityLabel(id)",
            ".accessibilityIdentifier(id)",
            ".accessibilityValue(value)"
        ]

        for reference in references {
            #expect(wireUpContains(source, reference))
        }

        #expect(!wireUpContains(source, "Color.clear"))
        #expect(!wireUpContains(source, ".frame(width: 0"))
    }
}
