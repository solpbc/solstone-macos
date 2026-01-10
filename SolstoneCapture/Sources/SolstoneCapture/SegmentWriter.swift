// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCaptureCore

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
}

/// Manages recording for a single 5-minute segment
/// Thread safety: Always accessed from MainActor context (via CaptureManager)
@MainActor
public final class SegmentWriter {
    /// The directory containing this segment's files (initially HHMMSS.incomplete)
    public let outputDirectory: URL

    /// The time prefix for file naming (e.g., "143022")
    public let timePrefix: String

    private var videoFrameWriters: [CGDirectDisplayID: VideoFrameWriter] = [:]
    private var audioManager: PerSourceAudioManager?
    private var systemAudioCaptureManager: SystemAudioCaptureManager?
    private var videoCaptureManager: PersistentVideoCaptureManager?
    private let verbose: Bool

    /// Closure to check if audio is muted (passed to PerSourceAudioManager)
    private let isAudioMuted: @Sendable () -> Bool

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
    ///   - isAudioMuted: Closure to check if audio is muted
    ///   - debugKeepRejectedAudio: Move rejected audio tracks to rejected/ subfolder instead of deleting
    ///   - silenceMusic: Silence music-only portions of system audio during remix
    ///   - verbose: Enable verbose logging
    public init(
        outputDirectory: URL,
        timePrefix: String,
        isAudioMuted: @escaping @Sendable () -> Bool = { false },
        debugKeepRejectedAudio: Bool = false,
        silenceMusic: Bool = true,
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.isAudioMuted = isAudioMuted
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
    }

    /// Starts recording to this segment
    /// - Parameters:
    ///   - displayInfos: Information about displays to capture
    ///   - filter: The content filter to use (for system audio window exclusion)
    ///   - mics: Initial microphone devices to start recording (optional)
    ///   - micCaptureManager: Shared capture manager for persistent mic engines (optional)
    ///   - systemAudioCaptureManager: Shared capture manager for persistent system audio stream (optional)
    ///   - videoCaptureManager: Shared capture manager for persistent video streams (optional)
    public func start(
        displayInfos: [DisplayInfo],
        filter: SCContentFilter,
        mics: [AudioInputDevice] = [],
        micCaptureManager: MicrophoneCaptureManager? = nil,
        systemAudioCaptureManager: SystemAudioCaptureManager? = nil,
        videoCaptureManager: PersistentVideoCaptureManager? = nil
    ) async throws {
        // Store reference to persistent video capture manager
        self.videoCaptureManager = videoCaptureManager
        Log.info("SegmentWriter: start() called with \(displayInfos.count) displays, videoCaptureManager=\(videoCaptureManager != nil ? "present" : "nil")")

        // Create video frame writers for each display
        for info in displayInfos {
            let videoURL = outputDirectory.appendingPathComponent("\(timePrefix)_display_\(info.displayID)_screen.mp4")

            let writer = try VideoFrameWriter(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: Self.frameRate,
                duration: Self.segmentDuration,
                verbose: verbose
            )

            videoFrameWriters[info.displayID] = writer

            // Wire callback from persistent video stream to this writer
            // Called synchronously on SCStream callback thread - VideoFrameWriter is thread-safe
            if let videoManager = videoCaptureManager {
                Log.info("SegmentWriter: Wiring callback for display \(info.displayID)")
                videoManager.setCallback(for: info.displayID) { [weak writer] buffer in
                    writer?.appendFrame(buffer)
                }
            } else {
                Log.warn("SegmentWriter: videoCaptureManager is nil, cannot wire callback for display \(info.displayID)")
            }
        }

        // Create per-source audio manager (with shared capture manager if provided)
        let manager: PerSourceAudioManager
        if let captureManager = micCaptureManager {
            manager = PerSourceAudioManager(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                captureManager: captureManager,
                isAudioMuted: isAudioMuted,
                verbose: verbose
            )
        } else {
            manager = PerSourceAudioManager(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                isAudioMuted: isAudioMuted,
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
        if let sysAudioManager = systemAudioCaptureManager {
            try await sysAudioManager.start(filter: filter)
            sysAudioManager.setCallback { [weak manager] buffer in
                manager?.appendSystemAudio(buffer)
            }
        }

        // Start initial microphones
        for device in mics {
            do {
                _ = try manager.addMicrophone(device)
            } catch {
                Log.warn("Failed to start mic \(device.name): \(error)")
            }
        }

        captureStartTime = Date()
        Log.info("Started segment with persistent video streams: \(outputDirectory.lastPathComponent)")
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

    // Note: Video content filters are now managed by PersistentVideoCaptureManager
    // System audio filter is managed by CaptureManager via SystemAudioCaptureManager

    /// Finishes recording, remixes audio, and closes all files
    public func finish() async {
        // Clear video callbacks first (streams keep running for next segment)
        videoCaptureManager?.clearCallbacks()

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
                Log.info("Audio remix complete: \(result.tracksWritten) tracks, \(result.tracksSkipped) skipped")
            } catch {
                Log.error("Audio remix failed: \(error)")
            }
        }

        // Finish all video frame writers
        Log.info("Finishing \(videoFrameWriters.count) video output(s)...")
        for (displayID, writer) in videoFrameWriters {
            Log.info("Waiting for video finish on display \(displayID)...")
            await withCheckedContinuation { continuation in
                writer.finish { result in
                    Log.info("Video finish callback fired for display \(displayID)")
                    switch result {
                    case let .success((url, frameCount)):
                        Log.info("Saved video for display \(displayID): \(url.lastPathComponent) (\(frameCount) frames)")
                    case let .failure(error):
                        Log.warn("Error finishing video for display \(displayID): \(error)")
                    }
                    continuation.resume()
                }
            }
            Log.info("Video finish complete for display \(displayID)")
        }
        Log.info("All video outputs finished")

        Log.debug("Finished segment: \(outputDirectory.lastPathComponent)", verbose: verbose)
    }

    /// Finishes capture and returns data for background remix
    /// Does NOT wait for remix - returns immediately after streams stop
    /// Use this for segment rotation to minimize gap between segments
    public func finishCapture() async -> SegmentCaptureResult? {
        // Clear video callbacks first (streams keep running for next segment)
        videoCaptureManager?.clearCallbacks()

        // Clear system audio callback (stream keeps running for next segment)
        systemAudioCaptureManager?.clearCallback()

        // Finish audio writers (but don't remix - returns inputs for background remix)
        var audioInputs: [AudioRemixerInput] = []
        if let manager = audioManager {
            audioInputs = await manager.finishAll()
        }

        // Finish all video frame writers
        Log.debug("Finishing \(videoFrameWriters.count) video output(s)...", verbose: verbose)
        for (displayID, writer) in videoFrameWriters {
            await withCheckedContinuation { continuation in
                writer.finish { result in
                    switch result {
                    case let .success((url, frameCount)):
                        Log.debug("Saved video for display \(displayID): \(url.lastPathComponent) (\(frameCount) frames)", verbose: self.verbose)
                    case let .failure(error):
                        Log.warn("Error finishing video for display \(displayID): \(error)")
                    }
                    continuation.resume()
                }
            }
        }

        guard let startTime = captureStartTime else {
            Log.warn("No capture start time recorded")
            return nil
        }

        Log.info("Capture finished, queued for background remix: \(outputDirectory.lastPathComponent)")

        return SegmentCaptureResult(
            segmentDirectory: outputDirectory,
            timePrefix: timePrefix,
            captureStartTime: startTime,
            audioInputs: audioInputs,
            debugKeepRejected: debugKeepRejectedAudio,
            silenceMusic: silenceMusic
        )
    }

    /// Finishes recording and renames segment to reflect actual duration
    /// - Returns: URL to the renamed segment directory, or original if rename failed
    public func finishAndRename() async -> URL {
        await finish()

        // Calculate actual duration
        guard let startTime = captureStartTime else {
            Log.warn("No capture start time recorded, keeping original segment name")
            return outputDirectory
        }

        let actualDuration = Int(Date().timeIntervalSince(startTime))
        let segmentKey = "\(timePrefix)_\(actualDuration)"

        Log.info("Finalizing segment: \(timePrefix).incomplete -> \(segmentKey)")

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
            Log.warn("Failed to rename segment files: \(error)")
            return outputDirectory
        }

        // Rename the directory from HHMMSS.incomplete to HHMMSS_duration
        let parentDir = outputDirectory.deletingLastPathComponent()
        let newDirectory = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: outputDirectory, to: newDirectory)
            Log.info("Renamed segment directory to: \(segmentKey)")
            return newDirectory
        } catch {
            Log.warn("Failed to rename segment directory: \(error)")
            return outputDirectory
        }
    }

    /// Errors that can occur during segment recording
    public enum SegmentError: Error, LocalizedError {
        case failedToCreateVideoWriter(displayID: CGDirectDisplayID)
        case failedToCreateAudioOutput

        public var errorDescription: String? {
            switch self {
            case .failedToCreateVideoWriter(let displayID):
                return "Failed to create video writer for display \(displayID)"
            case .failedToCreateAudioOutput:
                return "Failed to create audio output"
            }
        }
    }
}
