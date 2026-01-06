// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

/// Removes silent tracks from a multi-track M4A file
public final class SilentTrackRemover: Sendable {
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Removes silent tracks from an M4A file
    /// - Parameters:
    ///   - url: Path to the M4A file
    ///   - silenceInfo: Map of trackIndex -> hadMeaningfulAudio (true = keep, false = remove)
    ///   - trackInfo: Information about each track (for logging)
    /// - Returns: Number of tracks removed (0 if no re-encoding needed)
    public func removeSilentTracks(
        from url: URL,
        silenceInfo: [Int: Bool],
        trackInfo: [AudioTrackInfo] = []
    ) async throws -> Int {
        // Count how many tracks need to be removed
        let silentTrackIndices = silenceInfo.filter { trackIndex, hadAudio in
            // Track 0 is system audio - never remove
            trackIndex > 0 && !hadAudio
        }.map(\.key)

        if silentTrackIndices.isEmpty {
            Log.debug("No silent tracks to remove", verbose: verbose)
            return 0
        }

        // Log which tracks will be removed
        for index in silentTrackIndices.sorted() {
            let trackName = trackInfo.first { $0.trackIndex == index }?.trackType.displayName ?? "Track \(index)"
            Log.info("Removing silent track: \(trackName)")
        }

        // Read the source file
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard audioTracks.count > 1 else {
            // Only one track, nothing to remove
            return 0
        }

        // Determine which tracks to keep (by index)
        let tracksToKeep = silenceInfo.filter { trackIndex, hadAudio in
            // Keep track 0 (system audio) always, and any track with meaningful audio
            trackIndex == 0 || hadAudio
        }.map(\.key).sorted()

        guard tracksToKeep.count < audioTracks.count else {
            // All tracks have audio, nothing to remove
            return 0
        }

        // Create temporary output URL
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".m4a")

        // Create asset writer
        let writer = try AVAssetWriter(url: tempURL, fileType: .m4a)

        // Audio settings for output
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        // Create readers and writers for each track to keep
        var trackPairs: [(reader: AVAssetReaderTrackOutput, writer: AVAssetWriterInput)] = []

        for trackIndex in tracksToKeep {
            guard trackIndex < audioTracks.count else { continue }
            let sourceTrack = audioTracks[trackIndex]

            // Create reader output
            let readerOutput = AVAssetReaderTrackOutput(
                track: sourceTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )

            // Create writer input
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            writerInput.expectsMediaDataInRealTime = false

            if writer.canAdd(writerInput) {
                writer.add(writerInput)
                trackPairs.append((reader: readerOutput, writer: writerInput))
            }
        }

        guard !trackPairs.isEmpty else {
            throw SilentTrackRemoverError.noTracksToWrite
        }

        // Create asset reader
        let reader = try AVAssetReader(asset: asset)
        for pair in trackPairs {
            if reader.canAdd(pair.reader) {
                reader.add(pair.reader)
            }
        }

        // Start reading and writing
        guard reader.startReading() else {
            throw SilentTrackRemoverError.failedToStartReader(reader.error)
        }

        guard writer.startWriting() else {
            throw SilentTrackRemoverError.failedToStartWriter(writer.error)
        }

        writer.startSession(atSourceTime: .zero)

        // Process each track sequentially (simpler and avoids concurrency issues)
        for pair in trackPairs {
            while let sampleBuffer = pair.reader.copyNextSampleBuffer() {
                while !pair.writer.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
                pair.writer.append(sampleBuffer)
            }
            pair.writer.markAsFinished()
        }

        // Wait for writing to complete
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw SilentTrackRemoverError.writeFailed(writer.error)
        }

        reader.cancelReading()

        // Replace original file with processed file
        let fm = FileManager.default
        try fm.removeItem(at: url)
        try fm.moveItem(at: tempURL, to: url)

        let removedCount = silentTrackIndices.count
        Log.info("Removed \(removedCount) silent track(s) from \(url.lastPathComponent)")

        return removedCount
    }
}

/// Errors for SilentTrackRemover
public enum SilentTrackRemoverError: Error, LocalizedError {
    case noTracksToWrite
    case failedToStartReader(Error?)
    case failedToStartWriter(Error?)
    case writeFailed(Error?)

    public var errorDescription: String? {
        switch self {
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
