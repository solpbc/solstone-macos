// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation

/// Track type for audio recording
public enum AudioTrackType: Sendable, Equatable {
    case systemAudio
    case microphone(name: String, deviceUID: String)

    public var displayName: String {
        switch self {
        case .systemAudio:
            return "System Audio"
        case let .microphone(name, _):
            return name
        }
    }

    /// Returns the device UID for microphones, "system" for system audio
    public var sourceID: String {
        switch self {
        case .systemAudio:
            return "system"
        case let .microphone(_, deviceUID):
            return deviceUID
        }
    }
}

/// Timing information for a track, used during remix
public struct AudioTrackTimingInfo: Sendable {
    /// When this track started relative to segment start
    public let startOffset: CMTime
    /// When this track ended relative to segment start
    public let endOffset: CMTime
    /// The track type
    public let trackType: AudioTrackType
    /// Whether any audio was actually written to this track
    public let hasAudio: Bool

    public init(startOffset: CMTime, endOffset: CMTime, trackType: AudioTrackType, hasAudio: Bool = true) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.trackType = trackType
        self.hasAudio = hasAudio
    }
}

/// Writes audio from a single source to its own M4A file
/// Tracks timing offset for later remix alignment
public final class SingleTrackAudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let trackType: AudioTrackType
    private let segmentStartTime: CMTime
    private let verbose: Bool

    private var sessionStarted = false
    private var isFinished = false
    private var firstBufferTime: CMTime?
    private var lastBufferTime: CMTime?
    private let lock = NSLock()

    // Silence batching state
    private var silenceStartTime: CMTime?
    private var silenceAccumulatedSamples: Int = 0
    private var lastSilentBufferFormat: CMFormatDescription?
    private var lastSilentBufferSampleRate: Double = 48000

    /// RMS threshold below which audio is considered silent (approx -60dB)
    /// Very conservative to avoid cutting real audio
    private static let silenceThreshold: Float = 0.001

    /// Maximum silence duration before forcing a flush (1 second worth of samples at 48kHz)
    private static let maxSilenceSamples: Int = 48000

    public var onComplete: (() -> Void)?

    /// Audio settings for output (AAC, 48kHz, mono)
    private static nonisolated(unsafe) let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    /// Target sample rate for all tracks
    public static let targetSampleRate: Double = 48_000

    /// Creates a single-track audio writer
    /// - Parameters:
    ///   - url: Output file URL (.m4a)
    ///   - trackType: The type of audio track
    ///   - segmentStartTime: The segment's start time (for offset calculation)
    ///   - verbose: Enable verbose logging
    public init(url: URL, trackType: AudioTrackType, segmentStartTime: CMTime, verbose: Bool = false) throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.outputURL = url
        self.trackType = trackType
        self.segmentStartTime = segmentStartTime
        self.verbose = verbose

        // Create the single audio input
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SingleTrackAudioWriterError.cannotAddInput
        }

        writer.add(input)
        self.input = input

        Log.info("Created audio writer: \(trackType.displayName) -> \(url.lastPathComponent)")
    }

    /// Appends audio from a CMSampleBuffer (from SCStream)
    /// Uses silence batching to reduce encoder invocations during quiet periods
    /// - Parameter sampleBuffer: The audio sample buffer
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()

        if isFinished {
            lock.unlock()
            return
        }

        // Start session on first buffer
        let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            if writer.status == .unknown {
                writer.startWriting()
            }
            writer.startSession(atSourceTime: .zero)
            sessionStarted = true
            firstBufferTime = currentTime
            Log.debug("Started audio recording: \(trackType.displayName)", verbose: verbose)
        }
        lastBufferTime = currentTime

        let firstTime = firstBufferTime ?? currentTime
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)

        // Check if this buffer is silent
        let isSilent = isBufferSilent(sampleBuffer)

        if isSilent {
            // Start or continue silence accumulation
            if silenceStartTime == nil {
                silenceStartTime = currentTime
            }
            silenceAccumulatedSamples += numSamples

            // Cache format for creating silent buffer later
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                lastSilentBufferFormat = format
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    lastSilentBufferSampleRate = asbd.mSampleRate
                }
            }

            // Check if we should flush (max silence duration reached)
            if silenceAccumulatedSamples >= Self.maxSilenceSamples {
                flushSilence(firstTime: firstTime)
            }

            lock.unlock()
            return
        }

        // Non-silent buffer - flush any accumulated silence first
        if silenceAccumulatedSamples > 0 {
            flushSilence(firstTime: firstTime)
        }

        lock.unlock()

        // Write the non-silent buffer
        if input.isReadyForMoreMediaData {
            let adjustedTime = CMTimeSubtract(currentTime, firstTime)
            if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                input.append(retimedBuffer)
            }
        }
    }

    /// Check if a sample buffer contains silence (RMS below threshold)
    private func isBufferSilent(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return false
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer, length > 0 else {
            return false
        }

        // Determine sample format from format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return false
        }

        // Calculate RMS based on format
        let rms: Float
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float format
            let floatPtr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            let sampleCount = length / MemoryLayout<Float>.size
            var sumSquares: Float = 0
            for i in 0..<sampleCount {
                let sample = floatPtr[i]
                sumSquares += sample * sample
            }
            rms = sqrt(sumSquares / Float(max(1, sampleCount)))
        } else if asbd.mBitsPerChannel == 16 {
            // Int16 format
            let int16Ptr = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            let sampleCount = length / MemoryLayout<Int16>.size
            var sumSquares: Float = 0
            for i in 0..<sampleCount {
                let sample = Float(int16Ptr[i]) / 32768.0
                sumSquares += sample * sample
            }
            rms = sqrt(sumSquares / Float(max(1, sampleCount)))
        } else {
            // Unknown format, assume not silent
            return false
        }

        return rms < Self.silenceThreshold
    }

    /// Flush accumulated silence as a single silent buffer
    /// Must be called with lock held
    private func flushSilence(firstTime: CMTime) {
        guard silenceAccumulatedSamples > 0,
              let startTime = silenceStartTime,
              let formatDesc = lastSilentBufferFormat else {
            silenceStartTime = nil
            silenceAccumulatedSamples = 0
            return
        }

        // Create a single silent buffer for the accumulated duration
        let adjustedTime = CMTimeSubtract(startTime, firstTime)

        if let silentBuffer = createSilentBuffer(
            sampleCount: silenceAccumulatedSamples,
            presentationTime: adjustedTime,
            formatDescription: formatDesc,
            sampleRate: lastSilentBufferSampleRate
        ) {
            if input.isReadyForMoreMediaData {
                input.append(silentBuffer)
            }
        }

        // Reset silence state
        silenceStartTime = nil
        silenceAccumulatedSamples = 0
    }

    /// Create a silent CMSampleBuffer with the given parameters
    private func createSilentBuffer(sampleCount: Int, presentationTime: CMTime, formatDescription: CMFormatDescription, sampleRate: Double) -> CMSampleBuffer? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        let bytesPerSample = Int(asbd.mBytesPerFrame)
        let dataSize = sampleCount * bytesPerSample

        // Allocate zeroed memory
        guard let silentMemory = calloc(1, dataSize) else { return nil }

        // Create block buffer that owns the memory
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: silentMemory,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else {
            free(silentMemory)
            return nil
        }

        // Create sample buffer
        var silentBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(sampleCount), timescale: Int32(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &silentBuffer
        )

        return status == noErr ? silentBuffer : nil
    }

    /// Appends audio from an AVAudioPCMBuffer (from AVAudioEngine/external mics)
    /// - Parameters:
    ///   - buffer: The PCM audio buffer
    ///   - presentationTime: The presentation timestamp for this buffer
    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        // Convert PCM buffer to CMSampleBuffer
        guard let sampleBuffer = createSampleBuffer(from: buffer, presentationTime: presentationTime) else {
            Log.warn("Failed to convert PCM buffer to CMSampleBuffer for \(trackType.displayName)")
            return
        }

        appendAudio(sampleBuffer)
    }

    /// Finishes writing and returns timing info
    /// - Returns: Timing information for remix alignment
    public func finish() async -> AudioTrackTimingInfo {
        // extractTimingState also flushes any pending silence
        let (firstTime, lastTime, startTime, wasStarted) = extractTimingState()

        // Only mark input as finished if we actually started writing
        // Calling markAsFinished() on an input whose writer wasn't started throws an exception
        if wasStarted {
            input.markAsFinished()

            // End the session at the adjusted last media time
            if let firstTime = firstTime, let lastTime = lastTime {
                let adjustedEndTime = CMTimeSubtract(lastTime, firstTime)
                writer.endSession(atSourceTime: adjustedEndTime)
            }
        }

        // Calculate timing offsets
        let startOffset: CMTime
        let endOffset: CMTime

        if let firstTime = firstTime {
            startOffset = CMTimeSubtract(firstTime, startTime)
        } else {
            startOffset = .zero
        }

        if let lastTime = lastTime {
            endOffset = CMTimeSubtract(lastTime, startTime)
        } else {
            endOffset = startOffset
        }

        // Finalize writer only if it was started
        if wasStarted && writer.status == .writing {
            await writer.finishWriting()

            if writer.status == .failed {
                Log.error("Audio writer error for \(trackType.displayName): \(String(describing: writer.error))")
            } else {
                let duration = CMTimeGetSeconds(CMTimeSubtract(endOffset, startOffset))
                Log.info("Saved audio: \(outputURL.lastPathComponent) (\(String(format: "%.1f", duration))s)")
            }
        } else if !wasStarted {
            // No audio was written - clean up the empty file
            Log.info("No audio written for \(trackType.displayName), removing empty file")
            try? FileManager.default.removeItem(at: outputURL)
        }

        onComplete?()

        return AudioTrackTimingInfo(
            startOffset: startOffset,
            endOffset: endOffset,
            trackType: trackType,
            hasAudio: wasStarted
        )
    }

    /// Returns the output file URL
    public var url: URL {
        return outputURL
    }

    // MARK: - Private

    /// Extract timing state for use in async contexts (lock cannot be held across await)
    /// Also flushes any pending silence before marking as finished
    private func extractTimingState() -> (firstTime: CMTime?, lastTime: CMTime?, startTime: CMTime, wasStarted: Bool) {
        lock.lock()

        // Flush any pending silence before finishing
        if let firstTime = firstBufferTime, silenceAccumulatedSamples > 0 {
            flushSilence(firstTime: firstTime)
        }

        isFinished = true
        let firstTime = firstBufferTime
        let lastTime = lastBufferTime
        let startTime = segmentStartTime
        let wasStarted = sessionStarted
        lock.unlock()
        return (firstTime, lastTime, startTime, wasStarted)
    }

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

    private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let format = pcmBuffer.format
        let frameCount = pcmBuffer.frameLength

        guard frameCount > 0 else { return nil }

        // Create audio stream basic description
        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Create format description
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else { return nil }

        // Get the float channel data
        guard let floatData = pcmBuffer.floatChannelData?[0] else { return nil }

        // Create block buffer
        let dataSize = Int(frameCount) * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?

        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else { return nil }

        // Copy data to block buffer
        status = CMBlockBufferReplaceDataBytes(
            with: floatData,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )

        guard status == noErr else { return nil }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: Int64(frameCount), timescale: Int32(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }
}

/// Errors for SingleTrackAudioWriter
public enum SingleTrackAudioWriterError: Error, LocalizedError {
    case cannotAddInput

    public var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add audio input to writer"
        }
    }
}
