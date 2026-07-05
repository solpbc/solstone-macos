// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

public enum JournalIconSVGPathData {
    public static func string(from path: CGPath, precision: Int = 3) -> String {
        var segments: [String] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                segments.append("M\(format(points[0].x, precision: precision)) \(format(points[0].y, precision: precision))")
            case .addLineToPoint:
                segments.append("L\(format(points[0].x, precision: precision)) \(format(points[0].y, precision: precision))")
            case .addQuadCurveToPoint:
                segments.append(
                    "Q\(format(points[0].x, precision: precision)) \(format(points[0].y, precision: precision)) "
                        + "\(format(points[1].x, precision: precision)) \(format(points[1].y, precision: precision))"
                )
            case .addCurveToPoint:
                segments.append(
                    "C\(format(points[0].x, precision: precision)) \(format(points[0].y, precision: precision)) "
                        + "\(format(points[1].x, precision: precision)) \(format(points[1].y, precision: precision)) "
                        + "\(format(points[2].x, precision: precision)) \(format(points[2].y, precision: precision))"
                )
            case .closeSubpath:
                segments.append("Z")
            @unknown default:
                break
            }
        }
        return segments.joined(separator: " ")
    }

    public static func format(_ value: CGFloat, precision: Int = 3) -> String {
        let rounded = abs(value) < 0.000_5 ? 0 : Double(value)
        var text = String(format: "%.\(precision)f", rounded)
        while text.contains("."), text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text == "-0" ? "0" : text
    }
}
