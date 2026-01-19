// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import SolstoneCaptureCore

/// Captures periodic screenshots for a single display using a persistent SCStream
@MainActor
public final class ScreenshotCapturer {
    public let displayID: CGDirectDisplayID
    private let videoWriter: VideoWriter
    private let verbose: Bool

    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private var streamOutput: VideoStreamOutput?
    private var isRunning = false
    private let captureStartTime: Date
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0

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

        // Configure stream for 1 FPS video capture
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false  // Hide cursor to reduce frame changes
        config.scalesToFit = true   // Scale to specified width/height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS
        config.queueDepth = 3  // Small buffer for frames
        config.capturesAudio = false  // Video only - audio handled separately
        self.configuration = config

        Log.debug("ScreenshotCapturer: Created for display \(displayID) at \(width)x\(height)", verbose: verbose)
    }

    /// Updates the content filter for window exclusion
    /// Uses SCStream.updateContentFilter for efficiency (no stream recreation)
    public func updateContentFilter(_ filter: SCContentFilter) async {
        self.contentFilter = filter
        if let stream = stream {
            do {
                try await stream.updateContentFilter(filter)
                Log.debug("ScreenshotCapturer: Updated content filter for display \(displayID)", verbose: verbose)
            } catch {
                Log.warn("ScreenshotCapturer: Failed to update content filter: \(error)")
            }
        }
    }

    /// Starts the persistent video capture stream
    public func start() async {
        guard !isRunning else { return }
        isRunning = true

        do {
            // Create stream output handler
            let output = VideoStreamOutput { [weak self] pixelBuffer, isIdle in
                Task { @MainActor in
                    self?.handleFrame(pixelBuffer, isIdle: isIdle)
                }
            }
            self.streamOutput = output

            // Create and start the persistent stream
            let newStream = SCStream(filter: contentFilter, configuration: configuration, delegate: nil)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            self.stream = newStream

            Log.info("ScreenshotCapturer: Started persistent stream for display \(displayID)")
        } catch {
            Log.error("ScreenshotCapturer: Failed to start stream for display \(displayID): \(error)")
            isRunning = false
        }
    }

    /// Handles an incoming video frame from the stream
    /// - Parameters:
    ///   - pixelBuffer: The video frame pixel buffer
    ///   - isIdle: True if SCStream reports the frame as idle (no content change)
    private func handleFrame(_ pixelBuffer: CVPixelBuffer, isIdle: Bool) {
        guard isRunning else { return }

        // SCStream tells us when content hasn't changed via frame status
        if isIdle {
            skippedFrames += 1
            if verbose {
                Log.debug("ScreenshotCapturer: Display \(displayID) skipped idle frame (total skipped: \(skippedFrames))", verbose: true)
            }
            return
        }

        // Frame has new content, encode it
        let elapsed = Date().timeIntervalSince(captureStartTime)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

        videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
        frameIndex += 1

        if verbose {
            Log.debug("ScreenshotCapturer: Display \(displayID) frame #\(frameIndex) at \(String(format: "%.3f", elapsed))s", verbose: true)
        }
    }

    /// Stops the capture stream
    public func stop() async {
        isRunning = false

        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                Log.debug("ScreenshotCapturer: Error stopping stream: \(error)", verbose: verbose)
            }
        }

        stream = nil
        streamOutput = nil

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

// MARK: - Video Stream Output

/// Handles video frames from SCStream and forwards pixel buffers to a callback
private final class VideoStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: (CVPixelBuffer, Bool) -> Void

    init(onFrame: @escaping (CVPixelBuffer, Bool) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }

        // Extract pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Check frame status from SCStreamFrameInfo attachments
        // Status == .idle means no content change since last frame
        var isIdle = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue) {
            isIdle = (status == .idle)
        }

        onFrame(pixelBuffer, isIdle)
    }
}
