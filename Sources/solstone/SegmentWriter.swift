// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import os
import SolstoneCore
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
    public let silenceMusic: Bool
    public let micMetadataJSON: String?
    public let audioDiagnostics: AudioCaptureRecorder?
    public let audioOwnership: AudioNativeOwnership?

    public init(segmentDirectory: URL, timePrefix: String, capturedDurationSeconds: Int?,
                audioInputs: [AudioRemixerInput], silenceMusic: Bool, micMetadataJSON: String?,
                audioDiagnostics: AudioCaptureRecorder? = nil, audioOwnership: AudioNativeOwnership? = nil) {
        self.segmentDirectory = segmentDirectory
        self.timePrefix = timePrefix
        self.capturedDurationSeconds = capturedDurationSeconds
        self.audioInputs = audioInputs
        self.silenceMusic = silenceMusic
        self.micMetadataJSON = micMetadataJSON
        self.audioDiagnostics = audioDiagnostics
        self.audioOwnership = audioOwnership
    }
}

@MainActor
public protocol SegmentScreenshotCapturing: AnyObject, Sendable {
    var onTerminalStop: (@MainActor () -> Void)? { get set }
    func start() async throws
    func stop() async
    func updateContentFilter(_ filter: SCContentFilter) async
    func finishWithTimeout(seconds: Double) async -> Result<(URL, Int), Error>?
}

public extension SegmentScreenshotCapturing {
    var onTerminalStop: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
}

public protocol SegmentAudioManaging: AnyObject, Sendable {
    func bindDiagnostics(_ recorder: AudioCaptureRecorder)
    func bindSystemAudioBudget(_ budget: AudioMediaBudget)
    func setSegmentStartTime(_ time: CMTime)
    func startSystemAudio() throws -> String
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer)
    func addMicrophone(_ device: AudioInputDevice) throws -> String
    func removeMicrophone(deviceUID: String)
    func deselectMicrophone(deviceUID: String)
    func hasMicrophone(deviceUID: String) -> Bool
    func activeMicrophoneUIDs() -> [String]
    func getMicMetadata() -> [[String: Any]]
    func finishAll() async -> [AudioRemixerInput]
    func audioStatistics() -> [String: AudioWriterStatistics]
    func audioOwnership() -> AudioNativeOwnership?
    func prepareToFinishCapture() -> CMTime
}

public extension SegmentAudioManaging {
    func deselectMicrophone(deviceUID: String) { removeMicrophone(deviceUID: deviceUID) }
    func bindDiagnostics(_ recorder: AudioCaptureRecorder) {}
    func bindSystemAudioBudget(_ budget: AudioMediaBudget) {}
    func audioStatistics() -> [String: AudioWriterStatistics] { [:] }
    func audioOwnership() -> AudioNativeOwnership? { nil }
    func prepareToFinishCapture() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
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

    public var onTerminalStop: (@MainActor () -> Void)?
    public var onCaptureIssue: (@MainActor (String) -> Void)?

    private var screenshotCapturers: [CGDirectDisplayID: any SegmentScreenshotCapturing] = [:]
    private var audioManager: (any SegmentAudioManaging)?
    private var audioDiagnostics: AudioCaptureRecorder?
    private var systemAudioCaptureManager: SystemAudioCaptureManager?
    private let verbose: Bool
    private let capturerStopTimeoutSeconds: TimeInterval
    private let audioFinishTimeoutSeconds: TimeInterval
    private let screenshotCapturerFactory: ScreenshotCapturerFactory
    private let audioManagerFactory: AudioManagerFactory

    /// When true, silence music-only portions of system audio during remix
    private let silenceMusic: Bool

    /// Time when capture actually started (for computing actual duration)
    private var captureStartHostTime: CMTime?

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
    ///   - silenceMusic: Silence music-only portions of system audio during remix
    ///   - verbose: Enable verbose logging
    public init(
        outputDirectory: URL,
        timePrefix: String,
        silenceMusic: Bool = true,
        verbose: Bool = false,
        capturerStopTimeoutSeconds: TimeInterval = 5,
        audioFinishTimeoutSeconds: TimeInterval = 10,
        screenshotCapturerFactory: @escaping ScreenshotCapturerFactory = SegmentWriter.defaultScreenshotCapturerFactory,
        audioManagerFactory: @escaping AudioManagerFactory = SegmentWriter.defaultAudioManagerFactory
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
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
            Logger.capture.error("ScreenshotCapturer: terminal capture failure for display \(info.displayID, privacy: .public), restart policy exhausted")
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
    ///   - sources: Capture sources to record (.screen, .microphone, or both)
    ///   - displayInfos: Information about displays to capture
    ///   - filters: Content filters keyed by display ID
    ///   - audioFilter: Content filter to use for persistent system audio
    ///   - mics: Initial microphone devices to start recording (optional)
    ///   - micCaptureManager: Shared capture manager for persistent mic engines (optional)
    ///   - systemAudioCaptureManager: Shared capture manager for persistent system audio stream (optional)
    @discardableResult
    public func start(
        sources: CaptureSources = .all,
        displayInfos: [DisplayInfo] = [],
        filters: [CGDirectDisplayID: SCContentFilter] = [:],
        audioFilter: SCContentFilter? = nil,
        mics: [AudioInputDevice] = [],
        micCaptureManager: MicrophoneCaptureManager? = nil,
        systemAudioCaptureManager: SystemAudioCaptureManager? = nil
    ) async throws -> CaptureSources {
        var constructedCapturers: [CGDirectDisplayID: any SegmentScreenshotCapturing] = [:]
        var successfulSources: CaptureSources = []
        var screenError: Error?
        var micError: Error?
        var micAwaitingRecovery = false
        let segmentStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        captureStartHostTime = segmentStartTime

        let initialMics = micCaptureManager?.microphonesForStartup(fallback: mics) ?? mics
        var expected: [(id: String, kind: String)] = []
        if sources.contains(.screen) { expected.append(("system", "system")) }
        if sources.contains(.microphone) {
            expected += initialMics.map { ($0.uid, "microphone") }
            if initialMics.isEmpty && micCaptureManager?.hasEmptySelection != true {
                expected.append(("microphone", "microphone"))
            }
        }
        let diagnostics = try AudioCaptureRecorder(directory: outputDirectory, timePrefix: timePrefix, expected: expected,
            onFirstFailure: { [weak self] in
                Task { @MainActor in self?.onCaptureIssue?(Self.audioHealthChanged) }
            })
        audioDiagnostics = diagnostics

        var manager: (any SegmentAudioManaging)?
        if sources.contains(.microphone) || sources.contains(.screen) {
            manager = audioManagerFactory(outputDirectory, timePrefix, micCaptureManager, verbose)
            self.audioManager = manager
            manager?.bindDiagnostics(diagnostics)
            if let systemAudioCaptureManager { manager?.bindSystemAudioBudget(systemAudioCaptureManager.mediaBudget) }
            manager?.setSegmentStartTime(segmentStartTime)
        } else {
            manager = nil
            self.audioManager = nil
        }

        // Screen capture subsystem
        if sources.contains(.screen) {
            do {
                guard !displayInfos.isEmpty else { throw CaptureManager.CaptureError.noDisplaysAvailable }
                // Audio failure must not tear down otherwise healthy screenshots.
                do {
                    if let manager { _ = try manager.startSystemAudio() }
                    if let sysAudioManager = systemAudioCaptureManager, let audioFilter {
                        self.systemAudioCaptureManager = sysAudioManager
                        sysAudioManager.setCallback(onError: { diagnostics.failure("system", stage: "capture", error: $0) }) { [weak manager] buffer in
                            manager?.appendSystemAudio(buffer)
                        }
                        try await sysAudioManager.start(filter: audioFilter)
                        diagnostics.started("system")
                    } else {
                        diagnostics.failure("system", stage: "start", error: NSError(domain: "SolstoneAudioCapture", code: 2))
                    }
                } catch {
                    diagnostics.failure("system", stage: "start", error: error)
                    Logger.capture.error("System audio failed to start; continuing screenshot capture")
                }

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
                    capturer.onTerminalStop = { [weak self] in
                        self?.onTerminalStop?()
                    }
                    constructedCapturers[info.displayID] = capturer
                }
                screenshotCapturers = constructedCapturers

                // Start all screenshot capturers
                for (_, capturer) in screenshotCapturers {
                    try await capturer.start()
                }
                successfulSources.insert(.screen)
            } catch {
                screenError = error
                diagnostics.failure("system", stage: "screen_start", error: error)
                Logger.capture.error("Failed to start screen capture subsystem: \(error, privacy: .public)")
                // Use the same bounded cleanup as a failed whole-segment start.
                await self.systemAudioCaptureManager?.stop()
                if let failedManager = manager {
                    await rollbackStart(manager: failedManager, capturers: constructedCapturers)
                }
                constructedCapturers.removeAll()
                manager = nil
                if sources.contains(.microphone) && !(micCaptureManager?.microphonesForStartup(fallback: mics) ?? mics).isEmpty {
                    let microphoneManager = audioManagerFactory(outputDirectory, timePrefix, micCaptureManager, verbose)
                    microphoneManager.bindDiagnostics(diagnostics)
                    // Screen rollback clears state; the microphone fallback is
                    // still part of this same segment and keeps its origin.
                    captureStartHostTime = segmentStartTime
                    microphoneManager.setSegmentStartTime(segmentStartTime)
                    manager = microphoneManager
                    self.audioManager = microphoneManager
                }
                for info in displayInfos {
                    let url = outputDirectory.appendingPathComponent("\(timePrefix)_display_\(info.displayID)_screen.mp4")
                    try? FileManager.default.removeItem(at: url)
                }
                let systemURL = outputDirectory.appendingPathComponent("\(timePrefix)_audio_\(AudioTrackType.systemSourceID).m4a")
                try? FileManager.default.removeItem(at: systemURL)
                self.systemAudioCaptureManager = nil
            }
        }

        // Microphone subsystem
        if sources.contains(.microphone) {
            let currentMics = micCaptureManager?.microphonesForStartup(fallback: mics) ?? mics
            if currentMics.isEmpty && micCaptureManager?.hasEmptySelection != true {
                diagnostics.expect("microphone", kind: "microphone")
                diagnostics.failure("microphone", stage: "start", error: NSError(domain: "SolstoneAudioDevice", code: 2))
            }
            if let manager {
                var startedAnyMic = false
                var micStartFailed = false
                for device in currentMics {
                    do {
                        _ = try manager.addMicrophone(device)
                        diagnostics.started(device.uid)
                        startedAnyMic = true
                    } catch {
                        if error as? MicrophoneCaptureManager.SelectionError == .selectionChanged { continue }
                        diagnostics.failure(device.uid, stage: "start", error: error)
                        micStartFailed = true
                        Logger.capture.warning("Failed to start mic \(device.name, privacy: .public): \(error, privacy: .public)")
                    }
                }
                if startedAnyMic {
                    successfulSources.insert(.microphone)
                }
                // A selected microphone that failed to start is retried by recovery
                // into this segment; a microphone-only segment still begins.
                micAwaitingRecovery = micStartFailed
            } else {
                micError = SegmentError.failedToCreateAudioOutput
            }
        }

        if successfulSources.isEmpty && !(sources == .microphone && (micCaptureManager?.hasEmptySelection == true || micAwaitingRecovery)) {
            if let manager {
                await rollbackStart(manager: manager, capturers: constructedCapturers)
            }
            try diagnostics.seal(failed: true)
            if let screenError {
                throw screenError
            }
            if let micError {
                throw micError
            }
            throw SegmentError.failedToCreateAudioOutput
        }

        Logger.capture.info("Started segment (\(successfulSources.logDescription, privacy: .public)): \(self.outputDirectory.lastPathComponent, privacy: .public)")
        return successfulSources
    }

    // MARK: - Dynamic Microphone Management

    /// Add a microphone during recording (no segment rotation needed)
    /// - Parameter device: The audio input device to add
    public func addMicrophone(_ device: AudioInputDevice) throws {
        guard finishTask == nil else { throw SegmentError.segmentFinishing }
        guard let manager = audioManager else {
            throw SegmentError.failedToCreateAudioOutput
        }
        audioDiagnostics?.expect(device.uid, kind: "microphone")
        do {
            _ = try manager.addMicrophone(device)
            audioDiagnostics?.started(device.uid)
        } catch {
            if error as? MicrophoneCaptureManager.SelectionError == .selectionChanged { return }
            audioDiagnostics?.failure(device.uid, stage: "start", error: error)
            throw error
        }
    }

    /// Remove a microphone during recording (graceful stop)
    /// - Parameter deviceUID: The device UID to remove
    public func removeMicrophone(deviceUID: String) {
        audioManager?.removeMicrophone(deviceUID: deviceUID)
    }

    public func deselectMicrophone(deviceUID: String) {
        audioManager?.deselectMicrophone(deviceUID: deviceUID)
    }

    /// A running engine that stopped delivering is real loss: record it, then
    /// release the capture so reconciliation rebuilds it into the retained writer.
    /// Sent through `onCaptureIssue` when audio health changed; the owner-facing text
    /// is derived from current source health, not from this signal.
    public static let audioHealthChanged = "audio-health-changed"
    public func sourcesWithLoss() -> [String] { audioDiagnostics?.sourcesWithLoss() ?? [] }

    public func recordMicrophoneStall(deviceUID: String) {
        audioDiagnostics?.failure(deviceUID, stage: "stall", error: NSError(domain: "SolstoneAudioStall", code: 1))
        audioManager?.deselectMicrophone(deviceUID: deviceUID)
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
    /// Stops audio admission now. Pause and stop call this before the slower finish,
    /// so nothing said after the owner paused reaches the segment.
    public func cutAudio() {
        systemAudioCaptureManager?.clearCallback()
        _ = audioManager?.prepareToFinishCapture()
    }

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
        let captureCutoff = audioManager?.prepareToFinishCapture() ?? CMClockGetTime(CMClockGetHostTimeClock())

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
            } catch let error as TimeoutError {
                Logger.capture.warning("Timed out finishing audio writers; proceeding without audio inputs")
                audioDiagnostics?.finishFailure(error)
                audioInputs = []
            } catch {
                Logger.capture.warning("Failed to finish audio writers: \(error, privacy: .public)")
                audioDiagnostics?.finishFailure(error)
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
        if let startTime = captureStartHostTime {
            capturedDurationSeconds = clampedSegmentDurationSeconds(CMTimeSubtract(captureCutoff, startTime).seconds)
        } else {
            Logger.capture.warning("No capture start time recorded")
            capturedDurationSeconds = nil
        }

        for (id, statistics) in audioManager?.audioStatistics() ?? [:] { audioDiagnostics?.statistics(id, statistics) }
        do { try audioDiagnostics?.seal() }
        catch {
            Logger.capture.error("Segment audio metadata could not be saved; preserving failed segment")
            onCaptureIssue?("segment metadata could not be saved; segment preserved for recovery")
            await markIncompleteSegmentAsFailed(outputDirectory)
            return nil
        }
        Logger.capture.info("Capture finished, queued for background remix: \(self.outputDirectory.lastPathComponent, privacy: .public)")

        return SegmentCaptureResult(
            segmentDirectory: outputDirectory,
            timePrefix: timePrefix,
            capturedDurationSeconds: capturedDurationSeconds,
            audioInputs: audioInputs,
            silenceMusic: silenceMusic,
            micMetadataJSON: micMetadataJSON,
            audioDiagnostics: audioDiagnostics,
            audioOwnership: audioManager?.audioOwnership()
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
        captureStartHostTime = nil
    }

    /// Errors that can occur during segment recording
    public enum SegmentError: Error, LocalizedError {
        case failedToCreateScreenshotCapturer(displayID: CGDirectDisplayID)
        case failedToCreateAudioOutput
        case segmentFinishing
        case missingContentFilter(displayID: CGDirectDisplayID)

        public var errorDescription: String? {
            switch self {
            case .failedToCreateScreenshotCapturer(let displayID):
                return "Failed to create screenshot capturer for display \(displayID)"
            case .failedToCreateAudioOutput:
                return "Failed to create audio output"
            case .segmentFinishing:
                return "this segment has finished accepting audio."
            case .missingContentFilter(let displayID):
                return "Missing SCContentFilter for display \(displayID)"
            }
        }
    }
}
