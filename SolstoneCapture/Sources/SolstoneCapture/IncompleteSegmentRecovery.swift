// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import SolstoneCaptureCore

/// Recovers orphaned .incomplete segment directories on startup
/// Attempts to remix audio and rename files/directories to final format
public final class IncompleteSegmentRecovery: Sendable {
    private let verbose: Bool

    /// Minimum age (in seconds) for a segment to be considered stale and recoverable
    /// Segments newer than this are assumed to be actively recording
    private let minimumAge: TimeInterval = 120  // 2 minutes

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Scan captures directory and recover any incomplete segments
    /// - Returns: Number of successfully recovered segments
    public func recoverAll() async -> Int {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)

        guard fm.fileExists(atPath: capturesDir.path) else {
            return 0
        }

        var recoveredCount = 0

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

                // Check if directory is old enough to be stale
                if let attrs = try? fm.attributesOfItem(atPath: segmentDir.path),
                   let creationDate = attrs[.creationDate] as? Date
                {
                    let age = Date().timeIntervalSince(creationDate)
                    if age < minimumAge {
                        Log.debug("Skipping recent incomplete segment: \(segmentDir.lastPathComponent)", verbose: verbose)
                        continue
                    }
                }

                Log.info("Attempting to recover incomplete segment: \(segmentDir.lastPathComponent)")

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
    private func recoverSegment(at url: URL) async -> Bool {
        let fm = FileManager.default
        let dirName = url.lastPathComponent

        // Parse timePrefix from directory name (e.g., "143022" from "143022.incomplete")
        guard dirName.hasSuffix(".incomplete") else { return false }
        let timePrefix = String(dirName.dropLast(".incomplete".count))

        // List all files in the directory
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            Log.warn("Failed to list contents of \(dirName)")
            return await markAsFailed(url)
        }

        // Find video file(s) to get duration
        let videoFiles = files.filter { $0.pathExtension == "mp4" }
        guard let primaryVideo = videoFiles.first else {
            Log.warn("No video file found in \(dirName)")
            return await markAsFailed(url)
        }

        // Get duration from video file
        let duration: Int
        do {
            let asset = AVURLAsset(url: primaryVideo)
            let videoDuration = try await asset.load(.duration)
            duration = Int(CMTimeGetSeconds(videoDuration))
            if duration <= 0 {
                Log.warn("Video has zero duration in \(dirName)")
                return await markAsFailed(url)
            }
        } catch {
            Log.warn("Failed to get video duration in \(dirName): \(error)")
            return await markAsFailed(url)
        }

        // Find individual audio files (exclude consolidated audio file)
        // Pattern: HHMMSS_audio_*.m4a but NOT HHMMSS_audio.m4a
        let audioFiles = files.filter { file in
            let name = file.lastPathComponent
            return name.hasPrefix("\(timePrefix)_audio_") && name.hasSuffix(".m4a")
        }

        // Check if consolidated audio already exists
        let consolidatedAudioName = "\(timePrefix)_audio.m4a"
        let consolidatedAudioURL = url.appendingPathComponent(consolidatedAudioName)
        let hasConsolidatedAudio = fm.fileExists(atPath: consolidatedAudioURL.path)

        // If we have individual audio files and no consolidated audio, remix them
        if !audioFiles.isEmpty && !hasConsolidatedAudio {
            Log.info("Remixing \(audioFiles.count) audio file(s) for \(dirName)")

            do {
                let inputs = try await buildAudioInputs(from: audioFiles, timePrefix: timePrefix)

                if inputs.isEmpty {
                    Log.warn("No valid audio inputs for remix in \(dirName)")
                } else {
                    let remixer = AudioRemixer(verbose: verbose)
                    let result = try await remixer.remix(
                        inputs: inputs,
                        to: consolidatedAudioURL,
                        skipSilent: true,
                        deleteSourceFiles: true
                    )
                    Log.info("Remixed \(result.tracksWritten) track(s), skipped \(result.silentTracksSkipped) silent")
                }
            } catch {
                Log.warn("Audio remix failed for \(dirName): \(error)")
                // Continue with recovery anyway - at least save the video
            }
        }

        // Build new segment key with duration
        let segmentKey = "\(timePrefix)_\(duration)"

        // Rename all files to include duration
        do {
            try renameFilesWithDuration(in: url, timePrefix: timePrefix, segmentKey: segmentKey)
        } catch {
            Log.warn("Failed to rename files in \(dirName): \(error)")
            return await markAsFailed(url)
        }

        // Rename directory from .incomplete to final format
        let parentDir = url.deletingLastPathComponent()
        let finalURL = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: url, to: finalURL)
            Log.info("Recovered segment: \(dirName) -> \(segmentKey)")
            return true
        } catch {
            Log.warn("Failed to rename directory \(dirName): \(error)")
            return await markAsFailed(url)
        }
    }

    /// Build AudioRemixerInput array from audio files
    private func buildAudioInputs(from audioFiles: [URL], timePrefix: String) async throws -> [AudioRemixerInput] {
        var inputs: [AudioRemixerInput] = []
        let fm = FileManager.default

        // Find the earliest creation time to use as base
        var baseTime = Date.distantFuture
        for file in audioFiles {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let creationDate = attrs[.creationDate] as? Date
            {
                if creationDate < baseTime {
                    baseTime = creationDate
                }
            }
        }

        if baseTime == Date.distantFuture {
            baseTime = Date()
        }

        for audioURL in audioFiles {
            guard let timingInfo = await buildTimingInfo(for: audioURL, baseTime: baseTime, timePrefix: timePrefix) else {
                Log.debug("Skipping audio file (no timing info): \(audioURL.lastPathComponent)", verbose: verbose)
                continue
            }

            inputs.append(AudioRemixerInput(url: audioURL, timingInfo: timingInfo))
        }

        // Sort: system audio first, then mics by source ID
        inputs.sort { a, b in
            let aIsSystem = a.timingInfo.trackType.sourceID == "system"
            let bIsSystem = b.timingInfo.trackType.sourceID == "system"

            if aIsSystem && !bIsSystem { return true }
            if !aIsSystem && bIsSystem { return false }
            return a.timingInfo.trackType.sourceID < b.timingInfo.trackType.sourceID
        }

        return inputs
    }

    /// Build timing info for an audio file based on file metadata
    private func buildTimingInfo(for audioURL: URL, baseTime: Date, timePrefix: String) async -> AudioTrackTimingInfo? {
        let fm = FileManager.default
        let asset = AVURLAsset(url: audioURL)

        // Get duration from asset
        guard let assetDuration = try? await asset.load(.duration),
              CMTimeGetSeconds(assetDuration) > 0
        else {
            return nil
        }

        // Get creation time for start offset
        let creationDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: audioURL.path),
           let date = attrs[.creationDate] as? Date
        {
            creationDate = date
        } else {
            creationDate = baseTime
        }

        let startOffsetSeconds = max(0, creationDate.timeIntervalSince(baseTime))
        let startOffset = CMTime(seconds: startOffsetSeconds, preferredTimescale: 48000)
        let endOffset = CMTimeAdd(startOffset, assetDuration)

        // Parse track type from filename
        let trackType = parseTrackType(from: audioURL.lastPathComponent, timePrefix: timePrefix)

        return AudioTrackTimingInfo(
            startOffset: startOffset,
            endOffset: endOffset,
            trackType: trackType,
            hasAudio: true
        )
    }

    /// Parse track type from filename
    /// Examples:
    ///   - 143022_audio_system.m4a -> .systemAudio
    ///   - 143022_audio_BuiltInMicrophoneDevice.m4a -> .microphone(name: "BuiltInMicrophoneDevice", deviceUID: "BuiltInMicrophoneDevice")
    private func parseTrackType(from filename: String, timePrefix: String) -> AudioTrackType {
        // Remove prefix and suffix: "143022_audio_" ... ".m4a"
        let prefix = "\(timePrefix)_audio_"
        let suffix = ".m4a"

        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return .microphone(name: "Unknown", deviceUID: "unknown")
        }

        let deviceID = String(filename.dropFirst(prefix.count).dropLast(suffix.count))

        if deviceID == "system" {
            return .systemAudio
        } else {
            // Use device ID as both name and UID (we don't have the original name)
            return .microphone(name: deviceID, deviceUID: deviceID)
        }
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
            Log.debug("Renamed: \(filename) -> \(newFilename)", verbose: verbose)
        }
    }

    /// Mark a segment as failed by renaming from .incomplete to .failed
    private func markAsFailed(_ url: URL) async -> Bool {
        let fm = FileManager.default
        let dirName = url.lastPathComponent

        guard dirName.hasSuffix(".incomplete") else { return false }

        let failedName = String(dirName.dropLast(".incomplete".count)) + ".failed"
        let parentDir = url.deletingLastPathComponent()
        let failedURL = parentDir.appendingPathComponent(failedName)

        do {
            try fm.moveItem(at: url, to: failedURL)
            Log.warn("Marked segment as failed: \(dirName) -> \(failedName)")
            return false
        } catch {
            Log.error("Failed to mark segment as failed: \(error)")
            return false
        }
    }
}
