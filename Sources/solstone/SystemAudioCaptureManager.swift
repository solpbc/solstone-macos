// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import CoreMedia
import Foundation
import os
import SolstoneCore
@preconcurrency import ScreenCaptureKit

/// Manages persistent system audio capture via SCStream across segment rotations
/// The stream stays running - only the audio callback destination changes
/// This prevents ScreenCaptureKit conflicts during segment rotation
@MainActor
public final class SystemAudioCaptureManager {
    /// Remains alive across stream replacement and segment rotation.
    public let mediaBudget = AudioMediaBudget()
    /// Current audio callback - can be changed while stream is running
    public var onAudioBuffer: ((CMSampleBuffer) -> Void)? {
        get { desiredAudioCallback }
        set {
            desiredAudioCallback = newValue
            streamOutput?.onAudioBuffer = newValue
            audioCallbackRevision &+= 1
        }
    }
    /// Changes with every destination change, so a caller can undo only its own.
    private(set) var audioCallbackRevision: UInt64 = 0
    private var desiredAudioCallback: ((CMSampleBuffer) -> Void)?
    public var onCaptureError: ((Error) -> Void)?
    public var onTerminalStop: (@MainActor () -> Void)?

    private var stream: (any CaptureStreamControlling)?
    private var streamOutput: SystemAudioStreamOutput?
    private var streamDelegate: StreamDelegate?
    private var currentFilter: SCContentFilter?
    private var streamGeneration: Int = 0
    private var activeStreamID: UUID?
    private var isRecovering = false
    private var recoveryAttempts = 0
    private var sessionRequested = false
    private var interruptionRevision: UInt64 = 0
    private var unresolvedInterruption: Error?
    private var retiringStreams: [UUID: any CaptureStreamControlling] = [:]
    private var pendingNativeOperations: [UUID: Int] = [:]
    private var cleanupTasks: [UUID: Task<Void, Error>] = [:]
    private var invalidateRestartListener: (() -> Void)?
    private var listenerRevision: UInt64 = 0
    private var resetRecoveryScheduled = false
    private var pendingServiceReset = false
    internal typealias RestartListenerFactory = @MainActor (@escaping @MainActor () -> Void) throws -> (() -> Void)
    private let restartListenerFactory: RestartListenerFactory
    private let operationTimeoutSeconds: Double
    private let verbose: Bool
    private let streamFactory: CaptureStreamFactory
#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal private(set) var _restartDecisionTraceForTesting: [String] = []
    internal var _restartParkHookForTesting: (@MainActor () async -> Void)?
    internal var _stopParkHookForTesting: (@MainActor () async -> Void)?
    internal var _ackParkHookForTesting: (@MainActor () async -> Void)?
    internal var _resetAdmissionParkHookForTesting: (@MainActor () async -> Void)?
    internal var _resetRecoveryScheduledForTesting: Bool { resetRecoveryScheduled }
    internal var _streamGenerationForTesting: Int { streamGeneration }
#endif

    /// Health check timer - monitors for missing audio buffers
    private var healthCheckTimer: Timer?
    /// Serial so audio buffers reach the writer in the order the stream produced them.
    private let sampleQueue = DispatchQueue(label: "app.solstone.system-audio.samples", qos: .userInitiated)
    private let healthCheckInterval: TimeInterval = 30.0  // Check every 30 seconds
    private var consecutiveEmptyChecks: Int = 0
    private let maxEmptyChecks: Int = 2  // Restart after 2 consecutive empty checks (60s of no audio)

    public convenience init(verbose: Bool = false) {
        self.init(verbose: verbose, streamFactory: defaultCaptureStreamFactory)
    }

    internal init(verbose: Bool = false, streamFactory: @escaping CaptureStreamFactory, operationTimeoutSeconds: Double = 5,
                  restartListenerFactory: @escaping RestartListenerFactory = SystemAudioCaptureManager.liveRestartListenerFactory) {
        self.verbose = verbose
        self.streamFactory = streamFactory
        self.operationTimeoutSeconds = operationTimeoutSeconds
        self.restartListenerFactory = restartListenerFactory
    }

    private static func liveRestartListenerFactory(_ onChange: @escaping @MainActor () -> Void) throws -> (() -> Void) {
        let listener = HALPropertyListener(objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyServiceRestarted, onChange: onChange)
        guard listener.registrationStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(listener.registrationStatus))
        }
        return { listener.invalidate() }
    }

    private func registerRestartListener() {
        invalidateRestartListener?(); invalidateRestartListener = nil
        listenerRevision &+= 1
        let revision = listenerRevision
        guard sessionRequested else { return }
        do {
            invalidateRestartListener = try restartListenerFactory { [weak self] in
                guard let self, self.sessionRequested, self.listenerRevision == revision else { return }
                self.handleServiceRestart()
            }
        } catch {
            onCaptureError?(error)
            Logger.audio.error("[SystemAudio] HAL restart observation unavailable: \(error, privacy: .public)")
        }
    }

    private func handleServiceRestart() {
        guard sessionRequested else { return }
        recordInterruption(NSError(domain: "SolstoneAudioTransport", code: 1))
        registerRestartListener()
        retireCurrentTransport()
        if !isRecovering { recoveryAttempts = 0 }
        pendingServiceReset = true
        scheduleResetRecovery()
    }

    private func scheduleResetRecovery() {
        guard sessionRequested, pendingServiceReset, !isRecovering, !resetRecoveryScheduled else { return }
        resetRecoveryScheduled = true
        let generation = streamGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resetRecoveryScheduled = false
                self.scheduleResetRecovery()
            }
#if DEBUG || SOLSTONE_TEST_SUPPORT
            if let hook = self._resetAdmissionParkHookForTesting { await hook() }
#endif
            guard self.sessionRequested, self.streamGeneration == generation, self.pendingServiceReset else { return }
            self.pendingServiceReset = false
            await self.restartStream()
        }
    }

    private func recordInterruption(_ error: Error) {
        interruptionRevision &+= 1
        unresolvedInterruption = error
        onCaptureError?(error)
    }

    private func acknowledgeAudio(streamID: UUID, revision: UInt64) async -> Bool {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let hook = _ackParkHookForTesting { await hook() }
#endif
        guard sessionRequested, activeStreamID == streamID, stream != nil,
              interruptionRevision == revision else { return false }
        unresolvedInterruption = nil
        recoveryAttempts = 0
        consecutiveEmptyChecks = 0
        return true
    }

    private func retireCurrentTransport() {
        streamOutput?.onAudioBuffer = nil
        if let stream, let activeStreamID { retiringStreams[activeStreamID] = stream }
        stream = nil; streamOutput = nil; streamDelegate = nil; activeStreamID = nil
    }

    /// Retain ownership on unknown cleanup failure; never overlap a replacement.
    private func cleanupRetiredTransport(only: UUID? = nil) async throws {
        for (id, retired) in retiringStreams where only == nil || only == id {
            guard retiringStreams[id] === retired else { continue }
            let cleanup: Task<Void, Error>
            if let existing = cleanupTasks[id] { cleanup = existing }
            else {
                cleanup = Task { @MainActor in
                    defer { self.cleanupTasks.removeValue(forKey: id) }
                    do { try await retired.stopCapture() }
                    catch let error as NSError where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3808 {}
                }
                cleanupTasks[id] = cleanup
            }
            try await withTimeout(seconds: operationTimeoutSeconds) { try await cleanup.value }
            // A stop result cannot prove quiescence while an earlier start or
            // filter update may still resume inside the native framework.
            guard pendingNativeOperations[id, default: 0] == 0 else {
                throw NSError(domain: "SolstoneAudioTransport", code: 2)
            }
            if retiringStreams[id] === retired { retiringStreams.removeValue(forKey: id) }
        }
    }

    private func startNativeTransport(_ transport: any CaptureStreamControlling, id: UUID) async throws {
        pendingNativeOperations[id, default: 0] += 1
        defer { endNativeOperation(id) }
        try await transport.startCapture()
        if Task.isCancelled {
            try? await transport.stopCapture()
            throw CancellationError()
        }
    }

    private func endNativeOperation(_ id: UUID) {
        let remaining = pendingNativeOperations[id, default: 1] - 1
        if remaining == 0 { pendingNativeOperations.removeValue(forKey: id) }
        else { pendingNativeOperations[id] = remaining }
    }

    private func endSessionAdmission() {
        sessionRequested = false
        pendingServiceReset = false
        listenerRevision &+= 1
        invalidateRestartListener?(); invalidateRestartListener = nil
        stopHealthCheck()
    }

    /// Start the system audio capture stream
    /// - Parameter filter: The content filter to use
    /// - Throws: If stream fails to start
    public func start(filter: SCContentFilter) async throws {
        currentFilter = filter
        if sessionRequested {
            if isRecovering || resetRecoveryScheduled { return }
            if stream != nil { try await updateContentFilter(filter); return }
            await restartStream()
            return
        }
        streamGeneration += 1
        let gen = streamGeneration
        sessionRequested = true
        interruptionRevision &+= 1
        unresolvedInterruption = nil
        recoveryAttempts = 0
        let initialRevision = interruptionRevision
        registerRestartListener()
        startHealthCheck()
        do {
            try await cleanupRetiredTransport()
            let started = try await startStream(filter: filter, gen: gen, traceProceed: false)
            if !started, sessionRequested, streamGeneration == gen { await restartStream() }
        } catch {
            if sessionRequested, streamGeneration == gen, interruptionRevision == initialRevision {
                recordInterruption(error)
                if isPermissionError(error) || isUserStoppedStreamError(error) { endSessionAdmission() }
            }
            throw error
        }
    }

    /// Internal stream start - used for initial start and restarts
    private func startStream(filter: SCContentFilter, gen: Int, traceProceed: Bool) async throws -> Bool {
        Logger.audio.info("[SystemAudio] Starting persistent SCStream...")

        // Create stream output
        let streamID = UUID()
        let revision = interruptionRevision
        let output = SystemAudioStreamOutput(verbose: verbose, onValidAudio: { [weak self] output in
            Task { @MainActor in
                let accepted = await self?.acknowledgeAudio(streamID: streamID, revision: revision) ?? false
                output.completeAudioAcknowledgement(accepted)
            }
        })

        // Create delegate to handle stream errors
        let delegate = StreamDelegate { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamError(error, streamID: streamID)
            }
        }

        // Configure audio stream for system audio only (minimize video overhead)
        let config = SCStreamConfiguration()
        config.sampleRate = 48_000
        config.channelCount = 1
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false  // All mics via ExternalMicCapture
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max
        config.width = 2  // Minimum valid dimensions
        config.height = 2
        config.queueDepth = 1  // Minimize buffered frames

        // Create and configure stream with delegate for error handling
        if verbose { Logger.audio.debug("[SystemAudio] Creating SCStream with config: 48kHz, 1ch, audio=true, mic=false") }
        guard streamGeneration == gen else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            return false
        }
        if traceProceed {
            appendRestartProceedTraceForTesting()
        }
        let newStream = streamFactory(filter, config, delegate)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)

        activeStreamID = streamID
        retiringStreams[streamID] = newStream
        do {
            try await withTimeout(seconds: operationTimeoutSeconds) {
                try await self.startNativeTransport(newStream, id: streamID)
            }
            guard sessionRequested, streamGeneration == gen, activeStreamID == streamID,
                  interruptionRevision == revision else {
                appendRestartSuppressedTraceForTesting()
                retiringStreams[streamID] = newStream
                try await cleanupRetiredTransport(only: streamID)
                return false
            }
            try await withTimeout(seconds: operationTimeoutSeconds) {
                try await self.applyLatestFilter(to: newStream, id: streamID, initial: filter, generation: gen, revision: revision)
            }
        } catch {
            if activeStreamID == streamID { activeStreamID = nil }
            retiringStreams[streamID] = newStream
            do { try await cleanupRetiredTransport(only: streamID) }
            catch { Logger.audio.error("[SystemAudio] Uncommitted stream cleanup failed: \(error, privacy: .public)") }
            throw error
        }
        guard sessionRequested, streamGeneration == gen, activeStreamID == streamID,
              interruptionRevision == revision else {
            appendRestartSuppressedTraceForTesting()
            retiringStreams[streamID] = newStream
            try await cleanupRetiredTransport(only: streamID)
            return false
        }
        self.streamOutput = output
        output.onAudioBuffer = desiredAudioCallback
        self.streamDelegate = delegate
        self.stream = newStream
        pendingServiceReset = false
        retiringStreams.removeValue(forKey: streamID)

        // Reset health check state
        consecutiveEmptyChecks = 0

        Logger.audio.info("[SystemAudio] Started persistent system audio capture successfully")
        return true
    }

    private func applyLatestFilter(to transport: any CaptureStreamControlling, id: UUID, initial: SCContentFilter,
                                   generation: Int, revision: UInt64) async throws {
        pendingNativeOperations[id, default: 0] += 1
        defer { endNativeOperation(id) }
        var applied = initial
        while let desired = currentFilter, desired !== applied {
            try Task.checkCancellation()
            guard sessionRequested, streamGeneration == generation, interruptionRevision == revision else { throw CancellationError() }
            try await transport.updateContentFilter(desired)
            applied = desired
        }
        try Task.checkCancellation()
    }

    public func stop() async {
        streamGeneration += 1
        endSessionAdmission()
        retireCurrentTransport()
        currentFilter = nil
        onAudioBuffer = nil
        onCaptureError = nil
        unresolvedInterruption = nil
        do {
#if DEBUG || SOLSTONE_TEST_SUPPORT
            let hook = _stopParkHookForTesting
            try await withTimeout(seconds: operationTimeoutSeconds) {
                if let hook { await hook(); try Task.checkCancellation() }
                try await self.cleanupRetiredTransport()
            }
#else
            try await cleanupRetiredTransport()
#endif
        }
        catch { Logger.audio.warning("[SystemAudio] Error stopping stream: \(error, privacy: .public)") }
    }

    /// Update the content filter (for window exclusion changes)
    /// - Parameter filter: The new content filter
    public func updateContentFilter(_ filter: SCContentFilter) async throws {
        // Remember intent even while recovery has no transport. An old awaited
        // update must never overwrite the filter selected by a later caller.
        currentFilter = filter
        guard let stream = stream, let id = activeStreamID else {
            if verbose { Logger.audio.debug("[SystemAudio] updateContentFilter called but stream not running") }
            return
        }
        if verbose { Logger.audio.debug("[SystemAudio] Updating content filter for window exclusions") }
        try await withTimeout(seconds: operationTimeoutSeconds) {
            try await self.updateNativeFilter(stream, id: id, filter: filter)
        }
    }

    private func updateNativeFilter(_ stream: any CaptureStreamControlling, id: UUID, filter: SCContentFilter) async throws {
        pendingNativeOperations[id, default: 0] += 1
        defer { endNativeOperation(id) }
        try await stream.updateContentFilter(filter)
        try Task.checkCancellation()
    }

    /// Clear the audio callback (called during segment rotation)
    public func clearCallback() {
        let hadCallback = onAudioBuffer != nil
        onAudioBuffer = nil
        onCaptureError = nil
        Logger.audio.info("[SystemAudio] Cleared callback (had callback: \(hadCallback, privacy: .public), stream running: \(self.isRunning, privacy: .public))")
    }

    /// Clears the callback only if it is still the one `revision` names.
    func clearCallback(ifRevision revision: UInt64) {
        guard audioCallbackRevision == revision else { return }
        clearCallback()
    }

    /// Wire up a new callback (called when new segment starts)
    public func setCallback(onError: ((Error) -> Void)? = nil, _ callback: @escaping (CMSampleBuffer) -> Void) {
        onAudioBuffer = callback
        onCaptureError = onError
        if let unresolvedInterruption { onError?(unresolvedInterruption) }
        Logger.audio.info("[SystemAudio] Wired callback to new segment (stream running: \(self.isRunning, privacy: .public))")
    }

    /// Check if capture is running
    public var isRunning: Bool {
        stream != nil
    }

    // MARK: - Error Handling

    /// Handle stream errors reported by the delegate
    private func handleStreamError(_ error: Error, streamID: UUID) async {
        guard sessionRequested, activeStreamID == streamID else { return }
        recordInterruption(error)
        retireCurrentTransport()
        if isPermissionError(error) {
            endSessionAdmission()
            return
        }
        if isUserStoppedStreamError(error) {
            endSessionAdmission()
            onTerminalStop?()
            return
        }
        await restartStream()
    }

    // MARK: - Health Check

    /// Start the health check timer
    private func startHealthCheck() {
        stopHealthCheck()

        let timer = CaptureTimer.schedule(interval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
        timer.tolerance = 10.0  // Allow coalescing to reduce energy impact
        healthCheckTimer = timer
        if verbose { Logger.audio.debug("[SystemAudio] Started health check timer (interval: \(Int(self.healthCheckInterval), privacy: .public)s)") }
    }

    /// Stop the health check timer
    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        consecutiveEmptyChecks = 0
    }

    /// Check if audio buffers are being received
    private func performHealthCheck() async {
        guard sessionRequested, !isRecovering, currentFilter != nil else { return }
        guard let output = streamOutput, stream != nil else {
            await restartStream()
            return
        }

        let bufferCount = output.getAndResetBufferCount()

        if bufferCount == 0 {
            consecutiveEmptyChecks += 1
            Logger.audio.warning("[SystemAudio] Health check: No buffers received (consecutive: \(self.consecutiveEmptyChecks, privacy: .public)/\(self.maxEmptyChecks, privacy: .public))")

            if consecutiveEmptyChecks >= maxEmptyChecks {
                Logger.audio.notice("[SystemAudio] Callback absence; bounded fallback transport rebuild (activity unknown)")
                await restartStream()
            }
        } else {
            if consecutiveEmptyChecks > 0 {
                Logger.audio.info("[SystemAudio] Health check: Buffers resumed (\(bufferCount, privacy: .public) received)")
            }
            consecutiveEmptyChecks = 0
        }
    }

    /// A recorded interruption that hasn't been resolved by a delivering stream.
    public var hasUnresolvedInterruption: Bool { sessionRequested && unresolvedInterruption != nil }

    /// The interruption outlasted its rebuild budget. The recovery manager decides
    /// when to rebuild again; quiet periods with no recorded interruption never rebuild.
    public var needsRearm: Bool {
        sessionRequested && currentFilter != nil && !isRecovering && !resetRecoveryScheduled &&
            recoveryAttempts >= 3 && unresolvedInterruption != nil
    }

    /// Rebuilds the transport once more for an unresolved interruption.
    public func rearm() {
        guard needsRearm else { return }
        let revision = interruptionRevision
        Logger.audio.notice("[SystemAudio] Interruption still unresolved; rebuilding transport")
        Task { @MainActor [weak self] in
            guard let self, self.interruptionRevision == revision, self.unresolvedInterruption != nil,
                  self.recoveryAttempts >= 3 else { return }
            self.recoveryAttempts = 0
            await self.restartStream()
            // Only a rearm may renew a spent budget; health ticks stay quiet.
            if self.unresolvedInterruption != nil { self.recoveryAttempts = max(self.recoveryAttempts, 3) }
        }
    }

    /// Restart the stream (used by health check)
    private func restartStream() async {
        guard sessionRequested, currentFilter != nil, !isRecovering, recoveryAttempts < 3 else { return }
        isRecovering = true
        defer { isRecovering = false; scheduleResetRecovery() }
        let gen = streamGeneration
        retireCurrentTransport()
        while sessionRequested, streamGeneration == gen, recoveryAttempts < 3 {
            recoveryAttempts += 1
            do {
                try await cleanupRetiredTransport()
                try await restartBackoff()
                guard sessionRequested, streamGeneration == gen else {
                    appendRestartSuppressedTraceForTesting(); return
                }
                guard let filter = currentFilter else { return }
                if try await startStream(filter: filter, gen: gen, traceProceed: true) { return }
            } catch {
                guard sessionRequested, streamGeneration == gen else { appendRestartSuppressedTraceForTesting(); return }
                recordInterruption(error)
                Logger.audio.error("[SystemAudio] Recovery failed: \(error, privacy: .public)")
                if isPermissionError(error) { endSessionAdmission(); return }
                if isUserStoppedStreamError(error) { endSessionAdmission(); onTerminalStop?(); return }
                // Unknown cleanup failure keeps ownership and waits for another
                // bounded retry trigger; do not start over a still-owned stream.
                if !retiringStreams.isEmpty { return }
            }
        }
    }

    private func restartBackoff() async throws {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let hook = _restartParkHookForTesting {
            await hook()
            return
        }
#endif
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
    }

    private func appendRestartSuppressedTraceForTesting() {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        _restartDecisionTraceForTesting.append("restart suppressed - stream generation changed")
#endif
    }

    private func appendRestartProceedTraceForTesting() {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        _restartDecisionTraceForTesting.append("restart proceeding")
#endif
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _restartStreamForTesting() async {
        await restartStream()
    }

    internal func _handleStreamErrorForTesting(_ error: Error, from origin: UUID? = nil) async {
        guard let streamID = origin ?? activeStreamID else { return }
        await handleStreamError(error, streamID: streamID)
    }
    internal var _activeStreamIDForTesting: UUID? { activeStreamID }
    internal var _streamOutputForTesting: SystemAudioStreamOutput? { streamOutput }
    internal func _performHealthCheckForTesting() async { await performHealthCheck() }
#endif
}
