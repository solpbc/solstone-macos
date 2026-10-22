// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

public enum MicrophoneInterfaceState: Equatable, Sendable {
    case admitted
    case needsChoice(layout: MicrophoneMonitor.MicrophoneLayout)
    case layoutUnavailable
}

public func classifyMicrophone(
    device: AudioInputDevice,
    choice: MicrophoneChoice?,
    layoutResult: MicrophoneMonitor.MicrophoneLayoutResult? = nil
) -> MicrophoneInterfaceState {
    let result = layoutResult ?? MicrophoneMonitor.readLayout(deviceID: device.id)
    switch result {
    case .unavailable:
        return .layoutUnavailable
    case .available(let layout):
        if layout.channelCount <= 2 {
            return .admitted
        }
        guard let choice, choice.ordinal >= 0, choice.ordinal < layout.channelCount,
              choice.fingerprint == layout.fingerprint else {
            return .needsChoice(layout: layout)
        }
        return .admitted
    }
}

enum MicrophoneSelection {
    /// `enabled` always captures and `disabled` never does. A Bluetooth microphone
    /// in neither set follows other apps: it is taken in only while another app has
    /// it open, because opening an idle headset input degrades its playback.
    static func shouldCapture(
        _ device: AudioInputDevice,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>,
        inUseElsewhere: Set<String> = []
    ) -> Bool {
        if enabledMicUIDs.contains(device.uid) { return true }
        if disabledMicUIDs.contains(device.uid) { return false }
        if device.isOptInOnlyMicrophone { return false }
        if device.transportType == .bluetooth { return inUseElsewhere.contains(device.uid) }
        return true
    }
}
