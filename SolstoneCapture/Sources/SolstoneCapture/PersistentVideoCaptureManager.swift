// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCaptureCore

/// Manages persistent video capture streams via SCStream across segment rotations
/// Creates one stream per display - streams stay running, only callbacks change
/// This prevents ScreenCaptureKit overhead from creating/destroying streams per frame
@MainActor
public final class PersistentVideoCaptureManager {
    /// Per-display stream state
    private struct DisplayStream {
        let stream: SCStream
        let output: VideoStreamOutput
        let filter: SCContentFilter
    }

    private var displayStreams: [CGDirectDisplayID: DisplayStream] = [:]
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Start video capture streams for the given displays
    /// - Parameters:
    ///   - displays: The displays to capture
    ///   - excludedWindows: Windows to exclude from capture
    /// - Throws: If any stream fails to start
    public func start(displays: [SCDisplay], excludedWindows: [SCWindow] = []) async throws {
        // Already running - just update filters if needed
        if !displayStreams.isEmpty {
            Log.info("[VideoCapture] Streams already running, updating filters only")
            try await updateExcludedWindows(excludedWindows, displays: displays)
            return
        }

        Log.info("[VideoCapture] Starting \(displays.count) persistent video stream(s)...")

        for display in displays {
            try await startStreamForDisplay(display, excludedWindows: excludedWindows)
        }

        Log.info("[VideoCapture] Started all video streams successfully")
    }

    /// Start a stream for a single display
    private func startStreamForDisplay(_ display: SCDisplay, excludedWindows: [SCWindow]) async throws {
        let displayID = display.displayID

        // Create content filter for this display
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        // Create stream output
        let output = VideoStreamOutput(verbose: verbose)

        // Configure video stream
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.scalesToFit = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS
        config.queueDepth = 1  // Minimize buffering
        config.capturesAudio = false  // Video only - audio handled separately

        Log.debug("[VideoCapture] Creating stream for display \(displayID): \(display.width)x\(display.height)", verbose: verbose)

        // Create and configure stream
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))

        // Start capture
        Log.debug("[VideoCapture] Starting capture for display \(displayID)...", verbose: verbose)
        try await stream.startCapture()

        displayStreams[displayID] = DisplayStream(stream: stream, output: output, filter: filter)
        Log.info("[VideoCapture] Started stream for display \(displayID)")
    }

    /// Stop all video capture streams
    public func stop() async {
        guard !displayStreams.isEmpty else {
            Log.debug("[VideoCapture] stop() called but no streams running", verbose: verbose)
            return
        }

        Log.info("[VideoCapture] Stopping \(displayStreams.count) video stream(s)...")

        for (displayID, displayStream) in displayStreams {
            do {
                try await displayStream.stream.stopCapture()
                Log.debug("[VideoCapture] Stopped stream for display \(displayID)", verbose: verbose)
            } catch let error as NSError
                where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3808
            {
                // Stream already stopped - ignore
                Log.debug("[VideoCapture] Stream for display \(displayID) was already stopped", verbose: verbose)
            } catch {
                Log.warn("[VideoCapture] Error stopping stream for display \(displayID): \(error)")
            }
        }

        displayStreams.removeAll()
        Log.info("[VideoCapture] Stopped all video streams")
    }

    /// Set the callback for a specific display
    /// - Parameters:
    ///   - displayID: The display ID
    ///   - callback: The callback to receive video frames
    public func setCallback(for displayID: CGDirectDisplayID, callback: @escaping (CMSampleBuffer) -> Void) {
        guard let displayStream = displayStreams[displayID] else {
            Log.warn("[VideoCapture] setCallback called for unknown display \(displayID)")
            return
        }
        displayStream.output.onVideoFrame = callback
        Log.debug("[VideoCapture] Wired callback for display \(displayID)", verbose: verbose)
    }

    /// Clear all callbacks (called during segment rotation)
    public func clearCallbacks() {
        for (displayID, displayStream) in displayStreams {
            displayStream.output.onVideoFrame = nil
            Log.debug("[VideoCapture] Cleared callback for display \(displayID)", verbose: verbose)
        }
        Log.info("[VideoCapture] Cleared all callbacks (streams still running: \(isRunning))")
    }

    /// Update excluded windows for all streams
    /// - Parameters:
    ///   - excludedWindows: Windows to exclude from capture
    ///   - displays: Current displays (needed to create new filters)
    public func updateExcludedWindows(_ excludedWindows: [SCWindow], displays: [SCDisplay]) async throws {
        for display in displays {
            let displayID = display.displayID
            guard let displayStream = displayStreams[displayID] else { continue }

            let newFilter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            try await displayStream.stream.updateContentFilter(newFilter)
            Log.debug("[VideoCapture] Updated filter for display \(displayID)", verbose: verbose)
        }
    }

    /// Check if capture is running
    public var isRunning: Bool {
        !displayStreams.isEmpty
    }

    /// Get list of active display IDs
    public var activeDisplayIDs: [CGDirectDisplayID] {
        Array(displayStreams.keys)
    }
}
