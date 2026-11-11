// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What preparing one screenshot produced. The file the journal receives is
/// written only for `.ready`. png, jpeg and webp are copied unchanged. Every
/// other type is turned into a PNG here, in the app's own directory, and the
/// original file is left where it is.
enum ScreenshotPrepareResult: Equatable, Sendable {
    case ready
    case undecodable
    case overLimit
    case retry
}

enum ScreenshotPrepare {
    /// `pdfScale` is the number of pixels per page point. Zero or less means 1.
    /// The app passes the display's backing scale so a PDF page is drawn at
    /// the size the screen would show.
    static func prepare(source: URL, destination: URL, pdfScale: CGFloat) -> ScreenshotPrepareResult {
        let header: Data
        do {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            header = try file.read(upToCount: 64) ?? Data()
        } catch {
            return .retry
        }
        let kind = ScreenshotBytes.kind(header: header)
        if kind.accepted {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                return .ready
            } catch {
                return .retry
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: source, options: [.mappedIfSafe])
        } catch {
            return .retry
        }
        let png: Data?
        if kind == .pdf {
            png = renderPDF(data, scale: pdfScale)
        } else {
            png = imageIOToPNG(data)
        }
        guard let png, png.count >= 8, ScreenshotBytes.kind(header: png) == .png else {
            return .undecodable
        }
        if exceedsContract(png) { return .overLimit }
        do {
            try png.write(to: destination, options: .atomic)
            return .ready
        } catch {
            return .retry
        }
    }

    /// A converted PNG the journal will not keep: over 64 MiB, or over 100 megapixels.
    static func exceedsContract(_ png: Data) -> Bool {
        if png.count > ScreenshotBytes.maxBytes { return true }
        if let pixels = ScreenshotBytes.pixelCount(data: png), pixels > ScreenshotBytes.maxPixels { return true }
        return false
    }

    /// `.ready` still has to be uploaded. The other results are the answer
    /// itself: a file that cannot be converted, or that comes out too big, is
    /// final; a read that failed can be tried again.
    static func answer(for result: ScreenshotPrepareResult) -> ScreenshotAnswer? {
        switch result {
        case .ready: return nil
        case .undecodable, .overLimit: return .invalid
        case .retry: return .retry
        }
    }

    static func displayBackingScale() async -> CGFloat {
        let scale = await MainActor.run { NSScreen.screens.first?.backingScaleFactor ?? 1 }
        return scale > 0 ? scale : 1
    }

    private static func imageIOToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        switch CGImageSourceGetStatus(source) {
        case .statusInvalidData, .statusUnknownType, .statusUnexpectedEOF:
            return nil
        case .statusComplete, .statusIncomplete, .statusReadingHeader:
            break
        @unknown default:
            break
        }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        // No property dictionary: ImageIO copies the source metadata, including
        // EXIF, XMP and the colour profile, into the PNG.
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let png = out as Data
        return png.isEmpty ? nil : png
    }

    /// The first page, at its crop box (or the media box when the crop box is
    /// empty), times `scale`. A page rotated 90 or 270 degrees swaps width and
    /// height. The page is drawn with Core Graphics into an opaque bitmap.
    private static func renderPDF(_ data: Data, scale: CGFloat) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages >= 1,
              let page = document.page(at: 1) else { return nil }
        let crop = page.getBoxRect(.cropBox)
        let boxKind: CGPDFBox = (crop.width > 0 && crop.height > 0) ? .cropBox : .mediaBox
        let box = page.getBoxRect(boxKind)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let swapped = rotation == 90 || rotation == 270
        let pointWidth = swapped ? box.height : box.width
        let pointHeight = swapped ? box.width : box.height
        let factor = scale > 0 ? scale : 1
        let width = max(1, Int((pointWidth * factor).rounded()))
        let height = max(1, Int((pointHeight * factor).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.saveGState()
        context.scaleBy(x: factor, y: factor)
        let transform = page.getDrawingTransform(
            boxKind,
            rect: CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight),
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        return pngData(image)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let png = out as Data
        return png.isEmpty ? nil : png
    }
}
