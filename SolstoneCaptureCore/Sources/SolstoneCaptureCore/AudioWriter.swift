// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import AVFoundation
import CoreMedia

/// Manages audio capture and writing to M4A file with multiple tracks
public final class AudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let systemInput: AVAssetWriterInput
    private let microphoneInput: AVAssetWriterInput
    private let finishLock = NSLock()
    private let outputPath: String
    private let verbose: Bool

    private var sessionStarted = false
    private var firstAudioTime: CMTime?
    private var lastMediaTime: CMTime?
    private var systemFinished = false
    private var microphoneFinished = false
    private let duration: Double?
    public var onComplete: (() -> Void)?

    /// Creates an audio writer with two separate tracks (system audio and microphone)
    /// - Parameters:
    ///   - url: File URL to write audio to
    ///   - duration: Maximum duration in seconds, or nil for indefinite
    ///   - verbose: Enable verbose logging
    /// - Throws: Error if writer creation fails
    public static func create(
        url: URL,
        duration: Double?,
        verbose: Bool = false
    ) throws -> AudioWriter {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        return try AudioWriter(url: url, duration: duration, verbose: verbose)
    }

    private init(url: URL, duration: Double?, verbose: Bool) throws {
        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.duration = duration
        self.outputPath = url.path
        self.verbose = verbose

        // Configure AAC audio format for M4A (mono tracks)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]

        // Create separate inputs for system audio and microphone
        self.systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        self.systemInput.expectsMediaDataInRealTime = true

        self.microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        self.microphoneInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(systemInput), writer.canAdd(microphoneInput) else {
            throw NSError(
                domain: "AudioWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot add audio inputs to writer"]
            )
        }

        writer.add(systemInput)
        writer.add(microphoneInput)
        writer.startWriting()
    }

    /// Appends a system audio buffer to the writer
    /// - Parameter sampleBuffer: Audio sample buffer from SCStream
    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: systemInput) { [weak self] elapsed in
            self?.finishSystemAudio(elapsed: elapsed)
        }
    }

    /// Appends a microphone audio buffer to the writer
    /// - Parameter sampleBuffer: Audio sample buffer from SCStream
    public func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: microphoneInput) { [weak self] elapsed in
            self?.finishMicrophone(elapsed: elapsed)
        }
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        onFinish: @escaping (Double) -> Void
    ) {
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Single lock acquisition for all state checks and updates
        finishLock.lock()
        let finished = systemFinished && microphoneFinished
        if finished {
            finishLock.unlock()
            return
        }

        // Start session on first buffer
        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
            firstAudioTime = currentTime
            Log.info("Started audio recording to \(outputPath)")
        }
        lastMediaTime = currentTime
        let firstTime = firstAudioTime
        finishLock.unlock()

        guard let firstTime = firstTime else { return }
        let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

        // Check if we should continue recording
        if let duration = duration, mediaElapsed >= duration {
            // Duration exceeded, finish this track
            onFinish(mediaElapsed)
        } else if input.isReadyForMoreMediaData {
            // Still recording (indefinite or within duration)
            let adjustedTime = CMTimeSubtract(currentTime, firstTime)
            if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                input.append(retimedBuffer)
            }
        }
    }

    private func finishSystemAudio(elapsed: Double) {
        finishLock.lock()
        let alreadyFinished = systemFinished
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        if !alreadyFinished {
            systemFinished = true
            systemInput.markAsFinished()
        }
        let bothFinished = systemFinished && microphoneFinished
        finishLock.unlock()

        if !alreadyFinished {
            Log.debug("Finishing system audio track after \(String(format: "%.2f", elapsed)) seconds", verbose: verbose)
        }
        if !alreadyFinished && bothFinished {
            finalizeWriter(elapsed: elapsed, firstTime: firstTime, lastTime: lastTime)
        }
    }

    private func finishMicrophone(elapsed: Double) {
        finishLock.lock()
        let alreadyFinished = microphoneFinished
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        if !alreadyFinished {
            microphoneFinished = true
            microphoneInput.markAsFinished()
        }
        let bothFinished = systemFinished && microphoneFinished
        finishLock.unlock()

        if !alreadyFinished {
            Log.debug("Finishing microphone track after \(String(format: "%.2f", elapsed)) seconds", verbose: verbose)
        }
        if !alreadyFinished && bothFinished {
            finalizeWriter(elapsed: elapsed, firstTime: firstTime, lastTime: lastTime)
        }
    }

    private func finalizeWriter(elapsed: Double, firstTime: CMTime?, lastTime: CMTime?) {
        // End the session at the adjusted last media time (relative to session start at .zero)
        if let firstTime = firstTime, let lastTime = lastTime {
            let adjustedEndTime = CMTimeSubtract(lastTime, firstTime)
            writer.endSession(atSourceTime: adjustedEndTime)
        }

        // Check writer status before calling finishWriting
        guard writer.status == .writing else {
            Log.error("Audio writer not in writing state (status: \(writer.status.rawValue)), calling onComplete directly")
            if writer.status == .failed {
                Log.error("Audio writer error: \(String(describing: writer.error))")
            }
            onComplete?()
            return
        }

        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            if self.writer.status == .failed {
                Log.error("Audio writer error: \(String(describing: self.writer.error))")
            } else {
                Log.info("Saved audio to \(self.outputPath) (\(String(format: "%.1f", elapsed)) seconds, 2 tracks)")
            }
            self.onComplete?()
        }
    }

    /// Finishes all tracks and finalizes the writer (for graceful shutdown)
    /// This is idempotent - safe to call even if tracks are already finishing
    public func finishAllTracks() {
        finishLock.lock()
        let systemAlreadyFinished = systemFinished
        let micAlreadyFinished = microphoneFinished
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        if !systemFinished {
            systemFinished = true
            systemInput.markAsFinished()
        }
        if !microphoneFinished {
            microphoneFinished = true
            microphoneInput.markAsFinished()
        }
        finishLock.unlock()

        // Only finalize if we actually marked something as finished
        if !systemAlreadyFinished || !micAlreadyFinished {
            let elapsed: Double
            if let firstTime = firstTime, let lastTime = lastTime {
                elapsed = CMTimeGetSeconds(CMTimeSubtract(lastTime, firstTime))
            } else {
                elapsed = 0
            }
            if !systemAlreadyFinished {
                Log.debug("Finishing system audio track after \(String(format: "%.2f", elapsed)) seconds", verbose: verbose)
            }
            if !micAlreadyFinished {
                Log.debug("Finishing microphone track after \(String(format: "%.2f", elapsed)) seconds", verbose: verbose)
            }
            finalizeWriter(elapsed: elapsed, firstTime: firstTime, lastTime: lastTime)
        }
    }

    /// Creates a new sample buffer with adjusted timing
    private func createRetimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, newTime: CMTime) -> CMSampleBuffer? {
        var newSampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: CMTime.invalid
        )

        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )

        return status == noErr ? newSampleBuffer : nil
    }
}
