// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Routes system audio from SCStream to a callback
/// Used for routing system audio to PerSourceAudioManager
public final class SystemAudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    /// Callback for system audio sample buffers
    public var onAudioBuffer: ((CMSampleBuffer) -> Void)? {
        get {
            logLock.lock()
            defer { logLock.unlock() }
            return _onAudioBuffer
        }
        set {
            logLock.lock()
            defer { logLock.unlock() }
            _onAudioBuffer = newValue
        }
    }
    private var _onAudioBuffer: ((CMSampleBuffer) -> Void)?

    private let verbose: Bool
    private let onValidAudio: (@Sendable (SystemAudioStreamOutput) -> Void)?
    private var audioAcknowledgementPending = false
    private var audioAcknowledged = false

    // Buffer counting for logging and health checks
    private var systemAudioBufferCount: Int = 0
    private var totalBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Returns total buffers received and resets the counter (for health checks)
    public func getAndResetBufferCount() -> Int {
        logLock.lock()
        defer { logLock.unlock() }
        let count = totalBufferCount
        totalBufferCount = 0
        return count
    }

    /// Creates a system audio stream output
    /// - Parameter verbose: Enable verbose logging
    public convenience init(verbose: Bool = false) { self.init(verbose: verbose, onValidAudio: nil) }

    internal init(verbose: Bool = false, onValidAudio: (@Sendable (SystemAudioStreamOutput) -> Void)?) {
        self.verbose = verbose
        self.onValidAudio = onValidAudio
        super.init()
    }

    /// SCStreamOutput callback for handling captured audio
    public func stream(_: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio:
            deliverAudio(sb)
        default:
            return
        }
    }

    /// Detaching waits for admitted buffers to enqueue on their segment writer.
    /// The destination must enqueue promptly and must not change this callback.
    internal func deliverAudio(_ buffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer), CMSampleBufferGetNumSamples(buffer) > 0,
              let format = CMSampleBufferGetFormatDescription(buffer),
              CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio else { return }
        logLock.lock()
        defer { logLock.unlock() }
        systemAudioBufferCount += 1
        totalBufferCount += 1
        logAudioBuffersIfNeeded()
        _onAudioBuffer?(buffer)
        if !audioAcknowledged, !audioAcknowledgementPending, let onValidAudio {
            audioAcknowledgementPending = true
            onValidAudio(self)
        }
    }

    internal func completeAudioAcknowledgement(_ accepted: Bool) {
        logLock.lock()
        defer { logLock.unlock() }
        audioAcknowledgementPending = false
        audioAcknowledged = accepted
    }

    /// Logs audio buffer counts every 60 seconds (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 60.0 {
                Logger.audio.info("[SystemAudio] \(self.systemAudioBufferCount, privacy: .public) buffers in last minute")
                systemAudioBufferCount = 0
                lastAudioLogTime = now
            }
        } else {
            lastAudioLogTime = now
        }
    }
}
