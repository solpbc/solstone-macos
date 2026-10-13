// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// Reads back the pixels of a rendered image so icon and mark tests can check alpha and color.
public struct RGBASnapshot {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: Data

    public init?(image: CGImage) {
        let pixelWidth = image.width
        let pixelHeight = image.height
        let rowBytes = pixelWidth * 4
        var buffer = Data(count: rowBytes * pixelHeight)
        let rendered = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let baseAddress = pointer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard rendered else { return nil }
        width = pixelWidth
        height = pixelHeight
        bytesPerRow = rowBytes
        self.data = buffer
    }

    public func alphaAt(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return data[y * bytesPerRow + x * 4 + 3]
    }

    public func hasNonTransparentPixel() -> Bool {
        stride(from: 3, to: data.count, by: 4).contains { data[$0] > 0 }
    }

    public func containsColor(hex: String, near point: CGPoint, radius: Int, tolerance: Int = 28) -> Bool {
        guard let expected = rgb(hex: hex) else { return false }
        let candidates = [
            CGPoint(x: point.x, y: point.y),
            CGPoint(x: point.x, y: CGFloat(height - 1) - point.y)
        ]
        for candidate in candidates {
            let minX = max(Int(candidate.x.rounded()) - radius, 0)
            let maxX = min(Int(candidate.x.rounded()) + radius, width - 1)
            let minY = max(Int(candidate.y.rounded()) - radius, 0)
            let maxY = min(Int(candidate.y.rounded()) + radius, height - 1)
            for y in minY...maxY {
                for x in minX...maxX {
                    let index = y * bytesPerRow + x * 4
                    guard data[index + 3] > 180 else { continue }
                    if abs(Int(data[index]) - expected.red) <= tolerance,
                       abs(Int(data[index + 1]) - expected.green) <= tolerance,
                       abs(Int(data[index + 2]) - expected.blue) <= tolerance {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func rgb(hex: String) -> (red: Int, green: Int, blue: Int)? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = Int(trimmed, radix: 16) else {
            return nil
        }
        return (
            red: (value >> 16) & 0xff,
            green: (value >> 8) & 0xff,
            blue: value & 0xff
        )
    }
}
