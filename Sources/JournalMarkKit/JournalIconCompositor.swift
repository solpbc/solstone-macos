// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Foundation
import SwiftUI

public struct JournalIconTileResult {
    public enum Kind: Equatable {
        case owner
        case generic
    }

    public let kind: Kind
    public let image: CGImage
}

@MainActor
public enum JournalIconCompositor {
    static let ladderSides = [16, 32, 64, 128, 256, 512, 1024]

    public static func tile(spec: JournalMark?, side: CGFloat) -> JournalIconTileResult {
        if let spec,
           let valid = JournalMark.validate(spec),
           let owner = renderOwner(spec: valid, side: side) {
            return JournalIconTileResult(kind: .owner, image: owner)
        }
        return JournalIconTileResult(kind: .generic, image: renderGeneric(side: side))
    }

    public static func appIcon(spec: JournalMark?) -> NSImage {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        for side in ladderSides {
            let tile = self.tile(spec: spec, side: CGFloat(side))
            let rep = NSBitmapImageRep(cgImage: tile.image)
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        return image
    }

    private static func renderOwner(spec: JournalMark, side: CGFloat) -> CGImage? {
        guard let wordLayout = JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: spec.words[0], baselineY: JournalIconTileGeometry.ownerWordBaselines(tileSide: 100)[0]),
                JournalIconWordInput(word: spec.words[1], baselineY: JournalIconTileGeometry.ownerWordBaselines(tileSide: 100)[1])
            ],
            tileSide: side
        ),
              let layout = JournalIconTileGeometry.chipLayout(
                tileSide: side,
                rotations: [CGFloat(spec.icon1.rot), CGFloat(spec.icon2.rot)]
              ),
              let context = makeContext(side: side) else {
            return nil
        }

        drawTileBase(in: context, side: side)
        guard drawOwnerChip(spec.icon1, layout: layout, index: 0, in: context),
              drawOwnerChip(spec.icon2, layout: layout, index: 1, in: context) else {
            return nil
        }
        drawWordPaths(wordLayout.paths, in: context)
        return context.makeImage()
    }

    private static func renderGeneric(side: CGFloat) -> CGImage {
        guard let context = makeContext(side: side) else {
            return transparentImage(side: side)
        }
        drawTileBase(in: context, side: side)
        if let layout = JournalIconTileGeometry.chipLayout(tileSide: side, rotations: [0, 45]) {
            drawGenericChip(
                center: layout.centers[0],
                chipSide: layout.side,
                rotation: 0,
                colorHex: JournalIconTileGeometry.genericChip1Hex,
                in: context
            )
            drawGenericChip(
                center: layout.centers[1],
                chipSide: layout.side,
                rotation: 45,
                colorHex: JournalIconTileGeometry.genericChip2Hex,
                in: context
            )
        }
        if let wordLayout = JournalIconWordLayout.outlinedPaths(
            for: [
                JournalIconWordInput(word: "your", baselineY: JournalIconTileGeometry.ownerWordBaselines(tileSide: 100)[0]),
                JournalIconWordInput(word: "journal", baselineY: JournalIconTileGeometry.ownerWordBaselines(tileSide: 100)[1])
            ],
            tileSide: side
        ) {
            drawWordPaths(wordLayout.paths, in: context)
        }
        return context.makeImage() ?? transparentImage(side: side)
    }

    private static func makeContext(side: CGFloat) -> CGContext? {
        let pixels = max(Int(side.rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        return context
    }

    private static func transparentImage(side: CGFloat) -> CGImage {
        let pixels = max(Int(side.rounded()), 1)
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private static func drawTileBase(in context: CGContext, side: CGFloat) {
        guard let plate = JournalIconTileGeometry.platePath(tileSide: side),
              let fill = JournalIconTileGeometry.cgColor(hex: JournalIconTileGeometry.plateFillHex) else {
            return
        }
        context.addPath(plate)
        context.setFillColor(fill)
        context.fillPath()
    }

    private static func drawOwnerChip(
        _ icon: JournalMark.Icon,
        layout: JournalIconChipLayout,
        index: Int,
        in context: CGContext
    ) -> Bool {
        guard let stroke = JournalIconTileGeometry.cgColor(hex: icon.color.hex),
              let fill = JournalIconTileGeometry.cgColor(
                hex: icon.color.hex,
                alpha: JournalIconTileGeometry.ownerFillOpacity()
              ) else {
            return false
        }
        let center = layout.centers[index]
        let chipSide = layout.side
        let rotation = CGFloat(icon.rot == 45 ? 45 : 0)
        let chipPath = JournalIconTileGeometry.chipPath(center: center, side: chipSide, rotationDegrees: rotation)
        context.addPath(chipPath)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(chipPath)
        context.setStrokeColor(stroke)
        context.setLineWidth(JournalIconTileGeometry.ownerChipBorderWidth(chipSide: chipSide))
        context.strokePath()

        let glyphRect = JournalIconTileGeometry.glyphRect(center: center, chipSide: chipSide)
        guard let glyph = GlyphParser.parse(innerMarkup: icon.svg, in: glyphRect) else {
            return false
        }
        let rotatedGlyph = JournalIconTileGeometry.rotated(path: glyph.cgPath, degrees: rotation, center: center)
        context.addPath(rotatedGlyph)
        context.setStrokeColor(stroke)
        context.setLineWidth(MarkGeometry.glyphLineWidth(for: glyphRect))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        return true
    }

    private static func drawGenericChip(
        center: CGPoint,
        chipSide: CGFloat,
        rotation: CGFloat,
        colorHex: String,
        in context: CGContext
    ) {
        guard let stroke = JournalIconTileGeometry.cgColor(hex: colorHex),
              let fill = JournalIconTileGeometry.cgColor(hex: colorHex, alpha: JournalIconTileGeometry.genericFillOpacity) else {
            return
        }
        let path = JournalIconTileGeometry.chipPath(center: center, side: chipSide, rotationDegrees: rotation)
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(stroke)
        context.setLineWidth(JournalIconTileGeometry.ownerChipBorderWidth(chipSide: chipSide))
        context.setLineDash(phase: 0, lengths: JournalIconTileGeometry.genericDashLengths(chipSide: chipSide))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }

    private static func drawWordPaths(_ paths: [CGPath], in context: CGContext) {
        guard let fill = JournalIconTileGeometry.cgColor(hex: JournalIconTileGeometry.wordInkHex) else {
            return
        }
        context.setFillColor(fill)
        for path in paths {
            context.addPath(path)
            context.fillPath()
        }
    }
}
