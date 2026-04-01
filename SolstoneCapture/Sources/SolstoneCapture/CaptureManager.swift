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
    /// Recovery timer for auto-retry after error state
    private var retryTimer: Timer?
    private var windowExclusionTimer: Timer?
    private var heartbeatTimer: Timer?
    private var displays: [SCDisplay] = []
    private var contentFilter: SCContentFilter?
    private let verbose: Bool
    private let retryDelays: [TimeInterval] = [5, 30, 60]
    private let maxRetryCount = 20

    /// Persistent mic capture manager - keeps AVAudioEngine instances alive across segment rotations
    /// This prevents audio playback interference during rotation
    private let micCaptureManager: MicrophoneCaptureManager

    /// Persistent system audio capture manager - keeps SCStream alive across segment rotations
    private let systemAudioCaptureManager = SystemAudioCaptureManager()

    /// Window exclusion detector for filtering out specific app windows
    private var windowExclusionDetector: WindowExclusionDetector?

    /// Closure to check if audio is muted (passed to SegmentWriter)
    private let isAudioMuted: @Sendable () -> Bool

    /// Closure to check debug setting for keeping rejected audio tracks
    private let debugKeepRejectedAudio: @Sendable () -> Bool

    /// Closure to check if music silencing is enabled
    private let silenceMusic: @Sendable () -> Bool

    /// Currently excluded windows (for change detection)
    private var currentExcludedWindowIDs: Set<CGWindowID> = []

    /// Flag to prevent filter updates during stream startup
    private var isStreamReady: Bool = false

    /// Flag to prevent concurrent segment rotations
    private var isRotatingSegment: Bool = false

    private var retryCount: Int = 0
    private var isRecovering: Bool = false

    /// Tracks whether recording should resume when conditions allow (after wake/unlock)
    private var suspendedForRecovery: Bool = false

    /// Debounce task for unlock resume (cancelled by subsequent lock/sleep)
    private var unlockResumeTask: Task<Void, Never>? = nil

    /// Current default microphone device ID (for change detection)
    private var currentDefaultMicID: AudioDeviceID?

    /// CoreAudio listener block for default mic changes (nonisolated for deinit)
    nonisolated(unsafe) private var defaultMicListenerBlock: AudioObjectPropertyListenerBlock?

    /// UIDs of microphones to exclude from recording (disabled mics)
    private var disabledMicUIDs: Set<String> = []

    /// Observer tokens for screen lock/unlock notifications (must be removed in deinit)
    nonisolated(unsafe) private var screenLockedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var screenUnlockedObserver: NSObjectProtocol?

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
        isAudioMuted: @escaping @Sendable () -> Bool = { false },
        debugKeepRejectedAudio: @escaping @Sendable () -> Bool = { false },
        silenceMusic: @escaping @Sendable () -> Bool = { true },
        excludedAppNames: [String] = [],
        excludePrivateBrowsing: Bool = true,
        excludedTitlePatterns: [String] = [],
        microphoneGain: Float = 2.0,
        verbose: Bool = false
    ) {
        self.storageManager = storageManager
        self.isAudioMuted = isAudioMuted
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
        self.micCaptureManager = MicrophoneCaptureManager(gain: microphoneGain, verbose: verbose)

        // Create window exclusion detector if we have apps to exclude, title patterns, or private browsing detection
        if !excludedAppNames.isEmpty || !excludedTitlePatterns.isEmpty || excludePrivateBrowsing {
            self.windowExclusionDetector = WindowExclusionDetector(
                appNames: excludedAppNames,
                detectPrivateBrowsing: excludePrivateBrowsing,
                titlePatterns: excludedTitlePatterns
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

        // Listen for screen lock/unlock events
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreenLocked()
            }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleScreenUnlocked()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Remove DistributedNotificationCenter observers (separate from NotificationCenter)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

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
        suspendedForRecovery = false
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        // Ensure storage directory exists
        try storageManager.ensureBaseDirectoryExists()

        // Check screen capture permission before touching any ScreenCaptureKit APIs.
        // CGPreflightScreenCaptureAccess() checks without prompting.
        // CGRequestScreenCaptureAccess() shows one prompt if needed.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // Give the user a moment to respond, then check again
            try await Task.sleep(nanoseconds: 500_000_000)
            if !CGPreflightScreenCaptureAccess() {
                throw CaptureError.permissionDenied
            }
        }

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

        let oldState = state.label
        state = .recording
        Log.info("[State] \(oldState) -> \(state.label) (trigger: manual_start)")
        onStateChanged?(state)
        startHeartbeat()

        Log.info("Started recording session with \(displays.count) display(s)")
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
                    Log.info("Added mic mid-segment: \(device.name)")
                } catch {
                    Log.warn("Failed to add mic \(device.name): \(error)")
                }
            }

            // Remove disconnected mics from current segment
            for device in removed where segment.hasMicrophone(deviceUID: device.uid) {
                segment.removeMicrophone(deviceUID: device.uid)
                Log.info("Removed mic mid-segment: \(device.name)")
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
        // Mark stream as not ready
        isStreamReady = false

        // Stop monitoring for microphone changes
        stopDefaultMicMonitoring()

        // Cancel timers
        segmentTimer?.invalidate()
        segmentTimer = nil
        windowExclusionTimer?.invalidate()
        windowExclusionTimer = nil
        stopHeartbeat()
        stopRecoveryTimer()
        suspendedForRecovery = false
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

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
        Log.info("[State] \(oldState) -> \(state.label) (trigger: manual_stop)")
        onStateChanged?(state)

        Log.info("Stopped recording")

        // Trigger upload callback
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            await callback(url)
        }
    }

    /// Pauses recording (used when both audio and video are muted)
    public func pauseRecording() async {
        guard state.isRecording else { return }

        // Stop segment timer
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        stopRecoveryTimer()
        suspendedForRecovery = false
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

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
        Log.info("[State] \(oldState) -> \(state.label) (trigger: manual_pause)")
        onStateChanged?(state)

        Log.info("Paused recording")

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
        Log.info("[State] \(oldState) -> \(state.label) (trigger: manual_resume)")
        onStateChanged?(state)
        startHeartbeat()

        Log.info("Resumed recording")
    }

    /// Update segment duration based on debug setting
    /// - Parameter enabled: If true, use 1-minute segments; if false, use 5-minute segments
    public func setDebugSegments(_ enabled: Bool) async {
        let newDuration: TimeInterval = enabled ? 60 : 300
        if SegmentWriter.segmentDuration != newDuration {
            SegmentWriter.segmentDuration = newDuration
            Log.info("Segment duration changed to \(Int(newDuration))s")

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
        if !excludedAppNames.isEmpty || !excludedTitlePatterns.isEmpty || excludePrivateBrowsing {
            windowExclusionDetector = WindowExclusionDetector(
                appNames: excludedAppNames,
                detectPrivateBrowsing: excludePrivateBrowsing,
                titlePatterns: excludedTitlePatterns
            )
            Log.info("Updated window exclusions: \(excludedAppNames.count) apps, \(excludedTitlePatterns.count) title patterns, privateBrowsing=\(excludePrivateBrowsing)")
        } else {
            windowExclusionDetector = nil
            Log.info("Cleared window exclusions")
        }
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
        isStreamReady = false
        currentExcludedWindowIDs = []

        // Create segment writer
        let segment = SegmentWriter(
            outputDirectory: segmentDir,
            timePrefix: timePrefix,
            isAudioMuted: isAudioMuted,
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
            isStreamReady = true
            await updateWindowExclusions()
            startWindowExclusionTimer()
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
        Log.info("Next segment rotation in \(Int(interval)) seconds")
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let segmentName = self.currentSegment?.outputDirectory.lastPathComponent ?? "none"
                let sysAudio = self.systemAudioCaptureManager.isRunning ? "running" : "stopped"
                Log.info("[Heartbeat] state=\(self.state.label) displays=\(self.displays.count) segment=\(segmentName) rotation_in=\(Int(self.segmentTimeRemaining))s sysaudio=\(sysAudio)")
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
        Log.info("[State] \(oldState) -> error (trigger: \(trigger), error: \(message))")
        onStateChanged?(state)

        // Don't auto-retry permission errors — they require user action in System Settings
        if isPermissionError(message) {
            Log.info("[Recovery] Skipping auto-recovery: permission error requires user action")
        } else {
            startRecoveryTimer()
        }
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

        // Create new segment directory FIRST
        let newSegmentDir: URL
        let newTimePrefix: String
        do {
            (newSegmentDir, newTimePrefix) = try storageManager.createSegmentDirectory(segmentStartTime: Date())
        } catch {
            transitionToError("Failed to create segment directory: \(error.localizedDescription)", trigger: "rotation_failed")
            Log.error("Failed to rotate segment: \(error)")
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
                Log.info("[Segment] Finished \(dir.lastPathComponent): \(files.count) files, \(String(format: "%.1f", totalMB)) MB")
            } catch {
                Log.info("[Segment] Finished \(dir.lastPathComponent): unable to read directory")
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
            Log.error("Failed to start new segment: \(error)")
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

    // MARK: - Sleep/Wake/Lock Handling

    /// Check if the screen is currently locked
    private func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool else {
            return false
        }
        return locked
    }

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
        Log.info("[Event] willSleep (state: \(state.label), suspended: \(suspendedForRecovery))")

        // Cancel any pending unlock resume — sleep supersedes it
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        guard state.isRecording else { return }

        suspendedForRecovery = true

        // Finish current segment gracefully before sleep
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()

        let completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        } else {
            completedSegmentURL = nil
        }

        let oldState = state.label
        state = .paused
        Log.info("[State] \(oldState) -> \(state.label) (trigger: sleep)")
        onStateChanged?(state)

        // Use beginActivity to request time for upload before system suspends
        // Fire async to avoid blocking MainActor during sleep transition
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Processing and uploading segment before sleep"
            )

            Task {
                Log.info("Starting processing and upload in background before sleep")
                await callback(url)
                Log.info("Processing and upload completed before sleep")
                ProcessInfo.processInfo.endActivity(activity)
            }
        }

        Log.info("Capture paused for sleep")
    }

    private func handleDidWake() async {
        Log.info("[Event] didWake (state: \(state.label), suspended: \(suspendedForRecovery))")

        guard suspendedForRecovery else { return }

        // Already recording (shouldn't happen, but guard against double-start)
        guard !state.isRecording else {
            Log.warn("[Event] didWake: already recording, skipping resume")
            return
        }

        // If screen is locked, defer resume to unlock handler
        guard !isScreenLocked() else {
            Log.info("Screen is locked after wake, deferring to unlock handler")
            return
        }

        do {
            await waitForAudioDevices(timeout: 5.0)

            let content = try await withTimeout(seconds: 10) {
                try await SCShareableContent.current
            }
            displays = content.displays

            if let firstDisplay = displays.first {
                contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
            }

            currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

            try await startNewSegment()

            suspendedForRecovery = false

            let oldState = state.label
            state = .recording
            Log.info("[State] \(oldState) -> \(state.label) (trigger: wake)")
            onStateChanged?(state)
            startHeartbeat()
            Log.info("Capture resumed after wake")
        } catch {
            transitionToError("Failed to resume after wake: \(error.localizedDescription)", trigger: "wake_failed")
            Log.error("Failed to resume capture after wake: \(error)")
        }
    }

    private func handleScreenLocked() async {
        Log.info("[Event] screenLocked (state: \(state.label), suspended: \(suspendedForRecovery))")

        // Cancel any pending unlock resume
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        guard state.isRecording else { return }

        suspendedForRecovery = true

        // Finish current segment gracefully before lock
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()

        let completedSegmentURL: URL?
        if let segment = currentSegment {
            completedSegmentURL = await segment.finishAndRename()
            currentSegment = nil
        } else {
            completedSegmentURL = nil
        }

        // Stop all persistent captures during lock
        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()

        let oldState = state.label
        state = .paused
        Log.info("[State] \(oldState) -> \(state.label) (trigger: lock)")
        onStateChanged?(state)

        // Trigger upload callback
        if let url = completedSegmentURL, let callback = onSegmentComplete {
            Task {
                await callback(url)
            }
        }

        Log.info("Capture paused for screen lock")
    }

    private func handleScreenUnlocked() async {
        Log.info("[Event] screenUnlocked (state: \(state.label), suspended: \(suspendedForRecovery))")

        guard suspendedForRecovery else { return }

        // Already recording (shouldn't happen, but guard against double-start)
        guard !state.isRecording else {
            Log.warn("[Event] screenUnlocked: already recording, skipping resume")
            return
        }

        // Cancel any existing debounce task
        unlockResumeTask?.cancel()
        unlockResumeTask = nil

        // Debounce: wait 0.5s before resuming to handle rapid lock/unlock cycling
        unlockResumeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                // Task was cancelled (rapid re-lock)
                return
            }

            guard let self = self else { return }

            // Re-check state after debounce
            guard self.suspendedForRecovery, !self.state.isRecording else { return }

            do {
                await self.waitForAudioDevices(timeout: 5.0)

                let content = try await withTimeout(seconds: 10) {
                    try await SCShareableContent.current
                }
                self.displays = content.displays

                if let firstDisplay = self.displays.first {
                    self.contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])
                }

                self.currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

                try await self.startNewSegment()

                self.suspendedForRecovery = false
                self.unlockResumeTask = nil

                let oldState = self.state.label
                self.state = .recording
                Log.info("[State] \(oldState) -> \(self.state.label) (trigger: unlock)")
                self.onStateChanged?(self.state)
                self.startHeartbeat()
                Log.info("Capture resumed after unlock")
            } catch {
                self.transitionToError("Failed to resume after unlock: \(error.localizedDescription)", trigger: "unlock_failed")
                Log.error("Failed to resume capture after unlock: \(error)")
            }
        }
    }

    // MARK: - Recovery

    /// Schedules the next recovery attempt based on retryCount
    private func startRecoveryTimer() {
        retryTimer?.invalidate()

        guard retryCount < maxRetryCount else {
            Log.error("[Recovery] Giving up after \(maxRetryCount) failed attempts")
            return
        }

        let delay = retryCount < retryDelays.count ? retryDelays[retryCount] : 300.0
        Log.info("[Recovery] Scheduling attempt \(retryCount + 1)/\(maxRetryCount) in \(Int(delay))s")

        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.attemptRecovery()
            }
        }
        retryTimer?.tolerance = 5.0
    }

    /// Cancels pending recovery and resets retry state
    private func stopRecoveryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        isRecovering = false
    }

    /// Attempts to recover from error state by refreshing displays and starting a new segment
    private func attemptRecovery() async {
        guard state.isError else {
            stopRecoveryTimer()
            return
        }

        guard !isScreenLocked() else {
            Log.info("[Recovery] Screen is locked, deferring recovery")
            startRecoveryTimer()
            return
        }

        // Don't attempt recovery without screen capture permission
        guard CGPreflightScreenCaptureAccess() else {
            Log.info("[Recovery] No screen capture permission, stopping recovery")
            stopRecoveryTimer()
            return
        }

        guard !isRecovering else {
            Log.info("[Recovery] Already in progress, skipping")
            return
        }

        isRecovering = true
        defer { isRecovering = false }

        let attempt = retryCount + 1
        Log.info("[Recovery] Attempting recovery \(attempt)/\(maxRetryCount)")

        do {
            // Refresh display list
            let content = try await withTimeout(seconds: 10) {
                try await SCShareableContent.current
            }
            displays = content.displays

            guard let firstDisplay = displays.first else {
                throw CaptureError.noDisplaysAvailable
            }

            contentFilter = SCContentFilter(display: firstDisplay, excludingApplications: [], exceptingWindows: [])

            // Start fresh segment
            try await startNewSegment()

            // Success - restore recording state
            currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()
            let oldState = state.label
            state = .recording
            Log.info("[State] \(oldState) -> \(state.label) (trigger: recovery)")
            onStateChanged?(state)
            startHeartbeat()
            stopRecoveryTimer()
            Log.info("[Recovery] Successfully recovered on attempt \(attempt)")
        } catch {
            retryCount += 1
            Log.info("[Recovery] Attempt \(attempt) failed: \(error.localizedDescription)")

            if isPermissionError(error) {
                Log.info("[Recovery] Permission error detected, stopping auto-recovery")
                stopRecoveryTimer()
            } else if retryCount >= maxRetryCount {
                Log.error("[Recovery] Giving up after \(maxRetryCount) failed attempts")
            } else {
                startRecoveryTimer()
            }
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
            Log.info("Default microphone changed (no rotation - mics handled dynamically)")
            currentDefaultMicID = newDefaultMicID
            // No rotation needed - mics are handled dynamically via handleDeviceChange
        }
    }

    // MARK: - Window Exclusion

    /// Starts a timer to periodically check for window exclusions
    private func startWindowExclusionTimer() {
        windowExclusionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updateWindowExclusions()
            }
        }
        timer.tolerance = 2.0  // Allow coalescing to reduce energy impact
        windowExclusionTimer = timer
    }

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
            // Update system audio stream filter
            try await systemAudioCaptureManager.updateContentFilter(newFilter)
            // Update video (screenshot) filters
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
