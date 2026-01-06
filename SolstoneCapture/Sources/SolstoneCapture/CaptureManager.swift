// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCaptureCore

/// Manages continuous recording with segment rotation
/// Thread safety: All access is isolated to MainActor
@MainActor
public final class CaptureManager {
    /// Current state of the capture manager
    public enum State: Sendable {
        case idle
        case recording
        case paused
        case error(String)

        /// Check if state matches a case (ignoring associated values)
        var isIdle: Bool {
            if case .idle = self { return true }
            return false
        }

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isPaused: Bool {
            if case .paused = self { return true }
            return false
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    // MARK: - Properties

    private let storageManager: StorageManager
    private var currentSegment: SegmentWriter?
    private var segmentTimer: Timer?
    private var displays: [SCDisplay] = []
    private var contentFilter: SCContentFilter?
    private let verbose: Bool

    /// Window exclusion detector for filtering out specific app windows
    private let windowExclusionDetector: WindowExclusionDetector?

    /// Currently excluded windows (for change detection)
    private var currentExcludedWindowIDs: Set<CGWindowID> = []

    /// Flag to prevent filter updates during stream startup
    private var isStreamReady: Bool = false

    /// Flag to prevent concurrent segment rotations
    private var isRotatingSegment: Bool = false

    /// Track if we were recording before sleep (for resume on wake)
    private var wasRecordingBeforeSleep: Bool = false

    /// Current default microphone device ID (for change detection)
    private var currentDefaultMicID: AudioDeviceID?

    /// CoreAudio listener block for default mic changes (nonisolated for deinit)
    nonisolated(unsafe) private var defaultMicListenerBlock: AudioObjectPropertyListenerBlock?

    /// Persistent multi-microphone recorder (lives across segment rotations)
    private var multiMicRecorder: MultiMicRecorder?

    /// Current segment's output directory (for mic file rotation)
    private var currentSegmentDirectory: URL?
    private var currentTimePrefix: String?

    /// UIDs of microphones to exclude from recording (disabled mics)
    private var disabledMicUIDs: Set<String> = []

    public private(set) var state: State = .idle

    /// Called when a segment completes (for upload)
    public var onSegmentComplete: ((URL) async -> Void)?

    /// Called when state changes
    public var onStateChanged: ((State) -> Void)?

    /// Closure to get microphone priority list (for audio remixing)
    public var getMicrophonePriority: (() -> [String])?

    /// Time remaining in current segment
    public var segmentTimeRemaining: TimeInterval {
        guard let timer = segmentTimer else { return 0 }
        return max(0, timer.fireDate.timeIntervalSinceNow)
    }

    // MARK: - Initialization

    public init(
        storageManager: StorageManager,
        excludedAppNames: [String] = [],
        excludePrivateBrowsing: Bool = true,
        verbose: Bool = false
    ) {
        self.storageManager = storageManager
        self.verbose = verbose

        // Create window exclusion detector if we have apps to exclude or private browsing detection
        if !excludedAppNames.isEmpty || excludePrivateBrowsing {
            self.windowExclusionDetector = WindowExclusionDetector(
                appNames: excludedAppNames,
                detectPrivateBrowsing: excludePrivateBrowsing
            )
        } else {
            self.windowExclusionDetector = nil
        }

        // Listen for display changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleDisplayChange()
            }
        }

        // Listen for sleep/wake events
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleWillSleep()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleDidWake()
            }
        }

        // Listen for app activation changes (for window exclusion updates)
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Inline cleanup for default mic monitoring (can't call actor-isolated method from deinit)
        if let block = defaultMicListenerBlock {
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                DispatchQueue.main,
                block
            )
            defaultMicListenerBlock = nil
        }
    }

    // MARK: - Public Methods

    /// Starts recording
    /// - Parameter disabledMicUIDs: Set of microphone UIDs to exclude from recording
    public func startRecording(disabledMicUIDs: Set<String> = []) async throws {
        self.disabledMicUIDs = disabledMicUIDs
        guard state.isIdle || state.isPaused else { return }

        // Ensure storage directory exists
        try storageManager.ensureBaseDirectoryExists()

        // Get available content
        let content = try await SCShareableContent.current

        // Get all displays
        displays = content.displays
        guard !displays.isEmpty else {
            throw CaptureError.noDisplaysAvailable
        }

        // Create content filter for all displays
        contentFilter = SCContentFilter(display: displays[0], excludingApplications: [], exceptingWindows: [])

        // Start first segment
        try await startNewSegment()

        // Start monitoring for default microphone changes
        startDefaultMicMonitoring()

        state = .recording
        onStateChanged?(state)

        Log.info("Started recording session with \(displays.count) display(s)")
    }

    /// Stops recording
    public func stopRecording() async {
        // Mark stream as not ready
        isStreamReady = false

        // Stop monitoring for microphone changes
        stopDefaultMicMonitoring()

        // Cancel segment timer
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Stop mic recorder and get final results
        if let recorder = multiMicRecorder {
            let result = recorder.stop(deleteInactive: true)
            logMicResult(result, segmentDirectory: currentSegment?.outputDirectory)
            multiMicRecorder = nil
        }

        // Finish current segment and rename to actual duration
        var completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        }

        state = .idle
        onStateChanged?(state)

        Log.info("Stopped recording")

        // Remix and upload in background (don't block stop)
        if let url = completedSegmentURL {
            await remixAndUpload(url)
        }
    }

    /// Pauses recording (used when both audio and video are muted)
    public func pauseRecording() async {
        guard state.isRecording else { return }

        // Stop segment timer
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Stop mic recorder and get final results
        if let recorder = multiMicRecorder {
            let result = recorder.stop(deleteInactive: true)
            logMicResult(result, segmentDirectory: currentSegment?.outputDirectory)
            multiMicRecorder = nil
        }

        // Finish current segment and rename to actual duration
        var completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        }

        state = .paused
        onStateChanged?(state)

        Log.info("Paused recording")

        // Remix and upload in background (don't block pause)
        if let url = completedSegmentURL {
            await remixAndUpload(url)
        }
    }

    /// Resumes recording after pause
    public func resumeRecording() async throws {
        guard state.isPaused else { return }

        // Start new segment
        try await startNewSegment()

        state = .recording
        onStateChanged?(state)

        Log.info("Resumed recording")
    }

    // MARK: - Private Methods

    /// Starts a new recording segment (first segment only - creates directory and starts mics)
    private func startNewSegment() async throws {
        guard contentFilter != nil else {
            throw CaptureError.notInitialized
        }

        // Create segment directory with current time (named HHMMSS.incomplete)
        let (segmentDir, timePrefix) = try storageManager.createSegmentDirectory(
            segmentStartTime: Date()
        )

        // First segment - create and start mic recorder
        let recorder = MultiMicRecorder(
            outputDirectory: segmentDir,
            filePrefix: timePrefix,
            config: MultiMicConfig(maxMicrophones: 4),
            verbose: verbose
        )
        self.multiMicRecorder = recorder
        let micCount = try recorder.start(excludingUIDs: disabledMicUIDs)
        Log.debug("Started multi-mic capture for \(micCount) microphone(s)", verbose: verbose)

        // Start video/audio capture
        try await startNewSegmentWithDirectory(segmentDir, timePrefix: timePrefix)
    }

    /// Starts recording to a pre-created segment directory (used during rotation)
    private func startNewSegmentWithDirectory(_ segmentDir: URL, timePrefix: String) async throws {
        guard let filter = contentFilter else {
            throw CaptureError.notInitialized
        }

        // Reset stream ready flag for new segment
        isStreamReady = false
        currentExcludedWindowIDs = []

        // Track current segment info
        currentSegmentDirectory = segmentDir
        currentTimePrefix = timePrefix

        // Create segment writer
        let segment = SegmentWriter(
            outputDirectory: segmentDir,
            timePrefix: timePrefix,
            verbose: verbose
        )
        currentSegment = segment

        // Start recording - convert to DisplayInfo for sendable compliance
        let displayInfos = displays.map { DisplayInfo(from: $0) }
        try await segment.start(displayInfos: displayInfos, filter: filter, startMics: false)

        // Mark stream as ready after a short delay to allow capture to stabilize.
        // The 500ms delay ensures ScreenCaptureKit's stream is fully initialized
        // before we attempt to update content filters with window exclusions.
        // Without this delay, filter updates can fail or cause frame drops.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            isStreamReady = true
            await updateWindowExclusions()
        }

        // Schedule segment rotation
        scheduleSegmentRotation()
    }

    /// Log mic recording results and write metadata file
    private func logMicResult(_ result: MultiMicResult, segmentDirectory: URL? = nil) {
        for file in result.activeFiles {
            Log.info("Saved mic audio: \(file.url.lastPathComponent) from \(file.deviceName) (offset: \(String(format: "%.1f", file.startOffset))s, duration: \(String(format: "%.1f", file.duration))s)")
        }
        // Note: Silent mic deletions are logged individually in MultiMicRecorder.rotate()

        // Write mics.json metadata for upload priority selection
        // Derive directory from first file URL if not explicitly provided
        let dir = segmentDirectory ?? result.activeFiles.first?.url.deletingLastPathComponent()
        if let dir = dir, !result.activeFiles.isEmpty {
            writeMicsMetadata(result, to: dir)
        }
    }

    /// Write mics.json metadata file to segment directory
    private func writeMicsMetadata(_ result: MultiMicResult, to directory: URL) {
        struct MicEntry: Codable {
            let name: String
            let file: String
            let startOffset: Double
            let duration: Double
        }

        struct MicsMetadata: Codable {
            let segmentDuration: Double
            let mics: [MicEntry]
        }

        let entries = result.activeFiles.map { file in
            MicEntry(
                name: file.deviceName,
                file: file.url.lastPathComponent,
                startOffset: file.startOffset,
                duration: file.duration
            )
        }

        let metadata = MicsMetadata(
            segmentDuration: result.segmentDuration,
            mics: entries
        )

        let metadataURL = directory.appendingPathComponent("mics.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL)
            Log.debug("Wrote mics.json with \(entries.count) mic(s)", verbose: verbose)
        } catch {
            Log.warn("Failed to write mics.json: \(error)")
        }
    }

    private func scheduleSegmentRotation() {
        segmentTimer?.invalidate()
        let interval = Self.timeUntilNextSegmentBoundary()
        segmentTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.rotateSegment()
            }
        }
        Log.info("Next segment rotation in \(Int(interval)) seconds")
    }

    /// Calculate seconds until the next 5-minute clock boundary
    private static func timeUntilNextSegmentBoundary() -> TimeInterval {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .second], from: now)
        let minute = components.minute ?? 0
        let second = components.second ?? 0

        // Calculate seconds into the current 5-minute block
        let segmentMinutes = Int(SegmentWriter.segmentDuration / 60)
        let minutesIntoBlock = minute % segmentMinutes
        let secondsIntoBlock = (minutesIntoBlock * 60) + second

        // Time until next boundary
        let secondsUntilNext = Int(SegmentWriter.segmentDuration) - secondsIntoBlock

        // If we're exactly on a boundary, schedule for full duration
        return secondsUntilNext == 0 ? SegmentWriter.segmentDuration : TimeInterval(secondsUntilNext)
    }

    private func rotateSegment() async {
        guard state.isRecording else { return }

        // Prevent concurrent rotations
        guard !isRotatingSegment else {
            Log.debug("Segment rotation already in progress, skipping", verbose: verbose)
            return
        }
        isRotatingSegment = true
        defer { isRotatingSegment = false }

        Log.info("Rotating segment...")

        // Create new segment directory FIRST (so mics can rotate to it)
        let newSegmentDir: URL
        let newTimePrefix: String
        do {
            (newSegmentDir, newTimePrefix) = try storageManager.createSegmentDirectory(segmentStartTime: Date())
        } catch {
            state = .error("Failed to create segment directory: \(error.localizedDescription)")
            onStateChanged?(state)
            Log.error("Failed to rotate segment: \(error)")
            return
        }

        // Rotate mics to new directory BEFORE renaming old directory
        // This ensures mic cleanup happens while old directory still has .incomplete suffix
        if let recorder = multiMicRecorder, let oldDir = currentSegmentDirectory {
            let result = recorder.rotate(to: newSegmentDir, filePrefix: newTimePrefix, deleteInactive: true)
            logMicResult(result, segmentDirectory: oldDir)
        }

        // NOW finish and rename the old segment
        let completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
        } else {
            completedSegmentURL = nil
        }

        // Start recording to new segment
        do {
            try await startNewSegmentWithDirectory(newSegmentDir, timePrefix: newTimePrefix)
        } catch {
            state = .error("Failed to start new segment: \(error.localizedDescription)")
            onStateChanged?(state)
            Log.error("Failed to start new segment: \(error)")
        }

        // Remix and upload in background (non-blocking)
        // We start a Task (not detached) so we don't block segment rotation
        if let url = completedSegmentURL {
            Task {
                await remixAndUpload(url)
            }
        }
    }

    /// Remixes audio and triggers upload callback
    private func remixAndUpload(_ segmentURL: URL) async {
        let micPriority = getMicrophonePriority?() ?? []
        let isVerbose = verbose

        // Remix audio files
        let remixer = AudioRemixer(verbose: isVerbose)
        let config = RemixConfig(microphonePriority: micPriority)

        do {
            let result = try await remixer.remix(segmentDirectory: segmentURL, config: config)
            Log.info("Remixed segment: \(result.trackCount) tracks, deleted \(result.deletedFiles.count) files")
        } catch {
            Log.warn("Failed to remix segment audio: \(error)")
            // Don't fail the segment - original files remain for upload
        }

        // Trigger upload AFTER remix completes
        if let callback = onSegmentComplete {
            await callback(segmentURL)
        }
    }

    private func handleDisplayChange() async {
        guard state.isRecording else { return }

        Log.info("Display configuration changed")

        // Get new display list
        do {
            let content = try await SCShareableContent.current
            let newDisplays = content.displays

            // Check if displays changed
            let oldIDs = Set(displays.map { $0.displayID })
            let newIDs = Set(newDisplays.map { $0.displayID })

            if oldIDs != newIDs {
                Log.info("Display set changed, rotating segment")
                displays = newDisplays

                // Update filter
                if let firstDisplay = displays.first {
                    contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
                }

                // Force segment rotation to pick up new display config
                await rotateSegment()
            }
        } catch {
            Log.warn("Failed to get updated display list: \(error)")
        }
    }

    // MARK: - Sleep/Wake Handling

    /// Wait for at least one audio input device to become available
    /// - Parameter timeout: Maximum time to wait in seconds
    private func waitForAudioDevices(timeout: TimeInterval) async {
        let startTime = Date()
        let pollInterval: UInt64 = 100_000_000 // 100ms in nanoseconds

        while Date().timeIntervalSince(startTime) < timeout {
            let devices = MicrophoneMonitor.listInputDevices()
            if !devices.isEmpty {
                Log.info("Audio devices available after \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                return
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        // Timeout reached - log warning but don't fail
        // Recording can proceed without mic if needed
        Log.warn("Timeout waiting for audio devices after \(timeout)s")
    }

    private func handleWillSleep() async {
        Log.info("System going to sleep")

        // Remember if we were actively recording
        wasRecordingBeforeSleep = state.isRecording

        guard state.isRecording else { return }

        // Finish current segment gracefully before sleep
        segmentTimer?.invalidate()
        segmentTimer = nil

        // Stop mic recorder and get final results
        if let recorder = multiMicRecorder {
            let result = recorder.stop(deleteInactive: true)
            logMicResult(result, segmentDirectory: currentSegment?.outputDirectory)
            multiMicRecorder = nil
        }

        let completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        } else {
            completedSegmentURL = nil
        }

        state = .paused
        onStateChanged?(state)

        // Use beginActivity to request time for upload before system suspends
        // Fire async to avoid blocking MainActor during sleep transition
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            // Request system to delay sudden termination for our upload activity
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Uploading segment before sleep"
            )

            Task {
                Log.info("Starting upload in background before sleep")
                await callback(url)
                Log.info("Upload completed before sleep")
                ProcessInfo.processInfo.endActivity(activity)
            }
        }

        Log.info("Capture paused for sleep")
    }

    private func handleDidWake() async {
        Log.info("System woke from sleep")

        // Only resume if we were recording before sleep
        guard wasRecordingBeforeSleep else { return }
        wasRecordingBeforeSleep = false

        do {
            // Wait for audio devices to become available (up to 5 seconds)
            await waitForAudioDevices(timeout: 5.0)

            // Refresh display list
            let content = try await SCShareableContent.current
            displays = content.displays

            if let firstDisplay = displays.first {
                contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
            }

            // Update current default mic (may have changed on dock/undock)
            currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

            // Start fresh segment with current device state
            try await startNewSegment()

            state = .recording
            onStateChanged?(state)
            Log.info("Capture resumed after wake")
        } catch {
            state = .error("Failed to resume after wake: \(error.localizedDescription)")
            onStateChanged?(state)
            Log.error("Failed to resume capture after wake: \(error)")
        }
    }

    // MARK: - Default Microphone Monitoring

    private func startDefaultMicMonitoring() {
        currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                await self?.handleDefaultMicChange()
            }
        }
        defaultMicListenerBlock = block

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            Log.warn("Failed to add default mic listener: \(status)")
        } else {
            Log.debug("Started monitoring default microphone changes", verbose: verbose)
        }
    }

    private func stopDefaultMicMonitoring() {
        guard let block = defaultMicListenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
        defaultMicListenerBlock = nil
    }

    private func handleDefaultMicChange() async {
        guard state.isRecording else { return }

        let newDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

        // Check if default mic actually changed
        if newDefaultMicID != currentDefaultMicID {
            Log.info("Default microphone changed, restarting mic recorder")
            currentDefaultMicID = newDefaultMicID

            // Stop existing mic recorder and restart with fresh device list
            if let recorder = multiMicRecorder, let segmentDir = currentSegmentDirectory {
                let result = recorder.stop()
                logMicResult(result, segmentDirectory: segmentDir)
                multiMicRecorder = nil

                // Create new recorder with fresh device list
                let timePrefix = segmentDir.lastPathComponent.components(separatedBy: ".").first ?? ""
                let newRecorder = MultiMicRecorder(
                    outputDirectory: segmentDir,
                    filePrefix: timePrefix,
                    config: MultiMicConfig(maxMicrophones: 4),
                    verbose: verbose
                )
                self.multiMicRecorder = newRecorder
                do {
                    let micCount = try newRecorder.start()
                    Log.info("Restarted mic capture for \(micCount) microphone(s)")
                } catch {
                    Log.warn("Failed to restart mic recorder: \(error)")
                }
            }
        }
    }

    // MARK: - Window Exclusion

    /// Updates the content filter to exclude detected windows
    private func updateWindowExclusions() async {
        guard state.isRecording,
              isStreamReady,
              let detector = windowExclusionDetector,
              let segment = currentSegment,
              !displays.isEmpty else { return }

        // Detect windows to exclude
        let excludedWindows = await detector.detectExcludedWindows()
        let newExcludedIDs = Set(excludedWindows.map { $0.windowID })

        // Only update if exclusions changed
        guard newExcludedIDs != currentExcludedWindowIDs else { return }

        currentExcludedWindowIDs = newExcludedIDs

        // Create new filter with excluded windows
        let newFilter = SCContentFilter(
            display: displays[0],
            excludingWindows: excludedWindows
        )

        do {
            try await segment.updateContentFilter(newFilter)
            if !excludedWindows.isEmpty {
                Log.debug("Updated filter to exclude \(excludedWindows.count) window(s)", verbose: verbose)
            }
        } catch {
            Log.warn("Failed to update content filter: \(error)")
        }
    }

    // MARK: - Errors

    public enum CaptureError: Error, LocalizedError {
        case noDisplaysAvailable
        case notInitialized

        public var errorDescription: String? {
            switch self {
            case .noDisplaysAvailable:
                return "No displays available for capture"
            case .notInitialized:
                return "Capture manager not initialized"
            }
        }
    }
}
