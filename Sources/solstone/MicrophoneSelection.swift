// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum MicrophoneSelection {
    static func shouldCapture(
        _ device: AudioInputDevice,
        disabledMicUIDs: Set<String>,
        enabledMicUIDs: Set<String>
    ) -> Bool {
        if device.transportType.isOptInOnly { return enabledMicUIDs.contains(device.uid) }
        return !disabledMicUIDs.contains(device.uid)
    }
}
