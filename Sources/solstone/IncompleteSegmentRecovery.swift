// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

/// Recovers orphaned .incomplete segment directories on app startup and in-session via the capture heartbeat.
/// Remixes per-source audio and finalizes files/directories to HHMMSS_<duration>, excluding the
/// currently-recording segment by full standardized path so live recording is never finalized out from under the pipeline.
public final class IncompleteSegmentRecovery: IncompleteSegmentRecovering, Sendable {
    private let verbose: Bool
    private let capturesDirectory: URL?
    private let remixerFactory: @Sendable (Bool) -> any AudioRemixing

    static let stalenessMargin: TimeInterval = 60
    @MainActor
    static var minimumStaleAge: TimeInterval { SegmentWriter.segmentDuration + stalenessMargin }

    static func shouldSkipAsTooRecent(creationDate: Date?, now: Date, minimumAge: TimeInterval) -> Bool {
        guard let creationDate else { return true }
        return now.timeIntervalSince(creationDate) < minimumAge
    }

    public init(
        verbose: Bool = false,
        capturesDirectory: URL? = nil,
        remixerFactory: @escaping @Sendable (Bool) -> any AudioRemixing = { AudioRemixer(verbose: $0) }
    ) {
        self.verbose = verbose
        self.capturesDirectory = capturesDirectory
        self.remixerFactory = remixerFactory
    }

    /// Scan captures directory and recover any incomplete segments
    /// - Returns: Number of successfully recovered segments
    public func recoverAll(excludingActiveSegment activeSegmentPath: String? = nil) async -> Int {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = capturesDirectory ?? appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)

        guard fm.fileExists(atPath: capturesDir.path) else {
            return 0
        }

        var recoveredCount = 0
        let minimumStaleAge = await Self.minimumStaleAge

        // Find all date directories
        guard let dateDirs = try? fm.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for dateDir in dateDirs {
            // Find .incomplete directories within each date directory
            guard let segmentDirs = try? fm.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for segmentDir in segmentDirs {
                guard segmentDir.lastPathComponent.hasSuffix(".incomplete") else {
                    continue
                }

                // Skip .failed directories
                guard !segmentDir.lastPathComponent.hasSuffix(".failed") else {
                    continue
                }

                if let activeSegmentPath, segmentDir.standardizedFileURL.path == activeSegmentPath {
                    if verbose { Logger.storage.debug("Skipping active recording segment: \(segmentDir.lastPathComponent, privacy: .public)") }
                    continue
                }

                let creationDate = (try? fm.attributesOfItem(atPath: segmentDir.path))?[.creationDate] as? Date
                if Self.shouldSkipAsTooRecent(creationDate: creationDate, now: Date(), minimumAge: minimumStaleAge) {
                    if verbose { Logger.storage.debug("Skipping recent incomplete segment: \(segmentDir.lastPathComponent, privacy: .public)") }
                    continue
                }

                Logger.storage.info("Attempting to recover incomplete segment: \(segmentDir.lastPathComponent, privacy: .public)")

                if await recoverSegment(at: segmentDir) {
                    recoveredCount += 1
                }
            }
        }

        return recoveredCount
    }

    /// Recover a single incomplete segment directory
    /// - Parameter url: Path to the .incomplete directory
    /// - Returns: true if recovery succeeded
    internal func recoverSegment(at url: URL) async -> Bool {
        let fm = FileManager.default
        let dirName = url.lastPathComponent

        // Parse timePrefix from directory name (e.g., "143022" from "143022.incomplete")
        guard dirName.hasSuffix(".incomplete") else { return false }
        let timePrefix = String(dirName.dropLast(".incomplete".count))

        // List all files in the directory
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            Logger.storage.warning("Failed to list contents of \(dirName, privacy: .public)")
            return await markAsFailed(url)
        }

        // Find video file(s) to get duration
        let videoFiles = files.filter { $0.pathExtension == "mp4" }
        guard let primaryVideo = videoFiles.first else {
            Logger.storage.warning("No video file found in \(dirName, privacy: .public)")
            return await markAsFailed(url)
        }

        // Get duration from video file
        let duration: Int
        do {
            let asset = AVURLAsset(url: primaryVideo)
            let videoDuration = try await asset.load(.duration)
            duration = Int(CMTimeGetSeconds(videoDuration))
            if duration <= 0 {
                Logger.storage.warning("Video has zero duration in \(dirName, privacy: .public)")
                return await markAsFailed(url)
            }
        } catch {
            Logger.storage.warning("Failed to get video duration in \(dirName, privacy: .public): \(error, privacy: .public)")
            return await markAsFailed(url)
        }

        // Find individual audio files (exclude consolidated audio file)
        // Pattern: HHMMSS_audio_*.m4a but NOT HHMMSS_audio.m4a
        let audioFiles = audioSourceFiles(in: files, timePrefix: timePrefix)

        // Check if consolidated audio already exists
        let consolidatedAudioName = "\(timePrefix)_audio.m4a"
        let consolidatedAudioURL = url.appendingPathComponent(consolidatedAudioName)
        let hasConsolidatedAudio = fm.fileExists(atPath: consolidatedAudioURL.path)

        // If we have individual audio files and no consolidated audio, remix them
        if !audioFiles.isEmpty && !hasConsolidatedAudio {
            Logger.storage.info("Remixing \(audioFiles.count, privacy: .public) audio file(s) for \(dirName, privacy: .public)")

            do {
                let inputs = await buildAudioInputs(from: audioFiles, timePrefix: timePrefix, verbose: verbose)

                if inputs.isEmpty {
                    Logger.storage.warning("No valid audio inputs for remix in \(dirName, privacy: .public)")
                    return await markAsFailed(url)
                } else {
                    let remixer = makeRemixer(verbose: verbose)
                    let result = try await remixer.remix(
                        inputs: inputs,
                        to: consolidatedAudioURL,
                        deleteSourceFiles: true,
                        silenceMusic: true
                    )
                    Logger.storage.info("Remixed \(result.tracksWritten, privacy: .public) track(s), skipped \(result.tracksSkipped, privacy: .public)")
                }
            } catch AudioRemixerError.noTracksToWrite {
                Logger.storage.info("No audio tracks to write during recovery for \(dirName, privacy: .public)")
            } catch {
                Logger.storage.warning("Audio remix failed for \(dirName, privacy: .public): \(error, privacy: .public)")
                return await markAsFailed(url)
            }
        }

        // Build new segment key with duration
        let segmentKey = "\(timePrefix)_\(duration)"

        // Rename all files to include duration
        do {
            try renameFilesWithDuration(in: url, timePrefix: timePrefix, segmentKey: segmentKey)
        } catch {
            Logger.storage.warning("Failed to rename files in \(dirName, privacy: .public): \(error, privacy: .public)")
            return await markAsFailed(url)
        }

        // Rename directory from .incomplete to final format
        let parentDir = url.deletingLastPathComponent()
        let finalURL = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: url, to: finalURL)
            Logger.storage.info("Recovered segment: \(dirName, privacy: .public) -> \(segmentKey, privacy: .public)")
            return true
        } catch {
            Logger.storage.warning("Failed to rename directory \(dirName, privacy: .public): \(error, privacy: .public)")
            return await markAsFailed(url)
        }
    }

    /// Create the remixer used for recovery.
    private func makeRemixer(verbose: Bool) -> any AudioRemixing {
        remixerFactory(verbose)
    }

    /// Rename all files in directory to include duration suffix
    private func renameFilesWithDuration(in directory: URL, timePrefix: String, segmentKey: String) throws {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files {
            let filename = file.lastPathComponent

            // Only rename files that start with the time prefix
            guard filename.hasPrefix(timePrefix) else { continue }

            // Replace timePrefix with segmentKey (which includes duration)
            let newFilename = segmentKey + filename.dropFirst(timePrefix.count)
            let newURL = directory.appendingPathComponent(newFilename)

            // Skip if already renamed
            if filename == newFilename { continue }

            try fm.moveItem(at: file, to: newURL)
            if verbose { Logger.storage.debug("Renamed: \(filename, privacy: .public) -> \(newFilename, privacy: .public)") }
        }
    }

    /// Mark a segment as failed by renaming from .incomplete to .failed
    private func markAsFailed(_ url: URL) async -> Bool {
        await markIncompleteSegmentAsFailed(url)
    }
}
