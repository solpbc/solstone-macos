// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Information about a display for recording
public struct DisplayInfo: Sendable {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let bounds: CGRect  // Global screen coordinates

    public init(displayID: CGDirectDisplayID, width: Int, height: Int, bounds: CGRect) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.bounds = bounds
    }

    public init(from display: SCDisplay) {
        self.displayID = display.displayID
        self.width = display.width
        self.height = display.height
        // Get display bounds from CoreGraphics
        self.bounds = CGDisplayBounds(display.displayID)
    }
}

/// Result from finishing capture (used for background remix)
public struct SegmentCaptureResult: Sendable {
    public let segmentDirectory: URL
    public let timePrefix: String
    public let captureStartTime: Date
    public let audioInputs: [AudioRemixerInput]
    public let debugKeepRejected: Bool
    public let silenceMusic: Bool
    public let micMetadataJSON: String?
}

/// Manages recording for a single 5-minute segment
/// Thread safety: Always accessed from MainActor context (via CaptureManager)
@MainActor
public final class SegmentWriter {
    /// The directory containing this segment's files (initially HHMMSS.incomplete)
    public let outputDirectory: URL

    /// The time prefix for file naming (e.g., "143022")
    public let timePrefix: String

    private var screenshotCapturers: [CGDirectDisplayID: ScreenshotCapturer] = [:]
    private var audioManager: PerSourceAudioManager?
    private var systemAudioCaptureManager: SystemAudioCaptureManager?
    private let verbose: Bool

    /// When true, move rejected audio tracks to rejected/ subfolder instead of deleting
    private let debugKeepRejectedAudio: Bool

    /// When true, silence music-only portions of system audio during remix
    private let silenceMusic: Bool

    /// Time when capture actually started (for computing actual duration)
    private var captureStartTime: Date?

    /// Segment duration in seconds (default 5 minutes, can be changed for debug mode)
    public static var segmentDuration: TimeInterval = 300

    /// Frame rate for video capture
    public static let frameRate: Double = 1.0

    /// Creates a new segment writer
    /// - Parameters:
    ///   - outputDirectory: Directory to write segment files to (with .incomplete suffix)
    ///   - timePrefix: Time prefix for file naming (e.g., "143022")
    ///   - debugKeepRejectedAudio: Move rejected audio tracks to rejected/ subfolder instead of deleting
    ///   - silenceMusic: Silence music-only portions of system audio during remix
    ///   - verbose: Enable verbose logging
    public init(
        outputDirectory: URL,
        timePrefix: String,
        debugKeepRejectedAudio: Bool = false,
        silenceMusic: Bool = true,
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
    }

    /// Starts recording to this segment
    /// - Parameters:
    ///   - displayInfos: Information about displays to capture
    ///   - filters: Content filters keyed by display ID
    ///   - audioFilter: Content filter to use for persistent system audio
    ///   - mics: Initial microphone devices to start recording (optional)
    ///   - micCaptureManager: Shared capture manager for persistent mic engines (optional)
    ///   - systemAudioCaptureManager: Shared capture manager for persistent system audio stream (optional)
    public func start(
        displayInfos: [DisplayInfo],
        filters: [CGDirectDisplayID: SCContentFilter],
        audioFilter: SCContentFilter?,
        mics: [AudioInputDevice] = [],
        micCaptureManager: MicrophoneCaptureManager? = nil,
        systemAudioCaptureManager: SystemAudioCaptureManager? = nil
    ) async throws {
        for info in displayInfos {
            guard filters[info.displayID] != nil else {
                throw SegmentError.missingContentFilter(displayID: info.displayID)
            }
        }

        // Create screenshot capturers for each display
        for info in displayInfos {
            let videoURL = outputDirectory.appendingPathComponent("\(timePrefix)_display_\(info.displayID)_screen.mp4")

            let filter = filters[info.displayID]!
            let capturer = try ScreenshotCapturer(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: Self.frameRate,
                duration: Self.segmentDuration,
                contentFilter: filter,
                verbose: verbose
            )
            capturer.onHealthFailure = {
                Logger.capture.warning("ScreenshotCapturer: health failure reported for display \(info.displayID, privacy: .public)")
            }

            screenshotCapturers[info.displayID] = capturer
        }

        // Create per-source audio manager (with shared capture manager if provided)
        let manager: PerSourceAudioManager
        if let captureManager = micCaptureManager {
            manager = PerSourceAudioManager(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                captureManager: captureManager,
                verbose: verbose
            )
        } else {
            manager = PerSourceAudioManager(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                verbose: verbose
            )
        }
        self.audioManager = manager

        // Record segment start time
        let segmentStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        manager.setSegmentStartTime(segmentStartTime)

        // Start system audio writer
        _ = try manager.startSystemAudio()

        // Store reference to persistent system audio manager
        self.systemAudioCaptureManager = systemAudioCaptureManager

        // Start persistent system audio stream and wire callback to this segment's manager
        if let sysAudioManager = systemAudioCaptureManager, let audioFilter {
            try await sysAudioManager.start(filter: audioFilter)
            sysAudioManager.setCallback { [weak manager] buffer in
                manager?.appendSystemAudio(buffer)
            }
        }

        // Start initial microphones
        for device in mics {
            do {
                _ = try manager.addMicrophone(device)
            } catch {
                Logger.capture.warning("Failed to start mic \(device.name, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Start all screenshot capturers
        for (_, capturer) in screenshotCapturers {
            await capturer.start()
        }

        captureStartTime = Date()
        Logger.capture.info("Started segment using SCScreenshotManager (1fps periodic capture): \(self.outputDirectory.lastPathComponent, privacy: .public)")
    }

    // MARK: - Dynamic Microphone Management

    /// Add a microphone during recording (no segment rotation needed)
    /// - Parameter device: The audio input device to add
    public func addMicrophone(_ device: AudioInputDevice) throws {
        guard let manager = audioManager else {
            throw SegmentError.failedToCreateAudioOutput
        }
        _ = try manager.addMicrophone(device)
    }

    /// Remove a microphone during recording (graceful stop)
    /// - Parameter deviceUID: The device UID to remove
    public func removeMicrophone(deviceUID: String) {
        audioManager?.removeMicrophone(deviceUID: deviceUID)
    }

    /// Check if a microphone is currently being recorded
    public func hasMicrophone(deviceUID: String) -> Bool {
        return audioManager?.hasMicrophone(deviceUID: deviceUID) ?? false
    }

    /// Get list of currently active microphone UIDs
    public func activeMicrophoneUIDs() -> [String] {
        return audioManager?.activeMicrophoneUIDs() ?? []
    }

    /// Updates the content filter for window exclusion (video only)
    /// Note: System audio filter is managed by CaptureManager via SystemAudioCaptureManager
    /// - Parameter filters: New content filters keyed by display ID
    public func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws {
        // Update all screenshot capturers
        for (displayID, capturer) in screenshotCapturers {
            guard let filter = filters[displayID] else {
                let keyList = filters.keys.sorted().map(String.init).joined(separator: ",")
                Logger.capture.error("Missing SCContentFilter for display \(displayID, privacy: .public); available filter keys=[\(keyList, privacy: .public)]")
                continue
            }
            await capturer.updateContentFilter(filter)
        }
    }

    /// Finishes recording, remixes audio, and closes all files
    public func finish() async {
        // Stop all screenshot capturers first
        Logger.capture.info("Stopping \(self.screenshotCapturers.count, privacy: .public) screenshot capturer(s)...")
        for (displayID, capturer) in screenshotCapturers {
            Logger.capture.info("Stopping capturer for display \(displayID, privacy: .public)...")
            await capturer.stop()
        }

        // Clear system audio callback (stream keeps running for next segment)
        systemAudioCaptureManager?.clearCallback()

        // Finish audio manager and remix to single file
        if let manager = audioManager {
            let audioURL = outputDirectory.appendingPathComponent("\(timePrefix)_audio.m4a")
            do {
                let result = try await manager.finishAndRemix(
                    to: audioURL,
                    debugKeepRejected: debugKeepRejectedAudio,
                    deleteSourceFiles: true,
                    silenceMusic: silenceMusic
                )
                Logger.capture.info("Audio remix complete: \(result.tracksWritten, privacy: .public) tracks, \(result.tracksSkipped, privacy: .public) skipped")
            } catch {
                Logger.capture.error("Audio remix failed: \(error, privacy: .public)")
            }
        }

        // Finish all screenshot capturers (video writers)
        Logger.capture.info("Finishing \(self.screenshotCapturers.count, privacy: .public) video output(s)...")
        for (displayID, capturer) in screenshotCapturers {
            Logger.capture.info("Waiting for video finish on display \(displayID, privacy: .public)...")
            let result = await capturer.finishWithTimeout(seconds: 10)
            if let result {
                Logger.capture.info("Video finish callback fired for display \(displayID, privacy: .public)")
                switch result {
                case let .success((url, frameCount)):
                    Logger.capture.info("Saved video for display \(displayID, privacy: .public): \(url.lastPathComponent, privacy: .public) (\(frameCount, privacy: .public) frames)")
                case let .failure(error):
                    Logger.capture.warning("Error finishing video for display \(displayID, privacy: .public): \(error, privacy: .public)")
                }
            }
            Logger.capture.info("Video finish complete for display \(displayID, privacy: .public)")
        }
        Logger.capture.info("All video outputs finished")

        if verbose { Logger.capture.debug("Finished segment: \(self.outputDirectory.lastPathComponent, privacy: .public)") }
    }

    /// Finishes capture and returns data for background remix
    /// Does NOT wait for remix - returns immediately after streams stop
    /// Use this for segment rotation to minimize gap between segments
    public func finishCapture() async -> SegmentCaptureResult? {
        // Stop all screenshot capturers first
        Logger.capture.info("Stopping \(self.screenshotCapturers.count, privacy: .public) screenshot capturer(s) for background remix...")
        for (displayID, capturer) in screenshotCapturers {
            if verbose { Logger.capture.debug("Stopping capturer for display \(displayID, privacy: .public)...") }
            await capturer.stop()
        }

        // Clear system audio callback (stream keeps running for next segment)
        systemAudioCaptureManager?.clearCallback()

        // Capture mic metadata BEFORE finishAll() clears the state
        let micMetadata = getMicMetadata()
        let micMetadataJSON: String?
        if !micMetadata.isEmpty {
            let metadata: [String: Any] = ["mics": micMetadata]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
               let jsonString = String(data: data, encoding: .utf8) {
                micMetadataJSON = jsonString
            } else {
                micMetadataJSON = nil
            }
        } else {
            micMetadataJSON = nil
        }

        // Finish audio writers (but don't remix - returns inputs for background remix)
        var audioInputs: [AudioRemixerInput] = []
        if let manager = audioManager {
            audioInputs = await manager.finishAll()
        }

        // Finish all screenshot capturers (video writers)
        if verbose { Logger.capture.debug("Finishing \(self.screenshotCapturers.count, privacy: .public) video output(s)...") }
        for (displayID, capturer) in screenshotCapturers {
            let result = await capturer.finishWithTimeout(seconds: 10)
            if let result {
                switch result {
                case let .success((url, frameCount)):
                    if self.verbose { Logger.capture.debug("Saved video for display \(displayID, privacy: .public): \(url.lastPathComponent, privacy: .public) (\(frameCount, privacy: .public) frames)") }
                case let .failure(error):
                    Logger.capture.warning("Error finishing video for display \(displayID, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        guard let startTime = captureStartTime else {
            Logger.capture.warning("No capture start time recorded")
            return nil
        }

        Logger.capture.info("Capture finished, queued for background remix: \(self.outputDirectory.lastPathComponent, privacy: .public)")

        return SegmentCaptureResult(
            segmentDirectory: outputDirectory,
            timePrefix: timePrefix,
            captureStartTime: startTime,
            audioInputs: audioInputs,
            debugKeepRejected: debugKeepRejectedAudio,
            silenceMusic: silenceMusic,
            micMetadataJSON: micMetadataJSON
        )
    }

    /// Get mic metadata collected during this segment
    public func getMicMetadata() -> [[String: Any]] {
        return audioManager?.getMicMetadata() ?? []
    }

    /// Finishes recording and renames segment to reflect actual duration
    /// - Returns: URL to the renamed segment directory, or original if rename failed
    public func finishAndRename() async -> URL {
        // Capture mic metadata before finish() clears the audio manager state
        let micMetadata = getMicMetadata()

        await finish()

        // Write metadata file if we have mic metadata
        if !micMetadata.isEmpty {
            writeMetadataFile(mics: micMetadata)
        }

        // Calculate actual duration
        guard let startTime = captureStartTime else {
            Logger.capture.warning("No capture start time recorded, keeping original segment name")
            return outputDirectory
        }

        let actualDuration = Int(Date().timeIntervalSince(startTime))
        let segmentKey = "\(timePrefix)_\(actualDuration)"

        Logger.capture.info("Finalizing segment: \(self.timePrefix, privacy: .public).incomplete -> \(segmentKey, privacy: .public)")

        let fm = FileManager.default

        // Rename files inside the directory to add duration
        // From: 143022_audio.m4a -> 143022_127_audio.m4a
        do {
            let files = try fm.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
            for fileURL in files {
                let filename = fileURL.lastPathComponent
                // Replace timePrefix_ with segmentKey_ in filename
                if filename.hasPrefix("\(timePrefix)_") {
                    let suffix = filename.dropFirst(timePrefix.count + 1)  // +1 for underscore
                    let newFilename = "\(segmentKey)_\(suffix)"
                    let newFileURL = outputDirectory.appendingPathComponent(newFilename)
                    try fm.moveItem(at: fileURL, to: newFileURL)
                }
            }
        } catch {
            Logger.capture.warning("Failed to rename segment files: \(error, privacy: .public)")
            return outputDirectory
        }

        // Rename the directory from HHMMSS.incomplete to HHMMSS_duration
        let parentDir = outputDirectory.deletingLastPathComponent()
        let newDirectory = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: outputDirectory, to: newDirectory)
            Logger.capture.info("Renamed segment directory to: \(segmentKey, privacy: .public)")
            return newDirectory
        } catch {
            Logger.capture.warning("Failed to rename segment directory: \(error, privacy: .public)")
            return outputDirectory
        }
    }

    /// Write metadata file to segment directory
    private func writeMetadataFile(mics: [[String: Any]]) {
        let metaURL = outputDirectory.appendingPathComponent("\(timePrefix)_meta.json")
        let metadata: [String: Any] = ["mics": mics]

        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metaURL)
            if verbose { Logger.capture.debug("Wrote metadata file: \(metaURL.lastPathComponent, privacy: .public)") }
        } catch {
            Logger.capture.warning("Failed to write metadata file: \(error, privacy: .public)")
        }
    }

    /// Errors that can occur during segment recording
    public enum SegmentError: Error, LocalizedError {
        case failedToCreateScreenshotCapturer(displayID: CGDirectDisplayID)
        case failedToCreateAudioOutput
        case missingContentFilter(displayID: CGDirectDisplayID)

        public var errorDescription: String? {
            switch self {
            case .failedToCreateScreenshotCapturer(let displayID):
                return "Failed to create screenshot capturer for display \(displayID)"
            case .failedToCreateAudioOutput:
                return "Failed to create audio output"
            case .missingContentFilter(let displayID):
                return "Missing SCContentFilter for display \(displayID)"
            }
        }
    }
}
