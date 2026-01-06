// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Handles system audio capture from SCStream, routing to MultiTrackAudioWriter
/// Note: All microphones (including built-in) are captured via ExternalMicCapture
public final class MultiTrackStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    public let sema = DispatchSemaphore(value: 0)
    private let audioWriter: MultiTrackAudioWriter
    private let systemTrackIndex: Int
    private let verbose: Bool
    private var completed = false
    private let completedLock = NSLock()

    // Verbose logging state
    private var systemAudioBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Creates a multi-track stream output
    /// - Parameters:
    ///   - audioWriter: The multi-track audio writer to write to
    ///   - systemTrackIndex: Track index for system audio
    ///   - verbose: Enable verbose logging
    public init(
        audioWriter: MultiTrackAudioWriter,
        systemTrackIndex: Int,
        verbose: Bool
    ) {
        self.audioWriter = audioWriter
        self.systemTrackIndex = systemTrackIndex
        self.verbose = verbose
        super.init()

        // Wire up completion callback
        audioWriter.onComplete = { [weak self] in
            self?.completedLock.lock()
            self?.completed = true
            self?.completedLock.unlock()
            self?.sema.signal()
        }
    }

    /// SCStreamOutput callback for handling captured audio
    public func stream(_: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio:
            if verbose {
                logLock.lock()
                systemAudioBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter.appendAudio(sb, toTrack: systemTrackIndex)

        default:
            return
        }
    }

    /// Logs audio buffer counts every ~1 second (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 1.0 {
                Log.debug("System audio buffers in last ~1s: \(systemAudioBufferCount)", verbose: true)
                systemAudioBufferCount = 0
                lastAudioLogTime = now
            }
        } else {
            lastAudioLogTime = now
        }
    }

    /// Finishes audio writing (for graceful shutdown)
    /// Returns true if finish was initiated, false if already completed
    public func finish() -> Bool {
        completedLock.lock()
        let alreadyCompleted = completed
        completedLock.unlock()

        if alreadyCompleted {
            return false
        }

        audioWriter.finishAllTracks()
        return true
    }
}
