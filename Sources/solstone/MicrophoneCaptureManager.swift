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
    private var sourceBudgets: [String: WeakAudioMediaBudget] = [:]
    private let lock = NSLock()
    private let verbose: Bool
    private var gain: Float
    private var selectedDevices: [AudioInputDevice]?
    private var selectionRevisions: [String: UInt64] = [:]
    private let captureFactory: @Sendable (AudioInputDevice, Float, Bool) -> ExternalMicCapture
    private var _onRecoveryNeeded: (@Sendable (String) -> Void)?

    public enum SelectionError: Error, Equatable { case selectionChanged }

    /// Told, with the device UID, when a running microphone stopped on its own
    /// and needs a fresh start. Captures never retry themselves.
    public var onRecoveryNeeded: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onRecoveryNeeded } }
        set { lock.withLock { _onRecoveryNeeded = newValue } }
    }

    /// Publish current owner intent before starting or wiring any device.
    /// Only devices whose admission changes invalidate their old destinations.
    @discardableResult
    public func updateSelection(_ devices: [AudioInputDevice]) -> [String] {
        lock.withLock {
            let before = selectedDevices.map { Set($0.map(\.uid)) }
            let after = Set(devices.map(\.uid))
            let known = Set(captures.keys).union(before ?? []).union(after).union(selectionRevisions.keys)
            for uid in known where (before?.contains(uid) ?? true) != after.contains(uid) {
                selectionRevisions[uid, default: 0] &+= 1
            }
            selectedDevices = devices
            let revoked = captures.keys.filter { !after.contains($0) }
            for uid in revoked { captures[uid]?.setCallbacks(audio: nil, error: nil) }
            return revoked
        }
    }

    public func microphonesForStartup(fallback: [AudioInputDevice]) -> [AudioInputDevice] {
        lock.withLock { selectedDevices ?? fallback }
    }
    /// No microphone is selected right now, whether by the owner's choice or because
    /// none is connected. Neither is a capture failure; the session waits for one.
    public var hasEmptySelection: Bool {
        lock.withLock { selectedDevices?.isEmpty == true }
    }
    public var selectedDeviceUIDs: [String] { lock.withLock { selectedDevices?.map(\.uid) ?? [] } }
    public func allowsCapture(deviceUID: String) -> Bool {
        lock.withLock { selectionAllows(deviceUID) }
    }
    private func selectionAllows(_ uid: String) -> Bool {
        selectedDevices?.contains { $0.uid == uid } ?? true
    }
    internal func mediaBudget(for uid: String) -> AudioMediaBudget {
        lock.withLock { mediaBudgetLocked(for: uid) }
    }
    private func mediaBudgetLocked(for uid: String) -> AudioMediaBudget {
        sourceBudgets = sourceBudgets.filter { $0.value.value != nil }
        if let value = sourceBudgets[uid]?.value { return value }
        let value = captures[uid]?.mediaBudget ?? AudioMediaBudget()
        sourceBudgets[uid] = WeakAudioMediaBudget(value)
        return value
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
        lock.withLock {
            capture.useMediaBudget(mediaBudgetLocked(for: capture.device.uid))
            captures[capture.device.uid] = capture
        }
    }
    #endif

    public convenience init(gain: Float = 2.0, verbose: Bool = false) {
        self.init(gain: gain, verbose: verbose,
            captureFactory: { ExternalMicCapture(device: $0, gain: $1, verbose: $2) })
    }

    internal init(gain: Float = 2.0, verbose: Bool = false,
                  captureFactory: @escaping @Sendable (AudioInputDevice, Float, Bool) -> ExternalMicCapture) {
        self.gain = gain
        self.verbose = verbose
        self.captureFactory = captureFactory
    }

    /// Start capture for a device (reuses existing if already running).
    /// One attempt only: the recovery manager paces any retry, so a failing
    /// device never holds the caller.
    /// - Parameter device: The audio input device to capture from
    /// - Throws: If capture fails to start
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
        let mediaBudget = mediaBudgetLocked(for: device.uid)
        lock.unlock()
        failedCapture?.stop()

        // A fresh capture each time: AVAudioEngine can't recover from a failed state.
        let capture = captureFactory(device, captureGain, verbose)
        capture.useMediaBudget(mediaBudget)
        let uid = device.uid
        capture.onRecoveryNeeded = { [weak self] in self?.onRecoveryNeeded?(uid) }
        try capture.start()

        lock.lock()
        guard selectionAllows(device.uid), selectionRevisions[device.uid, default: 0] == selectionRevision else {
            lock.unlock()
            capture.stop()
            throw SelectionError.selectionChanged
        }
        captures[device.uid] = capture
        lock.unlock()

        Logger.audio.info("Started persistent capture for \(device.name, privacy: .public)")
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
    internal func setQueuedCallback(for deviceUID: String,
        callback: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?,
        onError: ((Error) -> Void)? = nil) {
        lock.withLock {
            guard let capture = captures[deviceUID] else { return }
            guard selectionAllows(deviceUID) else { capture.setCallbacks(audio: nil, error: nil); return }
            let revision = selectionRevisions[deviceUID, default: 0]
            capture.setQueuedCallbacks(audio: callback.map { callback in
                { [weak self] buffer, time in
                    guard let self else { return nil }
                    return self.lock.withLock {
                        guard self.selectionAllows(deviceUID), self.selectionRevisions[deviceUID, default: 0] == revision else { return nil }
                        return callback(buffer, time)
                    }
                }
            }, error: onError.map { onError in
                { [weak self] error in self?.deliver(deviceUID: deviceUID, revision: revision) { onError(error) } }
            }, rawError: onError, admissionGate: { [weak self] operation in
                guard let self else { return false }
                return self.lock.withLock {
                    guard self.selectionAllows(deviceUID), self.selectionRevisions[deviceUID, default: 0] == revision else { return false }
                    operation()
                    return true
                }
            })
        }
    }

    /// Clear all callbacks (called during segment rotation before writers change)
    public func clearAllCallbacks() {
        _ = detachCallbacks()
    }

    public func clearAllCallbacksAndDrain() async {
        let detached = detachForBoundary()
        for entry in detached.values { await entry.capture.drain() }
    }

    /// With a handoff, each selected microphone's later audio is held for the
    /// next segment in the same step that detaches it from this one.
    internal func detachForBoundary(handoff: AudioRotationHandoff? = nil) -> [String: (capture: ExternalMicCapture, cutoff: CMTime)] {
        let all = lock.withLock { captures.map { (uid: $0.key, capture: $0.value, allowed: selectionAllows($0.key),
            revision: selectionRevisions[$0.key, default: 0]) } }
        var detached: [String: (capture: ExternalMicCapture, cutoff: CMTime)] = [:]
        for entry in all {
            guard entry.allowed, let handoff, let stream = handoff.stream(for: entry.uid) else {
                detached[entry.uid] = (entry.capture, entry.capture.detachForBoundary())
                continue
            }
            let uid = entry.uid, revision = entry.revision
            let result = entry.capture.detachForBoundary(successor: { [weak self] buffer, time in
                guard let self else { return nil }
                return self.lock.withLock {
                    guard self.selectionAllows(uid), self.selectionRevisions[uid, default: 0] == revision else { return nil }
                    return stream.receive(pcm: buffer, at: time)
                }
            }, admissionGate: { [weak self] operation in
                guard let self else { return false }
                return self.lock.withLock {
                    guard self.selectionAllows(uid), self.selectionRevisions[uid, default: 0] == revision else { return false }
                    operation()
                    return true
                }
            })
            _ = handoff.stream(for: uid) { [weak capture = entry.capture] in
                capture?.clearDestination(ifRevision: result.revision)
            }
            detached[uid] = (entry.capture, result.cutoff)
        }
        return detached
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
