// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import os
@preconcurrency import ScreenCaptureKit

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

        var label: String {
            switch self {
            case .idle: return "idle"
            case .recording: return "recording"
            case .paused: return "paused"
            case .error: return "error"
            }
        }
    }

    // MARK: - Properties

    private let storageManager: StorageManager
    private var currentSegment: SegmentWriter?
    private var segmentTimer: Timer?
    private var heartbeatTimer: Timer?
    private var displays: [SCDisplay] = []
    private var contentFilter: SCContentFilter?
    private let verbose: Bool
    private let lifecycleManager = CaptureLifecycleManager()
    private let windowExclusionManager: WindowExclusionManager

    /// Persistent mic capture manager - keeps AVAudioEngine instances alive across segment rotations
    /// This prevents audio playback interference during rotation
    private let micCaptureManager: MicrophoneCaptureManager

    /// Persistent system audio capture manager - keeps SCStream alive across segment rotations
    private let systemAudioCaptureManager = SystemAudioCaptureManager()

    /// Closure to check debug setting for keeping rejected audio tracks
    private let debugKeepRejectedAudio: @Sendable () -> Bool

    /// Closure to check if music silencing is enabled
    private let silenceMusic: @Sendable () -> Bool

    /// Flag to prevent concurrent segment rotations
    private var isRotatingSegment: Bool = false

    /// Current default microphone device ID (for change detection)
    private var currentDefaultMicID: AudioDeviceID?

    /// CoreAudio listener block for default mic changes (nonisolated for deinit)
    nonisolated(unsafe) private var defaultMicListenerBlock: AudioObjectPropertyListenerBlock?

    /// UIDs of microphones to exclude from recording (disabled mics)
    private var disabledMicUIDs: Set<String> = []

    public private(set) var state: State = .idle

    /// Called when a segment completes (for upload)
    public var onSegmentComplete: ((URL) async -> Void)?

    /// Called when state changes
    public var onStateChanged: ((State) -> Void)?

    /// Time remaining in current segment
    public var segmentTimeRemaining: TimeInterval {
        guard let timer = segmentTimer else { return 0 }
        return max(0, timer.fireDate.timeIntervalSinceNow)
    }

    // MARK: - Initialization

    public init(
        storageManager: StorageManager,
        debugKeepRejectedAudio: @escaping @Sendable () -> Bool = { false },
        silenceMusic: @escaping @Sendable () -> Bool = { true },
        excludedAppNames: [String] = [],
        excludePrivateBrowsing: Bool = true,
        excludedTitlePatterns: [String] = [],
        microphoneGain: Float = 2.0,
        verbose: Bool = false
    ) {
        self.storageManager = storageManager
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
        self.micCaptureManager = MicrophoneCaptureManager(gain: microphoneGain, verbose: verbose)
        self.windowExclusionManager = WindowExclusionManager(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns,
            verbose: verbose
        )

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

        windowExclusionManager.configure(
            onFilterChanged: { [weak self] newFilter in
                guard let self, let segment = self.currentSegment else { return }
                try await self.systemAudioCaptureManager.updateContentFilter(newFilter)
                try await segment.updateContentFilter(newFilter)
            },
            primaryDisplay: { [weak self] in self?.displays.first },
            isRecording: { [weak self] in self?.state.isRecording ?? false }
        )
        lifecycleManager.configure(delegate: self)
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

        // Clear any stale recovery state (e.g., user manually restarted while paused from sleep/lock)
        lifecycleManager.reset(stopRecovery: false)

        // Ensure storage directory exists
        try storageManager.ensureBaseDirectoryExists()

        // Get available content (throws if screen recording permission not granted)
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

        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: manual_start)")
        onStateChanged?(state)
        startHeartbeat()

        Logger.capture.info("Started recording session with \(self.displays.count, privacy: .public) display(s)")
    }

    /// Handles audio device additions/removals
    /// Adds/removes mics from current segment dynamically (no rotation needed)
    public func handleDeviceChange(added: [AudioInputDevice], removed: [AudioInputDevice]) async {
        guard state.isRecording else { return }

        // Add new enabled mics to current segment
        if let segment = currentSegment {
            for device in added where !disabledMicUIDs.contains(device.uid) {
                do {
                    try segment.addMicrophone(device)
                    Logger.capture.info("Added mic mid-segment: \(device.name, privacy: .public)")
                } catch {
                    Logger.capture.warning("Failed to add mic \(device.name, privacy: .public): \(error, privacy: .public)")
                }
            }

            // Remove disconnected mics from current segment
            for device in removed where segment.hasMicrophone(deviceUID: device.uid) {
                segment.removeMicrophone(deviceUID: device.uid)
                Logger.capture.info("Removed mic mid-segment: \(device.name, privacy: .public)")
            }
        }

        // Always stop captures for removed devices, even if segment doesn't have them
        // This handles the case where a device disconnects during/after segment rotation
        for device in removed {
            micCaptureManager.stopCapture(deviceUID: device.uid)
        }
    }

    /// Stops recording
    public func stopRecording() async {
        windowExclusionManager.stop()

        // Stop monitoring for microphone changes
        stopDefaultMicMonitoring()

        // Cancel timers
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        lifecycleManager.reset(stopRecovery: true)

        // Finish current segment and rename to actual duration
        var completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        }

        // Stop all persistent captures (only when fully stopping recording)
        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()

        let oldState = state.label
        state = .idle
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: manual_stop)")
        onStateChanged?(state)

        Logger.capture.info("Stopped recording")

        // Trigger upload callback
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            await callback(url)
        }
    }

    /// Pauses recording (used for sleep/lock lifecycle events)
    public func pauseRecording() async {
        guard state.isRecording else { return }

        // Stop segment timer
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        lifecycleManager.reset(stopRecovery: true)

        // Finish current segment and rename to actual duration
        var completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        }

        // Stop all persistent captures during pause
        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()

        let oldState = state.label
        state = .paused
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: manual_pause)")
        onStateChanged?(state)

        Logger.capture.info("Paused recording")

        // Trigger upload callback
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            await callback(url)
        }
    }

    /// Resumes recording after pause
    public func resumeRecording() async throws {
        guard state.isPaused else { return }

        // Start new segment
        try await startNewSegment()

        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: manual_resume)")
        onStateChanged?(state)
        startHeartbeat()

        Logger.capture.info("Resumed recording")
    }

    /// Update segment duration based on debug setting
    /// - Parameter enabled: If true, use 1-minute segments; if false, use 5-minute segments
    public func setDebugSegments(_ enabled: Bool) async {
        let newDuration: TimeInterval = enabled ? 60 : 300
        if SegmentWriter.segmentDuration != newDuration {
            SegmentWriter.segmentDuration = newDuration
            Logger.capture.info("Segment duration changed to \(Int(newDuration), privacy: .public)s")

            // Trigger immediate rotation if recording
            if state.isRecording {
                await rotateSegment()
            }
        }
    }

    /// Update microphone gain (takes effect immediately on active captures)
    /// - Parameter gain: New gain multiplier (1.0 to 8.0)
    public func setMicrophoneGain(_ gain: Float) {
        micCaptureManager.updateGain(gain)
    }

    /// Update window exclusion settings (takes effect immediately)
    /// - Parameters:
    ///   - excludedAppNames: App names to always exclude
    ///   - excludePrivateBrowsing: Whether to exclude private browser windows
    ///   - excludedTitlePatterns: Patterns to match in any window title
    public func updateWindowExclusions(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String]
    ) {
        windowExclusionManager.updateExclusions(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns
        )
    }

    // MARK: - Private Methods

    /// Starts a new recording segment
    private func startNewSegment() async throws {
        guard contentFilter != nil else {
            throw CaptureError.notInitialized
        }

        // Create segment directory with current time (named HHMMSS.incomplete)
        let (segmentDir, timePrefix) = try storageManager.createSegmentDirectory(
            segmentStartTime: Date()
        )

        // Collect available mics
        let availableMics = MicrophoneMonitor.listInputDevices()
            .filter { !disabledMicUIDs.contains($0.uid) }
            .prefix(4)

        // Start video/audio capture
        try await startNewSegmentWithDirectory(segmentDir, timePrefix: timePrefix, mics: Array(availableMics))
    }

    /// Starts recording to a pre-created segment directory
    /// - Parameters:
    ///   - segmentDir: Directory to write segment files to
    ///   - timePrefix: Time prefix for file naming
    ///   - mics: Microphone devices to start recording
    private func startNewSegmentWithDirectory(_ segmentDir: URL, timePrefix: String, mics: [AudioInputDevice] = []) async throws {
        guard let filter = contentFilter else {
            throw CaptureError.notInitialized
        }

        // Reset stream ready flag for new segment
        windowExclusionManager.resetForNewSegment()

        // Create segment writer
        let segment = SegmentWriter(
            outputDirectory: segmentDir,
            timePrefix: timePrefix,
            debugKeepRejectedAudio: debugKeepRejectedAudio(),
            silenceMusic: silenceMusic(),
            verbose: verbose
        )
        currentSegment = segment

        // Start recording - convert to DisplayInfo for sendable compliance
        let displayInfos = displays.map { DisplayInfo(from: $0) }
        try await segment.start(
            displayInfos: displayInfos,
            filter: filter,
            mics: mics,
            micCaptureManager: micCaptureManager,
            systemAudioCaptureManager: systemAudioCaptureManager
        )

        // Mark stream as ready after a short delay to allow capture to stabilize.
        // The 500ms delay ensures ScreenCaptureKit's stream is fully initialized
        // before we attempt to update content filters with window exclusions.
        // Without this delay, filter updates can fail or cause frame drops.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.windowExclusionManager.streamBecameReady()
        }

        // Schedule segment rotation
        scheduleSegmentRotation()
    }

    private func scheduleSegmentRotation() {
        segmentTimer?.invalidate()
        let interval = Self.timeUntilNextSegmentBoundary()
        segmentTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.rotateSegment()
            }
        }
        Logger.capture.info("Next segment rotation in \(Int(interval), privacy: .public) seconds")
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let segmentName = self.currentSegment?.outputDirectory.lastPathComponent ?? "none"
                let sysAudio = self.systemAudioCaptureManager.isRunning ? "running" : "stopped"
                Logger.capture.info("[Heartbeat] state=\(self.state.label, privacy: .public) displays=\(self.displays.count, privacy: .public) segment=\(segmentName, privacy: .public) rotation_in=\(Int(self.segmentTimeRemaining), privacy: .public)s sysaudio=\(sysAudio, privacy: .public)")
            }
        }
        heartbeatTimer?.tolerance = 30.0
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func transitionToError(_ message: String, trigger: String) {
        let oldState = state.label
        state = .error(message)
        Logger.capture.info("[State] \(oldState, privacy: .public) -> error (trigger: \(trigger, privacy: .public), error: \(message, privacy: .public))")
        onStateChanged?(state)
        lifecycleManager.startRecoveryIfNeeded(message: message)
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
            if verbose { Logger.capture.debug("Segment rotation already in progress, skipping") }
            return
        }
        isRotatingSegment = true
        defer { isRotatingSegment = false }

        Logger.capture.info("Rotating segment...")

        // Create new segment directory FIRST
        let newSegmentDir: URL
        let newTimePrefix: String
        do {
            (newSegmentDir, newTimePrefix) = try storageManager.createSegmentDirectory(segmentStartTime: Date())
        } catch {
            transitionToError("Failed to create segment directory: \(error.localizedDescription)", trigger: "rotation_failed")
            Logger.capture.error("Failed to rotate segment: \(error, privacy: .public)")
            return
        }

        // Finish capture on old segment (non-blocking - doesn't wait for remix)
        var captureResult: SegmentCaptureResult?
        if let segment = currentSegment {
            captureResult = await segment.finishCapture()
        }

        // Log segment directory summary
        if let result = captureResult {
            let dir = result.segmentDirectory
            do {
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
                let totalBytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
                let totalMB = Double(totalBytes) / 1_048_576.0
                Logger.capture.info("[Segment] Finished \(dir.lastPathComponent, privacy: .public): \(files.count, privacy: .public) files, \(String(format: "%.1f", totalMB), privacy: .public) MB")
            } catch {
                Logger.capture.info("[Segment] Finished \(dir.lastPathComponent, privacy: .public): unable to read directory")
            }
        }

        // Collect available mics for new segment
        let availableMics = MicrophoneMonitor.listInputDevices()
            .filter { !disabledMicUIDs.contains($0.uid) }
            .prefix(4)

        // Start recording to new segment IMMEDIATELY (no waiting for remix)
        do {
            try await startNewSegmentWithDirectory(newSegmentDir, timePrefix: newTimePrefix, mics: Array(availableMics))
        } catch {
            transitionToError("Failed to start new segment: \(error.localizedDescription)", trigger: "rotation_failed")
            Logger.capture.error("Failed to start new segment: \(error, privacy: .public)")
        }

        // Enqueue remix for background processing
        // RemixQueue will handle: remix, file rename, directory rename, and upload trigger
        if let result = captureResult {
            let job = RemixQueue.RemixJob(
                segmentDirectory: result.segmentDirectory,
                timePrefix: result.timePrefix,
                captureStartTime: result.captureStartTime,
                audioInputs: result.audioInputs,
                debugKeepRejected: result.debugKeepRejected,
                silenceMusic: result.silenceMusic,
                micMetadataJSON: result.micMetadataJSON
            )
            await RemixQueue.shared.enqueue(job)
        }
    }

    private func handleDisplayChange() async {
        guard state.isRecording else { return }

        Logger.capture.info("Display configuration changed")

        // Get new display list
        do {
            let content = try await SCShareableContent.current
            let newDisplays = content.displays

            // Check if displays changed
            let oldIDs = Set(displays.map { $0.displayID })
            let newIDs = Set(newDisplays.map { $0.displayID })

            if oldIDs != newIDs {
                Logger.capture.info("Display set changed, rotating segment")
                displays = newDisplays

                // Update filter
                if let firstDisplay = displays.first {
                    contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
                }

                // Force segment rotation to pick up new display config
                await rotateSegment()
            }
        } catch {
            Logger.capture.warning("Failed to get updated display list: \(error, privacy: .public)")
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
            Logger.capture.warning("Failed to add default mic listener: \(status, privacy: .public)")
        } else {
            if verbose { Logger.capture.debug("Started monitoring default microphone changes") }
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
            Logger.capture.info("Default microphone changed (no rotation - mics handled dynamically)")
            currentDefaultMicID = newDefaultMicID
            // No rotation needed - mics are handled dynamically via handleDeviceChange
        }
    }

    // MARK: - Errors

    public enum CaptureError: Error, LocalizedError {
        case noDisplaysAvailable
        case notInitialized
        case permissionDenied

        public var errorDescription: String? {
            switch self {
            case .noDisplaysAvailable:
                return "No displays available for capture"
            case .notInitialized:
                return "Capture manager not initialized"
            case .permissionDenied:
                return "The user declined TCCs for application, window, display capture"
            }
        }
    }
}

// MARK: - CaptureLifecycleDelegate

extension CaptureManager: CaptureLifecycleDelegate {
    var lifecycleCurrentState: CaptureManager.State { state }

    func lifecyclePauseCapture(trigger: String, stopAudio: Bool) async -> URL? {
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()

        var completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        }

        if stopAudio {
            micCaptureManager.stopAll()
            await systemAudioCaptureManager.stop()
        }

        let oldState = state.label
        state = .paused
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(trigger, privacy: .public))")
        onStateChanged?(state)

        return completedSegmentURL
    }

    func lifecycleResumeCapture(trigger: String) async throws {
        let content = try await withTimeout(seconds: 10) {
            try await SCShareableContent.current
        }
        displays = content.displays

        if let firstDisplay = displays.first {
            contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
        }

        try await startNewSegment()

        currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(trigger, privacy: .public))")
        onStateChanged?(state)
        startHeartbeat()
    }

    func lifecycleTransitionToError(message: String, trigger: String) {
        transitionToError(message, trigger: trigger)
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {
        guard let callback = onSegmentComplete else { return }

        if useSleepActivity {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Processing and uploading segment before sleep"
            )

            Task {
                Logger.capture.info("Starting processing and upload in background before sleep")
                await callback(url)
                Logger.capture.info("Processing and upload completed before sleep")
                ProcessInfo.processInfo.endActivity(activity)
            }
        } else {
            Task {
                await callback(url)
            }
        }
    }
}
