// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import os
import SolstoneCore
@preconcurrency import ScreenCaptureKit

@MainActor
public protocol CaptureSegmentWriting: AnyObject, Sendable {
    var outputDirectory: URL { get }

    @discardableResult
    func start(
        sources: CaptureSources,
        displayInfos: [DisplayInfo],
        filters: [CGDirectDisplayID: SCContentFilter],
        audioFilter: SCContentFilter?,
        mics: [AudioInputDevice],
        micCaptureManager: MicrophoneCaptureManager?,
        systemAudioCaptureManager: SystemAudioCaptureManager?
    ) async throws -> CaptureSources
    func finishCapture() async -> SegmentCaptureResult?
    func updateContentFilter(_ filters: [CGDirectDisplayID: SCContentFilter]) async throws
    func addMicrophone(_ device: AudioInputDevice) throws
    func removeMicrophone(deviceUID: String)
    func deselectMicrophone(deviceUID: String)
    func hasMicrophone(deviceUID: String) -> Bool
    func activeMicrophoneUIDs() -> [String]
    var onTerminalStop: (@MainActor () -> Void)? { get set }
    var onCaptureIssue: (@MainActor (String) -> Void)? { get set }
}

public extension CaptureSegmentWriting {
    func deselectMicrophone(deviceUID: String) { removeMicrophone(deviceUID: deviceUID) }
    var onCaptureIssue: (@MainActor (String) -> Void)? {
        get { nil }
        set {}
    }
    var onTerminalStop: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
}

extension SegmentWriter: CaptureSegmentWriting {}

/// Manages continuous recording with segment rotation
/// Thread safety: All access is isolated to MainActor
@MainActor
public final class CaptureManager {
    public typealias SegmentFactory = @MainActor @Sendable (
        _ outputDirectory: URL,
        _ timePrefix: String,
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
    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal var beforeResumeNativeStartForTesting: (@MainActor () async -> Void)?
    #endif
    private var segmentTimer: Timer?
    private var segmentTimerRevision: UInt64 = 0
    private var heartbeatTimer: Timer?
    private var heartbeatTimerRevision: UInt64 = 0
    private var segmentStartGeneration = 0
    private var displays: [SCDisplay] = []
    private var filtersByDisplayID: [CGDirectDisplayID: SCContentFilter] = [:]
    private let verbose: Bool
    internal let lifecycleManager: CaptureLifecycleManager
    private let windowExclusionManager: WindowExclusionManager
    private let segmentFactory: SegmentFactory
    private let recoveryCoordinator: IncompleteSegmentRecoveryCoordinator
    private let finalizer: any SegmentFinalizing
    private let rotationTimeoutSeconds: TimeInterval
    private let captureZoneSource: CaptureZoneSource
    private let now: @Sendable () -> Date
    // Test-only bypass for fake segment factories without ScreenCaptureKit display state; defaults false.
    private let allowsEmptyDisplayConfigurationForTesting: Bool

    /// Persistent mic capture manager - keeps AVAudioEngine instances alive across segment rotations
    /// This prevents audio playback interference during rotation
    private let micCaptureManager: MicrophoneCaptureManager

    /// Persistent system audio capture manager - keeps SCStream alive across segment rotations
    private let systemAudioCaptureManager: SystemAudioCaptureManager

    /// Closure to check if music silencing is enabled
    private let silenceMusic: @Sendable () -> Bool

    /// Current default microphone device ID (for change detection)
    private var currentDefaultMicID: AudioDeviceID?

    /// CoreAudio listener for default mic changes
    private var defaultMicListener: HALPropertyListener?

    /// UIDs of microphones to exclude from recording (disabled mics)
    private var disabledMicUIDs: Set<String> = []
    private var enabledMicUIDs: Set<String> = []
    private var hasLiveMicrophoneSelection = false
    internal var microphoneSelectionProvider: (@MainActor () -> (disabled: Set<String>, enabled: Set<String>))?

    public private(set) var activeSources: CaptureSources = []
    private var sessionSources: CaptureSources = []
    private let microphoneDevices: @MainActor () -> [AudioInputDevice]
    private let shareableContentProvider: @MainActor () async throws -> SCShareableContent
    private(set) var state: State = .idle

    /// Called when state changes
    var onStateChanged: ((State) -> Void)?

    /// Called when an underlying stream encounters a terminal stop (e.g. macOS Stop Sharing)
    public var onTerminalStreamStop: (@MainActor () -> Void)?
    public var onAudioCaptureIssue: (@MainActor (String?) -> Void)?
    public private(set) var currentAudioCaptureIssue: String?

    public func handleTerminalStreamStop() {
        onTerminalStreamStop?()
    }

    /// Time remaining in current segment
    public var segmentTimeRemaining: TimeInterval {
        guard let timer = segmentTimer else { return 0 }
        return max(0, timer.fireDate.timeIntervalSinceNow)
    }

    // MARK: - Initialization

    public convenience init(
        storageManager: StorageManager,
        silenceMusic: @escaping @Sendable () -> Bool = { true },
        excludedAppNames: [String] = [],
        excludePrivateBrowsing: Bool = true,
        excludedTitlePatterns: [String] = [],
        excludePrivateBrowsingAccessibility: Bool = false,
        microphoneGain: Float = 2.0,
        verbose: Bool = false,
        segmentFactory: @escaping SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose
            )
        },
        recoveryCoordinator: IncompleteSegmentRecoveryCoordinator = .shared,
        finalizer: any SegmentFinalizing = RemixQueue.shared,
        rotationTimeoutSeconds: TimeInterval = 30,
        captureZoneSource: CaptureZoneSource = .device,
        now: @escaping @Sendable () -> Date = Date.init,
        allowsEmptyDisplayConfigurationForTesting: Bool = false,
        microphoneDevices: @escaping @MainActor () -> [AudioInputDevice] = MicrophoneMonitor.listInputDevices,
        shareableContentProvider: @escaping @MainActor () async throws -> SCShareableContent = { try await SCShareableContent.current }
    ) {
        self.init(
            storageManager: storageManager,
            silenceMusic: silenceMusic,
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns,
            excludePrivateBrowsingAccessibility: excludePrivateBrowsingAccessibility,
            microphoneGain: microphoneGain,
            verbose: verbose,
            segmentFactory: segmentFactory,
            recoveryCoordinator: recoveryCoordinator,
            finalizer: finalizer,
            rotationTimeoutSeconds: rotationTimeoutSeconds,
            captureZoneSource: captureZoneSource,
            now: now,
            allowsEmptyDisplayConfigurationForTesting: allowsEmptyDisplayConfigurationForTesting,
            microphoneDevices: microphoneDevices,
            shareableContentProvider: shareableContentProvider,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: CaptureLifecycleManager.liveRecoveryScheduler,
            isScreenLocked: CaptureLifecycleManager.defaultIsScreenLocked
        )
    }

    internal init(
        storageManager: StorageManager,
        silenceMusic: @escaping @Sendable () -> Bool = { true },
        excludedAppNames: [String] = [],
        excludePrivateBrowsing: Bool = true,
        excludedTitlePatterns: [String] = [],
        excludePrivateBrowsingAccessibility: Bool = false,
        microphoneGain: Float = 2.0,
        verbose: Bool = false,
        segmentFactory: @escaping SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose
            )
        },
        recoveryCoordinator: IncompleteSegmentRecoveryCoordinator = .shared,
        finalizer: any SegmentFinalizing = RemixQueue.shared,
        rotationTimeoutSeconds: TimeInterval = 30,
        captureZoneSource: CaptureZoneSource = .device,
        now: @escaping @Sendable () -> Date = Date.init,
        allowsEmptyDisplayConfigurationForTesting: Bool = false,
        microphoneDevices: @escaping @MainActor () -> [AudioInputDevice] = MicrophoneMonitor.listInputDevices,
        shareableContentProvider: @escaping @MainActor () async throws -> SCShareableContent = { try await SCShareableContent.current },
        streamFactory: @escaping CaptureStreamFactory,
        recoveryScheduler: @escaping RecoveryScheduler,
        isScreenLocked: @escaping @MainActor () -> Bool = CaptureLifecycleManager.defaultIsScreenLocked,
        microphoneCaptureManager: MicrophoneCaptureManager? = nil
    ) {
        self.storageManager = storageManager
        self.silenceMusic = silenceMusic
        self.verbose = verbose
        self.segmentFactory = segmentFactory
        self.recoveryCoordinator = recoveryCoordinator
        self.finalizer = finalizer
        self.rotationTimeoutSeconds = rotationTimeoutSeconds
        self.captureZoneSource = captureZoneSource
        self.now = now
        self.allowsEmptyDisplayConfigurationForTesting = allowsEmptyDisplayConfigurationForTesting
        self.microphoneDevices = microphoneDevices
        self.shareableContentProvider = shareableContentProvider
        self.micCaptureManager = microphoneCaptureManager ?? MicrophoneCaptureManager(gain: microphoneGain, verbose: verbose)
        self.systemAudioCaptureManager = SystemAudioCaptureManager(streamFactory: streamFactory)
        self.lifecycleManager = CaptureLifecycleManager(
            recoveryScheduler: recoveryScheduler,
            isScreenLocked: isScreenLocked
        )
        self.windowExclusionManager = WindowExclusionManager(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns,
            readsAccessibilityTitles: excludePrivateBrowsingAccessibility,
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
                // Video only. The system audio stream keeps the display's base filter: keeping an
                // application out of the video filter would also silence that app's audio.
                guard let self, self.sessionSources.contains(.screen), let segment = self.currentSegment else { return }
                try await segment.updateContentFilter(newFilters)
            },
            allDisplays: { [weak self] in self?.displays },
            isRecording: { [weak self] in
                guard let self else { return false }
                return self.state.isRecording && self.sessionSources.contains(.screen)
            }
        )
        lifecycleManager.configure(delegate: self)
        self.systemAudioCaptureManager.onTerminalStop = { [weak self] in
            self?.handleTerminalStreamStop()
        }
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
        guard state.isRecording, sessionSources.contains(.microphone) else { return }
        // Physical loss remains a failure, unlike a deliberate selection change.
        for device in removed {
            let capture = micCaptureManager.getCapture(for: device.uid)
            if capture?.isCapturing == true, let boundID = capture?.currentDeviceID,
               boundID != device.id,
               microphoneDevices().contains(where: { $0.uid == device.uid && $0.id == boundID }) { continue }
            currentSegment?.removeMicrophone(deviceUID: device.uid)
            micCaptureManager.stopCapture(deviceUID: device.uid)
        }
        // Event payloads can be stale. Admission always uses current enumeration
        // and owner intent, including the same four-device limit as startup.
        reconcileMicrophoneSelection(restartFailed: true)
    }

    public func updateMicrophoneSelection(disabled: Set<String>, enabled: Set<String>) {
        let renewed = disabledMicUIDs.subtracting(disabled).union(enabled.subtracting(enabledMicUIDs))
        micCaptureManager.authorizeMicrophoneRequest(deviceUIDs: renewed)
        disabledMicUIDs = disabled
        enabledMicUIDs = enabled
        hasLiveMicrophoneSelection = true
        reconcileMicrophoneSelection()
    }

    private func selectedMicrophonesForSegment() -> [AudioInputDevice] {
        if let current = microphoneSelectionProvider?() {
            disabledMicUIDs = current.disabled
            enabledMicUIDs = current.enabled
        }
        let available = microphoneDevices()
        let selected = Array(available.filter {
            MicrophoneSelection.shouldCapture($0, disabledMicUIDs: disabledMicUIDs, enabledMicUIDs: enabledMicUIDs)
        }.prefix(4))
        let revoked = micCaptureManager.updateSelection(selected, hasAvailableDevices: !available.isEmpty)
        for uid in revoked {
            currentSegment?.deselectMicrophone(deviceUID: uid)
            micCaptureManager.stopCapture(deviceUID: uid)
        }
        return selected
    }

    private func reconcileMicrophoneSelection(duringStartup: Bool = false, restartFailed: Bool = false) {
        let selected = selectedMicrophonesForSegment()
        guard (state.isRecording || duringStartup), sessionSources.contains(.microphone),
              let segment = currentSegment else { return }
        let selectedUIDs = Set(selected.map(\.uid))
        for uid in segment.activeMicrophoneUIDs() where !selectedUIDs.contains(uid) {
            segment.deselectMicrophone(deviceUID: uid)
        }
        for device in selected where !segment.hasMicrophone(deviceUID: device.uid) ||
            (restartFailed && micCaptureManager.getCapture(for: device.uid)?.isCapturing == false) {
            do { try segment.addMicrophone(device) }
            catch { Logger.capture.warning("Failed to reconcile mic \(device.name, privacy: .public): \(error, privacy: .public)") }
        }
        if segment.activeMicrophoneUIDs().isEmpty { activeSources.remove(.microphone) }
        else { activeSources.insert(.microphone) }
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
    ///   - excludePrivateBrowsingAccessibility: Whether to also match Safari, Chrome, Edge and Brave by their Accessibility titles
    public func updateWindowExclusions(
        excludedAppNames: [String],
        excludePrivateBrowsing: Bool,
        excludedTitlePatterns: [String],
        excludePrivateBrowsingAccessibility: Bool
    ) {
        windowExclusionManager.updateExclusions(
            excludedAppNames: excludedAppNames,
            excludePrivateBrowsing: excludePrivateBrowsing,
            excludedTitlePatterns: excludedTitlePatterns,
            readsAccessibilityTitles: excludePrivateBrowsingAccessibility
        )
    }

    // MARK: - Private Methods

    private func rebuildDisplaysAndFilters() async throws {
        let content = try await shareableContentProvider()
        try Task.checkCancellation()
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

    private func captureZoneForNewSegment() -> TimeZone? {
        do {
            return try captureZoneSource.currentTimeZone()
        } catch {
            Logger.storage.warning("Failed to resolve capture time zone: \(error, privacy: .public)")
            return nil
        }
    }

    /// Starts a new recording segment
    private func startNewSegment() async throws {
        try Task.checkCancellation()
        guard !lifecycleManager.ownerPauseIsHeld() else { throw CancellationError() }
        if sessionSources.contains(.screen) {
            guard allowsEmptyDisplayConfigurationForTesting || (!displays.isEmpty && !filtersByDisplayID.isEmpty) else {
                throw CaptureError.notInitialized
            }
        }

        // Create segment directory with current time (named HHMMSS.incomplete)
        let (segmentDir, timePrefix) = try storageManager.createSegmentDirectory(
            segmentStartTime: now(),
            timeZone: captureZoneForNewSegment()
        )

        let availableMics = sessionSources.contains(.microphone) ? selectedMicrophonesForSegment() : []

        // Start video/audio capture
        try await startNewSegmentWithDirectory(segmentDir, timePrefix: timePrefix, mics: availableMics)
    }

    /// Starts recording to a pre-created segment directory
    /// - Parameters:
    ///   - segmentDir: Directory to write segment files to
    ///   - timePrefix: Time prefix for file naming
    ///   - mics: Microphone devices to start recording
    private func startNewSegmentWithDirectory(_ segmentDir: URL, timePrefix: String, mics: [AudioInputDevice] = []) async throws {
        try Task.checkCancellation()
        guard !lifecycleManager.ownerPauseIsHeld() else { throw CancellationError() }
        if sessionSources.contains(.screen) {
            guard allowsEmptyDisplayConfigurationForTesting || (!displays.isEmpty && !filtersByDisplayID.isEmpty) else {
                throw CaptureError.notInitialized
            }
            if allowsEmptyDisplayConfigurationForTesting && displays.isEmpty && filtersByDisplayID.isEmpty {
                Logger.capture.info("Starting test segment with empty display/filter configuration")
            }
        }

        segmentStartGeneration += 1
        let generation = segmentStartGeneration

        // Every segment's streams start with the current exclusions, so their first frame never
        // holds an excluded app or a private window.
        var screenFilters = filtersByDisplayID
        if sessionSources.contains(.screen) {
            windowExclusionManager.resetForNewSegment()
            if !displays.isEmpty {
                screenFilters = await windowExclusionManager.filtersForNewSegment(displays: displays, base: filtersByDisplayID)
            }
        }

        // Create segment writer
        try Task.checkCancellation()
        guard generation == segmentStartGeneration, !lifecycleManager.ownerPauseIsHeld() else { throw CancellationError() }
        let segment = segmentFactory(
            segmentDir,
            timePrefix,
            silenceMusic(),
            verbose
        )
        currentAudioCaptureIssue = nil
        segment.onTerminalStop = { [weak self] in
            self?.handleTerminalStreamStop()
        }
        segment.onCaptureIssue = { [weak self, weak segment] message in
            guard let self, let segment, self.currentSegment?.outputDirectory == segment.outputDirectory else { return }
            self.currentAudioCaptureIssue = message
            self.onAudioCaptureIssue?(message)
        }
        currentSegment = segment

        // Start recording - convert to DisplayInfo for sendable compliance
        let displayInfos = sessionSources.contains(.screen) ? displays.map { DisplayInfo(from: $0) } : []
        let audioFilter = sessionSources.contains(.screen) ? displays.first.flatMap { filtersByDisplayID[$0.displayID] } : nil
        if sessionSources.contains(.screen) && audioFilter == nil {
            let displayID = displays.first.map { String($0.displayID) } ?? "nil"
            let keyList = filtersByDisplayID.keys.sorted().map(String.init).joined(separator: ",")
            Logger.capture.error("Missing audio SCContentFilter for display \(displayID, privacy: .public); available filter keys=[\(keyList, privacy: .public)]")
        }
        do {
            let startedSources = try await segment.start(
                sources: sessionSources,
                displayInfos: displayInfos,
                filters: sessionSources.contains(.screen) ? screenFilters : [:],
                audioFilter: audioFilter,
                mics: sessionSources.contains(.microphone) ? mics : [],
                micCaptureManager: sessionSources.contains(.microphone) ? micCaptureManager : nil,
                systemAudioCaptureManager: sessionSources.contains(.screen) ? systemAudioCaptureManager : nil
            )
            try Task.checkCancellation()
            guard generation == segmentStartGeneration else { throw CancellationError() }
            guard !startedSources.isEmpty || (sessionSources == .microphone && micCaptureManager.hasIntentionallyEmptySelection) else {
                throw CaptureError.noSourcesAvailable
            }
            self.activeSources = startedSources
            if sessionSources.contains(.microphone) {
                let latest = selectedMicrophonesForSegment()
                if Set(latest.map(\.uid)) != Set(mics.map(\.uid)) {
                    reconcileMicrophoneSelection(duringStartup: true)
                }
            }
            self.onAudioCaptureIssue?(currentAudioCaptureIssue)
        } catch {
            guard generation == segmentStartGeneration else { throw error }
            currentSegment = nil
            await stopPersistentAudioForDiscard()
            await markIncompleteSegmentAsFailed(segmentDir)
            throw error
        }

        guard generation == segmentStartGeneration else { return }

        // Mark stream as ready after a short delay to allow capture to stabilize.
        if sessionSources.contains(.screen) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.windowExclusionManager.streamBecameReady()
            }
        }

        // Schedule segment rotation
        scheduleSegmentRotation()
    }

    private func scheduleSegmentRotation() {
        stopSegmentRotation()
        let revision = segmentTimerRevision
        let interval = Self.timeUntilNextSegmentBoundary()
        segmentTimer = CaptureTimer.schedule(interval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.deliverSegmentBoundary(revision: revision)
            }
        }
        Logger.capture.info("Next segment rotation in \(Int(interval), privacy: .public) seconds")
    }

    private func stopSegmentRotation() {
        segmentTimerRevision &+= 1
        segmentTimer?.invalidate()
        segmentTimer = nil
    }

    private func deliverSegmentBoundary(revision: UInt64) async {
        guard segmentTimerRevision == revision, state.isRecording else { return }
        await lifecycleManager.enqueue(.rotate(reason: .boundary), admission: { [weak self] in
            guard let self else { return false }
            return self.segmentTimerRevision == revision && self.state.isRecording
        })
    }

    internal func scheduledBoundaryDeliveryForTesting() -> @MainActor @Sendable () async -> Void {
        scheduleSegmentRotation()
        let revision = segmentTimerRevision
        return { [weak self] in await self?.deliverSegmentBoundary(revision: revision) }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let revision = heartbeatTimerRevision
        heartbeatTimer = CaptureTimer.schedule(interval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.heartbeatTimerRevision == revision else { return }
                self.handleHeartbeatTick()
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
        heartbeatTimerRevision &+= 1
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func finalizeActiveSegmentForTransition(stopAudio: Bool) async -> URL? {
        stopSegmentRotation()
        stopHeartbeat()

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
        stopSegmentRotation()
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
            silenceMusic: result.silenceMusic,
            micMetadataJSON: result.micMetadataJSON,
            audioDiagnostics: result.audioDiagnostics,
            audioOwnership: result.audioOwnership
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

    private func reapAbandonedStart(generationAtSpawn: Int, abandonedDir: URL) async {
        guard segmentStartGeneration == generationAtSpawn + 1 else { return }
        _ = await discardCurrentSegmentWithoutEnqueue(matching: abandonedDir)
        await stopPersistentAudioForDiscard()
    }

    internal func handleDisplayChange() async {
        guard state.isRecording, activeSources.contains(.screen) else {
            if activeSources.contains(.screen) {
                await lifecycleManager.noteDisplayChange()
            }
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
        handleDefaultMicChange(currentID: MicrophoneMonitor.getDefaultInputDeviceID())
    }

    internal func handleDefaultMicChange(currentID newDefaultMicID: AudioDeviceID?) {
        guard state.isRecording, sessionSources.contains(.microphone) else { return }

        // Check if default mic actually changed
        if newDefaultMicID != currentDefaultMicID {
            Logger.capture.info("Default microphone changed (no rotation - mics handled dynamically)")
            currentDefaultMicID = newDefaultMicID
            reconcileMicrophoneSelection(restartFailed: true)
        }
    }

    // MARK: - Test Support

    internal func seedRecordingForTesting(currentSegment: any CaptureSegmentWriting, sources: CaptureSources = .all) {
        self.currentSegment = currentSegment
        self.activeSources = sources
        self.sessionSources = sources
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

#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal var isSystemAudioRunningForTesting: Bool {
        systemAudioCaptureManager.isRunning
    }
#endif

    // MARK: - Errors

    public enum CaptureError: Error, LocalizedError {
        case noDisplaysAvailable
        case notInitialized
        case noSourcesAvailable

        public var errorDescription: String? {
            switch self {
            case .noDisplaysAvailable:
                return "No displays available for capture"
            case .noSourcesAvailable:
                return UICopy.SOURCES_UNAVAILABLE
            case .notInitialized:
                return "Capture manager not initialized"
            }
        }
    }
}

// MARK: - CaptureLifecycleDelegate

extension CaptureManager: CaptureLifecycleDelegate {
    var lifecycleCurrentState: CaptureManager.State { state }
    var lifecycleOwnerPauseIsHeld: Bool { lifecycleManager.ownerPauseIsHeld() }

    func lifecycleAuthorizeResume(_ reason: ResumeReason) -> MicrophoneCaptureManager.RecoveryAuthorization? {
        guard reason == .user, sessionSources.contains(.microphone), !lifecycleOwnerPauseIsHeld else { return nil }
        return micCaptureManager.authorizeMicrophoneRequest()
    }

    func lifecycleCancelResumeAuthorization(_ authorization: MicrophoneCaptureManager.RecoveryAuthorization?) {
        micCaptureManager.cancelMicrophoneRequest(authorization)
    }

    func lifecycleStartCapture(
        reason: StartReason,
        sources: CaptureSources,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        shouldVetoCommit: @escaping @MainActor () -> Bool
    ) async throws -> StartResult {
        guard !lifecycleOwnerPauseIsHeld else { return .vetoedOwnerPause }
        guard !sources.isEmpty else {
            throw transitionFailure(for: CaptureError.notInitialized)
        }
        let microphoneAuthorization = reason == .user ? micCaptureManager.authorizeMicrophoneRequest() : nil
        if let current = microphoneSelectionProvider?() {
            self.disabledMicUIDs = current.disabled
            self.enabledMicUIDs = current.enabled
        } else if !hasLiveMicrophoneSelection {
            self.disabledMicUIDs = disabledMicUIDs
            self.enabledMicUIDs = enabledMicUIDs
        }
        self.sessionSources = sources
        self.activeSources = []

        do {
            recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)

            // Clear any stale recovery state (e.g., user manually restarted while paused from sleep/lock).
            lifecycleManager.resetLifecyclePendingState(stopRecovery: false)

            // Ensure storage directory exists.
            try storageManager.ensureBaseDirectoryExists()

            if sources.contains(.screen) && !allowsEmptyDisplayConfigurationForTesting {
                do {
                    try await rebuildDisplaysAndFilters()
                } catch {
                    guard sources.contains(.microphone) else { throw error }
                    sessionSources.remove(.screen)
                    Logger.capture.warning("Screen initialization failed; starting selected microphone: \(error, privacy: .public)")
                }
            }

            // Start first segment.
            try await startNewSegment()
        } catch {
            self.activeSources = []
            if error is CancellationError { micCaptureManager.cancelMicrophoneRequest(microphoneAuthorization) }
            throw transitionFailure(for: error)
        }

        if shouldVetoCommit() || lifecycleOwnerPauseIsHeld {
            _ = await discardCurrentSegmentWithoutEnqueue(matching: nil)
            await stopPersistentAudioForDiscard()
            self.activeSources = []
            micCaptureManager.cancelMicrophoneRequest(microphoneAuthorization)
            return lifecycleOwnerPauseIsHeld ? .vetoedOwnerPause : .vetoedScreenLocked
        }

        // Microphone intent survives intentional exclusion or temporary loss so
        // a later selection/hotplug can start it within the observing session.
        sessionSources = activeSources.union(sources.intersection(.microphone))
        // Start monitoring for default microphone changes.
        if sessionSources.contains(.microphone) {
            startDefaultMicMonitoring()
        }

        let oldState = state.label
        state = .recording
        Logger.capture.info("[State] \(oldState, privacy: .public) -> \(self.state.label, privacy: .public) (trigger: \(reason.trigger, privacy: .public))")
        onStateChanged?(state)
        startHeartbeat()

        Logger.capture.info("Started recording session (\(self.activeSources.logDescription, privacy: .public)) with \(self.displays.count, privacy: .public) display(s)")
        return .committed
    }

    func lifecycleResetForRestartFromError() async {
        Logger.capture.info("[Executor] resetting for restart from error")
        windowExclusionManager.stop()
        stopDefaultMicMonitoring()

        stopSegmentRotation()
        stopHeartbeat()
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
        stopSegmentRotation()
        stopHeartbeat()
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

        activeSources = []
        sessionSources = []
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
        Logger.capture.info("Rotating segment...")

        // Create new segment directory FIRST.
        let newSegmentDir: URL
        let newTimePrefix: String
        do {
            (newSegmentDir, newTimePrefix) = try storageManager.createSegmentDirectory(
                segmentStartTime: now(),
                timeZone: captureZoneForNewSegment()
            )
        } catch {
            transitionToError("Failed to create segment directory: \(error.localizedDescription)", error: error, trigger: "rotation_failed")
            Logger.capture.error("Failed to rotate segment: \(error, privacy: .public)")
            return .failed(transitionFailure(for: error))
        }

        var oldResult: SegmentCaptureResult?
        if let segment = currentSegment {
            oldResult = await segment.finishCapture()
        }
        if let oldResult {
            logSegmentSummary(oldResult)
        }

        if shouldVetoCommit() {
            Logger.capture.info("Segment rotation superseded by pause/lock; bailing without a new segment")
            await markDiscardedSegmentFailedAndRecover(newSegmentDir)
            return .superseded
        }

        let generationAtSpawn = segmentStartGeneration
        let startTask = Task { @MainActor in
            let availableMics = self.sessionSources.contains(.microphone) ? self.selectedMicrophonesForSegment() : []
            try await self.startNewSegmentWithDirectory(
                newSegmentDir,
                timePrefix: newTimePrefix,
                mics: availableMics
            )
        }

        do {
            try await withTimeout(seconds: rotationTimeoutSeconds) { @MainActor in
                try await startTask.value
            }
        } catch is TimeoutError {
            startTask.cancel()
            Logger.capture.error("[Rotation] Segment rotation timed out after \(Int(self.rotationTimeoutSeconds), privacy: .public)s; tearing down abandoned start and arming recovery (trigger: rotation_timeout)")
            _ = await discardCurrentSegmentWithoutEnqueue(matching: newSegmentDir)
            currentSegment = nil
            await stopPersistentAudioForDiscard()
            await markDiscardedSegmentFailedAndRecover(newSegmentDir)
            transitionToError(
                "Segment rotation timed out",
                error: TimeoutError(seconds: rotationTimeoutSeconds),
                trigger: "rotation_timeout"
            )
            Task { @MainActor [weak self] in
                _ = await startTask.result
                await self?.reapAbandonedStart(generationAtSpawn: generationAtSpawn, abandonedDir: newSegmentDir)
            }
            if let oldResult {
                await enqueueRemix(oldResult)
            }
            return .timedOut
        } catch {
            transitionToError("Failed to start new segment: \(error.localizedDescription)", error: error, trigger: "rotation_failed")
            Logger.capture.error("Failed to start new segment: \(error, privacy: .public)")
            currentSegment = nil
            if let oldResult {
                await enqueueRemix(oldResult)
            }
            return .failed(transitionFailure(for: error))
        }

        if shouldVetoCommit() {
            Logger.capture.info("Segment rotation superseded by pause/lock; bailing without a new segment")
            _ = await discardCurrentSegmentWithoutEnqueue(matching: newSegmentDir)
            await stopPersistentAudioForDiscard()
            await markDiscardedSegmentFailedAndRecover(newSegmentDir)
            return .superseded
        }

        if let oldResult {
            await enqueueRemix(oldResult)
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
        try Task.checkCancellation()
        recoveryCoordinator.scheduleDetached(excludingActiveSegment: currentSegment?.outputDirectory.standardizedFileURL.path)

        if sessionSources.contains(.screen) && !allowsEmptyDisplayConfigurationForTesting {
            try await withTimeout(seconds: 10) { @MainActor in
                try await self.rebuildDisplaysAndFilters()
            }
        }

        #if DEBUG || SOLSTONE_TEST_SUPPORT
        await beforeResumeNativeStartForTesting?()
        #endif
        try Task.checkCancellation()
        try await startNewSegment()

        if activeSources.contains(.microphone) {
            currentDefaultMicID = MicrophoneMonitor.getDefaultInputDeviceID()
        }
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
