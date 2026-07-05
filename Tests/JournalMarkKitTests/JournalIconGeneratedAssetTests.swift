// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import JournalMarkKit

@MainActor
@Suite("JournalIconGeneratedAsset")
struct JournalIconGeneratedAssetTests {
    @Test func committedSVGContainsSharedWordPathsAndPlate() throws {
        let svgURL = repoRootURL().appendingPathComponent("assets/icon-journal.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)

        #expect(svg.contains(JournalIconTileGeometry.platePathElement))

        let wordLayout = try #require(JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "your", baselineY: 70),
                JournalIconWordInput(word: "journal", baselineY: 86)
            ],
            tileSide: 1024
        ))

        for path in wordLayout.paths {
            let pathData = JournalIconSVGPathData.string(from: path)
            #expect(svg.contains(#"d="\#(pathData)""#))
        }
    }
}
