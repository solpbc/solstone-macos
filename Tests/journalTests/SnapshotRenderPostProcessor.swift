// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct SnapshotBitmap: Sendable {
    let bytes: [UInt8]
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let width: Int
    let height: Int
}

enum SnapshotRenderPostProcessor {
    static func writePNGAndValidateContent<ContentError: Error & Sendable>(
        pngData: Data,
        outputURL: URL,
        filename: String,
        bitmap: SnapshotBitmap?,
        emptyContent: @escaping @Sendable (_ filename: String, _ contentPixelCount: Int, _ minimum: Int) -> ContentError
    ) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outputURL)

            guard let bitmap else { return }
            guard bitmap.bytesPerPixel >= 3, bitmap.width > 0, bitmap.height > 0 else { return }

            let backgroundPixel = bitmap.bytes
            let epsilon = 8
            let minimumContentPixels = 400
            var contentPixelCount = 0
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let offset = y * bitmap.bytesPerRow + x * bitmap.bytesPerPixel
                    if abs(Int(bitmap.bytes[offset]) - Int(backgroundPixel[0])) > epsilon ||
                        abs(Int(bitmap.bytes[offset + 1]) - Int(backgroundPixel[1])) > epsilon ||
                        abs(Int(bitmap.bytes[offset + 2]) - Int(backgroundPixel[2])) > epsilon {
                        contentPixelCount += 1
                    }
                }
            }
            if contentPixelCount < minimumContentPixels {
                throw emptyContent(filename, contentPixelCount, minimumContentPixels)
            }
        }.value
    }
}
