// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreImage
import Foundation

enum JournalQRImage {
    enum QRImageError: Error, Equatable {
        case filterUnavailable
        case outputUnavailable
        case imageCreationFailed
    }

    static let targetPixelSize = 256

    static func make(from string: String) throws -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw QRImageError.filterUnavailable
        }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else {
            throw QRImageError.outputUnavailable
        }
        let context = CIContext()
        guard let source = context.createCGImage(output, from: output.extent) else {
            throw QRImageError.imageCreationFailed
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(
            data: nil,
            width: targetPixelSize,
            height: targetPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw QRImageError.imageCreationFailed
        }

        let rect = CGRect(x: 0, y: 0, width: targetPixelSize, height: targetPixelSize)
        bitmap.interpolationQuality = .none
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(rect)
        bitmap.draw(source, in: rect)

        guard let scaled = bitmap.makeImage() else {
            throw QRImageError.imageCreationFailed
        }
        return NSImage(
            cgImage: scaled,
            size: NSSize(width: targetPixelSize, height: targetPixelSize)
        )
    }
}
