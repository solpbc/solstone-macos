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
    private var currentFilter: SCContentFilter?
    private let verbose: Bool

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

        Log.info("[SystemAudio] Starting persistent SCStream...")
        currentFilter = filter

        // Create stream output
        let output = SystemAudioStreamOutput(verbose: verbose)
        self.streamOutput = output

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

        // Create and configure stream
        Log.debug("[SystemAudio] Creating SCStream with config: 48kHz, 1ch, audio=true, mic=false", verbose: verbose)
        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start capture
        Log.debug("[SystemAudio] Calling startCapture()...", verbose: verbose)
        try await newStream.startCapture()
        self.stream = newStream

        Log.info("[SystemAudio] Started persistent system audio capture successfully")
    }

    /// Stop the system audio capture stream
    public func stop() async {
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
}
