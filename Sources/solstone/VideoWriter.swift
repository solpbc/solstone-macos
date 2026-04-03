// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Manages video capture and .mov file writing using hardware HEVC encoding
public final class VideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let captureDuration: Double?

    private var started = false
    private var captureStartTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var frameCount: Int = 0
    private var lock = NSLock()

    /// Creates a video writer instance
    /// - Parameters:
    ///   - url: Output URL for the .mov file
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - frameRate: Frame rate in Hz
    ///   - duration: Maximum duration in seconds (nil for indefinite)
    ///   - bitrate: Target bitrate in bits per second (default: 1 Mbps, suitable for 1fps screen capture)
    /// - Throws: Error if writer cannot be created
    public static func create(
        url: URL,
        width: Int,
        height: Int,
        frameRate: Double,
        duration: Double?,
        bitrate: Int = 1_000_000
    ) throws -> VideoWriter {
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        // Fragmented MP4 for crash resilience - aligned with keyframe interval
        writer.movieFragmentInterval = CMTime(seconds: 30, preferredTimescale: 1)

        let compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoAverageBitRateKey: bitrate,
            // Keyframe every 90s balances P-frame compression with corruption resilience
            // ~3-4 keyframes per 5-minute segment
            AVVideoMaxKeyFrameIntervalKey: 90,
            AVVideoMaxKeyFrameIntervalDurationKey: 90
        ]

        let colorProps: [String: String] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProps,
            AVVideoCompressionPropertiesKey: compression
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input to writer"])
        }

        writer.add(videoInput)

        // Create pixel buffer adaptor for proper buffer management
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        return VideoWriter(
            writer: writer,
            videoInput: videoInput,
            pixelBufferAdaptor: adaptor,
            duration: duration
        )
    }

    private init(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor,
        duration: Double?
    ) {
        self.writer = writer
        self.videoInput = videoInput
        self.pixelBufferAdaptor = pixelBufferAdaptor
        self.captureDuration = duration
    }

    /// Appends a video frame from CMSampleBuffer
    /// - Parameter sampleBuffer: Sample buffer containing video frame
    public func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            // Normal at low frame rates when screen content hasn't changed
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        appendFrame(pixelBuffer, presentationTime: pts)
    }

    /// Appends a video frame from CVPixelBuffer with explicit timestamp
    /// - Parameters:
    ///   - pixelBuffer: Pixel buffer containing video frame
    ///   - presentationTime: Presentation timestamp for the frame
    public func appendFrame(_ pixelBuffer: CVPixelBuffer, presentationTime pts: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        if !started {
            started = true
            captureStartTime = pts
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            Log.info("Started video recording to \(writer.outputURL.path)")
        }

        // Check duration limit if specified
        if let duration = captureDuration, let startTime = captureStartTime {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, startTime))
            if elapsed >= duration {
                return
            }
        }

        // Check if writer is still in valid state
        guard writer.status == .writing else {
            Log.warn("VideoWriter: writer not in writing state (status: \(writer.status.rawValue)), frame \(frameCount + 1) dropped")
            return
        }

        if pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData {
            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: pts) {
                frameCount += 1
                lastPresentationTime = pts
            } else {
                Log.error("VideoWriter: frame \(frameCount + 1) FAILED to append, status=\(writer.status.rawValue)")
            }
        } else {
            Log.warn("VideoWriter: frame \(frameCount + 1) dropped (not ready)")
        }
    }

    /// Finishes writing and closes the video file
    /// - Parameter completion: Callback with result ((URL, frameCount) on success, error on failure)
    public func finish(completion: @escaping @Sendable (Result<(URL, Int), Error>) -> Void) {
        lock.lock()
        let shouldFinish = started
        let finalFrameCount = frameCount
        lock.unlock()

        guard shouldFinish else {
            completion(.failure(NSError(domain: "VideoWriter", code: -2, userInfo: [NSLocalizedDescriptionKey: "No frames written"])))
            return
        }

        // Check writer status before attempting to finish
        guard writer.status == .writing else {
            Log.error("Video writer not in writing state (status: \(writer.status.rawValue))")
            if writer.status == .failed {
                Log.error("Video writer error: \(String(describing: writer.error))")
            }
            completion(.failure(writer.error ?? NSError(domain: "VideoWriter", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Writer in invalid state: \(writer.status.rawValue)"])))
            return
        }

        // Drain any remaining frames before marking finished (with timeout and status check)
        var drainAttempts = 0
        while !videoInput.isReadyForMoreMediaData && writer.status == .writing && drainAttempts < 100 {
            Thread.sleep(forTimeInterval: 0.01)
            drainAttempts += 1
        }

        videoInput.markAsFinished()

        let outputURL = writer.outputURL
        writer.finishWriting { @Sendable in
            if self.writer.status == .completed {
                completion(.success((outputURL, finalFrameCount)))
            } else {
                completion(.failure(self.writer.error ?? NSError(domain: "VideoWriter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unknown error"])))
            }
        }
    }
}
