// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia

/// Handles audio capture (system audio) by implementing SCStreamOutput protocol
public final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    public let sema = DispatchSemaphore(value: 0)
    private let audioWriter: AudioWriter
    private let verbose: Bool
    private var completed = false
    private let completedLock = NSLock()

    // Verbose logging state
    private var systemAudioBufferCount: Int = 0
    private var microphoneBufferCount: Int = 0
    private var lastAudioLogTime: Date?
    private let logLock = NSLock()

    /// Creates an audio stream output
    /// - Parameters:
    ///   - audioURL: Output URL for audio file
    ///   - duration: Capture duration in seconds
    ///   - verbose: Enable verbose logging
    /// - Returns: AudioStreamOutput instance, or nil if writer creation fails
    public static func create(
        audioURL: URL,
        duration: Double?,
        verbose: Bool
    ) -> AudioStreamOutput? {
        let audioWriter: AudioWriter
        do {
            audioWriter = try AudioWriter.create(
                url: audioURL,
                duration: duration,
                verbose: verbose
            )
        } catch {
            Log.error("Failed to create audio writer: \(error)")
            return nil
        }

        let output = AudioStreamOutput(
            audioWriter: audioWriter,
            verbose: verbose
        )

        // Wire up completion callback
        audioWriter.onComplete = { [weak output] in
            output?.completedLock.lock()
            output?.completed = true
            output?.completedLock.unlock()
            output?.sema.signal()
        }

        return output
    }

    private init(
        audioWriter: AudioWriter,
        verbose: Bool
    ) {
        self.audioWriter = audioWriter
        self.verbose = verbose
        super.init()
    }

    /// SCStreamOutput callback for handling captured audio
    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .audio:
            if verbose {
                logLock.lock()
                systemAudioBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter.appendSystemAudio(sb)

        case .microphone:
            if verbose {
                logLock.lock()
                microphoneBufferCount += 1
                logAudioBuffersIfNeeded()
                logLock.unlock()
            }
            audioWriter.appendMicrophone(sb)

        default:
            return
        }
    }

    /// Logs audio buffer counts every ~1 second (must be called with logLock held)
    private func logAudioBuffersIfNeeded() {
        let now = Date()
        if let lastLog = lastAudioLogTime {
            if now.timeIntervalSince(lastLog) >= 1.0 {
                Log.debug("Audio buffers in last ~1s: system=\(systemAudioBufferCount), mic=\(microphoneBufferCount)", verbose: true)
                systemAudioBufferCount = 0
                microphoneBufferCount = 0
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
