// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation

/// Monitors audio device additions/removals and provides observable device list
@MainActor
@Observable
public final class AudioDeviceMonitor {
    public internal(set) var availableDevices: [AudioInputDevice] = []

    @ObservationIgnored
    private var deviceListener: HALPropertyListener?

    /// Previous device UIDs for change detection
    @ObservationIgnored
    private var previousDevices: [AudioInputDevice] = []

    /// Callback when devices are added or removed
    @ObservationIgnored
    public var onDeviceChange: ((_ added: [AudioInputDevice], _ removed: [AudioInputDevice]) -> Void)?

    public init() {
        refreshDevices()
        // Initialize previous UIDs without triggering callback
        previousDevices = availableDevices
        startListening()
    }

    /// Internal init for snapshot/testing — skips CoreAudio hardware interaction
    internal init(startListening: Bool) {
        if startListening {
            refreshDevices()
            previousDevices = availableDevices
            self.startListening()
        }
    }

    deinit {
        deviceListener?.invalidate()
    }

    public func refreshDevices() {
        applyDevices(MicrophoneMonitor.listInputDevices())
    }

    internal func applyDevices(_ newDevices: [AudioInputDevice]) {
        let added = newDevices.filter { device in
            !previousDevices.contains { $0.uid == device.uid && $0.id == device.id }
        }
        let removed = previousDevices.filter { device in
            !newDevices.contains { $0.uid == device.uid && $0.id == device.id }
        }

        // Update state
        previousDevices = newDevices
        availableDevices = newDevices

        // Notify if there were changes
        if !added.isEmpty || !removed.isEmpty {
            onDeviceChange?(added, removed)
        }
    }

    private func startListening() {
        deviceListener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            onChange: { [weak self] in self?.refreshDevices() }
        )
    }

    public func stopListening() {
        deviceListener?.invalidate()
        deviceListener = nil
    }
}
