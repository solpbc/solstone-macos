// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreGraphics
import CoreVideo
@preconcurrency import Accelerate

/// Converts CGImage to CVPixelBuffer in YCbCr 4:2:0 bi-planar format for HEVC encoding
/// Uses vImage for SIMD-accelerated colorspace conversion
public final class ImageConverter: @unchecked Sendable {
    private let width: Int
    private let height: Int
    private var pixelBufferPool: CVPixelBufferPool?
    private let lock = NSLock()

    /// Reusable ARGB buffer for intermediate conversion
    private var argbBuffer: vImage_Buffer?
    private var argbData: UnsafeMutableRawPointer?

    /// Cached vImage conversion matrix (expensive to generate)
    private var conversionMatrix: vImage_ARGBToYpCbCr?

    /// Creates an image converter for the specified dimensions
    /// - Parameters:
    ///   - width: Output width in pixels
    ///   - height: Output height in pixels
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixelBufferPool = createPixelBufferPool(width: width, height: height)

        // Pre-allocate ARGB buffer
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height
        self.argbData = UnsafeMutableRawPointer.allocate(byteCount: dataSize, alignment: 16)
        self.argbBuffer = vImage_Buffer(
            data: argbData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
    }

    deinit {
        argbData?.deallocate()
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

        // Convert CGImage to YCbCr 4:2:0 using vImage
        guard convertToYCbCrWithVImage(image: image, pixelBuffer: buffer) else {
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

    /// Converts CGImage to YCbCr 4:2:0 bi-planar format using vImage
    /// Uses SIMD-accelerated conversion for optimal performance
    private func convertToYCbCrWithVImage(image: CGImage, pixelBuffer: CVPixelBuffer) -> Bool {
        guard var argbBuffer = argbBuffer else { return false }

        let imageWidth = image.width
        let imageHeight = image.height
        let outWidth = min(imageWidth, width)
        let outHeight = min(imageHeight, height)

        // Draw CGImage into our pre-allocated ARGB buffer
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: argbBuffer.data,
            width: outWidth,
            height: outHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return false
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        // Update buffer dimensions for actual image size
        argbBuffer.width = vImagePixelCount(outWidth)
        argbBuffer.height = vImagePixelCount(outHeight)

        // Get pointers to Y and CbCr planes
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return false
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        // Create vImage buffers for output planes
        var yBuffer = vImage_Buffer(
            data: yPlane,
            height: vImagePixelCount(outHeight),
            width: vImagePixelCount(outWidth),
            rowBytes: yBytesPerRow
        )

        var cbcrBuffer = vImage_Buffer(
            data: cbcrPlane,
            height: vImagePixelCount(outHeight / 2),
            width: vImagePixelCount(outWidth / 2),
            rowBytes: cbcrBytesPerRow
        )

        // Use vImage to convert ARGB to YCbCr 4:2:0
        // BGRA (byte order 32 little with skip first) -> Y'CbCr
        // permuteMap reorders BGRA to ARGB for vImage (which expects ARGB)
        let permuteMap: [UInt8] = [3, 2, 1, 0]  // BGRA -> ARGB

        // Create conversion matrix on first use (expensive, so cache it)
        if conversionMatrix == nil {
            var info = vImage_YpCbCrPixelRange(
                Yp_bias: 0,
                CbCr_bias: 128,
                YpRangeMax: 255,
                CbCrRangeMax: 255,
                YpMax: 255,
                YpMin: 0,
                CbCrMax: 255,
                CbCrMin: 0
            )

            var matrix = vImage_ARGBToYpCbCr()
            let error = vImageConvert_ARGBToYpCbCr_GenerateConversion(
                kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
                &info,
                &matrix,
                kvImageARGB8888,
                kvImage420Yp8_CbCr8,
                vImage_Flags(kvImageNoFlags)
            )

            guard error == kvImageNoError else {
                Log.error("ImageConverter: Failed to generate conversion matrix: \(error)")
                return false
            }
            conversionMatrix = matrix
        }

        guard var matrix = conversionMatrix else { return false }

        // Convert BGRA to YCbCr 4:2:0 with permutation
        let error = vImageConvert_ARGB8888To420Yp8_CbCr8(
            &argbBuffer,
            &yBuffer,
            &cbcrBuffer,
            &matrix,
            permuteMap,
            vImage_Flags(kvImageNoFlags)
        )

        guard error == kvImageNoError else {
            Log.error("ImageConverter: vImage conversion failed: \(error)")
            return false
        }

        return true
    }
}
