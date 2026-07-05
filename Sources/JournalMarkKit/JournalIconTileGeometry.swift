// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

public struct JournalIconChipLayout {
    public let centers: [CGPoint]
    public let side: CGFloat
    let combinedBounds: CGRect
}

public enum JournalIconTileGeometry {
    static let referenceSide: CGFloat = 100
    static let chipSideRatio: CGFloat = 0.27
    static let chipCenterYRatio: CGFloat = 0.34
    static let ownerWordBaselineRatio: CGFloat = 0.70
    static let secondWordBaselineRatio: CGFloat = 0.86

    static let plateFillHex = "#FAF3E4"
    public static let wordInkHex = "#3F3830"
    public static let genericChip1Hex = "#E8923A"
    public static let genericChip2Hex = "#D4A017"
    static let genericFillOpacity: CGFloat = 0.07

    static let platePathD = "M 527.36 0 c 103.834 0 155.751 0 195.41 20.207 a 185.4 185.4 0 0 1 81.023 81.023 c 20.207 39.659 20.207 91.576 20.207 195.41 L 824 527.36 c 0 103.834 0 155.751 -20.207 195.41 a 185.4 185.4 0 0 1 -81.023 81.023 c -39.659 20.207 -91.576 20.207 -195.41 20.207 L 296.64 824 c -103.834 0 -155.751 0 -195.41 -20.207 a 185.4 185.4 0 0 1 -81.023 -81.023 c -20.207 -39.659 -20.207 -91.576 -20.207 -195.41 L 0 296.64 c 0 -103.834 0 -155.751 20.207 -195.41 a 185.4 185.4 0 0 1 81.023 -81.023 c 39.659 -20.207 91.576 -20.207 195.41 -20.207 Z"
    public static var platePathElement: String {
        ##"<path fill="#FAF3E4" transform="translate(100,100)" d="\##(platePathD)"/>"##
    }

    public static func chipLayout(tileSide: CGFloat, rotations: [CGFloat]) -> JournalIconChipLayout? {
        guard tileSide > 0, rotations.count == 2 else { return nil }
        let side = chipSide(tileSide: tileSide)
        let gap = chipGap(chipSide: side)
        let centerY = chipCenterY(tileSide: tileSide)
        let separation = side + gap
        let initialCenters = [
            CGPoint(x: tileSide * 0.5 - separation / 2, y: centerY),
            CGPoint(x: tileSide * 0.5 + separation / 2, y: centerY)
        ]

        let initialBounds = zip(initialCenters, rotations).map {
            rotatedSquareBounds(center: $0.0, side: side, degrees: $0.1)
        }
        let combined = initialBounds.dropFirst().reduce(initialBounds[0]) { $0.union($1) }
        let shiftX = tileSide * 0.5 - combined.midX
        let centers = initialCenters.map { CGPoint(x: $0.x + shiftX, y: $0.y) }
        let shiftedBounds = zip(centers, rotations).map {
            rotatedSquareBounds(center: $0.0, side: side, degrees: $0.1)
        }
        let shiftedCombined = shiftedBounds.dropFirst().reduce(shiftedBounds[0]) { $0.union($1) }
        return JournalIconChipLayout(centers: centers, side: side, combinedBounds: shiftedCombined)
    }

    static func chipSide(tileSide: CGFloat) -> CGFloat {
        tileSide * chipSideRatio
    }

    static func chipRadius(chipSide: CGFloat) -> CGFloat {
        // Derived from MarkGeometry so icon chips track the JournalMarkView proportions.
        chipSide * MarkGeometry.chipRadius / MarkGeometry.size
    }

    static func chipGap(chipSide: CGFloat) -> CGFloat {
        // Derived from MarkGeometry so icon chips track the JournalMarkView proportions.
        chipSide * MarkGeometry.iconGap / MarkGeometry.size
    }

    static func ownerFillOpacity() -> CGFloat {
        CGFloat(MarkGeometry.iconFillOpacity)
    }

    static func glyphSide(chipSide: CGFloat) -> CGFloat {
        // Derived from MarkGeometry so icon glyphs track the JournalMarkView proportions.
        chipSide * MarkGeometry.glyphScale
    }

    public static func ownerChipBorderWidth(chipSide: CGFloat) -> CGFloat {
        // Spec-defined icon ratio, distinct from MarkGeometry.chipBorderWidth.
        2 * chipSide / 48
    }

    static func ownerChipBorderWidth(tileSide: CGFloat) -> CGFloat {
        ownerChipBorderWidth(chipSide: chipSide(tileSide: tileSide))
    }

    public static func genericDashLengths(chipSide: CGFloat) -> [CGFloat] {
        [3.2 * chipSide / 27, 2.4 * chipSide / 27]
    }

    static func chipCenterY(tileSide: CGFloat) -> CGFloat {
        tileSide * chipCenterYRatio
    }

    static func ownerWordBaselines(tileSide: CGFloat) -> [CGFloat] {
        [tileSide * ownerWordBaselineRatio, tileSide * secondWordBaselineRatio]
    }

    static func chipRect(center: CGPoint, side: CGFloat) -> CGRect {
        CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    static func glyphRect(center: CGPoint, chipSide: CGFloat) -> CGRect {
        let side = glyphSide(chipSide: chipSide)
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    public static func chipPath(center: CGPoint, side: CGFloat, rotationDegrees: CGFloat) -> CGPath {
        let rect = chipRect(center: center, side: side)
        let radius = chipRadius(chipSide: side)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        return rotated(path: path, degrees: rotationDegrees, center: center)
    }

    static func rotated(path: CGPath, degrees: CGFloat, center: CGPoint) -> CGPath {
        guard degrees != 0 else { return path }
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        return path.copy(using: &transform) ?? path
    }

    static func platePath(tileSide: CGFloat) -> CGPath? {
        guard let path = GlyphParser.parse(
            innerMarkup: #"<path d="\#(platePathD)" />"#,
            in: CGRect(x: 100, y: 100, width: 24, height: 24)
        ) else {
            return nil
        }
        var transform = CGAffineTransform(scaleX: tileSide / 1024, y: tileSide / 1024)
        return path.cgPath.copy(using: &transform)
    }

    static func cgColor(hex: String, alpha: CGFloat = 1) -> CGColor? {
        guard let components = rgbComponents(hex: hex) else { return nil }
        return CGColor(
            red: components.red,
            green: components.green,
            blue: components.blue,
            alpha: alpha
        )
    }

    private static func rgbComponents(hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = Int(trimmed, radix: 16) else {
            return nil
        }
        return (
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255
        )
    }

    private static func rotatedSquareBounds(center: CGPoint, side: CGFloat, degrees: CGFloat) -> CGRect {
        let radians = abs(degrees) * .pi / 180
        let width = side * (abs(cos(radians)) + abs(sin(radians)))
        return CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width)
    }
}
