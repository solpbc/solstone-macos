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
    public let capturedDurationSeconds: Int?
    public let audioInputs: [AudioRemixerInput]
    public let debugKeepRejected: Bool
    public let silenceMusic: Bool
    public let micMetadataJSON: String?
}

@MainActor
public protocol SegmentScreenshotCapturing: AnyObject, Sendable {
    func start() async throws
    func stop() async
    func updateContentFilter(_ filter: SCContentFilter) async
    func finishWithTimeout(seconds: Double) async -> Result<(URL, Int), Error>?
}

public protocol SegmentAudioManaging: AnyObject, Sendable {
    func setSegmentStartTime(_ time: CMTime)
    func startSystemAudio() throws -> String
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer)
    func addMicrophone(_ device: AudioInputDevice) throws -> String
    func removeMicrophone(deviceUID: String)
    func hasMicrophone(deviceUID: String) -> Bool
    func activeMicrophoneUIDs() -> [String]
    func getMicMetadata() -> [[String: Any]]
    func finishAll() async -> [AudioRemixerInput]
}

extension ScreenshotCapturer: SegmentScreenshotCapturing {}
extension PerSourceAudioManager: SegmentAudioManaging {}

/// Manages recording for a single 5-minute segment
/// Thread safety: Always accessed from MainActor context (via CaptureManager)
@MainActor
public final class SegmentWriter {
    public typealias ScreenshotCapturerFactory = @MainActor @Sendable (
        _ info: DisplayInfo,
        _ videoURL: URL,
        _ frameRate: Double,
        _ duration: Double?,
        _ contentFilter: SCContentFilter?,
        _ verbose: Bool
    ) throws -> any SegmentScreenshotCapturing

    public typealias AudioManagerFactory = @Sendable (
        _ outputDirectory: URL,
        _ timePrefix: String,
        _ captureManager: MicrophoneCaptureManager?,
        _ verbose: Bool
    ) -> any SegmentAudioManaging

    /// The directory containing this segment's files (initially HHMMSS.incomplete)
    public let outputDirectory: URL

    /// The time prefix for file naming (e.g., "143022")
    public let timePrefix: String

    private var screenshotCapturers: [CGDirectDisplayID: any SegmentScreenshotCapturing] = [:]
    private var audioManager: (any SegmentAudioManaging)?
    private var systemAudioCaptureManager: SystemAudioCaptureManager?
    private let verbose: Bool
    private let capturerStopTimeoutSeconds: TimeInterval
    private let audioFinishTimeoutSeconds: TimeInterval
    private let screenshotCapturerFactory: ScreenshotCapturerFactory
    private let audioManagerFactory: AudioManagerFactory

    /// When true, move rejected audio tracks to rejected/ subfolder instead of deleting
    private let debugKeepRejectedAudio: Bool

    /// When true, silence music-only portions of system audio during remix
    private let silenceMusic: Bool

    /// Time when capture actually started (for computing actual duration)
    private var captureStartTime: Date?

    /// Shared finish task so concurrent lifecycle paths close the segment exactly once.
    private var finishTask: Task<SegmentCaptureResult?, Never>?

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
        verbose: Bool = false,
        capturerStopTimeoutSeconds: TimeInterval = 5,
        audioFinishTimeoutSeconds: TimeInterval = 10,
        screenshotCapturerFactory: @escaping ScreenshotCapturerFactory = SegmentWriter.defaultScreenshotCapturerFactory,
        audioManagerFactory: @escaping AudioManagerFactory = SegmentWriter.defaultAudioManagerFactory
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
        self.capturerStopTimeoutSeconds = capturerStopTimeoutSeconds
        self.audioFinishTimeoutSeconds = audioFinishTimeoutSeconds
        self.screenshotCapturerFactory = screenshotCapturerFactory
        self.audioManagerFactory = audioManagerFactory
    }

    internal var capturerStopTimeoutSecondsForTesting: TimeInterval { capturerStopTimeoutSeconds }

    internal var audioFinishTimeoutSecondsForTesting: TimeInterval { audioFinishTimeoutSeconds }

    public static let defaultScreenshotCapturerFactory: ScreenshotCapturerFactory = { info, videoURL, frameRate, duration, contentFilter, verbose in
        guard let contentFilter else {
            throw SegmentError.missingContentFilter(displayID: info.displayID)
        }

        let capturer = try ScreenshotCapturer(
            displayID: info.displayID,
            videoURL: videoURL,
            width: info.width,
            height: info.height,
            frameRate: frameRate,
            duration: duration,
            contentFilter: contentFilter,
            verbose: verbose
        )
        capturer.onHealthFailure = {
            Logger.capture.warning("ScreenshotCapturer: health failure reported for display \(info.displayID, privacy: .public)")
        }
        return capturer
    }

    public static let defaultAudioManagerFactory: AudioManagerFactory = { outputDirectory, timePrefix, captureManager, verbose in
        if let captureManager {
            return PerSourceAudioManager(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                captureManager: captureManager,
                verbose: verbose
            )
        }

        return PerSourceAudioManager(
            outputDirectory: outputDirectory,
            timePrefix: timePrefix,
            verbose: verbose
        )
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
        var constructedCapturers: [CGDirectDisplayID: any SegmentScreenshotCapturing] = [:]
        let manager = audioManagerFactory(outputDirectory, timePrefix, micCaptureManager, verbose)
        self.audioManager = manager

        do {
            // Create screenshot capturers for each display
            for info in displayInfos {
                let videoURL = outputDirectory.appendingPathComponent("\(timePrefix)_display_\(info.displayID)_screen.mp4")
                let capturer = try screenshotCapturerFactory(
                    info,
                    videoURL,
                    Self.frameRate,
                    Self.segmentDuration,
                    filters[info.displayID],
                    verbose
                )
                constructedCapturers[info.displayID] = capturer
            }

            screenshotCapturers = constructedCapturers

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
                try await capturer.start()
            }
        } catch {
            await rollbackStart(manager: manager, capturers: constructedCapturers)
            throw error
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

    /// Finishes capture and returns data for background remix
    /// Does NOT wait for remix - returns immediately after streams stop
    /// Use this for segment rotation to minimize gap between segments
    public func finishCapture() async -> SegmentCaptureResult? {
        if let finishTask {
            return await finishTask.value
        }

        let task = Task { @MainActor in
            await self.performFinishCapture()
        }
        finishTask = task
        return await task.value
    }

    private func performFinishCapture() async -> SegmentCaptureResult? {
        let finishInstant = Date()

        // Stop all screenshot capturers first
        Logger.capture.info("Stopping \(self.screenshotCapturers.count, privacy: .public) screenshot capturer(s) for background remix...")
        for (displayID, capturer) in screenshotCapturers {
            if verbose { Logger.capture.debug("Stopping capturer for display \(displayID, privacy: .public)...") }
            do {
                try await withTimeout(seconds: capturerStopTimeoutSeconds) {
                    await capturer.stop()
                }
            } catch is TimeoutError {
                Logger.capture.warning("Timeout stopping capturer for display \(displayID, privacy: .public)")
            } catch {
                Logger.capture.warning("Error stopping capturer for display \(displayID, privacy: .public): \(error, privacy: .public)")
            }
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
            do {
                audioInputs = try await withTimeout(seconds: audioFinishTimeoutSeconds) {
                    await manager.finishAll()
                }
            } catch is TimeoutError {
                Logger.capture.warning("Timed out finishing audio writers; proceeding without audio inputs")
                audioInputs = []
            } catch {
                Logger.capture.warning("Failed to finish audio writers: \(error, privacy: .public)")
                audioInputs = []
            }
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

        let capturedDurationSeconds: Int?
        if let startTime = captureStartTime {
            capturedDurationSeconds = clampedSegmentDurationSeconds(finishInstant.timeIntervalSince(startTime))
        } else {
            Logger.capture.warning("No capture start time recorded")
            capturedDurationSeconds = nil
        }

        Logger.capture.info("Capture finished, queued for background remix: \(self.outputDirectory.lastPathComponent, privacy: .public)")

        return SegmentCaptureResult(
            segmentDirectory: outputDirectory,
            timePrefix: timePrefix,
            capturedDurationSeconds: capturedDurationSeconds,
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

    private func rollbackStart(
        manager: any SegmentAudioManaging,
        capturers: [CGDirectDisplayID: any SegmentScreenshotCapturing]
    ) async {
        Logger.capture.warning("Rolling back partially started segment: \(self.outputDirectory.lastPathComponent, privacy: .public)")
        systemAudioCaptureManager?.clearCallback()

        for (displayID, capturer) in capturers {
            do {
                try await withTimeout(seconds: 5) {
                    await capturer.stop()
                }
            } catch {
                Logger.capture.warning("Failed to stop capturer during rollback for display \(displayID, privacy: .public): \(error, privacy: .public)")
            }
        }

        do {
            _ = try await withTimeout(seconds: 5) {
                await manager.finishAll()
            }
        } catch {
            Logger.capture.warning("Failed to finish audio writers during rollback: \(error, privacy: .public)")
        }

        screenshotCapturers.removeAll()
        audioManager = nil
        systemAudioCaptureManager = nil
        captureStartTime = nil
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
