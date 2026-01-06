// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import SolstoneCaptureCore

/// Manages persistent microphone captures across segment rotations
/// Engines stay running - only the audio callback destination changes
/// This prevents audio playback interference during segment rotation
public final class MicrophoneCaptureManager: @unchecked Sendable {
    /// Active captures keyed by device UID
    private var captures: [String: ExternalMicCapture] = [:]
    private let lock = NSLock()
    private let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Start capture for a device (reuses existing if already running)
    /// Retries up to 3 times with increasing delays if device isn't ready
    /// - Parameter device: The audio input device to capture from
    /// - Throws: If capture fails to start after all retries
    public func startCapture(for device: AudioInputDevice) throws {
        lock.lock()

        // Already running - nothing to do
        if captures[device.uid] != nil {
            lock.unlock()
            Log.debug("Capture already running for \(device.name)", verbose: verbose)
            return
        }
        lock.unlock()

        // Retry with increasing delays if device isn't ready yet
        // Create a fresh capture for each attempt (AVAudioEngine can't recover from failed state)
        let retryDelays: [TimeInterval] = [0, 0.2, 0.5, 1.0]
        var lastError: Error?

        for (attempt, delay) in retryDelays.enumerated() {
            if delay > 0 {
                Log.info("Retrying \(device.name) after \(Int(delay * 1000))ms (attempt \(attempt + 1))")
                Thread.sleep(forTimeInterval: delay)
            }

            // Create fresh capture for each attempt
            let capture = ExternalMicCapture(device: device, verbose: verbose)

            do {
                try capture.start()

                // Success - store in dict
                lock.lock()
                captures[device.uid] = capture
                lock.unlock()

                Log.info("Started persistent capture for \(device.name)")
                return
            } catch {
                lastError = error
                Log.debug("Attempt \(attempt + 1) failed for \(device.name): \(error)", verbose: verbose)
                // Let capture go out of scope - AVAudioEngine will be deallocated
            }
        }

        throw lastError ?? ExternalMicCapture.ExternalMicCaptureError.failedToCreateFormat
    }

    /// Stop capture for a specific device (called when device disconnects)
    /// - Parameter deviceUID: The UID of the device to stop
    public func stopCapture(deviceUID: String) {
        lock.lock()
        guard let capture = captures.removeValue(forKey: deviceUID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Stop outside lock
        capture.stop()
        Log.info("Stopped capture for \(capture.device.name)")
    }

    /// Set the audio callback for a specific capture
    /// - Parameters:
    ///   - deviceUID: The UID of the device
    ///   - callback: The callback to receive audio buffers, or nil to pause
    public func setCallback(
        for deviceUID: String,
        callback: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)?
    ) {
        lock.lock()
        let capture = captures[deviceUID]
        lock.unlock()

        if capture == nil {
            Log.warn("setCallback: No capture found for deviceUID \(deviceUID)")
        }
        capture?.onAudioBuffer = callback
    }

    /// Clear all callbacks (called during segment rotation before writers change)
    public func clearAllCallbacks() {
        lock.lock()
        let allCaptures = Array(captures.values)
        lock.unlock()

        for capture in allCaptures {
            capture.onAudioBuffer = nil
        }
        Log.debug("Cleared all mic callbacks", verbose: verbose)
    }

    /// Get the capture for a device (if running)
    /// - Parameter deviceUID: The UID of the device
    /// - Returns: The capture, or nil if not running
    public func getCapture(for deviceUID: String) -> ExternalMicCapture? {
        lock.lock()
        defer { lock.unlock() }
        return captures[deviceUID]
    }

    /// Check if a capture is running for a device
    /// - Parameter deviceUID: The UID of the device
    /// - Returns: True if capture is running
    public func hasCapture(for deviceUID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return captures[deviceUID] != nil
    }

    /// Get all active device UIDs
    /// - Returns: Array of device UIDs with active captures
    public func activeDeviceUIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(captures.keys)
    }

    /// Stop all captures (called when recording stops entirely)
    public func stopAll() {
        lock.lock()
        let allCaptures = Array(captures.values)
        captures.removeAll()
        lock.unlock()

        for capture in allCaptures {
            capture.stop()
        }
        Log.info("Stopped all mic captures")
    }
}
