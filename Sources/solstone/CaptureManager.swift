// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import os
@preconcurrency import ScreenCaptureKit

@MainActor
public protocol CaptureSegmentWriting: AnyObject, Sendable {
    var outputDirectory: URL { get }

    func start(
        displayInfos: [DisplayInfo],
        filters: [CGDirectDisplayID: SCContentFilter],
        audioFilter: SCContentFilter?,
        mics: [AudioInputDevice],
        micCaptureManager: MicrophoneCaptureManager?,
        systemAudioCaptureManager: SystemAudioCaptureManager?
    ) async throws
    func finishCapture() async -> SegmentCaptureResult?
    func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws
    func addMicrophone(_ device: AudioInputDevice) throws
    func removeMicrophone(deviceUID: String)
    func hasMicrophone(deviceUID: String) -> Bool
    func activeMicrophoneUIDs() -> [String]
}

extension SegmentWriter: CaptureSegmentWriting {}

/// Manages continuous recording with segment rotation
/// Thread safety: All access is isolated to MainActor
@MainActor
public final class CaptureManager {
    public typealias SegmentFactory = @MainActor @Sendable (
        _ outputDirectory: URL,
        _ timePrefix: String,
        _ debugKeepRejectedAudio: Bool,
        _ silenceMusic: Bool,
        _ verbose: Bool
    ) -> any CaptureSegmentWriting

    /// Current state of the capture manager
    enum State: Sendable {
        case idle
        case recording
        case paused(reasons: Set<PauseReason>)
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

        var pausedReasons: Set<PauseReason> {
            if case .paused(let reasons) = self { return reasons }
            return []
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
    private var currentSegment: (any CaptureSegmentWriting)?
    private var segmentTimer: Timer?
    private var heartbeatTimer: Timer?
    private var pendingRotationRetryTask: Task<Void, Never>?
    private var displays: [SCDisplay] = []
    private var filtersByDisplayID: [CGDirectDisplayID: SCContentFilter] = [:]
    private let verbose: Bool
    private let lifecycleManager = CaptureLifecycleManager()
    private let windowExclusionManager: WindowExclusionManager
    private let segmentFactory: SegmentFactory
    private let recoveryCoordinator: IncompleteSegmentRecoveryCoordinator
    private let finalizer: any SegmentFinalizing
    private let rotationTimeoutSeconds: TimeInterval
    private let now: @Sendable () -> Date
    // Test-only bypass for fake segment factories without ScreenCaptureKit display state; defaults false.
    private let allowsEmptyDisplayConfigurationForTesting: Bool

    /// Persistent mic capture manager - keeps AVAudioEngine instances alive across segment rotations
    /// This prevents audio playback interference during rotation
    private let micCaptureManager: MicrophoneCaptureManager

    /// Persistent system audio capture manager - keeps SCStream alive across segment rotations
    private let systemAudioCaptureManager = SystemAudioCaptureManager()

    /// Closure to check debug setting for keeping rejected audio tracks
    private let debugKeepRejectedAudio: @Sendable () -> Bool

    /// Closure to check if music silencing is enabled
    private let silenceMusic: @Sendable () -> Bool

    /// Current default microphone device ID (for change detection)
    private var currentDefaultMicID: AudioDeviceID?

    /// CoreAudio listener for default mic changes
    private var defaultMicListener: HALPropertyListener?

    /// UIDs of microphones to exclude from recording (disabled mics)
    private var disabledMicUIDs: Set<String> = []
    private var enabledMicUIDs: Set<String> = []

    private(set) var state: State = .idle

    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

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
        verbose: Bool = false,
        segmentFactory: @escaping SegmentFactory = { outputDirectory, timePrefix, debugKeepRejectedAudio, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                debugKeepRejectedAudio: debugKeepRejectedAudio,
                silenceMusic: silenceMusic,
                verbose: verbose
            )
        },
        recoveryCoordinator: IncompleteSegmentRecoveryCoordinator = .shared,
        finalizer: any SegmentFinalizing = RemixQueue.shared,
        rotationTimeoutSeconds: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init,
        allowsEmptyDisplayConfigurationForTesting: Bool = false
    ) {
        self.storageManager = storageManager
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.silenceMusic = silenceMusic
        self.verbose = verbose
        self.segmentFactory = segmentFactory
        self.recoveryCoordinator = recoveryCoordinator
        self.finalizer = finalizer
        self.rotationTimeoutSeconds = rotationTimeoutSeconds
        self.now = now
        self.allowsEmptyDisplayConfigurationForTesting = allowsEmptyDisplayConfigurationForTesting
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
            onFiltersChanged: { [weak self] newFilters in
                guard let self, let segment = self.currentSegment else { return }
                if let audioFilter = self.displays.first.flatMap({ newFilters[$0.displayID] }) {
                    try await self.systemAudioCaptureManager.updateContentFilter(audioFilter)
                } else {
                    let displayID = self.displays.first.map { String($0.displayID) } ?? "nil"
                    let keyList = newFilters.keys.sorted().map(String.init).joined(separator: ",")
                    Logger.capture.error("Missing audio SCContentFilter for display \(displayID, privacy: .public); available filter keys=[\(keyList, privacy: .public)]")
                }
                try await segment.updateContentFilter(newFilters)
            },
            allDisplays: { [weak self] in self?.displays },
            isRecording: { [weak self] in self?.state.isRecording ?? false }
        )
        lifecycleManager.configure(delegate: self)
    }

    deinit {
        defaultMicListener?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    @discardableResult
    internal func enqueueTransition(_ intent: CaptureIntent) async -> TransitionOutcome {
        await lifecycleManager.enqueue(intent)
    }

    internal var isRecoveryScheduled: Bool {
        lifecycleManager.isRecoveryScheduled
    }

    /// Handles audio device additions/removals
    /// Adds/removes mics from current segment dynamically (no rotation needed)
    public func handleDeviceChange(added: [AudioInputDevice], removed: [AudioInputDevice]) async {
        guard state.isRecording else { return }

        // Add new enabled mics to current segment
        if let segment = currentSegment {
            for device in added where MicrophoneSelection.shouldCapture(
                device,
                disabledMicUIDs: disabledMicUIDs,
                enabledMicUIDs: enabledMicUIDs
            ) {
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

    /// Update segment duration based on debug setting
    /// - Parameter enabled: If true, use 1-minute segments; if false, use 5-minute segments
    public func setDebugSegments(_ enabled: Bool) async {
        let newDuration: TimeInterval = enabled ? 60 : 300
        if SegmentWriter.segmentDuration != newDuration {
            SegmentWriter.segmentDuration = newDuration
            Logger.capture.info("Segment duration changed to \(Int(newDuration), privacy: .public)s")

            // Trigger immediate rotation if recording
            if state.isRecording {
                await enqueueTransition(.rotate(reason: .debugToggle))
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

    private func rebuildDisplaysAndFilters() async throws {
        let content = try await SCShareableContent.current
        let newDisplays = content.displays
        guard !newDisplays.isEmpty else {
            throw CaptureError.noDisplaysAvailable
        }
        displays = newDisplays
        filtersByDisplayID = Dictionary(
            uniqueKeysWithValues: newDisplays.map { display in
                (display.displayID, SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []))
            }
        )
    }

    /// Starts a new recording segment
    private func startNewSegment() async throws {
        guard allowsEmptyDisplayConfigurationForTesting || (!displays.isEmpty && !filtersByDisplayID.isEmpty) else {
            throw CaptureError.notInitialized
        }

        // Create segment directory with current time (named HHMMSS.incomplete)
        let (segmentDir, timePrefix) = try storageManager.createSegmentDirectory(
            segmentStartTime: now()
        )

        // Collect available mics
        let availableMics = MicrophoneMonitor.listInputDevices()
            .filter {
                MicrophoneSelection.shouldCapture($0, disabledMicUIDs: disabledMicUIDs, enabledMicUIDs: enabledMicUIDs)
            }
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
        guard allowsEmptyDisplayConfigurationForTesting || (!displays.isEmpty && !filtersByDisplayID.isEmpty) else {
            throw CaptureError.notInitialized
        }
        if allowsEmptyDisplayConfigurationForTesting && displays.isEmpty && filtersByDisplayID.isEmpty {
            Logger.capture.info("Starting test segment with empty display/filter configuration")
        }

        // Reset stream ready flag for new segment
        windowExclusionManager.resetForNewSegment()

        // Create segment writer
        let segment = segmentFactory(
            segmentDir,
            timePrefix,
            debugKeepRejectedAudio(),
            silenceMusic(),
            verbose
        )
        currentSegment = segment

        // Start recording - convert to DisplayInfo for sendable compliance
        let displayInfos = displays.map { DisplayInfo(from: $0) }
        let audioFilter = displays.first.flatMap { filtersByDisplayID[$0.displayID] }
        if audioFilter == nil {
            let displayID = displays.first.map { String($0.displayID) } ?? "nil"
            let keyList = filtersByDisplayID.keys.sorted().map(String.init).joined(separator: ",")
            Logger.capture.error("Missing audio SCContentFilter for display \(displayID, privacy: .public); available filter keys=[\(keyList, privacy: .public)]")
        }
        do {
            try await segment.start(
                displayInfos: displayInfos,
                filters: filtersByDisplayID,
                audioFilter: audioFilter,
                mics: mics,
                micCaptureManager: micCaptureManager,
                systemAudioCaptureManager: systemAudioCaptureManager
            )
        } catch {
            currentSegment = nil
            await markIncompleteSegmentAsFailed(segmentDir)
            throw error
        }

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
                await self?.enqueueTransition(.rotate(reason: .boundary))
            }
        }
        Logger.capture.info("Next segment rotation in \(Int(interval), privacy: .public) seconds")
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleHeartbeatTick()
            }
        }
        heartbeatTimer?.tolerance = 30.0
    }

    internal func handleHeartbeatTick() {
        let segmentName = currentSegment?.outputDirectory.lastPathComponent ?? "none"
        let sysAudio = systemAudioCaptureManager.isRunning ? "running" : "stopped"
        Logger.capture.info("[Heartbeat] state=\(self.state.label, privacy: .public) displays=\(self.displays.count, privacy: .public) segment=\(segmentName, privacy: .public) rotation_in=\(Int(self.segmentTimeRemaining), privacy: .public)s sysaudio=\(sysAudio, privacy: .public)")
        recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func cancelPendingRotationRetry() {
        pendingRotationRetryTask?.cancel()
        pendingRotationRetryTask = nil
    }

    private func finalizeActiveSegmentForTransition(stopAudio: Bool) async -> URL? {
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        cancelPendingRotationRetry()

        var result: SegmentCaptureResult?
        if let segment = currentSegment {
            result = await segment.finishCapture()
            currentSegment = nil
            if let result {
                await enqueueRemix(result)
            }
        }

        if stopAudio {
            micCaptureManager.stopAll()
            await systemAudioCaptureManager.stop()
        }

        return result?.segmentDirectory
    }

    private func discardCurrentSegmentWithoutEnqueue(matching expectedDirectory: URL?) async -> URL? {
        guard let segment = currentSegment else { return nil }
        let segmentDirectory = segment.outputDirectory
        if let expectedDirectory, segmentDirectory != expectedDirectory {
            return nil
        }

        _ = await segment.finishCapture()
        if currentSegment?.outputDirectory == segmentDirectory {
            currentSegment = nil
        }
        segmentTimer?.invalidate()
        segmentTimer = nil
        return segmentDirectory
    }

    private func stopPersistentAudioForDiscard() async {
        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()
    }

    private func markDiscardedSegmentFailedAndRecover(_ segmentDir: URL) async {
        await markIncompleteSegmentAsFailed(segmentDir)
        recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)
    }

    internal func enterNoDisplayRecovery() async {
        _ = await finalizeActiveSegmentForTransition(stopAudio: true)
        transitionToError("all displays disconnected", error: CaptureError.noDisplaysAvailable, trigger: "no_displays")
    }

    private func transitionToError(_ message: String, error: Error, trigger: String) {
        let oldState = state.label
        state = .error(message)
        Logger.capture.info("[State] \(oldState, privacy: .public) -> error (trigger: \(trigger, privacy: .public), error: \(message, privacy: .public))")
        onStateChanged?(state)
        lifecycleManager.startRecoveryIfNeeded(error: error)
    }

    private func transitionFailure(for error: Error) -> TransitionFailure {
        TransitionFailure(message: error.localizedDescription, isPermissionError: isPermissionError(error))
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

    private func enqueueRemix(_ result: SegmentCaptureResult) async {
        let job = RemixQueue.RemixJob(
            segmentDirectory: result.segmentDirectory,
            timePrefix: result.timePrefix,
            capturedDurationSeconds: result.capturedDurationSeconds,
            audioInputs: result.audioInputs,
            debugKeepRejected: result.debugKeepRejected,
            silenceMusic: result.silenceMusic,
            micMetadataJSON: result.micMetadataJSON
        )
        await finalizer.enqueue(job)
    }

    private func logSegmentSummary(_ result: SegmentCaptureResult) {
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

    private func scheduleDelayedRotationRetry() {
        guard pendingRotationRetryTask == nil else { return }
        pendingRotationRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingRotationRetryTask = nil
            guard self.state.isRecording else { return }
            await self.enqueueTransition(.rotate(reason: .retry))
        }
    }

    private func handleDisplayChange() async {
        guard state.isRecording else {
            await lifecycleManager.noteDisplayChange()
            return
        }

        Logger.capture.info("Display configuration changed")

        do {
            let oldIDs = Set(displays.map { $0.displayID })
            try await rebuildDisplaysAndFilters()
            let newIDs = Set(displays.map { $0.displayID })

            if oldIDs != newIDs {
                Logger.capture.info("Display set changed, rotating segment")
                await enqueueTransition(.rotate(reason: .displayChange))
            }
        } catch CaptureError.noDisplaysAvailable {
            let error = CaptureError.noDisplaysAvailable
            Logger.capture.error("No displays available after display change: \(error.localizedDescription, privacy: .public)")
            await enterNoDisplayRecovery()
        } catch {
            Logger.capture.warning("Failed to get updated display list: \(error, privacy: .public)")
        }
    }

    // MARK: - Default Microphone Monitoring

    private func startDefaultMicMonitoring() {
        currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()

        defaultMicListener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            onChange: { [weak self] in
                Task { await self?.handleDefaultMicChange() }
            }
        )
        if verbose { Logger.capture.debug("Started monitoring default microphone changes") }
    }

    private func stopDefaultMicMonitoring() {
        defaultMicListener?.invalidate()
        defaultMicListener = nil
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

    // MARK: - Test Support

    internal func seedRecordingForTesting(currentSegment: any CaptureSegmentWriting) {
        self.currentSegment = currentSegment
        state = .recording
    }

    internal var rotationTimeoutSecondsForTesting: TimeInterval {
        rotationTimeoutSeconds
    }

    internal var hasSegmentTimerForTesting: Bool {
        segmentTimer != nil
    }

    internal var hasHeartbeatTimerForTesting: Bool {
        heartbeatTimer != nil
    }

    internal var hasPendingRotationRetryForTesting: Bool {
        pendingRotationRetryTask != nil
    }

    internal var queuedIntentSnapshotForTesting: [IntentSnapshot] {
        lifecycleManager.queuedIntentSnapshotForTesting
    }

    internal var inFlightIntentForTesting: IntentSnapshot? {
        lifecycleManager.inFlightIntentForTesting
    }

    internal var lastVetoReasonForTesting: VetoReason? {
        lifecycleManager.lastVetoReasonForTesting
    }

    internal func nowForTesting() -> Date {
        now()
    }

    internal var currentSegmentForTesting: (any CaptureSegmentWriting)? {
        currentSegment
    }

#if DEBUG
    internal var isSystemAudioRunningForTesting: Bool {
        systemAudioCaptureManager.isRunning
    }
#endif

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

// MARK: - CaptureLifecycleDelegate

extension CaptureManager: CaptureLifecycleDelegate {
    var lifecycleCurrentState: CaptureManager.State { state }

    func lifecycleStartCapture(
        reason: StartReason,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async throws -> StartResult {
        self.disabledMicUIDs = disabledMicUIDs
        self.enabledMicUIDs = enabledMicUIDs

        do {
            recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)

            // Clear any stale recovery state (e.g., user manually restarted while paused from sleep/lock).
            lifecycleManager.resetLifecyclePendingState(stopRecovery: false)

            // Ensure storage directory exists.
            try storageManager.ensureBaseDirectoryExists()

            if !allowsEmptyDisplayConfigurationForTesting {
                try await rebuildDisplaysAndFilters()
            }

            // Start first segment.
            try await startNewSegment()
        } catch {
            throw transitionFailure(for: error)
        }

        if shouldVetoCommit() {
            _ = await discardCurrentSegmentWithoutEnqueue(matching: nil)
            await stopPersistentAudioForDiscard()
            return .vetoedScreenLocked
        }

        // Start monitoring for default microphone changes.
        startDefaultMicMonitoring()

        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(reason.trigger, privacy: .public))")
        onStateChanged?(state)
        startHeartbeat()

        Logger.capture.info("Started recording session with \(self.displays.count, privacy: .public) display(s)")
        return .committed
    }

    func lifecycleResetForRestartFromError() async {
        Logger.capture.info("[Executor] resetting for restart from error")
        windowExclusionManager.stop()
        stopDefaultMicMonitoring()

        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        cancelPendingRotationRetry()
        lifecycleManager.resetLifecyclePendingState(stopRecovery: true)

        if let segment = currentSegment {
            let result = await segment.finishCapture()
            currentSegment = nil
            if let result {
                await enqueueRemix(result)
            }
        }

        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()
    }

    func lifecycleStartFromErrorFailed(_ failure: TransitionFailure) {
        lifecycleManager.noteStartFromErrorFailed(isPermissionError: failure.isPermissionError)
    }

    func lifecycleStopCapture(reason: StopReason) async {
        windowExclusionManager.stop()

        // Stop monitoring for microphone changes.
        stopDefaultMicMonitoring()

        // Cancel timers.
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopHeartbeat()
        cancelPendingRotationRetry()
        lifecycleManager.resetLifecyclePendingState(stopRecovery: true)

        // Finish current segment and enqueue remix before tearing down persistent captures.
        if let segment = currentSegment {
            let result = await segment.finishCapture()
            currentSegment = nil
            if let result {
                await enqueueRemix(result)
            }
        }

        // Stop all persistent captures (only when fully stopping recording).
        micCaptureManager.stopAll()
        await systemAudioCaptureManager.stop()

        let oldState = state.label
        state = .idle
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(reason.trigger, privacy: .public))")
        onStateChanged?(state)

        Logger.capture.info("Stopped recording")
    }

    func lifecycleRotateSegment(
        reason: RotateReason,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async -> RotationResult {
        cancelPendingRotationRetry()

        Logger.capture.info("Rotating segment...")

        // Create new segment directory FIRST.
        let newSegmentDir: URL
        let newTimePrefix: String
        do {
            (newSegmentDir, newTimePrefix) = try storageManager.createSegmentDirectory(segmentStartTime: now())
        } catch {
            transitionToError("Failed to create segment directory: \(error.localizedDescription)", error: error, trigger: "rotation_failed")
            Logger.capture.error("Failed to rotate segment: \(error, privacy: .public)")
            return .failed(transitionFailure(for: error))
        }

        let rotationOutcome: (captureResult: SegmentCaptureResult?, superseded: Bool)
        do {
            rotationOutcome = try await withTimeout(seconds: rotationTimeoutSeconds) { @MainActor in
                // Finish capture on old segment (non-blocking - doesn't wait for remix).
                var result: SegmentCaptureResult?
                if let segment = self.currentSegment {
                    result = await segment.finishCapture()
                }

                // Log segment directory summary.
                if let result {
                    self.logSegmentSummary(result)
                }

                if shouldVetoCommit() {
                    Logger.capture.info("Segment rotation superseded by pause/lock; bailing without a new segment")
                    await self.markDiscardedSegmentFailedAndRecover(newSegmentDir)
                    return (nil, true)
                }

                try Task.checkCancellation()

                // Collect available mics for new segment.
                let availableMics = MicrophoneMonitor.listInputDevices()
                    .filter {
                        MicrophoneSelection.shouldCapture(
                            $0,
                            disabledMicUIDs: self.disabledMicUIDs,
                            enabledMicUIDs: self.enabledMicUIDs
                        )
                    }
                    .prefix(4)

                // Start recording to new segment IMMEDIATELY (no waiting for remix).
                try await self.startNewSegmentWithDirectory(newSegmentDir, timePrefix: newTimePrefix, mics: Array(availableMics))

                if shouldVetoCommit() {
                    Logger.capture.info("Segment rotation superseded by pause/lock; bailing without a new segment")
                    _ = await self.discardCurrentSegmentWithoutEnqueue(matching: newSegmentDir)
                    await self.stopPersistentAudioForDiscard()
                    await self.markDiscardedSegmentFailedAndRecover(newSegmentDir)
                    return (nil, true)
                }
                return (result, false)
            }
        } catch is TimeoutError {
            Logger.capture.error("Segment rotation timed out; marking abandoned segment failed and scheduling recovery")
            if currentSegment?.outputDirectory == newSegmentDir {
                currentSegment = nil
            }
            await markIncompleteSegmentAsFailed(newSegmentDir)
            recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)
            scheduleDelayedRotationRetry()
            return .timedOut
        } catch {
            transitionToError("Failed to start new segment: \(error.localizedDescription)", error: error, trigger: "rotation_failed")
            Logger.capture.error("Failed to start new segment: \(error, privacy: .public)")
            return .failed(transitionFailure(for: error))
        }

        if rotationOutcome.superseded {
            return .superseded
        }

        // Enqueue remix for background processing.
        // RemixQueue will handle: remix, file rename, directory rename, and upload trigger.
        if let result = rotationOutcome.captureResult {
            await enqueueRemix(result)
        }
        return .committed
    }

    func lifecyclePauseCapture(reason: PauseReason, stopAudio: Bool) async -> URL? {
        let completedURL = await finalizeActiveSegmentForTransition(stopAudio: stopAudio)

        let oldState = state.label
        let newReasons = state.pausedReasons.union([reason])
        state = .paused(reasons: newReasons)
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) reasons=[\(renderPauseReasons(newReasons), privacy: .public)] (trigger: \(reason.trigger, privacy: .public))")
        onStateChanged?(state)

        return completedURL
    }

    func lifecycleApplyResumeReason(_ reason: ResumeReason) -> ResumeResolution {
        let currentReasons = state.pausedReasons
        let remainingReasons = currentReasons.subtracting(reason.clearsPauseReasons)

        if remainingReasons.isEmpty {
            return .readyToResume(restore: currentReasons)
        }

        let oldState = state.label
        state = .paused(reasons: remainingReasons)
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) reasons=[\(renderPauseReasons(remainingReasons), privacy: .public)] (trigger: \(reason.trigger, privacy: .public))")
        onStateChanged?(state)
        return .stayedPaused
    }

    func lifecyclePrepareResume(trigger: String) async throws {
        recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)

        if !allowsEmptyDisplayConfigurationForTesting {
            try await withTimeout(seconds: 10) { @MainActor in
                try await self.rebuildDisplaysAndFilters()
            }
        }

        try await startNewSegment()

        currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()
    }

    func lifecycleCommitResume(trigger: String) {
        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(trigger, privacy: .public))")
        onStateChanged?(state)
        startHeartbeat()
    }

    func lifecycleAbortPreparedResume(restore: Set<PauseReason>?, trigger: String) async {
        let abortedDirectory = await discardCurrentSegmentWithoutEnqueue(matching: nil)
        await stopPersistentAudioForDiscard()
        if let abortedDirectory {
            Logger.capture.info("[Event] \(trigger, privacy: .public): aborting prepared resume segment \(abortedDirectory.lastPathComponent, privacy: .public)")
            await markDiscardedSegmentFailedAndRecover(abortedDirectory)
        } else {
            Logger.capture.info("[Event] \(trigger, privacy: .public): aborting prepared resume with no active segment")
            recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)
        }

        let oldState = state.label
        let reasons = restore?.isEmpty == false ? restore! : Set<PauseReason>([.lock])
        state = .paused(reasons: reasons)
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) reasons=[\(renderPauseReasons(reasons), privacy: .public)] (trigger: \(trigger, privacy: .public)_aborted)")
        onStateChanged?(state)
    }

    func lifecycleTransitionToError(message: String, error: Error, trigger: String) {
        transitionToError(message, error: error, trigger: trigger)
    }

    func lifecycleProcessSegment(_ url: URL, useSleepActivity: Bool) {
        if useSleepActivity {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Processing and uploading segment before sleep"
            )

            Task {
                Logger.capture.info("Starting processing and upload in background before sleep")
                await self.finalizer.waitForCompletion()
                Logger.capture.info("Processing and upload completed before sleep")
                ProcessInfo.processInfo.endActivity(activity)
            }
        } else {
            Task {
                Logger.capture.info("Waiting for segment processing after lock: \(url.lastPathComponent, privacy: .public)")
                await self.finalizer.waitForCompletion()
            }
        }
    }
}
