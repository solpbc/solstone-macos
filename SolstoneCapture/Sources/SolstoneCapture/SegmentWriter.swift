// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
    private var audioOutput: AudioStreamOutput?
    private(set) var audioStream: SCStream?
    private let verbose: Bool

    /// Time when capture actually started (for computing actual duration)
    private var captureStartTime: Date?

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

        // Create system audio output (named _system.m4a; remixed audio will be _audio.m4a)
        let audioURL = outputDirectory.appendingPathComponent("\(timePrefix)_system.m4a")
        guard let audio = AudioStreamOutput.create(
            audioURL: audioURL,
            duration: Self.segmentDuration,
            verbose: verbose
        ) else {
            throw SegmentError.failedToCreateAudioOutput
        }
        audioOutput = audio

        // Configure audio-only stream
        // We still need SCStream for system audio capture (SCScreenshotManager is image-only)
        let config = SCStreamConfiguration()
        config.sampleRate = 48_000
        config.channelCount = 1
        config.capturesAudio = true
        config.captureMicrophone = false  // Mic recording handled by CaptureManager

        // Create audio-only stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.audioStream = stream

        // Add audio output only (no video outputs - we use screenshots instead)
        if let audioOutput = audioOutput {
            try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        }

        // Start audio stream
        try await stream.startCapture()

        // Start all screenshot capturers
        for (_, capturer) in screenshotCapturers {
            capturer.start()
        }

        captureStartTime = Date()
        Log.info("Started segment using SCScreenshotManager (1fps periodic capture): \(outputDirectory.lastPathComponent)")
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
    /// Note: Mic recording is handled by CaptureManager and hot-swapped during rotation
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

        // Finish audio (system audio)
        if let audioOutput = audioOutput {
            _ = audioOutput.finish()
            // Wait for audio completion using withCheckedContinuation
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = audioOutput.sema.wait(timeout: .now() + 5)
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
                    case .success(let (url, frameCount)):
                        Log.info("Saved video for display \(displayID): \(url.lastPathComponent) (\(frameCount) frames)")
                    case .failure(let error):
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
        // From: 143022_system.m4a -> 143022_127_system.m4a
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
