// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import VideoToolbox

/// Captures periodic screenshots for a single display using a persistent SCStream
@MainActor
public final class ScreenshotCapturer {
    public let displayID: CGDirectDisplayID
    public var onHealthFailure: (() -> Void)?
    public var onTerminalStop: (@MainActor () -> Void)?
    public var onScreenStopped: (@MainActor () -> Void)?
    public var onFrameDelivered: (@MainActor () -> Void)?
    public var currentPreviewEpoch: (@Sendable () -> UInt64)?
    public var onLatestFrame: (@MainActor @Sendable (CGImage, Int, UInt64) -> Void)?
    public var siteFrameGate: SiteFrameGate?
    public var isSiteRuleActive: Bool = false {
        didSet {
            let active = isSiteRuleActive
            sampleQueueRuleActive.withLock { $0 = active }
            if !active {
                if let gate = siteFrameGate {
                    let actions = gate.deactivate(displayID: displayID)
                    applyGateActions(actions)
                }
                pendingBuffers.removeAll()
            }
        }
    }

    private let videoWriter: VideoWriter
    private let verbose: Bool
    private let sampleQueueRuleActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var pendingBuffers: [UInt64: CVPixelBuffer] = [:]
    private var nextFrameID: UInt64 = 0

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
    private let captureOriginTicks: UInt64
    private var frameIndex: Int = 0
    private var skippedFrames: Int = 0
    private var consecutiveEmptyChecks = 0
    private var healthCheckFrameCount = 0
    private var firstFrameLogged = false
    private var streamStartTime: Date?
#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal private(set) var _teardownTraceForTesting: [String] = []
    internal private(set) var _restartDecisionTraceForTesting: [String] = []
    internal var _restartParkHookForTesting: (@MainActor () async -> Void)?
    internal var _streamGenerationForTesting: Int { streamGeneration }
    internal var _submittedVideoFrameCountForTesting: Int { frameIndex }
    internal var _isRunningForTesting: Bool { isRunning }
    internal var _hasStreamForTesting: Bool { stream != nil }
    internal var _isHealthCheckActiveForTesting: Bool { healthCheckTimer != nil }
#endif

    private let healthCheckInterval: TimeInterval = 30.0
    private let maxEmptyChecks: Int = 2
    private let maxRestartAttempts: Int = 3

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
        self.captureOriginTicks = mach_absolute_time()

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
    public func start() async throws {
        streamGeneration += 1
        let gen = streamGeneration

        guard !isRunning else { return }
        isRunning = true
        firstFrameLogged = false
        streamStartTime = Date()

        do {
            // Create stream output handler
            let output = VideoStreamOutput(sampleQueueRuleActive: sampleQueueRuleActive) { [weak self] pixelBuffer, isIdle, displayTicks in
                let epoch = self?.currentPreviewEpoch?() ?? 0
                Task { @MainActor in
                    self?.handleFrameFromOutput(generation: gen, pixelBuffer: pixelBuffer, isIdle: isIdle, epoch: epoch, displayTimeTicks: displayTicks)
                }
            }

            let delegate = StreamDelegate { [weak self] error in
                Task { @MainActor in
                    self?.handleStreamErrorFromDelegate(generation: gen, error: error)
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
            guard streamGeneration == gen else { return }
            isRunning = false
            throw error
        }
    }

    internal func handleFrameFromOutput(generation: Int, pixelBuffer: CVPixelBuffer, isIdle: Bool, epoch: UInt64, displayTimeTicks: UInt64? = nil) {
        guard streamGeneration == generation, isRunning else { return }
        handleFrame(pixelBuffer, isIdle: isIdle, epoch: epoch, displayTimeTicks: displayTimeTicks)
    }

    internal func handleStreamErrorFromDelegate(generation: Int, error: Error) {
        guard streamGeneration == generation, isRunning else { return }
        handleStreamError(error)
    }

    /// Handles an incoming video frame from the stream
    /// - Parameters:
    ///   - pixelBuffer: The video frame pixel buffer
    ///   - isIdle: True if SCStream reports the frame as idle (no content change)
    ///   - epoch: The preview epoch sampled on the stream queue
    ///   - displayTimeTicks: Mach absolute timestamp from frame attachment displayTime
    private func handleFrame(_ pixelBuffer: CVPixelBuffer, isIdle: Bool, epoch: UInt64, displayTimeTicks: UInt64? = nil) {
        guard isRunning else { return }
        onFrameDelivered?()
        healthCheckFrameCount += 1

        if !firstFrameLogged {
            firstFrameLogged = true
            let elapsed = streamStartTime.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
            Logger.capture.info("ScreenshotCapturer: First frame received for display \(self.displayID, privacy: .public) after \(elapsed, privacy: .public)s")
        }

        // The live preview is not gated and is never saved.
        // A preview may have been invalidated since the last changed frame (for example,
        // while startup was still committing). A valid idle buffer can repopulate it;
        // the receiver still enforces the current epoch, source and pause authority.
        if let onLatestFrame, let image = downscalePixelBufferToCGImage(pixelBuffer, maxSide: 640) {
            onLatestFrame(image, streamGeneration, epoch)
        }

        // SCStream tells us when content hasn't changed via frame status.
        // Preview delivery must not turn duplicate frames into encoded video frames.
        if isIdle {
            skippedFrames += 1
            if verbose {
                Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) skipped idle frame (total skipped: \(self.skippedFrames, privacy: .public))")
            }
            return
        }

        if !isSiteRuleActive {
            // Frame has new content, encode it
            let elapsed = Date().timeIntervalSince(captureStartTime)
            let pts: CMTime
            if let gate = siteFrameGate {
                pts = gate.clampInactivePTS(displayID: displayID, elapsed: elapsed)
            } else {
                pts = CMTime(seconds: elapsed, preferredTimescale: 600)
            }

            videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
            frameIndex += 1

            if verbose {
                Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) frame #\(self.frameIndex, privacy: .public) at \(String(format: "%.3f", elapsed), privacy: .public)s")
            }
            return
        }

        guard let gate = siteFrameGate else {
            let elapsed = Date().timeIntervalSince(captureStartTime)
            let pts = CMTime(seconds: elapsed, preferredTimescale: 600)
            videoWriter.appendFrame(pixelBuffer, presentationTime: pts)
            frameIndex += 1
            return
        }

        nextFrameID &+= 1
        let frameID = nextFrameID
        pendingBuffers[frameID] = pixelBuffer

        let c = displayTimeTicks.map { HostClock.seconds(ticks: $0) }
        let held = SiteHeldFrame(
            id: frameID,
            displayTicks: displayTimeTicks,
            c: c,
            originTicks: captureOriginTicks
        )

        var actions = gate.enqueue(displayID: displayID, frame: held)
        let now = HostClock.seconds(ticks: mach_absolute_time())
        actions.append(contentsOf: gate.evaluate(displayID: displayID, now: now))

        applyGateActions(actions)
    }

    private func applyGateActions(_ actions: [SiteFrameAction]) {
        for action in actions {
            switch action {
            case .release(let id, let pts):
                if let buffer = pendingBuffers.removeValue(forKey: id) {
                    videoWriter.appendFrame(buffer, presentationTime: pts)
                    frameIndex += 1
                    if verbose {
                        Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) released frame #\(self.frameIndex, privacy: .public) at \(String(format: "%.3f", pts.seconds), privacy: .public)s")
                    }
                }
            case .drop(let id, let reason):
                pendingBuffers.removeValue(forKey: id)
                if verbose {
                    Logger.capture.debug("ScreenshotCapturer: Display \(self.displayID, privacy: .public) dropped frame \(id, privacy: .public) (\(reason.rawValue, privacy: .public))")
                }
            }
        }
    }

    private func downscalePixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer, maxSide: Int = 640) -> CGImage? {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let originalImage = cgImage else { return nil }

        let width = originalImage.width
        let height = originalImage.height
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)

        if longest <= maxSide {
            return originalImage
        }

        let scale = Double(maxSide) / Double(longest)
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
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
            drainGateAndFlush()
            videoWriter.finish(completion: completion)
        }
    }

    private func drainGateAndFlush() {
        if let gate = siteFrameGate {
            let now = HostClock.seconds(ticks: mach_absolute_time())
            let actions = gate.drain(displayID: displayID, now: now)
            applyGateActions(actions)
        }
        pendingBuffers.removeAll()
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
        healthCheckTimer = CaptureTimer.schedule(interval: healthCheckInterval, repeats: true) { [weak self] _ in
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
#if DEBUG || SOLSTONE_TEST_SUPPORT
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

#if DEBUG || SOLSTONE_TEST_SUPPORT
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
            await restartStream()
        }
    }

    private func restartStream() async {
        guard isRunning, stream != nil else {
            if verbose { Logger.capture.debug("ScreenshotCapturer: Restart requested for display \(self.displayID, privacy: .public) but stream is not running") }
            return
        }
        streamGeneration += 1
        var gen = streamGeneration

        Logger.capture.info("ScreenshotCapturer: Restarting stream for display \(self.displayID, privacy: .public)")

        onScreenStopped?()
        await teardownStream()
        guard streamGeneration == gen else {
            Logger.capture.info("ScreenshotCapturer: restart suppressed - stream generation changed for display \(self.displayID, privacy: .public)")
            appendRestartSuppressedTraceForTesting()
            return
        }

        var attempts = 0
        while attempts < maxRestartAttempts {
            attempts += 1
            if attempts > 1 {
                streamGeneration += 1
                gen = streamGeneration
            }

            do {
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

                let attemptGen = gen

                let output = VideoStreamOutput(sampleQueueRuleActive: sampleQueueRuleActive) { [weak self] pixelBuffer, isIdle, displayTicks in
                    let epoch = self?.currentPreviewEpoch?() ?? 0
                    Task { @MainActor in
                        self?.handleFrameFromOutput(generation: attemptGen, pixelBuffer: pixelBuffer, isIdle: isIdle, epoch: epoch, displayTimeTicks: displayTicks)
                    }
                }

                let delegate = StreamDelegate { [weak self] error in
                    Task { @MainActor in
                        self?.handleStreamErrorFromDelegate(generation: attemptGen, error: error)
                    }
                }

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
                return
            } catch {
                guard streamGeneration == gen, isRunning else {
                    appendRestartSuppressedTraceForTesting()
                    return
                }
                if isPermissionError(error) {
                    stopHealthCheck()
                    isRunning = false
                    onScreenStopped?()
                    return
                }
                Logger.capture.error("ScreenshotCapturer: Failed restart attempt \(attempts, privacy: .public)/\(self.maxRestartAttempts, privacy: .public) for display \(self.displayID, privacy: .public): \(error, privacy: .public)")
            }
        }

        Logger.capture.error("ScreenshotCapturer: terminal capture failure for display \(self.displayID, privacy: .public) - restart policy exhausted")
        onHealthFailure?()
        isRunning = false
        stopHealthCheck()
        onScreenStopped?()
    }

    private func handleStreamError(_ error: Error) {
        guard isRunning else { return }
        Logger.capture.error("ScreenshotCapturer: Stream error for display \(self.displayID, privacy: .public): \(error, privacy: .public)")

        // Don't restart on permission errors — they require user action
        if isPermissionError(error) {
            Logger.capture.info("ScreenshotCapturer: Permission error, not restarting (requires user action in System Settings)")
            stopHealthCheck()
            isRunning = false
            onScreenStopped?()
            return
        } else if isUserStoppedStreamError(error) {
            Logger.capture.info("ScreenshotCapturer: Stream stopped by user (Stop Sharing)")
            stopHealthCheck()
            stream = nil
            streamOutput = nil
            streamDelegate = nil
            isRunning = false
            onTerminalStop?()
            return
        }

        Task { @MainActor [weak self] in
            await self?.restartStream()
        }
    }

    private func restartBackoff() async throws {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let hook = _restartParkHookForTesting {
            await hook()
            return
        }
#endif
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func appendRestartSuppressedTraceForTesting() {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        _restartDecisionTraceForTesting.append("restart suppressed - stream generation changed")
#endif
    }

    private func appendRestartProceedTraceForTesting() {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        _restartDecisionTraceForTesting.append("restart proceeding")
#endif
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _restartStreamForTesting() async {
        await restartStream()
    }

    internal func _handleStreamErrorForTesting(_ error: Error) async {
        handleStreamError(error)
        await Task.yield()
    }

    internal func _performHealthCheckForTesting() async {
        await performHealthCheck()
    }
#endif
}

// MARK: - Video Stream Output

/// Handles video frames from SCStream and forwards pixel buffers to a callback
internal final class VideoStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    internal let sampleQueueRuleActive: OSAllocatedUnfairLock<Bool>
    internal let onFrameHandler: (CVPixelBuffer, Bool, UInt64?) -> Void

    init(
        sampleQueueRuleActive: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: false),
        onFrame: @escaping (CVPixelBuffer, Bool, UInt64?) -> Void
    ) {
        self.sampleQueueRuleActive = sampleQueueRuleActive
        self.onFrameHandler = onFrame
        super.init()
    }

    convenience init(onFrame: @escaping (CVPixelBuffer, Bool) -> Void) {
        self.init(sampleQueueRuleActive: OSAllocatedUnfairLock(initialState: false)) { buffer, isIdle, _ in
            onFrame(buffer, isIdle)
        }
    }

    internal func onFrame(_ pixelBuffer: CVPixelBuffer, _ isIdle: Bool, _ displayTicks: UInt64? = nil) {
        onFrameHandler(pixelBuffer, isIdle, displayTicks)
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }

        let isActive = sampleQueueRuleActive.withLock { $0 }

        if !isActive {
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

            onFrame(pixelBuffer, isIdle, nil)
            return
        }

        // Rule is active: read status and displayTime, deep-copy buffer, hop only copy. Failed copy not encoded.
        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var isIdle = false
        var displayTime: UInt64? = nil
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] {
            if let statusValue = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusValue) {
                isIdle = (status == .idle)
            }
            displayTime = HostClock.displayTimeTicks(from: attachments)
        }

        guard let copiedBuffer = deepCopyPixelBuffer(sourceBuffer) else { return }
        onFrame(copiedBuffer, isIdle, displayTime)
    }
}

private func deepCopyPixelBuffer(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    let width = CVPixelBufferGetWidth(src)
    let height = CVPixelBufferGetHeight(src)
    let pixelFormat = CVPixelBufferGetPixelFormatType(src)

    var optDst: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        nil,
        &optDst
    )
    guard status == kCVReturnSuccess, let dst = optDst else { return nil }

    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }

    if CVPixelBufferIsPlanar(src) {
        let planeCount = CVPixelBufferGetPlaneCount(src)
        for plane in 0..<planeCount {
            guard let srcAddr = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                  let dstAddr = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else {
                return nil
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(src, plane)

            if srcBytesPerRow == dstBytesPerRow {
                memcpy(dstAddr, srcAddr, srcBytesPerRow * planeHeight)
            } else {
                let bytesToCopy = min(srcBytesPerRow, dstBytesPerRow)
                for row in 0..<planeHeight {
                    let srcRow = srcAddr.advanced(by: row * srcBytesPerRow)
                    let dstRow = dstAddr.advanced(by: row * dstBytesPerRow)
                    memcpy(dstRow, srcRow, bytesToCopy)
                }
            }
        }
    } else {
        guard let srcAddr = CVPixelBufferGetBaseAddress(src),
              let dstAddr = CVPixelBufferGetBaseAddress(dst) else {
            return nil
        }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(src)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)

        if srcBytesPerRow == dstBytesPerRow {
            memcpy(dstAddr, srcAddr, srcBytesPerRow * height)
        } else {
            let bytesToCopy = min(srcBytesPerRow, dstBytesPerRow)
            for row in 0..<height {
                let srcRow = srcAddr.advanced(by: row * srcBytesPerRow)
                let dstRow = dstAddr.advanced(by: row * dstBytesPerRow)
                memcpy(dstRow, srcRow, bytesToCopy)
            }
        }
    }

    return dst
}
