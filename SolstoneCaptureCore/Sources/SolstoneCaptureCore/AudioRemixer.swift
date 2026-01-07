// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

/// Input for the audio remixer
public struct AudioRemixerInput: Sendable {
    /// URL to the source M4A file
    public let url: URL
    /// Timing information for alignment
    public let timingInfo: AudioTrackTimingInfo

    public init(url: URL, timingInfo: AudioTrackTimingInfo) {
        self.url = url
        self.timingInfo = timingInfo
    }
}

/// Result of the remix operation
public struct AudioRemixerResult: Sendable {
    /// Number of tracks written to output
    public let tracksWritten: Int
    /// Number of silent tracks skipped
    public let silentTracksSkipped: Int
    /// Number of tracks skipped due to no speech
    public let noSpeechTracksSkipped: Int
    /// URLs of source files that were processed
    public let sourceFiles: [URL]

    public init(tracksWritten: Int, silentTracksSkipped: Int, noSpeechTracksSkipped: Int = 0, sourceFiles: [URL]) {
        self.tracksWritten = tracksWritten
        self.silentTracksSkipped = silentTracksSkipped
        self.noSpeechTracksSkipped = noSpeechTracksSkipped
        self.sourceFiles = sourceFiles
    }
}

/// Combines multiple single-track M4A files into a single multi-track M4A
/// Handles timing alignment, silence filtering, and speech detection
public final class AudioRemixer: Sendable {
    private let verbose: Bool

    /// RMS threshold for silence detection (default: 0.01 ≈ -40dB)
    private let silenceThreshold: Float

    /// Minimum duration of non-silent audio to consider track meaningful (default: 0.5s)
    private let meaningfulAudioDuration: Double

    /// If true, move rejected files to rejected/ subfolder instead of deleting
    private let debugKeepRejected: Bool

    /// Audio settings for output (AAC, 48kHz, mono)
    private static nonisolated(unsafe) let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    public init(
        verbose: Bool = false,
        silenceThreshold: Float = 0.01,
        meaningfulAudioDuration: Double = 0.5,
        debugKeepRejected: Bool = false
    ) {
        self.verbose = verbose
        self.silenceThreshold = silenceThreshold
        self.meaningfulAudioDuration = meaningfulAudioDuration
        self.debugKeepRejected = debugKeepRejected
    }

    /// Remix multiple tracks into a single output file
    /// - Parameters:
    ///   - inputs: Array of track inputs with timing info
    ///   - outputURL: Destination M4A file
    ///   - deleteSourceFiles: If true, delete source files after successful remix
    /// - Returns: Remix result with track counts
    public func remix(
        inputs: [AudioRemixerInput],
        to outputURL: URL,
        deleteSourceFiles: Bool = true
    ) async throws -> AudioRemixerResult {
        guard !inputs.isEmpty else {
            throw AudioRemixerError.noInputs
        }

        let outputDirectory = outputURL.deletingLastPathComponent()

        // Filter inputs - skip tracks with no audio, silent mic tracks, or mic tracks without speech
        var tracksToProcess: [(input: AudioRemixerInput, asset: AVURLAsset)] = []
        var silentCount = 0
        var noSpeechCount = 0

        for input in inputs {
            // Skip tracks that never received any audio
            guard input.timingInfo.hasAudio else {
                Log.info("Dropping track with no audio: \(input.timingInfo.trackType.displayName)")
                silentCount += 1
                continue
            }

            // Check if file exists
            guard FileManager.default.fileExists(atPath: input.url.path) else {
                Log.warn("Audio file not found: \(input.url.lastPathComponent)")
                silentCount += 1
                continue
            }

            let asset = AVURLAsset(url: input.url)

            // Check for silence
            let hasMeaningfulAudio = await analyzeForSilence(asset: asset)
            if !hasMeaningfulAudio {
                Log.info("Dropping silent track: \(input.timingInfo.trackType.displayName)")
                handleRejectedFile(input.url, reason: "silent", outputDirectory: outputDirectory)
                silentCount += 1
                continue
            }

            // Check for speech
            let hasSpeech = await analyzeForSpeech(url: input.url)
            if !hasSpeech {
                Log.info("Dropping track with no speech: \(input.timingInfo.trackType.displayName)")
                handleRejectedFile(input.url, reason: "no-speech", outputDirectory: outputDirectory)
                noSpeechCount += 1
                continue
            }

            tracksToProcess.append((input, asset))
        }

        guard !tracksToProcess.isEmpty else {
            throw AudioRemixerError.noTracksToWrite
        }

        // Create temporary output URL
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".m4a")

        // Track whether we should clean up the temp file
        var cleanupTempFile = true
        defer {
            if cleanupTempFile {
                Log.warn("Cleaning up temp file after remix failure")
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        // Create asset writer
        let writer = try AVAssetWriter(url: tempURL, fileType: .m4a)

        // Create readers and writers for each track
        var trackPairs: [(
            reader: AVAssetReaderTrackOutput,
            writer: AVAssetWriterInput,
            assetReader: AVAssetReader,
            startOffset: CMTime,
            trackType: AudioTrackType
        )] = []

        for (input, asset) in tracksToProcess {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = audioTracks.first else {
                Log.warn("No audio track in: \(input.url.lastPathComponent)")
                continue
            }

            // Create reader
            let assetReader = try AVAssetReader(asset: asset)

            // Create reader output with PCM decode
            let readerOutput = AVAssetReaderTrackOutput(
                track: sourceTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )

            if assetReader.canAdd(readerOutput) {
                assetReader.add(readerOutput)
            }

            // Create writer input
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            writerInput.expectsMediaDataInRealTime = false

            if writer.canAdd(writerInput) {
                writer.add(writerInput)
                trackPairs.append((
                    reader: readerOutput,
                    writer: writerInput,
                    assetReader: assetReader,
                    startOffset: input.timingInfo.startOffset,
                    trackType: input.timingInfo.trackType
                ))
            }
        }

        guard !trackPairs.isEmpty else {
            throw AudioRemixerError.noTracksToWrite
        }

        // Start all readers
        for pair in trackPairs {
            guard pair.assetReader.startReading() else {
                throw AudioRemixerError.failedToStartReader(pair.assetReader.error)
            }
        }

        // Start writing
        guard writer.startWriting() else {
            throw AudioRemixerError.failedToStartWriter(writer.error)
        }

        writer.startSession(atSourceTime: .zero)

        // Process tracks interleaved - AVAssetWriter needs data from all tracks roughly together
        var finishedTracks = Set<Int>()
        var pendingSamples = [Int: CMSampleBuffer]()

        while finishedTracks.count < trackPairs.count {
            for (idx, pair) in trackPairs.enumerated() {
                guard !finishedTracks.contains(idx) else { continue }

                // Get pending sample or read new one
                let sampleBuffer: CMSampleBuffer?
                if let pending = pendingSamples[idx] {
                    sampleBuffer = pending
                } else {
                    sampleBuffer = pair.reader.copyNextSampleBuffer()
                }

                if let buffer = sampleBuffer {
                    if pair.writer.isReadyForMoreMediaData {
                        // Retime buffer to apply start offset
                        if let retimedBuffer = retimeBuffer(buffer, offset: pair.startOffset) {
                            pair.writer.append(retimedBuffer)
                        }
                        pendingSamples.removeValue(forKey: idx)
                    } else {
                        // Hold onto sample for next iteration
                        pendingSamples[idx] = buffer
                    }
                } else {
                    // No more samples for this track
                    pair.writer.markAsFinished()
                    finishedTracks.insert(idx)
                }
            }

            // Small yield to prevent tight loop
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }

        // Wait for writing to complete
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw AudioRemixerError.writeFailed(writer.error)
        }

        // Cancel all readers
        for pair in trackPairs {
            pair.assetReader.cancelReading()
        }

        // Disable cleanup - we're about to move the file into place
        cleanupTempFile = false

        // Remove existing output if present
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try fm.moveItem(at: tempURL, to: outputURL)

        Log.info("Remixed \(trackPairs.count) track(s) to \(outputURL.lastPathComponent)")

        // Delete source files if requested
        let sourceURLs = inputs.map(\.url)
        if deleteSourceFiles {
            for url in sourceURLs {
                // Only try to delete if file exists (may have been cleaned up by SingleTrackAudioWriter)
                guard fm.fileExists(atPath: url.path) else {
                    continue
                }
                do {
                    try fm.removeItem(at: url)
                    Log.debug("Deleted source: \(url.lastPathComponent)", verbose: verbose)
                } catch {
                    Log.warn("Failed to delete source \(url.lastPathComponent): \(error)")
                }
            }
        }

        return AudioRemixerResult(
            tracksWritten: trackPairs.count,
            silentTracksSkipped: silentCount,
            noSpeechTracksSkipped: noSpeechCount,
            sourceFiles: sourceURLs
        )
    }

    // MARK: - Private

    /// Analyze an asset to determine if it has meaningful audio
    private func analyzeForSilence(asset: AVURLAsset) async -> Bool {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return false }

            let reader = try AVAssetReader(asset: asset)

            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )

            if reader.canAdd(output) {
                reader.add(output)
            }

            guard reader.startReading() else { return false }

            var totalNonSilentDuration: Double = 0

            while let sampleBuffer = output.copyNextSampleBuffer() {
                let bufferDuration = analyzeBufferForSilence(sampleBuffer)
                if bufferDuration > 0 {
                    totalNonSilentDuration += bufferDuration
                }

                // Early exit if we've found enough non-silent audio
                if totalNonSilentDuration >= meaningfulAudioDuration {
                    reader.cancelReading()
                    return true
                }
            }

            reader.cancelReading()
            return totalNonSilentDuration >= meaningfulAudioDuration

        } catch {
            Log.warn("Failed to analyze audio for silence: \(error)")
            // If analysis fails, assume it has audio to be safe
            return true
        }
    }

    /// Analyze a sample buffer and return the duration if it's non-silent, 0 otherwise
    private func analyzeBufferForSilence(_ sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else { return 0 }

        // Get format description for sample rate
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return 0 }

        let sampleRate = asbd.pointee.mSampleRate
        let bytesPerSample = Int(asbd.pointee.mBytesPerFrame)
        let sampleCount = length / max(bytesPerSample, 1)

        guard sampleCount > 0 else { return 0 }

        let bufferDuration = Double(sampleCount) / sampleRate

        // Calculate RMS for float samples
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let rms = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { floatPointer in
                var rmsValue: Float = 0
                vDSP_rmsqv(floatPointer, 1, &rmsValue, vDSP_Length(sampleCount))
                return rmsValue
            }

            if rms >= silenceThreshold {
                return bufferDuration
            }
        }

        return 0
    }

    /// Analyze an audio file for speech presence using on-device recognition
    private func analyzeForSpeech(url: URL) async -> Bool {
        let detector = SpeechDetector.shared

        // If speech detection isn't available, fall back to allowing the track
        guard detector.isAvailable else {
            Log.debug("Speech detection not available, allowing track", verbose: verbose)
            return true
        }

        let result = await detector.detectSpeech(in: url, timeout: 10.0)

        switch result {
        case .speechDetected:
            Log.debug("Speech detected in: \(url.lastPathComponent)", verbose: verbose)
            return true
        case .noSpeech:
            Log.debug("No speech in: \(url.lastPathComponent)", verbose: verbose)
            return false
        case .unavailable(let reason):
            Log.debug("Speech detection unavailable (\(reason)), allowing track", verbose: verbose)
            return true  // Fail open - if detection fails, include the track
        }
    }

    /// Handle a rejected audio file - either delete or move to rejected/ subfolder
    private func handleRejectedFile(_ url: URL, reason: String, outputDirectory: URL) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else { return }

        if debugKeepRejected {
            // Move to rejected/ subfolder
            let rejectedDir = outputDirectory.appendingPathComponent("rejected")
            do {
                try fm.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
                let destURL = rejectedDir.appendingPathComponent("\(reason)_\(url.lastPathComponent)")
                try fm.moveItem(at: url, to: destURL)
                Log.debug("Moved rejected file to: \(destURL.lastPathComponent)", verbose: verbose)
            } catch {
                Log.warn("Failed to move rejected file: \(error)")
                // Fall back to deletion
                try? fm.removeItem(at: url)
            }
        } else {
            // Delete the file
            do {
                try fm.removeItem(at: url)
                Log.debug("Deleted rejected file: \(url.lastPathComponent)", verbose: verbose)
            } catch {
                Log.warn("Failed to delete rejected file: \(error)")
            }
        }
    }

    /// Retime a sample buffer by adding an offset to its presentation time
    private func retimeBuffer(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newTime = CMTimeAdd(originalTime, offset)

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

/// Errors for AudioRemixer
public enum AudioRemixerError: Error, LocalizedError {
    case noInputs
    case noTracksToWrite
    case failedToStartReader(Error?)
    case failedToStartWriter(Error?)
    case writeFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No input files provided"
        case .noTracksToWrite:
            return "No tracks to write after filtering"
        case let .failedToStartReader(error):
            return "Failed to start reader: \(error?.localizedDescription ?? "unknown error")"
        case let .failedToStartWriter(error):
            return "Failed to start writer: \(error?.localizedDescription ?? "unknown error")"
        case let .writeFailed(error):
            return "Write failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
