// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Routes video frames from SCStream to a callback
/// Used for routing video frames to VideoFrameWriter
public final class VideoStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Callback for video frame sample buffers
    public var onVideoFrame: ((CMSampleBuffer) -> Void)?

    private let verbose: Bool

    // Verbose logging state
    private var frameCount: Int = 0
    private var lastLogTime: Date?
    private let logLock = NSLock()

    /// Creates a video stream output
    /// - Parameter verbose: Enable verbose logging
    public init(verbose: Bool = false) {
        self.verbose = verbose
        super.init()
    }

    /// SCStreamOutput callback for handling captured video frames
    public func stream(_: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            logLock.lock()
            frameCount += 1
            let currentCount = frameCount
            logFramesIfNeeded()
            logLock.unlock()

            if let callback = onVideoFrame {
                if currentCount <= 3 {
                    Log.info("[VideoStream] Frame \(currentCount) dispatching to callback")
                }
                callback(sb)
            } else if currentCount <= 5 {
                // Log first few frames without callback to help diagnose wiring issues
                Log.warn("[VideoStream] Frame \(currentCount) received but no callback set")
            }

        default:
            // Ignore audio and other types
            return
        }
    }

    /// Logs frame counts every 60 seconds (must be called with logLock held)
    private func logFramesIfNeeded() {
        let now = Date()
        if let lastLog = lastLogTime {
            if now.timeIntervalSince(lastLog) >= 60.0 {
                Log.info("[VideoStream] \(frameCount) frames in last minute")
                frameCount = 0
                lastLogTime = now
            }
        } else {
            lastLogTime = now
        }
    }
}
