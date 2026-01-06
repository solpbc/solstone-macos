// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

/// Result of audio remixing
public struct RemixResult: Sendable {
    public let outputURL: URL
    public let deletedFiles: [URL]
    public let trackCount: Int
}

/// Configuration for remix operation
public struct RemixConfig: Sendable {
    /// Microphone priority order (names, highest priority first)
    public let microphonePriority: [String]

    /// Threshold for considering a mic "started late" (seconds)
    public let startOffsetThreshold: Double

    /// Threshold for considering a mic has "complete coverage" (percentage of segment)
    public let coverageThreshold: Double

    public init(
        microphonePriority: [String],
        startOffsetThreshold: Double = 5.0,
        coverageThreshold: Double = 0.9
    ) {
        self.microphonePriority = microphonePriority
        self.startOffsetThreshold = startOffsetThreshold
        self.coverageThreshold = coverageThreshold
    }
}

/// Errors that can occur during remixing
public enum RemixError: Error, LocalizedError {
    case systemAudioNotFound
    case writerFailed(String)
    case readerFailed(String)
    case noAudioTracks

    public var errorDescription: String? {
        switch self {
        case .systemAudioNotFound:
            return "System audio file not found"
        case .writerFailed(let reason):
            return "Asset writer failed: \(reason)"
        case .readerFailed(let reason):
            return "Asset reader failed: \(reason)"
        case .noAudioTracks:
            return "No audio tracks found in source file"
        }
    }
}

/// Remixes system audio and mic audio into a single multi-track M4A file
public final class AudioRemixer: Sendable {
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Remix audio files in a segment directory
    /// - Parameters:
    ///   - segmentDirectory: Directory containing audio files
    ///   - config: Remix configuration (mic priority)
    /// - Returns: RemixResult on success
    public func remix(segmentDirectory: URL, config: RemixConfig) async throws -> RemixResult {
        // 1. Find system audio file
        let systemAudioURL = try findSystemAudioFile(in: segmentDirectory)

        // 2. Load mics metadata (or scan for mic files if metadata missing)
        let (metadata, micFiles) = try loadMicsInfo(from: segmentDirectory)

        // 3. If no mic files, just rename system audio to _audio.m4a
        if micFiles.isEmpty {
            let outputURL = try renameSystemToAudio(systemAudioURL: systemAudioURL, segmentDirectory: segmentDirectory)
            return RemixResult(outputURL: outputURL, deletedFiles: [], trackCount: 1)
        }

        // 4. Determine if this is a fixed or changed segment
        let isFixed = isFixedSegment(micFiles: micFiles, metadata: metadata, config: config)

        // 5. Select mic files based on segment type
        let selectedMics = selectMicsForRemix(
            micFiles: micFiles,
            config: config,
            isFixed: isFixed
        )

        // 6. Create output file URL (replace _system with _audio in filename)
        let systemFilename = systemAudioURL.lastPathComponent
        let outputFilename = systemFilename.replacingOccurrences(of: "_system.m4a", with: "_audio.m4a")
        let outputURL = segmentDirectory.appendingPathComponent(outputFilename)

        // 7. Create multi-track M4A
        try await createMultiTrackM4A(
            outputURL: outputURL,
            systemAudioURL: systemAudioURL,
            micFiles: selectedMics,
            segmentDuration: metadata?.segmentDuration ?? 300.0
        )

        // 8. Delete original audio files
        var deletedFiles: [URL] = []

        // Delete system audio
        try FileManager.default.removeItem(at: systemAudioURL)
        deletedFiles.append(systemAudioURL)

        // Delete all mic files (not just selected ones)
        for mic in micFiles {
            if FileManager.default.fileExists(atPath: mic.url.path) {
                try FileManager.default.removeItem(at: mic.url)
                deletedFiles.append(mic.url)
            }
        }

        // Delete mics.json (no longer needed after remix)
        let micsJsonURL = segmentDirectory.appendingPathComponent("mics.json")
        if FileManager.default.fileExists(atPath: micsJsonURL.path) {
            try? FileManager.default.removeItem(at: micsJsonURL)
            deletedFiles.append(micsJsonURL)
        }

        Log.info("Created remix: \(outputFilename) with \(1 + selectedMics.count) track(s)")

        return RemixResult(
            outputURL: outputURL,
            deletedFiles: deletedFiles,
            trackCount: 1 + selectedMics.count
        )
    }

    // MARK: - Private Types

    private struct MicsMetadata: Codable {
        let segmentDuration: Double
        let mics: [MicEntry]
    }

    private struct MicEntry: Codable {
        let name: String
        let file: String
        let startOffset: Double
        let duration: Double
    }

    private struct MicFileInfo {
        let deviceName: String
        let url: URL
        let startOffset: TimeInterval
        let duration: TimeInterval
    }

    // MARK: - Private Helpers

    private func findSystemAudioFile(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let audioFile = contents.first(where: {
            $0.lastPathComponent.hasSuffix("_system.m4a")
        }) else {
            throw RemixError.systemAudioNotFound
        }
        return audioFile
    }

    /// Load mic info from mics.json or scan directory for mic files
    private func loadMicsInfo(from directory: URL) throws -> (MicsMetadata?, [MicFileInfo]) {
        let metadataURL = directory.appendingPathComponent("mics.json")

        if FileManager.default.fileExists(atPath: metadataURL.path) {
            // Load from mics.json
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(MicsMetadata.self, from: data)

            let micFiles = metadata.mics.map { entry in
                MicFileInfo(
                    deviceName: entry.name,
                    url: directory.appendingPathComponent(entry.file),
                    startOffset: entry.startOffset,
                    duration: entry.duration
                )
            }.filter { FileManager.default.fileExists(atPath: $0.url.path) }

            return (metadata, micFiles)
        } else {
            // Fallback: scan for _mic*.m4a files
            Log.debug("No mics.json found, scanning for mic files", verbose: verbose)
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let micFiles = contents.filter { $0.lastPathComponent.contains("_mic") && $0.pathExtension == "m4a" }
                .map { url in
                    // Extract device name from filename: HHMMSS_DDD_mic1_DeviceName.m4a
                    let filename = url.deletingPathExtension().lastPathComponent
                    let parts = filename.split(separator: "_")
                    let deviceName = parts.count > 3 ? parts.dropFirst(3).joined(separator: "_") : "Unknown"
                    return MicFileInfo(
                        deviceName: deviceName,
                        url: url,
                        startOffset: 0,  // Unknown without metadata
                        duration: 0      // Unknown without metadata
                    )
                }
            return (nil, micFiles)
        }
    }

    /// If no mics, just rename system audio to _audio.m4a
    private func renameSystemToAudio(systemAudioURL: URL, segmentDirectory: URL) throws -> URL {
        let systemFilename = systemAudioURL.lastPathComponent
        let outputFilename = systemFilename.replacingOccurrences(of: "_system.m4a", with: "_audio.m4a")
        let outputURL = segmentDirectory.appendingPathComponent(outputFilename)

        try FileManager.default.moveItem(at: systemAudioURL, to: outputURL)
        Log.info("Renamed system audio to: \(outputFilename) (no mics)")
        return outputURL
    }

    /// Determines if this is a "fixed" segment (no mic list changes)
    private func isFixedSegment(micFiles: [MicFileInfo], metadata: MicsMetadata?, config: RemixConfig) -> Bool {
        guard let metadata = metadata else {
            // Without metadata, assume it's a changed segment (include all mics)
            return micFiles.count <= 1
        }

        guard let topMic = selectHighestPriorityMic(from: micFiles, config: config) else {
            return true  // No mics = fixed by definition
        }

        // Check for coverage gap: late start OR early end
        let hasLateStart = topMic.startOffset > config.startOffsetThreshold
        let hasEarlyEnd = topMic.duration < (metadata.segmentDuration * config.coverageThreshold)

        if hasLateStart || hasEarlyEnd {
            Log.debug("Changed segment: late start=\(hasLateStart), early end=\(hasEarlyEnd)", verbose: verbose)
            return false
        }

        // Check for device swap: multiple mics with non-overlapping time ranges
        if micFiles.count > 1 {
            let sorted = micFiles.sorted { $0.startOffset < $1.startOffset }
            for i in 1..<sorted.count {
                let prev = sorted[i - 1]
                let curr = sorted[i]
                let prevEnd = prev.startOffset + prev.duration
                // If current mic started after previous ended (with 1s tolerance)
                if curr.startOffset > prevEnd - 1.0 {
                    Log.debug("Changed segment: device swap detected", verbose: verbose)
                    return false
                }
            }
        }

        return true
    }

    private func selectHighestPriorityMic(from micFiles: [MicFileInfo], config: RemixConfig) -> MicFileInfo? {
        for name in config.microphonePriority {
            if let mic = micFiles.first(where: { $0.deviceName == name }) {
                return mic
            }
        }
        return micFiles.first
    }

    private func selectMicsForRemix(
        micFiles: [MicFileInfo],
        config: RemixConfig,
        isFixed: Bool
    ) -> [MicFileInfo] {
        if isFixed {
            // Fixed segment: just the highest priority mic
            if let topMic = selectHighestPriorityMic(from: micFiles, config: config) {
                return [topMic]
            }
            return []
        } else {
            // Changed segment: include all mics, sorted by priority
            return micFiles.sorted { mic1, mic2 in
                let idx1 = config.microphonePriority.firstIndex(of: mic1.deviceName) ?? Int.max
                let idx2 = config.microphonePriority.firstIndex(of: mic2.deviceName) ?? Int.max
                return idx1 < idx2
            }
        }
    }

    private func createMultiTrackM4A(
        outputURL: URL,
        systemAudioURL: URL,
        micFiles: [MicFileInfo],
        segmentDuration: TimeInterval
    ) async throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create asset writer
        let writer = try AVAssetWriter(url: outputURL, fileType: .m4a)

        // Audio settings for all tracks (AAC, 48kHz, mono)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]

        // Create input for system audio (Track 1)
        let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemInput.expectsMediaDataInRealTime = false
        writer.add(systemInput)

        // Create inputs for each mic
        var micInputs: [(input: AVAssetWriterInput, startOffset: CMTime, url: URL)] = []
        for mic in micFiles {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            let startOffset = CMTime(seconds: mic.startOffset, preferredTimescale: 48_000)
            micInputs.append((input, startOffset, mic.url))
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process system audio
        try await processTrack(
            sourceURL: systemAudioURL,
            input: systemInput,
            startOffset: .zero
        )

        // Process each mic file
        for (input, startOffset, url) in micInputs {
            try await processTrack(
                sourceURL: url,
                input: input,
                startOffset: startOffset
            )
        }

        // Finish writing
        await writer.finishWriting()

        if writer.status == .failed {
            throw RemixError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
    }

    private func processTrack(
        sourceURL: URL,
        input: AVAssetWriterInput,
        startOffset: CMTime
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            input.markAsFinished()
            Log.debug("No audio track in \(sourceURL.lastPathComponent)", verbose: verbose)
            return
        }

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)

        guard reader.startReading() else {
            throw RemixError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        // If we have a start offset, we need to write silence first
        if startOffset.seconds > 0 {
            try await writeSilence(to: input, duration: startOffset)
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            // Adjust timing for startOffset
            let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let adjustedTime = CMTimeAdd(originalTime, startOffset)

            if let adjustedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                }
                input.append(adjustedBuffer)
            }
        }

        input.markAsFinished()
    }

    /// Write silence to a track for the given duration
    private func writeSilence(to input: AVAssetWriterInput, duration: CMTime) async throws {
        let sampleRate: Double = 48_000
        let totalSamples = Int(duration.seconds * sampleRate)

        // Create silence in chunks to avoid huge allocations
        let chunkSize = 4800  // 100ms at 48kHz
        var samplesWritten = 0

        while samplesWritten < totalSamples {
            let samplesToWrite = min(chunkSize, totalSamples - samplesWritten)
            let silentData = Data(repeating: 0, count: samplesToWrite * 4)  // 4 bytes per float sample

            // Create audio buffer
            var blockBuffer: CMBlockBuffer?
            silentData.withUnsafeBytes { ptr in
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: silentData.count,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: silentData.count,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                if let blockBuffer = blockBuffer {
                    CMBlockBufferReplaceDataBytes(
                        with: ptr.baseAddress!,
                        blockBuffer: blockBuffer,
                        offsetIntoDestination: 0,
                        dataLength: silentData.count
                    )
                }
            }

            guard let buffer = blockBuffer else { continue }

            // Create sample buffer
            var formatDescription: CMAudioFormatDescription?
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )

            guard let format = formatDescription else { continue }

            let presentationTime = CMTime(
                value: CMTimeValue(samplesWritten),
                timescale: CMTimeScale(sampleRate)
            )

            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(samplesToWrite), timescale: CMTimeScale(sampleRate)),
                presentationTimeStamp: presentationTime,
                decodeTimeStamp: .invalid
            )

            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: buffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: format,
                sampleCount: samplesToWrite,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )

            if let sb = sampleBuffer {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                input.append(sb)
            }

            samplesWritten += samplesToWrite
        }
    }

    private func createRetimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, newTime: CMTime) -> CMSampleBuffer? {
        var newSampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
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
