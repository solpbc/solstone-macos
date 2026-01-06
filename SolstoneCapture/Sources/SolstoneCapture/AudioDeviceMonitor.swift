// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Foundation
import SolstoneCaptureCore

/// Monitors audio device additions/removals and provides observable device list
@MainActor
@Observable
public final class AudioDeviceMonitor {
    public private(set) var availableDevices: [AudioInputDevice] = []

    /// Storage for the listener block - nonisolated for deinit access
    @ObservationIgnored
    private nonisolated(unsafe) var listenerBlock: AudioObjectPropertyListenerBlock?

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

    deinit {
        // Clean up the listener synchronously since deinit is nonisolated
        guard let block = listenerBlock else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
        listenerBlock = block

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }
}
