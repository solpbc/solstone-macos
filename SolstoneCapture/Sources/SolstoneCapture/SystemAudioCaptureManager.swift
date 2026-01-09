// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCaptureCore

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

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var streamDelegate: StreamDelegate?
    private var currentFilter: SCContentFilter?
    private let verbose: Bool

    /// Health check timer - monitors for missing audio buffers
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 30.0  // Check every 30 seconds
    private var consecutiveEmptyChecks: Int = 0
    private let maxEmptyChecks: Int = 2  // Restart after 2 consecutive empty checks (60s of no audio)

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Start the system audio capture stream
    /// - Parameter filter: The content filter to use
    /// - Throws: If stream fails to start
    public func start(filter: SCContentFilter) async throws {
        // Already running - just update filter if needed
        if stream != nil {
            Log.info("[SystemAudio] Stream already running, updating filter only")
            try await updateContentFilter(filter)
            return
        }

        try await startStream(filter: filter)
        startHealthCheck()
    }

    /// Internal stream start - used for initial start and restarts
    private func startStream(filter: SCContentFilter) async throws {
        Log.info("[SystemAudio] Starting persistent SCStream...")
        currentFilter = filter

        // Create stream output
        let output = SystemAudioStreamOutput(verbose: verbose)
        self.streamOutput = output

        // Create delegate to handle stream errors
        let delegate = StreamDelegate { [weak self] error in
            Task { @MainActor in
                await self?.handleStreamError(error)
            }
        }
        self.streamDelegate = delegate

        // Configure audio stream for system audio only (minimize video overhead)
        let config = SCStreamConfiguration()
        config.sampleRate = 48_000
        config.channelCount = 1
        config.capturesAudio = true
        config.captureMicrophone = false  // All mics via ExternalMicCapture
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps max
        config.width = 2  // Minimum valid dimensions
        config.height = 2
        config.queueDepth = 1  // Minimize buffered frames

        // Create and configure stream with delegate for error handling
        Log.debug("[SystemAudio] Creating SCStream with config: 48kHz, 1ch, audio=true, mic=false", verbose: verbose)
        let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start capture
        Log.debug("[SystemAudio] Calling startCapture()...", verbose: verbose)
        try await newStream.startCapture()
        self.stream = newStream

        // Reset health check state
        consecutiveEmptyChecks = 0

        Log.info("[SystemAudio] Started persistent system audio capture successfully")
    }

    /// Stop the system audio capture stream
    public func stop() async {
        stopHealthCheck()

        guard let stream = stream else {
            Log.debug("[SystemAudio] stop() called but stream not running", verbose: verbose)
            return
        }

        Log.info("[SystemAudio] Stopping persistent SCStream...")

        do {
            try await stream.stopCapture()
            Log.debug("[SystemAudio] stopCapture() completed successfully", verbose: verbose)
        } catch let error as NSError
            where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3808
        {
            // Stream already stopped - ignore
            Log.debug("[SystemAudio] Stream was already stopped (code -3808)", verbose: verbose)
        } catch {
            Log.warn("[SystemAudio] Error stopping stream: \(error)")
        }

        self.stream = nil
        self.streamOutput = nil
        self.streamDelegate = nil
        self.currentFilter = nil

        Log.info("[SystemAudio] Stopped system audio capture")
    }

    /// Update the content filter (for window exclusion changes)
    /// - Parameter filter: The new content filter
    public func updateContentFilter(_ filter: SCContentFilter) async throws {
        guard let stream = stream else {
            Log.debug("[SystemAudio] updateContentFilter called but stream not running", verbose: verbose)
            return
        }
        Log.debug("[SystemAudio] Updating content filter for window exclusions", verbose: verbose)
        try await stream.updateContentFilter(filter)
        currentFilter = filter
    }

    /// Clear the audio callback (called during segment rotation)
    public func clearCallback() {
        let hadCallback = streamOutput?.onAudioBuffer != nil
        streamOutput?.onAudioBuffer = nil
        Log.info("[SystemAudio] Cleared callback (had callback: \(hadCallback), stream running: \(isRunning))")
    }

    /// Wire up a new callback (called when new segment starts)
    public func setCallback(_ callback: @escaping (CMSampleBuffer) -> Void) {
        streamOutput?.onAudioBuffer = callback
        Log.info("[SystemAudio] Wired callback to new segment (stream running: \(isRunning))")
    }

    /// Check if capture is running
    public var isRunning: Bool {
        stream != nil
    }

    // MARK: - Error Handling

    /// Handle stream errors reported by the delegate
    private func handleStreamError(_ error: Error) async {
        Log.error("[SystemAudio] Stream error: \(error)")

        // Clean up the failed stream
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        // Attempt to restart if we have a filter
        guard let filter = currentFilter else {
            Log.error("[SystemAudio] Cannot restart - no filter available")
            return
        }

        Log.info("[SystemAudio] Attempting to restart stream after error...")

        do {
            // Small delay before restart to avoid rapid retry loops
            try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            try await startStream(filter: filter)
            Log.info("[SystemAudio] Stream restarted successfully after error")
        } catch {
            Log.error("[SystemAudio] Failed to restart stream: \(error)")
        }
    }

    // MARK: - Health Check

    /// Start the health check timer
    private func startHealthCheck() {
        stopHealthCheck()

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performHealthCheck()
            }
        }
        Log.debug("[SystemAudio] Started health check timer (interval: \(Int(healthCheckInterval))s)", verbose: verbose)
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
            Log.warn("[SystemAudio] Health check: No buffers received (consecutive: \(consecutiveEmptyChecks)/\(maxEmptyChecks))")

            if consecutiveEmptyChecks >= maxEmptyChecks {
                Log.error("[SystemAudio] Health check failed - no audio for \(Int(healthCheckInterval) * maxEmptyChecks)s, restarting stream")
                await restartStream()
            }
        } else {
            if consecutiveEmptyChecks > 0 {
                Log.info("[SystemAudio] Health check: Buffers resumed (\(bufferCount) received)")
            }
            consecutiveEmptyChecks = 0
        }
    }

    /// Restart the stream (used by health check)
    private func restartStream() async {
        guard let filter = currentFilter else {
            Log.error("[SystemAudio] Cannot restart - no filter available")
            return
        }

        // Save current callback
        let savedCallback = streamOutput?.onAudioBuffer

        Log.info("[SystemAudio] Restarting stream due to health check failure...")

        // Stop current stream
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                Log.debug("[SystemAudio] Error stopping stream for restart: \(error)", verbose: verbose)
            }
        }
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        // Small delay before restart
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Start fresh stream
        do {
            try await startStream(filter: filter)

            // Restore callback if we had one
            if let callback = savedCallback {
                streamOutput?.onAudioBuffer = callback
                Log.info("[SystemAudio] Restored callback after restart")
            }

            Log.info("[SystemAudio] Stream restarted successfully")
        } catch {
            Log.error("[SystemAudio] Failed to restart stream: \(error)")
        }
    }
}

// MARK: - Stream Delegate

/// Delegate to handle SCStream errors
private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
