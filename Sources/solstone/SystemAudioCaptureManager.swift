// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Manages persistent system audio capture via SCStream across segment rotations
/// The stream stays running - only the audio callback destination changes
/// This prevents ScreenCaptureKit conflicts during segment rotation
@MainActor
public final class SystemAudioCaptureManager {
    /// Current audio callback - can be changed while stream is running
    public var onAudioBuffer: ((CMSampleBuffer) -> Void)? {
        get { streamOutput?.onAudioBuffer }
        set { streamOutput?.onAudioBuffer = newValue }
    }

    private var stream: (any CaptureStreamControlling)?
    private var streamOutput: SystemAudioStreamOutput?
    private var streamDelegate: StreamDelegate?
    private var currentFilter: SCContentFilter?
    private var streamGeneration: Int = 0
    private let verbose: Bool
    private let streamFactory: CaptureStreamFactory
#if DEBUG
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

    internal init(verbose: Bool = false, streamFactory: @escaping CaptureStreamFactory) {
        self.verbose = verbose
        self.streamFactory = streamFactory
    }

    /// Start the system audio capture stream
    /// - Parameter filter: The content filter to use
    /// - Throws: If stream fails to start
    public func start(filter: SCContentFilter) async throws {
        streamGeneration += 1
        let gen = streamGeneration

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
        let delegate = StreamDelegate { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamError(error)
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
        try await newStream.startCapture()
        guard streamGeneration == gen else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            try? await newStream.stopCapture()
            return false
        }
        currentFilter = filter
        self.streamOutput = output
        self.streamDelegate = delegate
        self.stream = newStream

        // Reset health check state
        consecutiveEmptyChecks = 0

        Logger.audio.info("[SystemAudio] Started persistent system audio capture successfully")
        return true
    }

    /// Stop the system audio capture stream
    public func stop() async {
        streamGeneration += 1
        stopHealthCheck()

        guard let stream = stream else {
            if verbose { Logger.audio.debug("[SystemAudio] stop() called but stream not running") }
            return
        }

        Logger.audio.info("[SystemAudio] Stopping persistent SCStream...")

#if DEBUG
        let stopParkHook = _stopParkHookForTesting
#endif
        do {
            try await withTimeout(seconds: 5) {
#if DEBUG
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

        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        self.currentFilter = nil

        Logger.audio.info("[SystemAudio] Stopped system audio capture")
    }

    /// Update the content filter (for window exclusion changes)
    /// - Parameter filter: The new content filter
    public func updateContentFilter(_ filter: SCContentFilter) async throws {
        guard let stream = stream else {
            if verbose { Logger.audio.debug("[SystemAudio] updateContentFilter called but stream not running") }
            return
        }
        if verbose { Logger.audio.debug("[SystemAudio] Updating content filter for window exclusions") }
        try await stream.updateContentFilter(filter)
        currentFilter = filter
    }

    /// Clear the audio callback (called during segment rotation)
    public func clearCallback() {
        let hadCallback = streamOutput?.onAudioBuffer != nil
        streamOutput?.onAudioBuffer = nil
        Logger.audio.info("[SystemAudio] Cleared callback (had callback: \(hadCallback, privacy: .public), stream running: \(self.isRunning, privacy: .public))")
    }

    /// Wire up a new callback (called when new segment starts)
    public func setCallback(_ callback: @escaping (CMSampleBuffer) -> Void) {
        streamOutput?.onAudioBuffer = callback
        Logger.audio.info("[SystemAudio] Wired callback to new segment (stream running: \(self.isRunning, privacy: .public))")
    }

    /// Check if capture is running
    public var isRunning: Bool {
        stream != nil
    }

    // MARK: - Error Handling

    /// Handle stream errors reported by the delegate
    private func handleStreamError(_ error: Error) async {
        Logger.audio.error("[SystemAudio] Stream error: \(error, privacy: .public)")

        // Clean up the failed stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        // Don't restart on permission errors — they require user action
        if isPermissionError(error) {
            Logger.audio.info("[SystemAudio] Permission error, not restarting (requires user action in System Settings)")
            stopHealthCheck()
            return
        }

        // Attempt to restart if we have a filter
        guard currentFilter != nil else {
            Logger.audio.error("[SystemAudio] Cannot restart - no filter available")
            return
        }
        let gen = streamGeneration

        Logger.audio.info("[SystemAudio] Attempting to restart stream after error...")

        do {
            // Small delay before restart to avoid rapid retry loops
            try await restartBackoff()
            guard streamGeneration == gen else {
                Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
                appendRestartSuppressedTraceForTesting()
                return
            }
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
            Logger.audio.info("[SystemAudio] Stream restarted successfully after error")
        } catch {
            if isPermissionError(error) {
                Logger.audio.info("[SystemAudio] Permission error on restart, stopping health check")
                stopHealthCheck()
            }
            Logger.audio.error("[SystemAudio] Failed to restart stream: \(error, privacy: .public)")
        }
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
        guard let output = streamOutput, stream != nil else {
            return
        }

        let bufferCount = output.getAndResetBufferCount()

        if bufferCount == 0 {
            consecutiveEmptyChecks += 1
            Logger.audio.warning("[SystemAudio] Health check: No buffers received (consecutive: \(self.consecutiveEmptyChecks, privacy: .public)/\(self.maxEmptyChecks, privacy: .public))")

            if consecutiveEmptyChecks >= maxEmptyChecks {
                Logger.audio.error("[SystemAudio] Health check failed - no audio for \(Int(self.healthCheckInterval) * self.maxEmptyChecks, privacy: .public)s, restarting stream")
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
        guard currentFilter != nil else {
            Logger.audio.error("[SystemAudio] Cannot restart - no filter available")
            return
        }
        let gen = streamGeneration

        // Save current callback
        let savedCallback = streamOutput?.onAudioBuffer

        Logger.audio.info("[SystemAudio] Restarting stream due to health check failure...")

        // Stop current stream
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                if verbose { Logger.audio.debug("[SystemAudio] Error stopping stream for restart: \(error, privacy: .public)") }
            }
        }
        guard streamGeneration == gen else {
            Logger.audio.info("[SystemAudio] restart suppressed - stream generation changed")
            appendRestartSuppressedTraceForTesting()
            return
        }
        stream = nil
        streamOutput = nil
        streamDelegate = nil

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

            // Restore callback if we had one
            if let callback = savedCallback {
                streamOutput?.onAudioBuffer = callback
                Logger.audio.info("[SystemAudio] Restored callback after restart")
            }

            Logger.audio.info("[SystemAudio] Stream restarted successfully")
        } catch {
            Logger.audio.error("[SystemAudio] Failed to restart stream: \(error, privacy: .public)")
            if isPermissionError(error) {
                Logger.audio.info("[SystemAudio] Permission error, stopping health check")
                stopHealthCheck()
            }
        }
    }

    private func restartBackoff() async throws {
#if DEBUG
        if let hook = _restartParkHookForTesting {
            await hook()
            return
        }
#endif
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
    }

    private func appendRestartSuppressedTraceForTesting() {
#if DEBUG
        _restartDecisionTraceForTesting.append("restart suppressed - stream generation changed")
#endif
    }

    private func appendRestartProceedTraceForTesting() {
#if DEBUG
        _restartDecisionTraceForTesting.append("restart proceeding")
#endif
    }

#if DEBUG
    internal func _restartStreamForTesting() async {
        await restartStream()
    }

    internal func _handleStreamErrorForTesting(_ error: Error) async {
        await handleStreamError(error)
    }
#endif
}
