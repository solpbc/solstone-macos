// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import JournalMarkKit

@MainActor
@Suite("JournalIconWordLayout")
struct JournalIconWordLayoutTests {
    @Test func lowercaseEnforcementProducesSameOutlines() throws {
        let uppercase = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "YOUR", baselineY: 70),
                JournalIconWordInput(word: "JOURNAL", baselineY: 86)
            ],
            tileSide: 100
        ))
        let lowercase = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "your", baselineY: 70),
                JournalIconWordInput(word: "journal", baselineY: 86)
            ],
            tileSide: 100
        ))

        #expect(JournalIconSVGPathData.string(from: uppercase.combinedPath) == JournalIconSVGPathData.string(from: lowercase.combinedPath))
    }

    @Test func wordsShareOneShrinkToFitFontSize() throws {
        let short = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "your", baselineY: 70),
                JournalIconWordInput(word: "journal", baselineY: 86)
            ],
            tileSide: 100
        ))
        expectClose(short.fontSizeInReferenceSpace, 12)

        let wide = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "a", baselineY: 70),
                JournalIconWordInput(word: "mmmmmmmmm", baselineY: 86)
            ],
            tileSide: 100
        ))

        #expect(wide.fontSizeInReferenceSpace < 12)
        #expect(wide.measuredWidths.max() ?? 0 <= 76.01)
        #expect(wide.measuredWidths[0] < wide.measuredWidths[1])
    }

    @Test func glyphBoundsSitAboveBaselineInYDownCoordinates() throws {
        let result = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "our", baselineY: 70)
            ],
            tileSide: 100
        ))
        let bounds = result.paths[0].boundingBox

        #expect(bounds.minY < 70)
        #expect(bounds.maxY <= 70.5)
    }

    @Test func deterministicPathOutput() throws {
        let inputs = [
            JournalIconWordInput(word: "your", baselineY: 70),
            JournalIconWordInput(word: "journal", baselineY: 86)
        ]
        let first = try #require(JournalIconWordLayout.outlinedPaths(for: inputs, tileSide: 256))
        let second = try #require(JournalIconWordLayout.outlinedPaths(for: inputs, tileSide: 256))

        expectRectClose(first.combinedPath.boundingBox, second.combinedPath.boundingBox)
        #expect(JournalIconSVGPathData.string(from: first.combinedPath) == JournalIconSVGPathData.string(from: second.combinedPath))
    }
}
