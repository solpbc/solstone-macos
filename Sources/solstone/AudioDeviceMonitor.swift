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
    private var previousDeviceUIDs: Set<String> = []

    /// Callback when devices are added or removed
    @ObservationIgnored
    public var onDeviceChange: ((_ added: [AudioInputDevice], _ removed: [AudioInputDevice]) -> Void)?

    public init() {
        refreshDevices()
        // Initialize previous UIDs without triggering callback
        previousDeviceUIDs = Set(availableDevices.map { $0.uid })
        startListening()
    }

    /// Internal init for snapshot/testing — skips CoreAudio hardware interaction
    internal init(startListening: Bool) {
        if startListening {
            refreshDevices()
            previousDeviceUIDs = Set(availableDevices.map { $0.uid })
            self.startListening()
        }
    }

    deinit {
        deviceListener?.invalidate()
    }

    public func refreshDevices() {
        let newDevices = MicrophoneMonitor.listInputDevices()
        let newUIDs = Set(newDevices.map { $0.uid })

        // Compute added and removed devices
        let addedUIDs = newUIDs.subtracting(previousDeviceUIDs)
        let removedUIDs = previousDeviceUIDs.subtracting(newUIDs)

        let added = newDevices.filter { addedUIDs.contains($0.uid) }
        let removed = availableDevices.filter { removedUIDs.contains($0.uid) }

        // Update state
        previousDeviceUIDs = newUIDs
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
