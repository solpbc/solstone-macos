// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures periodic screenshots for a single display using a persistent SCStream
@MainActor
public final class ScreenshotCapturer {
    public let displayID: CGDirectDisplayID
    public var onHealthFailure: (() -> Void)?

    private let videoWriter: VideoWriter
    private let verbose: Bool

    private var contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: (any CaptureStreamControlling)?
    private var streamOutput: VideoStreamOutput?
    private var streamDelegate: StreamDelegate?
    private var healthCheckTimer: Timer?
    private var isRunning = false
    private var streamGeneration: Int = 0
    private let streamFactory: CaptureStreamFactory
    private let captureStartTime: Date
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0
    private var consecutiveEmptyChecks = 0
    private var healthCheckFrameCount = 0
    private var firstFrameLogged = false
    private var streamStartTime: Date?
#if DEBUG
    internal private(set) var _teardownTraceForTesting: [String] = []
    internal private(set) var _restartDecisionTraceForTesting: [String] = []
    internal var _restartParkHookForTesting: (@MainActor () async -> Void)?
    internal var _streamGenerationForTesting: Int { streamGeneration }
#endif

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
    public convenience init(
        displayID: CGDirectDisplayID,
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        contentFilter: SCContentFilter,
        verbose: Bool
    ) throws {
        try self.init(
            displayID: displayID,
            videoURL: videoURL,
            width: width,
            height: height,
            frameRate: frameRate,
            duration: duration,
            contentFilter: contentFilter,
            verbose: verbose,
            streamFactory: defaultCaptureStreamFactory
        )
    }

    internal init(
        displayID: CGDirectDisplayID,
        videoURL: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        contentFilter: SCContentFilter,
        verbose: Bool,
        streamFactory: @escaping CaptureStreamFactory
    ) throws {
        self.displayID = displayID
        self.contentFilter = contentFilter
        self.verbose = verbose
        self.streamFactory = streamFactory
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

        if verbose { Logger.capture.debug("ScreenshotCapturer: Created for display \(displayID, privacy: .public) at \(width, privacy: .public)x\(height, privacy: .public)") }
    }

    /// Updates the content filter for window exclusion
    /// Uses SCStream.updateContentFilter for efficiency (no stream recreation)
    public func updateContentFilter(_ filter: SCContentFilter) async {
        self.contentFilter = filter
        if let stream = stream {
            do {
                try await stream.updateContentFilter(filter)
                if verbose { Logger.capture.debug("ScreenshotCapturer: Updated content filter for display \(self.displayID, privacy: .public)") }
            } catch {
                Logger.capture.error("Failed to update SCStream config for display \(self.displayID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Starts the persistent video capture stream
    public func start() async {
        streamGeneration += 1
        let gen = streamGeneration

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

            let delegate = StreamDelegate { [weak self] error in
                Task { @MainActor in
                    self?.handleStreamError(error)
                }
            }

            // Create and start the persistent stream
            guard streamGeneration == gen else {
                Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
                appendRestartSuppressedTraceForTesting()
                return
            }
            let newStream = streamFactory(contentFilter, configuration, delegate)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            guard streamGeneration == gen else {
                Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
                appendRestartSuppressedTraceForTesting()
                try? await newStream.stopCapture()
                return
            }
            self.streamOutput = output
            self.streamDelegate = delegate
            self.stream = newStream
            startHealthCheck()

            Logger.capture.info("ScreenshotCapturer: Started persistent stream for display \(self.displayID, privacy: .public)")
        } catch {
            Logger.capture.error("ScreenshotCapturer: Failed to start stream for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
            if streamGeneration == gen {
                isRunning = false
            }
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
            Logger.capture.info("ScreenshotCapturer: First frame received for display \(self.displayID, privacy: .public) after \(elapsed, privacy: .public)s")
        }

        // SCStream tells us when content hasn't changed via frame status
        if isIdle {
            skippedFrames += 1
            if verbose {
                Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) skipped idle frame (total skipped: \(self.skippedFrames, privacy: .public))")
            }
            return
        }

        // Frame has new content, encode it
        let elapsed = Date().timeIntervalSince(captureStartTime)
        let pts = CMTime(seconds: elapsed, preferredTimescale: 600)

        videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
        frameIndex += 1

        if verbose {
            Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) frame #\(self.frameIndex, privacy: .public) at \(String(format: "%.3f", elapsed), privacy: .public)s")
        }
    }

    /// Stops the capture stream
    public func stop() async {
        streamGeneration += 1
        stopHealthCheck()
        isRunning = false

        await teardownStream()

        let totalFrames = frameIndex + skippedFrames
        let skipPercent = totalFrames > 0 ? (skippedFrames * 100) / totalFrames : 0
        Logger.capture.info("ScreenshotCapturer: Stopped for display \(self.displayID, privacy: .public) - \(self.frameIndex, privacy: .public) frames encoded, \(self.skippedFrames, privacy: .public) duplicates skipped (\(skipPercent, privacy: .public)%)")
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
                    Logger.capture.warning("Timeout waiting for video finish on display \(self.displayID, privacy: .public)")
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

    private func teardownStream() async {
#if DEBUG
        _teardownTraceForTesting.append("stopCapture")
#endif
        if let stream = stream {
            do {
                try await withTimeout(seconds: 5) {
                    try await stream.stopCapture()
                }
            } catch is TimeoutError {
                Logger.capture.warning("ScreenshotCapturer: Timeout stopping capture stream for display \(self.displayID, privacy: .public)")
            } catch {
                if verbose { Logger.capture.debug("ScreenshotCapturer: Error stopping stream: \(error, privacy: .public)") }
            }
        }

#if DEBUG
        _teardownTraceForTesting.append("dropOutput")
#endif
        stream = nil
        streamOutput = nil
        streamDelegate = nil
    }

    private func performHealthCheck() async {
        guard stream != nil else { return }

        let frameCount = getAndResetFrameCount()
        if frameCount > 0 {
            consecutiveEmptyChecks = 0
            return
        }

        consecutiveEmptyChecks += 1
        Logger.capture.warning("ScreenshotCapturer: Health check found no frames for display \(self.displayID, privacy: .public) (consecutive: \(self.consecutiveEmptyChecks, privacy: .public)/\(self.maxEmptyChecks, privacy: .public))")

        if consecutiveEmptyChecks >= maxEmptyChecks {
            Logger.capture.error("ScreenshotCapturer: Health check failed for display \(self.displayID, privacy: .public), restarting stream")
            onHealthFailure?()
            await restartStream()
        }
    }

    private func restartStream() async {
        guard isRunning, stream != nil else {
            if verbose { Logger.capture.debug("ScreenshotCapturer: Restart requested for display \(self.displayID, privacy: .public) but stream is not running") }
            return
        }
        let gen = streamGeneration

        Logger.capture.info("ScreenshotCapturer: Restarting stream for display \(self.displayID, privacy: .public)")

        await teardownStream()
        guard streamGeneration == gen else {
            Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
            appendRestartSuppressedTraceForTesting()
            return
        }

        do {
            try await restartBackoff()
        } catch {
            if verbose { Logger.capture.debug("ScreenshotCapturer: Restart sleep interrupted for display \(self.displayID, privacy: .public): \(error, privacy: .public)") }
        }
        guard streamGeneration == gen else {
            Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
            appendRestartSuppressedTraceForTesting()
            return
        }

        let output = VideoStreamOutput { [weak self] pixelBuffer, isIdle in
            Task { @MainActor in
                self?.handleFrame(pixelBuffer, isIdle: isIdle)
            }
        }

        let delegate = StreamDelegate { [weak self] error in
            Task { @MainActor in
                self?.handleStreamError(error)
            }
        }

        do {
            guard streamGeneration == gen else {
                Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
                appendRestartSuppressedTraceForTesting()
                return
            }
            appendRestartProceedTraceForTesting()
            let newStream = streamFactory(contentFilter, configuration, delegate)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()
            guard streamGeneration == gen else {
                Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
                appendRestartSuppressedTraceForTesting()
                try? await newStream.stopCapture()
                return
            }
            self.streamOutput = output
            self.streamDelegate = delegate
            self.stream = newStream
            self.firstFrameLogged = false
            self.streamStartTime = Date()
            self.consecutiveEmptyChecks = 0
            self.healthCheckFrameCount = 0
            Logger.capture.info("ScreenshotCapturer: Stream restarted successfully for display \(self.displayID, privacy: .public)")
        } catch {
            Logger.capture.error("ScreenshotCapturer: Failed to restart stream for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
            if isPermissionError(error) {
                Logger.capture.info("ScreenshotCapturer: Permission error, stopping health check for display \(self.displayID, privacy: .public)")
                stopHealthCheck()
            }
        }
    }

    private func handleStreamError(_ error: Error) {
        guard isRunning else { return }
        Logger.capture.error("ScreenshotCapturer: Stream error for display \(self.displayID, privacy: .public): \(error, privacy: .public)")

        // Don't restart on permission errors — they require user action
        if isPermissionError(error) {
            Logger.capture.info("ScreenshotCapturer: Permission error, not restarting (requires user action in System Settings)")
            stopHealthCheck()
            return
        }

        onHealthFailure?()
        Task { @MainActor [weak self] in
            await self?.restartStream()
        }
    }

    private func restartBackoff() async throws {
#if DEBUG
        if let hook = _restartParkHookForTesting {
            await hook()
            return
        }
#endif
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func appendRestartSuppressedTraceForTesting() {
#if DEBUG
        _restartDecisionTraceForTesting.append("restart suppressed - stream generation changed")
#endif
    }

    private func appendRestartProceedTraceForTesting() {
#if DEBUG
        _restartDecisionTraceForTesting.append("restart proceeding")
#endif
    }

#if DEBUG
    internal func _restartStreamForTesting() async {
        await restartStream()
    }

    internal func _handleStreamErrorForTesting(_ error: Error) async {
        handleStreamError(error)
        await Task.yield()
    }
#endif
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
