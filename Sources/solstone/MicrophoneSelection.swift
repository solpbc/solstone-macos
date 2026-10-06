// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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
