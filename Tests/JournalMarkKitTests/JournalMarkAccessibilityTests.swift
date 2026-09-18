// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalMarkKit

@Suite("JournalMarkAccessibility")
struct JournalMarkAccessibilityTests {
    @Test func spokenValueUsesDecodedColorName() {
        let mark = Self.mark(color1: "amber", color2: "lime")
        #expect(JournalMarkAccessibility.spokenValue(mark: mark) == "amber bug, lime gem, afoot, unfixed")
        #expect(JournalMarkAccessibility.chipToken(colorName: "amber", glyphName: "bug") == "amber bug")
        #expect(JournalMarkAccessibility.spokenValue(mark: .uiTestSample) == "amber bug, lime gem, afoot, unfixed")
    }

    @Test func spokenValueFallsBackToGlyphNameWhenColorNameAbsent() {
        let mark = Self.mark(color1: nil, color2: nil)
        #expect(JournalMarkAccessibility.spokenValue(mark: mark) == "bug, gem, afoot, unfixed")
        #expect(JournalMarkAccessibility.chipToken(colorName: nil, glyphName: "bug") == "bug")
        #expect(JournalMarkAccessibility.chipToken(colorName: "  ", glyphName: "bug") == "bug")
        #expect(JournalMarkAccessibility.chipToken(colorName: "", glyphName: "gem") == "gem")
    }

    @Test func spokenValueForNilIsGeneric() {
        #expect(JournalMarkAccessibility.spokenValue(mark: nil) == "your journal, not set up yet")
        #expect(JournalMarkGeneric.spokenValue == "your journal, not set up yet")
        #expect(JournalMarkGeneric.words == ["your", "journal"])
        #expect(!JournalMarkAccessibility.spokenValue(mark: nil).contains("bug"))
        #expect(!JournalMarkAccessibility.spokenValue(mark: nil).contains("gem"))
    }

    @Test func genericPaletteMatchesTheSharedIconCompositorSource() {
        // The single source is JournalIconTileGeometry — never re-declared, so the generic-mark
        // card and the app-icon compositor cannot drift from each other.
        #expect(JournalIconTileGeometry.genericChip1Hex == "#E8913A")
        #expect(JournalIconTileGeometry.genericChip2Hex == "#D4A017")
    }

    private static func mark(color1: String?, color2: String?) -> JournalMark {
        JournalMark(
            icon1: JournalMark.Icon(
                name: "bug",
                color: JournalMark.MarkColor(hex: "#f59e0b", name: color1),
                rot: 0,
                svg: #"<path d="M0 0" />"#
            ),
            icon2: JournalMark.Icon(
                name: "gem",
                color: JournalMark.MarkColor(hex: "#84cc16", name: color2),
                rot: 45,
                svg: #"<path d="M0 0" />"#
            ),
            words: ["afoot", "unfixed"]
        )
    }
}
