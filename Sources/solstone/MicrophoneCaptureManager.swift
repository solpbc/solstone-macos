// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import os

/// Manages persistent microphone captures across segment rotations
/// Engines stay running - only the audio callback destination changes
/// This prevents audio playback interference during segment rotation
public final class MicrophoneCaptureManager: @unchecked Sendable {
    /// Active captures keyed by device UID
    private var captures: [String: ExternalMicCapture] = [:]
    private let lock = NSLock()
    private let verbose: Bool
    private var gain: Float
    private var selectedDevices: [AudioInputDevice]?
    private var selectionRevisions: [String: UInt64] = [:]
    private var selectionHasAvailableDevices = false

    public enum SelectionError: Error, Equatable { case selectionChanged }

    /// Publish current owner intent before starting or wiring any device.
    /// Only devices whose admission changes invalidate their old destinations.
    @discardableResult
    public func updateSelection(_ devices: [AudioInputDevice], hasAvailableDevices: Bool) -> [String] {
        lock.withLock {
            let before = selectedDevices.map { Set($0.map(\.uid)) }
            let after = Set(devices.map(\.uid))
            let known = Set(captures.keys).union(before ?? []).union(after).union(selectionRevisions.keys)
            for uid in known where (before?.contains(uid) ?? true) != after.contains(uid) {
                selectionRevisions[uid, default: 0] &+= 1
            }
            selectedDevices = devices
            selectionHasAvailableDevices = hasAvailableDevices
            let revoked = captures.keys.filter { !after.contains($0) }
            for uid in revoked { captures[uid]?.setCallbacks(audio: nil, error: nil) }
            return revoked
        }
    }

    public func microphonesForStartup(fallback: [AudioInputDevice]) -> [AudioInputDevice] {
        lock.withLock { selectedDevices ?? fallback }
    }
    public var hasIntentionallyEmptySelection: Bool {
        lock.withLock { selectionHasAvailableDevices && selectedDevices?.isEmpty == true }
    }
    public func allowsCapture(deviceUID: String) -> Bool {
        lock.withLock { selectionAllows(deviceUID) }
    }
    private func selectionAllows(_ uid: String) -> Bool {
        selectedDevices?.contains { $0.uid == uid } ?? true
    }
    private func deliver(deviceUID: String, revision: UInt64, _ callback: () -> Void) {
        // The production callbacks only enqueue writer/diagnostic work and never
        // reenter this manager. Delivery and revocation share this linearization.
        lock.withLock {
            guard selectionAllows(deviceUID), selectionRevisions[deviceUID, default: 0] == revision else { return }
            callback()
        }
    }
    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _installForTesting(_ capture: ExternalMicCapture) {
        lock.withLock { captures[capture.device.uid] = capture }
    }
    #endif

    public init(gain: Float = 2.0, verbose: Bool = false) {
        self.gain = gain
        self.verbose = verbose
    }

    /// Start capture for a device (reuses existing if already running)
    /// Retries up to 3 times with increasing delays if device isn't ready
    /// - Parameter device: The audio input device to capture from
    /// - Throws: If capture fails to start after all retries
    public func startCapture(for device: AudioInputDevice) throws {
        lock.lock()
        guard selectionAllows(device.uid) else { lock.unlock(); throw SelectionError.selectionChanged }
        let selectionRevision = selectionRevisions[device.uid, default: 0]

        // Already running - nothing to do
        if captures[device.uid]?.isCapturing == true {
            lock.unlock()
            if verbose { Logger.audio.debug("Capture already running for \(device.name, privacy: .public)") }
            return
        }
        let failedCapture = captures.removeValue(forKey: device.uid)
        let captureGain = gain
        lock.unlock()
        failedCapture?.stop()

        // Retry with increasing delays if device isn't ready yet
        // Create a fresh capture for each attempt (AVAudioEngine can't recover from failed state)
        let retryDelays: [TimeInterval] = [0, 0.2, 0.5, 1.0]
        var lastError: Error?

        for (attempt, delay) in retryDelays.enumerated() {
            if delay > 0 {
                Logger.audio.info("Retrying \(device.name, privacy: .public) after \(Int(delay * 1000), privacy: .public)ms (attempt \(attempt + 1, privacy: .public))")
                Thread.sleep(forTimeInterval: delay)
            }

            guard lock.withLock({ selectionAllows(device.uid) && selectionRevisions[device.uid, default: 0] == selectionRevision }) else {
                throw SelectionError.selectionChanged
            }
            // Create fresh capture for each attempt
            let capture = ExternalMicCapture(device: device, gain: captureGain, verbose: verbose)

            do {
                try capture.start()

                // Success - store in dict
                lock.lock()
                guard selectionAllows(device.uid), selectionRevisions[device.uid, default: 0] == selectionRevision else {
                    lock.unlock()
                    capture.stop()
                    throw SelectionError.selectionChanged
                }
                captures[device.uid] = capture
                lock.unlock()

                Logger.audio.info("Started persistent capture for \(device.name, privacy: .public)")
                return
            } catch {
                if error as? SelectionError == .selectionChanged { throw error }
                lastError = error
                if verbose { Logger.audio.debug("Attempt \(attempt + 1, privacy: .public) failed for \(device.name, privacy: .public): \(error, privacy: .public)") }
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
        Logger.audio.info("Stopped capture for \(capture.device.name, privacy: .public)")
    }

    /// Set the audio callback for a specific capture
    /// - Parameters:
    ///   - deviceUID: The UID of the device
    ///   - callback: The callback to receive audio buffers, or nil to pause
    public func setCallback(
        for deviceUID: String,
        callback: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)?,
        onError: ((Error) -> Void)? = nil
    ) {
        lock.withLock {
            guard let capture = captures[deviceUID] else {
                if callback != nil { Logger.audio.warning("setCallback: No capture found for deviceUID \(deviceUID, privacy: .public)") }
                return
            }
            guard selectionAllows(deviceUID) else { capture.setCallbacks(audio: nil, error: nil); return }
            let revision = selectionRevisions[deviceUID, default: 0]
            capture.setCallbacks(audio: callback.map { callback in
                { [weak self] buffer, time in
                    self?.deliver(deviceUID: deviceUID, revision: revision) { callback(buffer, time) }
                }
            }, error: onError.map { onError in
                { [weak self] error in
                    self?.deliver(deviceUID: deviceUID, revision: revision) { onError(error) }
                }
            })
        }
    }

    /// Clear all callbacks (called during segment rotation before writers change)
    public func clearAllCallbacks() {
        _ = detachCallbacks()
    }

    public func clearAllCallbacksAndDrain() async {
        let detached = detachCallbacks()
        for capture in detached { await capture.drain() }
    }

    private func detachCallbacks() -> [ExternalMicCapture] {
        lock.lock()
        let allCaptures = Array(captures.values)
        lock.unlock()

        for capture in allCaptures {
            capture.setCallbacks(audio: nil, error: nil)
        }
        if verbose { Logger.audio.debug("Cleared all mic callbacks") }
        return allCaptures
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
        return captures[deviceUID]?.isCapturing == true
    }

    /// Get all active device UIDs
    /// - Returns: Array of device UIDs with active captures
    public func activeDeviceUIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return captures.compactMap { $0.value.isCapturing ? $0.key : nil }
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
        Logger.audio.info("Stopped all mic captures")
    }

    /// Update gain on all active captures (takes effect immediately)
    /// Also stores for future captures
    /// - Parameter newGain: New gain multiplier (1.0 to 8.0)
    public func updateGain(_ newGain: Float) {
        lock.lock()
        self.gain = newGain
        let allCaptures = Array(captures.values)
        lock.unlock()

        for capture in allCaptures {
            capture.gainMultiplier = newGain
        }
        Logger.audio.info("Updated mic gain to \(newGain, privacy: .public)x on \(allCaptures.count, privacy: .public) capture(s)")
    }
}
