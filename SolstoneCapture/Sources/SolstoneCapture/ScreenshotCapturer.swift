// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import SolstoneCaptureCore

/// Captures periodic screenshots for a single display using a persistent SCStream
@MainActor
public final class ScreenshotCapturer {
    public let displayID: CGDirectDisplayID
    public var onHealthFailure: (() -> Void)?

    private let videoWriter: VideoWriter
    private let verbose: Bool

    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private var streamOutput: VideoStreamOutput?
    private var streamDelegate: StreamDelegate?
    private var healthCheckTimer: Timer?
    private var isRunning = false
    private let captureStartTime: Date
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0
    private var consecutiveEmptyChecks = 0
    private var healthCheckFrameCount = 0
    private var firstFrameLogged = false
    private var streamStartTime: Date?

    private let healthCheckInterval: TimeInterval = 30.0
    private let maxEmptyChecks: Int = 2

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
        firstFrameLogged = false
        streamStartTime = Date()

        do {
            // Create stream output handler
            let output = VideoStreamOutput { [weak self] pixelBuffer, isIdle in
                Task { @MainActor in
                    self?.handleFrame(pixelBuffer, isIdle: isIdle)
                }
            }
            self.streamOutput = output

            let delegate = StreamDelegate { [weak self] error in
                Task { @MainActor in
                    self?.handleStreamError(error)
                }
            }
            self.streamDelegate = delegate

            // Create and start the persistent stream
            let newStream = SCStream(filter: contentFilter, configuration: configuration, delegate: delegate)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            self.stream = newStream
            startHealthCheck()

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
        healthCheckFrameCount += 1

        if !firstFrameLogged {
            firstFrameLogged = true
            let elapsed = streamStartTime.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
            Log.info("ScreenshotCapturer: First frame received for display \(displayID) after \(elapsed)s")
        }

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
        stopHealthCheck()
        isRunning = false

        if let stream = stream {
            do {
                try await withTimeout(seconds: 5) {
                    try await stream.stopCapture()
                }
            } catch is TimeoutError {
                Log.warn("ScreenshotCapturer: Timeout stopping capture stream for display \(displayID)")
            } catch {
                Log.debug("ScreenshotCapturer: Error stopping stream: \(error)", verbose: verbose)
            }
        }

        stream = nil
        streamOutput = nil
        streamDelegate = nil

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

    /// Finishes video writing with a timeout to prevent indefinite hangs.
    /// Returns the result from the video writer, or nil if the timeout fires first.
    public func finishWithTimeout(seconds: Double) async -> Result<(URL, Int), Error>? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            Task {
                try? await Task.sleep(for: .seconds(seconds))
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                if !alreadyResumed {
                    Log.warn("Timeout waiting for video finish on display \(self.displayID)")
                    continuation.resume(returning: nil)
                }
            }

            self.finish { result in
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                if !alreadyResumed {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func getAndResetFrameCount() -> Int {
        let frameCount = healthCheckFrameCount
        healthCheckFrameCount = 0
        return frameCount
    }

    private func startHealthCheck() {
        stopHealthCheck()
        consecutiveEmptyChecks = 0
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
        healthCheckTimer?.tolerance = 10.0
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func performHealthCheck() async {
        guard stream != nil else { return }

        let frameCount = getAndResetFrameCount()
        if frameCount > 0 {
            consecutiveEmptyChecks = 0
            return
        }

        consecutiveEmptyChecks += 1
        Log.warn("ScreenshotCapturer: Health check found no frames for display \(displayID) (consecutive: \(consecutiveEmptyChecks)/\(maxEmptyChecks))")

        if consecutiveEmptyChecks >= maxEmptyChecks {
            Log.error("ScreenshotCapturer: Health check failed for display \(displayID), restarting stream")
            onHealthFailure?()
            await restartStream()
        }
    }

    private func restartStream() async {
        guard isRunning, stream != nil else {
            Log.debug("ScreenshotCapturer: Restart requested for display \(displayID) but stream is not running", verbose: verbose)
            return
        }

        Log.info("ScreenshotCapturer: Restarting stream for display \(displayID)")

        if let stream = self.stream {
            self.streamOutput = nil
            do {
                try await withTimeout(seconds: 5) {
                    try await stream.stopCapture()
                }
            } catch is TimeoutError {
                Log.warn("ScreenshotCapturer: Timeout stopping stream during restart for display \(displayID)")
            } catch {
                Log.debug("ScreenshotCapturer: Error stopping stream during restart for display \(displayID): \(error)", verbose: verbose)
            }
        }

        self.stream = nil
        self.streamDelegate = nil

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            Log.debug("ScreenshotCapturer: Restart sleep interrupted for display \(displayID): \(error)", verbose: verbose)
        }

        let output = VideoStreamOutput { [weak self] pixelBuffer, isIdle in
            Task { @MainActor in
                self?.handleFrame(pixelBuffer, isIdle: isIdle)
            }
        }
        self.streamOutput = output

        let delegate = StreamDelegate { [weak self] error in
            Task { @MainActor in
                self?.handleStreamError(error)
            }
        }
        self.streamDelegate = delegate

        do {
            let newStream = SCStream(filter: self.contentFilter, configuration: self.configuration, delegate: delegate)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            self.stream = newStream
            self.firstFrameLogged = false
            self.streamStartTime = Date()
            self.consecutiveEmptyChecks = 0
            self.healthCheckFrameCount = 0
            Log.info("ScreenshotCapturer: Stream restarted successfully for display \(displayID)")
        } catch {
            Log.error("ScreenshotCapturer: Failed to restart stream for display \(displayID): \(error)")
            if isPermissionError(error) {
                Log.info("ScreenshotCapturer: Permission error, stopping health check for display \(displayID)")
                stopHealthCheck()
            }
        }
    }

    private func handleStreamError(_ error: Error) {
        guard isRunning else { return }
        Log.error("ScreenshotCapturer: Stream error for display \(displayID): \(error)")

        // Don't restart on permission errors — they require user action
        if isPermissionError(error) {
            Log.info("ScreenshotCapturer: Permission error, not restarting (requires user action in System Settings)")
            stopHealthCheck()
            return
        }

        onHealthFailure?()
        Task { @MainActor [weak self] in
            await self?.restartStream()
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
