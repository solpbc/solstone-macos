// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import SolstoneCaptureCore

/// Captures periodic screenshots for a single display using SCScreenshotManager
@MainActor
public final class ScreenshotCapturer {
    public let displayID: CGDirectDisplayID
    private let videoWriter: VideoWriter
    private let imageConverter: ImageConverter
    private let verbose: Bool

    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var captureTask: Task<Void, Never>?
    private var isRunning = false
    private let captureStartTime: Date
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0

    /// Hash of the previous frame for duplicate detection
    private var previousFrameHash: UInt64 = 0

    /// Creates a screenshot capturer for a single display
    /// - Parameters:
    ///   - displayID: The display ID to capture
    ///   - videoURL: Output URL for video file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate for video (used for encoding settings)
    ///   - duration: Capture duration in seconds
    ///   - contentFilter: Content filter for window exclusion
    ///   - verbose: Enable verbose logging
    /// - Throws: Error if writer creation fails
    public init(
        displayID: CGDirectDisplayID,
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        contentFilter: SCContentFilter,
        verbose: Bool
    ) throws {
        self.displayID = displayID
        self.contentFilter = contentFilter
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

        // Create image converter for this display's dimensions
        self.imageConverter = ImageConverter(width: width, height: height)

        // Configure screenshot capture
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false  // Hide cursor to reduce frame changes
        config.scalesToFit = true   // Scale to specified width/height
        self.configuration = config

        Log.debug("ScreenshotCapturer: Created for display \(displayID) at \(width)x\(height)", verbose: verbose)
    }

    /// Updates the content filter for window exclusion
    /// The updated filter will be used on the next screenshot capture
    public func updateContentFilter(_ filter: SCContentFilter) {
        self.contentFilter = filter
    }

    /// Starts the periodic screenshot capture loop
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        captureTask = Task { @MainActor in
            await captureLoop()
        }

        Log.info("ScreenshotCapturer: Started for display \(displayID)")
    }

    /// Computes a fast hash of a CGImage by sampling pixels
    /// Uses FNV-1a hash on sampled pixel data for speed
    private func computeFrameHash(_ image: CGImage) -> UInt64 {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              CFDataGetLength(data) > 0 else {
            return 0
        }

        let length = CFDataGetLength(data)
        let ptr = CFDataGetBytePtr(data)

        // FNV-1a hash with sampling (every 1024th byte for speed)
        var hash: UInt64 = 14695981039346656037  // FNV offset basis
        let sampleInterval = max(1, length / 4096)  // Sample ~4096 points

        for i in stride(from: 0, to: length, by: sampleInterval) {
            hash ^= UInt64(ptr![i])
            hash = hash &* 1099511628211  // FNV prime
        }

        return hash
    }

    /// Main capture loop - runs at 1fps
    private func captureLoop() async {
        while isRunning && !Task.isCancelled {
            let captureStart = ContinuousClock.now

            do {
                // Capture screenshot
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: configuration
                )

                // Check if frame has changed
                let currentHash = computeFrameHash(image)
                if currentHash == previousFrameHash && previousFrameHash != 0 {
                    // Frame unchanged, skip encoding
                    skippedFrames += 1
                    if verbose {
                        Log.debug("ScreenshotCapturer: Display \(displayID) skipped duplicate frame (total skipped: \(skippedFrames))", verbose: true)
                    }
                } else {
                    // Frame changed, encode it
                    previousFrameHash = currentHash

                    if let pixelBuffer = imageConverter.convert(image) {
                        // Calculate presentation time based on elapsed time
                        let elapsed = Date().timeIntervalSince(captureStartTime)
                        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

                        videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
                        frameIndex += 1

                        if verbose {
                            Log.debug("ScreenshotCapturer: Display \(displayID) frame #\(frameIndex) at \(String(format: "%.3f", elapsed))s", verbose: true)
                        }
                    } else {
                        Log.warn("ScreenshotCapturer: Failed to convert image for display \(displayID)")
                    }
                }
            } catch {
                // Log but continue - transient failures shouldn't stop capture
                Log.warn("ScreenshotCapturer: Capture failed for display \(displayID): \(error)")
            }

            // Sleep until next capture interval (accounting for capture time)
            let elapsed = ContinuousClock.now - captureStart
            let remaining = Duration.seconds(1) - elapsed
            if remaining > .zero {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    // Task was cancelled
                    break
                }
            }
        }
    }

    /// Stops the capture loop
    public func stop() async {
        isRunning = false
        captureTask?.cancel()
        if let task = captureTask {
            await task.value
        }
        captureTask = nil
        let totalFrames = frameIndex + skippedFrames
        let skipPercent = totalFrames > 0 ? (skippedFrames * 100) / totalFrames : 0
        Log.info("ScreenshotCapturer: Stopped for display \(displayID) - \(frameIndex) frames encoded, \(skippedFrames) duplicates skipped (\(skipPercent)%)")
    }

    /// Finishes video writing and closes the file
    /// - Parameter completion: Callback with result (URL and frame count on success)
    public func finish(completion: @escaping @Sendable (Result<(URL, Int), Error>) -> Void) {
        Task {
            await stop()
            videoWriter.finish(completion: completion)
        }
    }
}
