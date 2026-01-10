// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import CoreVideo
import Foundation
import SolstoneCaptureCore

/// Writes video frames received from a persistent SCStream to an MP4 file
/// Frames are received via appendFrame() callback, not captured directly
@MainActor
public final class VideoFrameWriter {
    public let displayID: CGDirectDisplayID
    private let videoWriter: VideoWriter
    private let verbose: Bool

    private let captureStartTime: Date
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0

    /// Hash of the previous frame for duplicate detection
    private var previousFrameHash: UInt64 = 0

    /// Creates a video frame writer for a single display
    /// - Parameters:
    ///   - displayID: The display ID this writer handles
    ///   - videoURL: Output URL for video file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate for video (used for encoding settings)
    ///   - duration: Capture duration in seconds
    ///   - verbose: Enable verbose logging
    /// - Throws: Error if writer creation fails
    public init(
        displayID: CGDirectDisplayID,
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        verbose: Bool
    ) throws {
        self.displayID = displayID
        self.verbose = verbose
        self.captureStartTime = Date()

        // Create video writer
        self.videoWriter = try VideoWriter.create(
            url: videoURL,
            width: width,
            height: height,
            frameRate: frameRate,
            duration: duration
        )

        Log.debug("VideoFrameWriter: Created for display \(displayID) at \(width)x\(height)", verbose: verbose)
    }

    /// Append a video frame from the stream
    /// - Parameter sampleBuffer: The CMSampleBuffer containing the video frame
    public func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            Log.warn("VideoFrameWriter: Failed to get pixel buffer from sample buffer for display \(displayID)")
            return
        }

        // Check if frame has changed using hash
        let currentHash = computeFrameHash(pixelBuffer)
        if currentHash == previousFrameHash && previousFrameHash != 0 {
            // Frame unchanged, skip encoding
            skippedFrames += 1
            if verbose {
                Log.debug("VideoFrameWriter: Display \(displayID) skipped duplicate frame (total skipped: \(skippedFrames))", verbose: true)
            }
            return
        }

        // Frame changed, encode it
        previousFrameHash = currentHash

        // Calculate presentation time based on elapsed time
        let elapsed = Date().timeIntervalSince(captureStartTime)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

        videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
        frameIndex += 1

        if verbose {
            Log.debug("VideoFrameWriter: Display \(displayID) frame #\(frameIndex) at \(String(format: "%.3f", elapsed))s", verbose: true)
        }
    }

    /// Computes a fast hash of a CVPixelBuffer by sampling pixels
    /// Uses FNV-1a hash on sampled pixel data for speed
    private func computeFrameHash(_ pixelBuffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return 0
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let length = bytesPerRow * height

        guard length > 0 else { return 0 }

        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        // FNV-1a hash with sampling (sample ~4096 points for speed)
        var hash: UInt64 = 14695981039346656037  // FNV offset basis
        let sampleInterval = max(1, length / 4096)

        for i in stride(from: 0, to: length, by: sampleInterval) {
            hash ^= UInt64(ptr[i])
            hash = hash &* 1099511628211  // FNV prime
        }

        return hash
    }

    /// Stops accepting frames and logs statistics
    public func stop() {
        let totalFrames = frameIndex + skippedFrames
        let skipPercent = totalFrames > 0 ? (skippedFrames * 100) / totalFrames : 0
        Log.info("VideoFrameWriter: Stopped for display \(displayID) - \(frameIndex) frames encoded, \(skippedFrames) duplicates skipped (\(skipPercent)%)")
    }

    /// Finishes video writing and closes the file
    /// - Parameter completion: Callback with result (URL and frame count on success)
    public func finish(completion: @escaping @Sendable (Result<(URL, Int), Error>) -> Void) {
        stop()
        videoWriter.finish(completion: completion)
    }
}
