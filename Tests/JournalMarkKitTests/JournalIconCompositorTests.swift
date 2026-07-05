// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Testing
@testable import JournalMarkKit

@MainActor
@Suite("JournalIconCompositor", .serialized)
struct JournalIconCompositorTests {
    @Test func appIconContainsExpectedBitmapReps() {
        let image = JournalIconCompositor.appIcon(spec: nil)
        let widths = image.representations
            .compactMap { ($0 as? NSBitmapImageRep)?.pixelsWide }
            .sorted()

        #expect(widths == JournalIconCompositor.ladderSides)
    }

    @Test func tileRendersNonBlankGenericAndOwner() throws {
        let generic = JournalIconCompositor.tile(spec: nil, side: 256)
        #expect(generic.kind == .generic)
        #expect(try #require(RGBASnapshot(image: generic.image)).hasNonTransparentPixel())

        let owner = JournalIconCompositor.tile(spec: .uiTestSample, side: 256)
        #expect(owner.kind == .owner)
        #expect(try #require(RGBASnapshot(image: owner.image)).hasNonTransparentPixel())
    }

    @Test func invalidSpecFallsBackToGeneric() {
        let invalid = JournalMark(
            icon1: JournalMark.uiTestSample.icon1,
            icon2: JournalMark.Icon(
                name: JournalMark.uiTestSample.icon2.name,
                color: JournalMark.uiTestSample.icon2.color,
                rot: 90,
                svg: JournalMark.uiTestSample.icon2.svg
            ),
            words: JournalMark.uiTestSample.words
        )

        #expect(JournalIconCompositor.tile(spec: invalid, side: 256).kind == .generic)
    }

    @Test func validSpecFallsBackToGenericWhenWordLayoutCannotResolveFont() {
        JournalIconWordLayout.forceFontUnavailableForTesting = true
        defer { JournalIconWordLayout.forceFontUnavailableForTesting = false }

        #expect(JournalIconCompositor.tile(spec: .uiTestSample, side: 256).kind == .generic)
    }

    @Test func committedICNSCornersStayTransparentAtEveryLadderSide() throws {
        let url = repoRootURL().appendingPathComponent("Sources/journal/Resources/AppIcon.icns")
        let image = try #require(NSImage(contentsOf: url))

        for side in JournalIconCompositor.ladderSides {
            var rect = NSRect(x: 0, y: 0, width: side, height: side)
            let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let snapshot = try #require(RGBASnapshot(image: cgImage))
            #expect(snapshot.alphaAt(x: 0, y: 0) == 0)
            #expect(snapshot.alphaAt(x: snapshot.width - 1, y: 0) == 0)
            #expect(snapshot.alphaAt(x: 0, y: snapshot.height - 1) == 0)
            #expect(snapshot.alphaAt(x: snapshot.width - 1, y: snapshot.height - 1) == 0)
        }
    }

    @Test func ownerBorderColorAppearsNearExpectedChipCenters() throws {
        for side in [256, 1024] {
            let tile = JournalIconCompositor.tile(spec: .uiTestSample, side: CGFloat(side))
            let snapshot = try #require(RGBASnapshot(image: tile.image))
            let layout = try #require(JournalIconTileGeometry.chipLayout(tileSide: CGFloat(side), rotations: [0, 45]))
            let chip1LeftEdge = CGPoint(
                x: layout.centers[0].x - layout.side / 2,
                y: layout.centers[0].y
            )

            #expect(snapshot.containsColor(
                hex: JournalMark.uiTestSample.icon1.color.hex,
                near: chip1LeftEdge,
                radius: max(6, side / 48),
                tolerance: 36
            ))
        }
    }
}
