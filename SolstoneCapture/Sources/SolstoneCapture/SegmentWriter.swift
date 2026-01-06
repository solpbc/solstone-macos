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

/// Manages recording for a single 5-minute segment
/// Thread safety: Always accessed from MainActor context (via CaptureManager)
@MainActor
public final class SegmentWriter {
    /// The directory containing this segment's files (initially HHMMSS.incomplete)
    public let outputDirectory: URL

    /// The time prefix for file naming (e.g., "143022")
    public let timePrefix: String

    private var screenshotCapturers: [CGDirectDisplayID: ScreenshotCapturer] = [:]
    private var multiTrackOutput: MultiTrackStreamOutput?
    private var multiTrackWriter: MultiTrackAudioWriter?
    private(set) var audioStream: SCStream?
    private let verbose: Bool

    /// Time when capture actually started (for computing actual duration)
    private var captureStartTime: Date?

    /// Track indices for external mics (deviceUID -> trackIndex)
    private var externalMicTracks: [String: Int] = [:]

    /// Recording start time for external mic timing
    private var recordingStartTime: CMTime?

    /// Segment duration in seconds (5 minutes)
    public static let segmentDuration: TimeInterval = 300

    /// Frame rate for video capture
    public static let frameRate: Double = 1.0

    /// Creates a new segment writer
    /// - Parameters:
    ///   - outputDirectory: Directory to write segment files to (with .incomplete suffix)
    ///   - timePrefix: Time prefix for file naming (e.g., "143022")
    ///   - verbose: Enable verbose logging
    public init(
        outputDirectory: URL,
        timePrefix: String,
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.verbose = verbose
    }

    /// Starts recording to this segment
    /// - Parameters:
    ///   - displayInfos: Information about displays to capture
    ///   - filter: The content filter to use (for window exclusion)
    ///   - startMics: If true, mic recording is handled externally (by CaptureManager)
    public func start(displayInfos: [DisplayInfo], filter: SCContentFilter, startMics: Bool = true) async throws {
        // Create screenshot capturers for each display
        for info in displayInfos {
            let videoURL = outputDirectory.appendingPathComponent("\(timePrefix)_display_\(info.displayID)_screen.mp4")

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

            screenshotCapturers[info.displayID] = capturer
        }

        // Create multi-track audio writer (single _audio.m4a with all tracks)
        let audioURL = outputDirectory.appendingPathComponent("\(timePrefix)_audio.m4a")
        let audioWriter = try MultiTrackAudioWriter(
            url: audioURL,
            duration: Self.segmentDuration,
            verbose: verbose
        )
        self.multiTrackWriter = audioWriter

        // Add system audio track (track 0 - never dropped)
        let systemTrackIndex = try audioWriter.addTrack(type: .systemAudio)

        // Create stream output that routes system audio to multi-track writer
        // Note: All mics (including built-in) are captured via ExternalMicCapture
        let output = MultiTrackStreamOutput(
            audioWriter: audioWriter,
            systemTrackIndex: systemTrackIndex,
            verbose: verbose
        )
        self.multiTrackOutput = output

        // Configure audio stream for system audio only
        let config = SCStreamConfiguration()
        config.sampleRate = 48_000
        config.channelCount = 1
        config.capturesAudio = true
        config.captureMicrophone = false  // All mics via ExternalMicCapture

        // Create audio stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.audioStream = stream

        // Add stream output for system audio only
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start audio stream
        try await stream.startCapture()

        // Record start time for external mic buffer timing
        recordingStartTime = CMClockGetTime(CMClockGetHostTimeClock())

        // Start all screenshot capturers
        for (_, capturer) in screenshotCapturers {
            capturer.start()
        }

        captureStartTime = Date()
        Log.info("Started segment using SCScreenshotManager (1fps periodic capture): \(outputDirectory.lastPathComponent)")
    }

    // MARK: - External Microphone Management

    /// Registers an external microphone and creates a track for it
    /// - Parameters:
    ///   - deviceUID: The unique identifier of the audio device
    ///   - name: Display name of the device
    /// - Returns: The track index for this microphone
    public func registerExternalMic(deviceUID: String, name: String) throws -> Int {
        guard let writer = multiTrackWriter else {
            throw SegmentError.failedToCreateAudioOutput
        }

        let trackIndex = try writer.addTrack(type: .microphone(name: name, deviceUID: deviceUID))
        externalMicTracks[deviceUID] = trackIndex
        Log.info("Registered external mic '\(name)' as track \(trackIndex)")
        return trackIndex
    }

    /// Appends audio from an external microphone
    /// - Parameters:
    ///   - buffer: The PCM audio buffer
    ///   - deviceUID: The device UID to identify the track
    ///   - presentationTime: The presentation timestamp
    public func appendExternalMicAudio(_ buffer: AVAudioPCMBuffer, deviceUID: String, presentationTime: CMTime) {
        guard let writer = multiTrackWriter,
              let trackIndex = externalMicTracks[deviceUID] else {
            return
        }

        writer.appendPCMBuffer(buffer, toTrack: trackIndex, presentationTime: presentationTime)
    }

    /// Returns silence information for all audio tracks
    public func getSilenceInfo() -> [Int: Bool] {
        return multiTrackWriter?.getSilenceInfo() ?? [:]
    }

    /// Returns track information for all audio tracks
    public func getTrackInfo() -> [AudioTrackInfo] {
        return multiTrackWriter?.getTrackInfo() ?? []
    }

    /// Updates the content filter for window exclusion
    /// - Parameter filter: The new content filter
    public func updateContentFilter(_ filter: SCContentFilter) async throws {
        // Update audio stream filter
        if let stream = audioStream {
            try await stream.updateContentFilter(filter)
        }

        // Update all screenshot capturers
        for (_, capturer) in screenshotCapturers {
            capturer.updateContentFilter(filter)
        }
    }

    /// Finishes recording and closes all files
    /// Note: External mic recording is handled by CaptureManager
    public func finish() async {
        // Stop all screenshot capturers first
        Log.info("Stopping \(screenshotCapturers.count) screenshot capturer(s)...")
        for (displayID, capturer) in screenshotCapturers {
            Log.info("Stopping capturer for display \(displayID)...")
            await capturer.stop()
        }

        // Stop audio stream
        if let stream = audioStream {
            do {
                try await stream.stopCapture()
            } catch {
                Log.warn("Error stopping audio stream: \(error)")
            }
            self.audioStream = nil
        }

        // Finish multi-track audio
        if let output = multiTrackOutput {
            _ = output.finish()
            // Wait for audio completion using withCheckedContinuation
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = output.sema.wait(timeout: .now() + 5)
                    continuation.resume()
                }
            }
        }

        // Finish all screenshot capturers (video writers)
        // Note: capturers were already stopped above, now just finish the video writers
        Log.info("Finishing \(screenshotCapturers.count) video output(s)...")
        for (displayID, capturer) in screenshotCapturers {
            Log.info("Waiting for video finish on display \(displayID)...")
            await withCheckedContinuation { continuation in
                capturer.finish { result in
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
        case failedToCreateScreenshotCapturer(displayID: CGDirectDisplayID)
        case failedToCreateAudioOutput

        public var errorDescription: String? {
            switch self {
            case .failedToCreateScreenshotCapturer(let displayID):
                return "Failed to create screenshot capturer for display \(displayID)"
            case .failedToCreateAudioOutput:
                return "Failed to create audio output"
            }
        }
    }
}
