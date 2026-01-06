// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Track type for multi-track audio recording
public enum AudioTrackType: Sendable, Equatable {
    case systemAudio
    case microphone(name: String, deviceUID: String)

    var displayName: String {
        switch self {
        case .systemAudio:
            return "System Audio"
        case let .microphone(name, _):
            return name
        }
    }
}

/// Information about a track in the multi-track writer
public struct AudioTrackInfo: Sendable {
    public let trackIndex: Int
    public let trackType: AudioTrackType
    public let hadMeaningfulAudio: Bool
}

/// Manages audio capture to a single M4A file with multiple tracks
/// Supports system audio, built-in mic, and external mics
public final class MultiTrackAudioWriter: @unchecked Sendable {
    /// Track state (internal)
    private struct TrackState {
        let input: AVAssetWriterInput
        let trackIndex: Int
        let trackType: AudioTrackType
        let silenceDetector: SilenceDetector?  // nil for system audio (never dropped)
        var finished: Bool = false
    }

    private let writer: AVAssetWriter
    private var tracks: [TrackState] = []
    private let outputPath: String
    private let verbose: Bool
    private let duration: Double?

    private var sessionStarted = false
    private var firstAudioTime: CMTime?
    private var lastMediaTime: CMTime?
    private let lock = NSLock()

    public var onComplete: (() -> Void)?

    /// Audio settings for all tracks (AAC, 48kHz, mono)
    private static nonisolated(unsafe) let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    /// Target sample rate for all tracks
    public static let targetSampleRate: Double = 48_000

    /// Creates a multi-track audio writer
    /// - Parameters:
    ///   - url: Output file URL (.m4a)
    ///   - duration: Maximum duration in seconds, or nil for indefinite
    ///   - verbose: Enable verbose logging
    public init(url: URL, duration: Double?, verbose: Bool = false) throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.outputPath = url.path
        self.duration = duration
        self.verbose = verbose
    }

    /// Adds a new track to the writer
    /// - Parameter type: The type of track to add
    /// - Returns: The track index
    /// - Throws: Error if track cannot be added
    public func addTrack(type: AudioTrackType) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard writer.status == .unknown || writer.status == .writing else {
            throw MultiTrackAudioWriterError.writerNotReady(status: writer.status)
        }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw MultiTrackAudioWriterError.cannotAddTrack(type: type)
        }

        writer.add(input)

        // Only add silence detector for mic tracks (system audio is never dropped)
        let silenceDetector: SilenceDetector?
        switch type {
        case .systemAudio:
            silenceDetector = nil
        case .microphone:
            silenceDetector = SilenceDetector()
        }

        let trackIndex = tracks.count
        let trackState = TrackState(
            input: input,
            trackIndex: trackIndex,
            trackType: type,
            silenceDetector: silenceDetector
        )
        tracks.append(trackState)

        Log.info("Added audio track \(trackIndex): \(type.displayName)")
        return trackIndex
    }

    /// Starts writing if not already started
    public func startWritingIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        if writer.status == .unknown {
            writer.startWriting()
        }
    }

    /// Appends audio from a CMSampleBuffer (from SCStream)
    /// - Parameters:
    ///   - sampleBuffer: The audio sample buffer
    ///   - trackIndex: The track to append to
    public func appendAudio(_ sampleBuffer: CMSampleBuffer, toTrack trackIndex: Int) {
        lock.lock()
        guard trackIndex >= 0 && trackIndex < tracks.count else {
            lock.unlock()
            Log.warn("Invalid track index: \(trackIndex)")
            return
        }

        let track = tracks[trackIndex]
        if track.finished {
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
            firstAudioTime = currentTime
            Log.info("Started multi-track audio recording to \(outputPath)")
        }
        lastMediaTime = currentTime

        let firstTime = firstAudioTime ?? currentTime
        lock.unlock()

        let mediaElapsed = CMTimeGetSeconds(CMTimeSubtract(currentTime, firstTime))

        // Check duration limit
        if let duration = duration, mediaElapsed >= duration {
            finishTrack(trackIndex)
            return
        }

        // Process for silence detection if applicable
        if let silenceDetector = track.silenceDetector {
            processSampleBufferForSilence(sampleBuffer, detector: silenceDetector)
        }

        // Write to track
        if track.input.isReadyForMoreMediaData {
            let adjustedTime = CMTimeSubtract(currentTime, firstTime)
            if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                track.input.append(retimedBuffer)
            }
        }
    }

    /// Appends audio from an AVAudioPCMBuffer (from AVAudioEngine/external mics)
    /// - Parameters:
    ///   - buffer: The PCM audio buffer
    ///   - trackIndex: The track to append to
    ///   - presentationTime: The presentation timestamp for this buffer
    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, toTrack trackIndex: Int, presentationTime: CMTime) {
        // Convert PCM buffer to CMSampleBuffer
        guard let sampleBuffer = createSampleBuffer(from: buffer, presentationTime: presentationTime) else {
            Log.warn("Failed to convert PCM buffer to CMSampleBuffer for track \(trackIndex)")
            return
        }

        appendAudio(sampleBuffer, toTrack: trackIndex)
    }

    /// Finishes a specific track
    public func finishTrack(_ trackIndex: Int) {
        lock.lock()
        guard trackIndex >= 0 && trackIndex < tracks.count else {
            lock.unlock()
            return
        }

        if tracks[trackIndex].finished {
            lock.unlock()
            return
        }

        tracks[trackIndex].finished = true
        tracks[trackIndex].input.markAsFinished()

        let allFinished = tracks.allSatisfy { $0.finished }
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        lock.unlock()

        Log.debug("Finished track \(trackIndex): \(tracks[trackIndex].trackType.displayName)", verbose: verbose)

        if allFinished {
            finalizeWriter(firstTime: firstTime, lastTime: lastTime)
        }
    }

    /// Finishes all tracks and finalizes the writer
    public func finishAllTracks() {
        lock.lock()
        let firstTime = firstAudioTime
        let lastTime = lastMediaTime
        var anyFinished = false

        for i in 0..<tracks.count {
            if !tracks[i].finished {
                tracks[i].finished = true
                tracks[i].input.markAsFinished()
                anyFinished = true
            }
        }
        lock.unlock()

        if anyFinished {
            finalizeWriter(firstTime: firstTime, lastTime: lastTime)
        }
    }

    /// Returns silence information for all tracks
    /// - Returns: Dictionary mapping track index to whether it had meaningful audio
    public func getSilenceInfo() -> [Int: Bool] {
        lock.lock()
        defer { lock.unlock() }

        var info: [Int: Bool] = [:]
        for track in tracks {
            // System audio always has meaningful audio (never dropped)
            if case .systemAudio = track.trackType {
                info[track.trackIndex] = true
            } else {
                info[track.trackIndex] = track.silenceDetector?.hadMeaningfulAudio ?? true
            }
        }
        return info
    }

    /// Returns information about all tracks
    public func getTrackInfo() -> [AudioTrackInfo] {
        lock.lock()
        defer { lock.unlock() }

        return tracks.map { track in
            let hadAudio: Bool
            if case .systemAudio = track.trackType {
                hadAudio = true
            } else {
                hadAudio = track.silenceDetector?.hadMeaningfulAudio ?? true
            }

            return AudioTrackInfo(
                trackIndex: track.trackIndex,
                trackType: track.trackType,
                hadMeaningfulAudio: hadAudio
            )
        }
    }

    /// Returns the number of tracks
    public var trackCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tracks.count
    }

    // MARK: - Private

    private func processSampleBufferForSilence(_ sampleBuffer: CMSampleBuffer, detector: SilenceDetector) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else { return }

        // Get format description for sample rate
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let sampleRate = asbd.pointee.mSampleRate
        let bytesPerSample = Int(asbd.pointee.mBytesPerFrame)
        let sampleCount = length / max(bytesPerSample, 1)

        guard sampleCount > 0 else { return }

        let bufferDuration = Double(sampleCount) / sampleRate

        // Convert to float samples for RMS calculation
        // Assuming 32-bit float samples (common for AAC decoding)
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPointer in
                detector.processBuffer(floatPointer, count: sampleCount, bufferDuration: bufferDuration)
            }
        }
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

    private func finalizeWriter(firstTime: CMTime?, lastTime: CMTime?) {
        // End the session at the adjusted last media time
        if let firstTime = firstTime, let lastTime = lastTime {
            let adjustedEndTime = CMTimeSubtract(lastTime, firstTime)
            writer.endSession(atSourceTime: adjustedEndTime)
        }

        guard writer.status == .writing else {
            Log.error("Audio writer not in writing state (status: \(writer.status.rawValue)), calling onComplete directly")
            if writer.status == .failed {
                Log.error("Audio writer error: \(String(describing: writer.error))")
            }
            onComplete?()
            return
        }

        let trackCount = tracks.count
        let elapsed: Double
        if let firstTime = firstTime, let lastTime = lastTime {
            elapsed = CMTimeGetSeconds(CMTimeSubtract(lastTime, firstTime))
        } else {
            elapsed = 0
        }

        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            if self.writer.status == .failed {
                Log.error("Audio writer error: \(String(describing: self.writer.error))")
            } else {
                Log.info("Saved audio to \(self.outputPath) (\(String(format: "%.1f", elapsed)) seconds, \(trackCount) tracks)")
            }
            self.onComplete?()
        }
    }
}

/// Errors for MultiTrackAudioWriter
public enum MultiTrackAudioWriterError: Error, LocalizedError {
    case writerNotReady(status: AVAssetWriter.Status)
    case cannotAddTrack(type: AudioTrackType)

    public var errorDescription: String? {
        switch self {
        case let .writerNotReady(status):
            return "Writer not ready (status: \(status.rawValue))"
        case let .cannotAddTrack(type):
            return "Cannot add track: \(type.displayName)"
        }
    }
}
