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

    public init() {
        refreshDevices()
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
        availableDevices = MicrophoneMonitor.listInputDevices()
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
