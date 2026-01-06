// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreGraphics
import CoreVideo
import Accelerate

/// Converts CGImage to CVPixelBuffer in YCbCr 4:2:0 bi-planar format for HEVC encoding
public final class ImageConverter: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var pixelBufferPool: CVPixelBufferPool?
    private let lock = NSLock()

    /// Creates an image converter for the specified dimensions
    /// - Parameters:
    ///   - width: Output width in pixels
    ///   - height: Output height in pixels
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixelBufferPool = createPixelBufferPool(width: width, height: height)
    }

    /// Converts a CGImage to a CVPixelBuffer in YCbCr 4:2:0 bi-planar format
    /// - Parameter image: The CGImage to convert
    /// - Returns: CVPixelBuffer suitable for HEVC encoding, or nil if conversion fails
    public func convert(_ image: CGImage) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }

        // Get pixel buffer from pool
        var pixelBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }

        // Fallback to direct allocation if pool fails
        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            CVPixelBufferCreate(
                nil,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }

        guard let buffer = pixelBuffer else {
            Log.error("ImageConverter: Failed to create pixel buffer")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        // Convert CGImage to YCbCr 4:2:0
        guard convertToYCbCr(image: image, pixelBuffer: buffer) else {
            Log.error("ImageConverter: Failed to convert image to YCbCr")
            return nil
        }

        return buffer
    }

    /// Creates a pixel buffer pool for efficient buffer reuse
    private func createPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )

        if status != kCVReturnSuccess {
            Log.warn("ImageConverter: Failed to create pixel buffer pool: \(status)")
            return nil
        }

        return pool
    }

    /// Converts CGImage to YCbCr 4:2:0 bi-planar format in the pixel buffer
    /// Uses ITU-R BT.709 color matrix (standard for HD video)
    private func convertToYCbCr(image: CGImage, pixelBuffer: CVPixelBuffer) -> Bool {
        let imageWidth = image.width
        let imageHeight = image.height

        // Create ARGB context to draw the CGImage
        let bytesPerRow = imageWidth * 4
        guard let context = CGContext(
            data: nil,
            width: imageWidth,
            height: imageHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return false
        }

        // Draw image (flipping vertically as CGImage origin is bottom-left)
        context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        guard let argbData = context.data else {
            return false
        }

        // Get pointers to Y and CbCr planes
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return false
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        // Use the actual output dimensions (may differ from image dimensions)
        let outWidth = min(imageWidth, width)
        let outHeight = min(imageHeight, height)

        let srcPtr = argbData.assumingMemoryBound(to: UInt8.self)
        let yPtr = yPlane.assumingMemoryBound(to: UInt8.self)
        let cbcrPtr = cbcrPlane.assumingMemoryBound(to: UInt8.self)

        // ITU-R BT.709 coefficients for full range (0-255)
        // Y  = 0.2126 * R + 0.7152 * G + 0.0722 * B
        // Cb = -0.1146 * R - 0.3854 * G + 0.5 * B + 128
        // Cr = 0.5 * R - 0.4187 * G - 0.0813 * B + 128

        // Process each row
        for y in 0..<outHeight {
            let srcRowOffset = y * bytesPerRow
            let yRowOffset = y * yBytesPerRow

            // Process Y for every pixel
            for x in 0..<outWidth {
                // BGRA format (byte order 32 little with skip first = BGRA in memory)
                let pixelOffset = srcRowOffset + x * 4
                let b = Int(srcPtr[pixelOffset])
                let g = Int(srcPtr[pixelOffset + 1])
                let r = Int(srcPtr[pixelOffset + 2])
                // Alpha at pixelOffset + 3, ignored

                // Calculate Y using fixed-point arithmetic (8-bit precision)
                // Y = 16 + 65.481 * R + 128.553 * G + 24.966 * B (for limited range)
                // For full range: Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
                let yVal = (54 * r + 183 * g + 18 * b) >> 8  // Approximation of BT.709
                yPtr[yRowOffset + x] = UInt8(min(255, max(0, yVal)))
            }
        }

        // Process CbCr for every 2x2 block (4:2:0 subsampling)
        let cbcrHeight = outHeight / 2
        let cbcrWidth = outWidth / 2

        for y in 0..<cbcrHeight {
            let srcRow0Offset = (y * 2) * bytesPerRow
            let srcRow1Offset = (y * 2 + 1) * bytesPerRow
            let cbcrRowOffset = y * cbcrBytesPerRow

            for x in 0..<cbcrWidth {
                // Average 2x2 block of pixels for Cb and Cr
                var rSum = 0
                var gSum = 0
                var bSum = 0

                // Top-left
                var pixelOffset = srcRow0Offset + (x * 2) * 4
                bSum += Int(srcPtr[pixelOffset])
                gSum += Int(srcPtr[pixelOffset + 1])
                rSum += Int(srcPtr[pixelOffset + 2])

                // Top-right
                pixelOffset = srcRow0Offset + (x * 2 + 1) * 4
                bSum += Int(srcPtr[pixelOffset])
                gSum += Int(srcPtr[pixelOffset + 1])
                rSum += Int(srcPtr[pixelOffset + 2])

                // Bottom-left
                pixelOffset = srcRow1Offset + (x * 2) * 4
                bSum += Int(srcPtr[pixelOffset])
                gSum += Int(srcPtr[pixelOffset + 1])
                rSum += Int(srcPtr[pixelOffset + 2])

                // Bottom-right
                pixelOffset = srcRow1Offset + (x * 2 + 1) * 4
                bSum += Int(srcPtr[pixelOffset])
                gSum += Int(srcPtr[pixelOffset + 1])
                rSum += Int(srcPtr[pixelOffset + 2])

                // Average
                let r = rSum / 4
                let g = gSum / 4
                let b = bSum / 4

                // Calculate Cb and Cr (BT.709 full range)
                // Cb = 128 - 0.1146 * R - 0.3854 * G + 0.5 * B
                // Cr = 128 + 0.5 * R - 0.4187 * G - 0.0813 * B
                let cb = 128 + ((-29 * r - 99 * g + 128 * b) >> 8)
                let cr = 128 + ((128 * r - 107 * g - 21 * b) >> 8)

                // CbCr interleaved
                cbcrPtr[cbcrRowOffset + x * 2] = UInt8(min(255, max(0, cb)))
                cbcrPtr[cbcrRowOffset + x * 2 + 1] = UInt8(min(255, max(0, cr)))
            }
        }

        return true
    }
}
