// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Testing
@testable import JournalMarkKit

@Suite("JournalIconTileGeometry")
struct JournalIconTileGeometryTests {
    @Test func chipCentersWithoutOpticalShift() throws {
        let layout256 = try #require(JournalIconTileGeometry.chipLayout(tileSide: 256, rotations: [0, 0]))
        expectClose(layout256.side, 69.12)
        expectClose(layout256.centers[0].x, 85.4912, tolerance: 0.001)
        expectClose(layout256.centers[1].x, 170.5088, tolerance: 0.001)
        expectClose(layout256.centers[0].y, 87.04, tolerance: 0.001)
        expectClose(JournalIconTileGeometry.ownerChipBorderWidth(chipSide: layout256.side), 2.88)

        let layout1024 = try #require(JournalIconTileGeometry.chipLayout(tileSide: 1024, rotations: [0, 0]))
        expectClose(layout1024.side, 276.48)
        expectClose(layout1024.centers[0].x, 341.9648, tolerance: 0.001)
        expectClose(layout1024.centers[1].x, 682.0352, tolerance: 0.001)
        expectClose(layout1024.centers[0].y, 348.16, tolerance: 0.001)
        expectClose(JournalIconTileGeometry.ownerChipBorderWidth(chipSide: layout1024.side), 11.52)
    }

    @Test func opticalRecenteringMatchesSanityAnchors() throws {
        let layout256 = try #require(JournalIconTileGeometry.chipLayout(tileSide: 256, rotations: [0, 45]))
        expectClose(layout256.centers[0].x, 78.33, tolerance: 0.01)
        expectClose(layout256.centers[1].x, 163.35, tolerance: 0.01)
        expectClose(layout256.centers[0].y, 87.04, tolerance: 0.001)

        let layout1024 = try #require(JournalIconTileGeometry.chipLayout(tileSide: 1024, rotations: [0, 45]))
        expectClose(layout1024.centers[0].x, 313.33, tolerance: 0.01)
        expectClose(layout1024.centers[1].x, 653.40, tolerance: 0.01)
        expectClose(layout1024.centers[0].y, 348.16, tolerance: 0.001)
    }

    @Test func dashLengthsUseChipSideNormalization() {
        let dash256 = JournalIconTileGeometry.genericDashLengths(chipSide: JournalIconTileGeometry.chipSide(tileSide: 256))
        expectClose(dash256[0], 8.192)
        expectClose(dash256[1], 6.144)

        let dash1024 = JournalIconTileGeometry.genericDashLengths(chipSide: JournalIconTileGeometry.chipSide(tileSide: 1024))
        expectClose(dash1024[0], 32.768)
        expectClose(dash1024[1], 24.576)
    }
}
