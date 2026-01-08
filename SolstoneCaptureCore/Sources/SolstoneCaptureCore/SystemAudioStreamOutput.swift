// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Routes system audio from SCStream to a callback
/// Used for routing system audio to PerSourceAudioManager
public final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Callback for system audio sample buffers
    public var onAudioBuffer: ((CMSampleBuffer) -> Void)?

    private let verbose: Bool

    // Verbose logging state
    private var systemAudioBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Creates a system audio stream output
    /// - Parameter verbose: Enable verbose logging
    public init(verbose: Bool = false) {
        self.verbose = verbose
        super.init()
    }

    /// SCStreamOutput callback for handling captured audio
    public func stream(_: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio:
            logLock.lock()
            systemAudioBufferCount += 1
            logAudioBuffersIfNeeded()
            logLock.unlock()
            onAudioBuffer?(sb)

        default:
            return
        }
    }

    /// Logs audio buffer counts every 60 seconds (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 60.0 {
                Log.info("[SystemAudio] \(systemAudioBufferCount) buffers in last minute")
                systemAudioBufferCount = 0
                lastAudioLogTime = now
            }
        } else {
            lastAudioLogTime = now
        }
    }
}
