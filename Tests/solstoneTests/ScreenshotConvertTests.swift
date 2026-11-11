// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import solstone

@Suite("Screenshot conversion")
struct ScreenshotConvertTests {
    @Test func acceptedPngJpegAndWebpStayByteForByte() throws {
        let image = try #require(Self.solid(red: 0.2, green: 0.4, blue: 0.6))
        let png = try Self.encode(image, type: .png, metadata: false)
        let jpeg = try Self.encode(image, type: .jpeg, metadata: false)
        var webp = Data(count: 32)
        webp.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        webp.replaceSubrange(8..<12, with: Array("WEBP".utf8))
        webp.append(contentsOf: [9, 8, 7, 6])
        for (name, bytes) in [("shot.png", png), ("shot.jpg", jpeg), ("shot.webp", webp)] {
            let (source, destination, root) = try Self.pair(name)
            try bytes.write(to: source)
            let result = ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2)
            #expect(result == .ready)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Self.names(in: source.deletingLastPathComponent()) == [name])
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func tiffKeepsExifMakeXmpAndColour() throws {
        try assertMetadataRoundTrip(type: .tiff, name: "shot.tiff")
    }

    @Test func heicKeepsWhateverTheSourceStored() throws {
        try assertMetadataRoundTrip(type: .heic, name: "shot.heic")
    }

    @Test func gifBecomesPng() throws {
        let image = try #require(Self.solid(red: 0, green: 1, blue: 0))
        let gif = try Self.encode(image, type: .gif, metadata: false)
        let (source, destination, root) = try Self.pair("shot.gif")
        defer { try? FileManager.default.removeItem(at: root) }
        try gif.write(to: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .ready)
        let png = try Data(contentsOf: destination)
        #expect(ScreenshotBytes.kind(header: png) == .png)
        #expect(try Self.pixelSize(png) == Self.pixelSize(gif))
        #expect(try Data(contentsOf: source) == gif)
    }

    @Test func otherImageBecomesPng() throws {
        let image = try #require(Self.solid(red: 0, green: 0, blue: 1))
        let bmp = try Self.encode(image, type: .bmp, metadata: false)
        let (source, destination, root) = try Self.pair("shot.bmp")
        defer { try? FileManager.default.removeItem(at: root) }
        try bmp.write(to: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .ready)
        let png = try Data(contentsOf: destination)
        #expect(ScreenshotBytes.kind(header: png) == .png)
        #expect(try Self.pixelSize(png) == Self.pixelSize(bmp))
    }

    @Test func pdfFirstPageIsDrawnAtTheGivenScale() throws {
        let pdf = Self.redPDF(width: 20, height: 10)
        let (source, destination, root) = try Self.pair("shot.pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        try pdf.write(to: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .ready)
        let png = try Data(contentsOf: destination)
        #expect(try Self.pixelSize(png) == (40, 20))
        let sample = try Self.pixel(png, x: 20, y: 10)
        #expect(sample.0 > 200)
        #expect(sample.1 < 40)
        #expect(sample.2 < 40)
        #expect(try Data(contentsOf: source) == pdf)
    }

    @Test func aRotatedPdfSwapsItsSidesAndAZeroScaleMeansOne() throws {
        let pdf = Self.pdf(media: CGRect(x: 0, y: 0, width: 30, height: 10), rotate: 90)
        let (source, destination, root) = try Self.pair("turned.pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        try pdf.write(to: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .ready)
        #expect(try Self.pixelSize(Data(contentsOf: destination)) == (20, 60))

        let (again, flat, _) = try Self.pair("flat.pdf", root: root)
        try Self.redPDF(width: 20, height: 10).write(to: again)
        #expect(ScreenshotPrepare.prepare(source: again, destination: flat, pdfScale: 0) == .ready)
        #expect(try Self.pixelSize(Data(contentsOf: flat)) == (20, 10))
    }

    @Test func garbageIsFinalAndAMissingFileCanBeTriedAgain() throws {
        let (source, destination, root) = try Self.pair("shot.heic")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0xAB, count: 80).write(to: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .undecodable)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let missing = source.deletingLastPathComponent().appendingPathComponent("gone.tiff")
        #expect(ScreenshotPrepare.prepare(source: missing, destination: destination, pdfScale: 2) == .retry)
    }

    @Test func theSizeGateReadsTheConvertedPng() {
        #expect(ScreenshotPrepare.exceedsContract(ScreenshotBytes.pngHeader(width: 20_000, height: 20_000)))
        var heavy = Data([0x89, 0x50, 0x4E, 0x47])
        heavy.append(Data(count: ScreenshotBytes.maxBytes))
        #expect(ScreenshotPrepare.exceedsContract(heavy))
        #expect(!ScreenshotPrepare.exceedsContract(ScreenshotBytes.pngHeader(width: 2, height: 3)))
        #expect(ScreenshotPrepare.answer(for: .undecodable) == .invalid)
        #expect(ScreenshotPrepare.answer(for: .overLimit) == .invalid)
        #expect(ScreenshotPrepare.answer(for: .retry) == .retry)
        #expect(ScreenshotPrepare.answer(for: .ready) == nil)
    }

    private func assertMetadataRoundTrip(type: UTType, name: String) throws {
        let image = try #require(Self.solid(red: 1, green: 0.5, blue: 0))
        let encoded = try Self.encode(image, type: type, metadata: true)
        let (source, destination, root) = try Self.pair(name)
        defer { try? FileManager.default.removeItem(at: root) }
        try encoded.write(to: source)
        let before = try Data(contentsOf: source)
        #expect(ScreenshotPrepare.prepare(source: source, destination: destination, pdfScale: 2) == .ready)
        #expect(try Data(contentsOf: source) == before)
        let png = try Data(contentsOf: destination)
        #expect(ScreenshotBytes.kind(header: png) == .png)
        let sourceProps = try #require(Self.properties(before))
        let pngProps = try #require(Self.properties(png))
        try Self.expectStoredText(sourceProps, survivedIn: pngProps, bag: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifUserComment)
        try Self.expectStoredText(sourceProps, survivedIn: pngProps, bag: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFMake)
        let sourceXMP = Self.xmp(before)
        let pngXMP = Self.xmp(png)
        for marker in ["kept-make", "kept-comment"] where sourceXMP.contains(marker) {
            #expect(pngXMP.contains(marker), "png xmp missing \(marker): \(pngXMP)")
        }
        let sourceColour = Self.colourName(before)
        if sourceColour != nil {
            #expect(Self.colourName(png) == sourceColour, "png colour \(String(describing: Self.colourName(png))) source \(String(describing: sourceColour))")
        }
        let exif = Self.nested(sourceProps, kCGImagePropertyExifDictionary)
        let tiffBag = Self.nested(sourceProps, kCGImagePropertyTIFFDictionary)
        #expect(exif[kCGImagePropertyExifUserComment as String] as? String == "kept-comment", "\(type.identifier) exif \(exif) xmp \(sourceXMP)")
        #expect(tiffBag[kCGImagePropertyTIFFMake as String] as? String == "kept-make", "\(type.identifier) tiff \(tiffBag)")
        #expect(sourceXMP.contains("kept-make") && sourceXMP.contains("kept-comment"), "\(type.identifier) xmp \(sourceXMP)")
        #expect(sourceColour == (CGColorSpace.sRGB as String), "\(type.identifier) colour \(String(describing: sourceColour))")
    }

    private static func expectStoredText(
        _ source: [String: Any],
        survivedIn png: [String: Any],
        bag: CFString,
        key: CFString
    ) throws {
        let stored = nested(source, bag)[key as String] as? String
        guard let stored else { return }
        #expect(nested(png, bag)[key as String] as? String == stored, "\(key) missing from \(nested(png, bag))")
    }

    private static func solid(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let colour = CGColor(colorSpace: space, components: [red, green, blue, 1]) else { return nil }
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, metadata: Bool) throws -> Data {
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        if metadata {
            var props: [CFString: Any] = [:]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "kept-comment"]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "kept-make"]
            let meta = CGImageMetadataCreateMutable()
            let tag = try #require(CGImageMetadataTagCreate(
                "http://ns.adobe.com/xap/1.0/" as CFString,
                "xmp" as CFString,
                "CreatorTool" as CFString,
                .string,
                "kept-xmp" as CFString
            ))
            #expect(CGImageMetadataSetTagWithPath(meta, nil, "xmp:CreatorTool" as CFString, tag))
            CGImageDestinationAddImageAndMetadata(destination, image, meta, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        let data = out as Data
        try #require(!data.isEmpty)
        return data
    }

    private static func redPDF(width: CGFloat, height: CGFloat) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return out as Data
    }

    /// A one-page PDF with a /Rotate entry. Core Graphics' PDF writer has no
    /// key for that entry, so the bytes are written directly.
    private static func pdf(media: CGRect, rotate: Int) -> Data {
        let header = "%PDF-1.4\n"
        let objects = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [\(Self.num(media.minX)) \(Self.num(media.minY)) \(Self.num(media.maxX)) \(Self.num(media.maxY))] /Rotate \(rotate) >>\nendobj\n",
        ]
        var body = Data(header.utf8)
        var offsets = [0]
        for object in objects {
            offsets.append(body.count)
            body.append(contentsOf: object.utf8)
        }
        let start = body.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        body.append(contentsOf: xref.utf8)
        return body
    }

    private static func num(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }

    private static func properties(_ data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return raw
    }

    private static func nested(_ props: [String: Any], _ key: CFString) -> [String: Any] {
        props[key as String] as? [String: Any] ?? [:]
    }

    private static func xmp(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let packet = CGImageMetadataCreateXMPData(metadata, nil) else { return "" }
        return String(decoding: packet as Data, as: UTF8.self)
    }

    private static func colourName(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.colorSpace?.name as String?
    }

    private static func pixelSize(_ data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private static func pixel(_ data: Data, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        let index = (y * image.width + x) * 4
        return (buffer[index], buffer[index + 1], buffer[index + 2])
    }

    private static func pair(_ name: String, root: URL? = nil) throws -> (URL, URL, URL) {
        let directory = try root ?? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("shot-convert-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()
        let sourceDir = directory.appendingPathComponent("src-\(name)", isDirectory: true)
        let destDir = directory.appendingPathComponent("out-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        return (sourceDir.appendingPathComponent(name), destDir.appendingPathComponent("screenshot_screen.png"), directory)
    }

    private static func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
    }
}
