// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
    /// Current audio callback - can be changed while stream is running
    public var onAudioBuffer: ((CMSampleBuffer) -> Void)? {
        get { desiredAudioCallback }
        set {
            desiredAudioCallback = newValue
            streamOutput?.onAudioBuffer = newValue
        }
    }
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
    private let operationTimeoutSeconds: Double
    private let verbose: Bool
    private let streamFactory: CaptureStreamFactory
#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal private(set) var _restartDecisionTraceForTesting: [String] = []
    internal var _restartParkHookForTesting: (@MainActor () async -> Void)?
    internal var _stopParkHookForTesting: (@MainActor () async -> Void)?
    internal var _streamGenerationForTesting: Int { streamGeneration }
#endif

    /// Health check timer - monitors for missing audio buffers
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 30.0  // Check every 30 seconds
    private var consecutiveEmptyChecks: Int = 0
    private let maxEmptyChecks: Int = 2  // Restart after 2 consecutive empty checks (60s of no audio)

    public convenience init(verbose: Bool = false) {
        self.init(verbose: verbose, streamFactory: defaultCaptureStreamFactory)
    }

    internal init(verbose: Bool = false, streamFactory: @escaping CaptureStreamFactory, operationTimeoutSeconds: Double = 5) {
        self.verbose = verbose
        self.streamFactory = streamFactory
        self.operationTimeoutSeconds = operationTimeoutSeconds
    }

    /// Start the system audio capture stream
    /// - Parameter filter: The content filter to use
    /// - Throws: If stream fails to start
    public func start(filter: SCContentFilter) async throws {
        streamGeneration += 1
        let gen = streamGeneration
        currentFilter = filter
        recoveryAttempts = 0

        // Already running - just update filter if needed
        if stream != nil {
            Logger.audio.info("[SystemAudio] Stream already running, updating filter only")
            try await updateContentFilter(filter)
            return
        }

        if try await startStream(filter: filter, gen: gen, traceProceed: false) {
            startHealthCheck()
        }
    }

    /// Internal stream start - used for initial start and restarts
    private func startStream(filter: SCContentFilter, gen: Int, traceProceed: Bool) async throws -> Bool {
        Logger.audio.info("[SystemAudio] Starting persistent SCStream...")

        // Create stream output
        let output = SystemAudioStreamOutput(verbose: verbose)

        // Create delegate to handle stream errors
        let streamID = UUID()
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
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start capture
        if verbose { Logger.audio.debug("[SystemAudio] Calling startCapture()...") }
        activeStreamID = streamID
        do {
            try await withTimeout(seconds: operationTimeoutSeconds) {
                try await newStream.startCapture()
                if Task.isCancelled {
                    try? await newStream.stopCapture()
                    throw CancellationError()
                }
            }
        } catch {
            if activeStreamID == streamID { activeStreamID = nil }
            throw error
        }
        guard streamGeneration == gen, activeStreamID == streamID else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            try? await withTimeout(seconds: operationTimeoutSeconds) { try await newStream.stopCapture() }
            return false
        }
        if let desiredFilter = currentFilter, desiredFilter !== filter {
            try await newStream.updateContentFilter(desiredFilter)
            guard streamGeneration == gen, activeStreamID == streamID else {
                try? await withTimeout(seconds: operationTimeoutSeconds) { try await newStream.stopCapture() }
                return false
            }
        }
        self.streamOutput = output
        output.onAudioBuffer = desiredAudioCallback
        self.streamDelegate = delegate
        self.stream = newStream

        // Reset health check state
        consecutiveEmptyChecks = 0
        recoveryAttempts = 0

        Logger.audio.info("[SystemAudio] Started persistent system audio capture successfully")
        return true
    }

    /// Stop the system audio capture stream
    public func stop() async {
        streamGeneration += 1
        stopHealthCheck()
        let stoppingStream = stream
        streamOutput?.onAudioBuffer = nil
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        activeStreamID = nil
        currentFilter = nil
        onAudioBuffer = nil
        onCaptureError = nil

        guard let stream = stoppingStream else {
            if verbose { Logger.audio.debug("[SystemAudio] stop() called but stream not running") }
            return
        }

        Logger.audio.info("[SystemAudio] Stopping persistent SCStream...")

#if DEBUG || SOLSTONE_TEST_SUPPORT
        let stopParkHook = _stopParkHookForTesting
#endif
        do {
            try await withTimeout(seconds: 5) {
#if DEBUG || SOLSTONE_TEST_SUPPORT
                if let hook = stopParkHook {
                    await hook()
                    try Task.checkCancellation()
                }
#endif
                try await stream.stopCapture()
            }
            if verbose { Logger.audio.debug("[SystemAudio] stopCapture() completed successfully") }
        } catch let error as NSError
            where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3808
        {
            // Stream already stopped - ignore
            if verbose { Logger.audio.debug("[SystemAudio] Stream was already stopped (code -3808)") }
        } catch is TimeoutError {
            Logger.audio.warning("[SystemAudio] Timeout stopping stream; dropping local stream references")
        } catch {
            Logger.audio.warning("[SystemAudio] Error stopping stream: \(error, privacy: .public)")
        }

        Logger.audio.info("[SystemAudio] Stopped system audio capture")
    }

    /// Update the content filter (for window exclusion changes)
    /// - Parameter filter: The new content filter
    public func updateContentFilter(_ filter: SCContentFilter) async throws {
        // Remember intent even while recovery has no transport. An old awaited
        // update must never overwrite the filter selected by a later caller.
        currentFilter = filter
        guard let stream = stream else {
            if verbose { Logger.audio.debug("[SystemAudio] updateContentFilter called but stream not running") }
            return
        }
        if verbose { Logger.audio.debug("[SystemAudio] Updating content filter for window exclusions") }
        try await stream.updateContentFilter(filter)
    }

    /// Clear the audio callback (called during segment rotation)
    public func clearCallback() {
        let hadCallback = onAudioBuffer != nil
        onAudioBuffer = nil
        onCaptureError = nil
        Logger.audio.info("[SystemAudio] Cleared callback (had callback: \(hadCallback, privacy: .public), stream running: \(self.isRunning, privacy: .public))")
    }

    /// Wire up a new callback (called when new segment starts)
    public func setCallback(onError: ((Error) -> Void)? = nil, _ callback: @escaping (CMSampleBuffer) -> Void) {
        onAudioBuffer = callback
        onCaptureError = onError
        Logger.audio.info("[SystemAudio] Wired callback to new segment (stream running: \(self.isRunning, privacy: .public))")
    }

    /// Check if capture is running
    public var isRunning: Bool {
        stream != nil
    }

    // MARK: - Error Handling

    /// Handle stream errors reported by the delegate
    private func handleStreamError(_ error: Error, streamID: UUID) async {
        guard activeStreamID == streamID else { return }
        Logger.audio.error("[SystemAudio] Stream error: \(error, privacy: .public)")
        onCaptureError?(error)

        // Clean up the failed stream
        streamOutput?.onAudioBuffer = nil
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        activeStreamID = nil

        // Don't restart on permission errors — they require user action
        if isPermissionError(error) {
            Logger.audio.info("[SystemAudio] Permission error, not restarting (requires user action in System Settings)")
            stopHealthCheck()
            return
        } else if isUserStoppedStreamError(error) {
            Logger.audio.info("[SystemAudio] Stream stopped by user (Stop Sharing)")
            stopHealthCheck()
            onTerminalStop?()
            return
        }

        await restartStream()
    }

    // MARK: - Health Check

    /// Start the health check timer
    private func startHealthCheck() {
        stopHealthCheck()

        let timer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
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
        guard !isRecovering, currentFilter != nil else { return }
        guard let output = streamOutput, stream != nil else {
            await restartStream()
            return
        }

        let bufferCount = output.getAndResetBufferCount()

        if bufferCount == 0 {
            consecutiveEmptyChecks += 1
            Logger.audio.warning("[SystemAudio] Health check: No buffers received (consecutive: \(self.consecutiveEmptyChecks, privacy: .public)/\(self.maxEmptyChecks, privacy: .public))")

            if consecutiveEmptyChecks >= maxEmptyChecks {
                Logger.audio.error("[SystemAudio] Health check failed - no audio for \(Int(self.healthCheckInterval) * self.maxEmptyChecks, privacy: .public)s, restarting stream")
                onCaptureError?(NSError(domain: "SolstoneAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "System audio stopped delivering buffers"]))
                await restartStream()
            }
        } else {
            if consecutiveEmptyChecks > 0 {
                Logger.audio.info("[SystemAudio] Health check: Buffers resumed (\(bufferCount, privacy: .public) received)")
            }
            consecutiveEmptyChecks = 0
        }
    }

    /// Restart the stream (used by health check)
    private func restartStream() async {
        guard currentFilter != nil, !isRecovering, recoveryAttempts < 3 else { return }
        isRecovering = true
        defer { isRecovering = false }
        recoveryAttempts += 1
        let gen = streamGeneration

        Logger.audio.info("[SystemAudio] Restarting stream due to health check failure...")

        // Stop current stream
        let stoppingStream = stream
        streamOutput?.onAudioBuffer = nil
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        activeStreamID = nil
        if let stream = stoppingStream {
            do {
                try await withTimeout(seconds: operationTimeoutSeconds) { try await stream.stopCapture() }
            } catch {
                if streamGeneration == gen { onCaptureError?(error) }
                Logger.audio.error("[SystemAudio] Error stopping stream for restart: \(error, privacy: .public)")
            }
        }
        guard streamGeneration == gen else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            return
        }
        // Small delay before restart
        try? await restartBackoff()
        guard streamGeneration == gen else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            return
        }

        // Start fresh stream
        do {
            guard let filter = currentFilter else {
                Logger.audio.error("[SystemAudio] Cannot restart - no filter available")
                return
            }
            guard try await startStream(filter: filter, gen: gen, traceProceed: true) else { return }
            guard streamGeneration == gen else {
                Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
                appendRestartSuppressedTraceForTesting()
                return
            }

            Logger.audio.notice("[SystemAudio] Stream restarted successfully")
        } catch {
            guard streamGeneration == gen else { return }
            onCaptureError?(error)
            Logger.audio.error("[SystemAudio] Failed to restart stream: \(error, privacy: .public)")
            if isPermissionError(error) {
                Logger.audio.info("[SystemAudio] Permission error, stopping health check")
                stopHealthCheck()
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
