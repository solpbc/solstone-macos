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
        // A saved fingerprint that no longer matches is not a stereo downmix, at any channel count.
        if let choice, choice.fingerprint != layout.fingerprint
            || choice.ordinal < 0 || choice.ordinal >= layout.channelCount {
            return .needsChoice(layout: layout)
        }
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

enum MicrophoneChoicePrompt: Equatable, Sendable {
    /// More than two inputs, and no saved choice for this layout.
    case pickInput
    /// A saved choice does not match the layout that is readable now.
    case inputsChanged
}

func microphoneChoicePrompt(choice: MicrophoneChoice?, layout: MicrophoneMonitor.MicrophoneLayout) -> MicrophoneChoicePrompt {
    if let choice, choice.fingerprint != layout.fingerprint {
        return .inputsChanged
    }
    return .pickInput
}

func microphoneChoiceCopy(choice: MicrophoneChoice?, layout: MicrophoneMonitor.MicrophoneLayout) -> String {
    switch microphoneChoicePrompt(choice: choice, layout: layout) {
    case .pickInput: UICopy.MICROPHONE_NEEDS_CHOICE
    case .inputsChanged: UICopy.MICROPHONE_INPUTS_CHANGED
    }
}

/// Needs-choice always presents the unselected placeholder. A stale ordinal must not look selected,
/// or choosing that same row again never dispatches a new choice.
func microphonePickerSelection(interfaceState: MicrophoneInterfaceState, choice: MicrophoneChoice?) -> Int {
    if case .needsChoice = interfaceState { return -1 }
    return choice?.ordinal ?? 0
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
