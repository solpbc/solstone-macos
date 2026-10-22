import CoreAudio
import Testing
@testable import solstone

@Suite("MicrophoneSelection")
struct MicrophoneSelectionTests {
    @Test func continuityIsExcludedByDefault() {
        let device = makeDevice(uid: "continuity", transportType: .continuityWireless)

        let shouldCapture = MicrophoneSelection.shouldCapture(
            device,
            disabledMicUIDs: [],
            enabledMicUIDs: []
        )

        #expect(!shouldCapture)
    }

    @Test func continuityIsIncludedWhenExplicitlyEnabled() {
        let device = makeDevice(uid: "continuity", transportType: .continuityWired)

        let shouldCapture = MicrophoneSelection.shouldCapture(
            device,
            disabledMicUIDs: [],
            enabledMicUIDs: ["continuity"]
        )

        #expect(shouldCapture)
    }

    @Test func builtinAndUSBCaptureUnlessDisabled() {
        let builtin = makeDevice(uid: "builtin", transportType: .builtin)
        let usb = makeDevice(uid: "usb", transportType: .usb)

        #expect(MicrophoneSelection.shouldCapture(builtin, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(MicrophoneSelection.shouldCapture(usb, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(!MicrophoneSelection.shouldCapture(builtin, disabledMicUIDs: ["builtin"], enabledMicUIDs: []))
        #expect(!MicrophoneSelection.shouldCapture(usb, disabledMicUIDs: ["usb"], enabledMicUIDs: []))
    }

    @Test func aggregateIsExcludedUnlessEnabled() {
        let device = makeDevice(uid: "aggregate", transportType: .aggregate)

        #expect(!MicrophoneSelection.shouldCapture(device, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(MicrophoneSelection.shouldCapture(device, disabledMicUIDs: [], enabledMicUIDs: ["aggregate"]))
    }

    @Test func iPhoneNamedDeviceIsExcludedByDefaultEvenWithMisreportedTransport() {
        // macOS doesn't reliably report a ContinuityCapture* transport type for every
        // iPhone/iPad variant -- some report .usb, .bluetooth, or .unknown instead. The name
        // fallback in isOptInOnlyMicrophone must still gate this device as opt-in-only.
        let device = makeDevice(uid: "iphone-usb", name: "David's iPhone Microphone", transportType: .usb)

        #expect(!MicrophoneSelection.shouldCapture(device, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(MicrophoneSelection.shouldCapture(device, disabledMicUIDs: [], enabledMicUIDs: ["iphone-usb"]))
    }

    @Test func bluetoothFollowsOtherAppsUnlessTheOwnerChose() {
        let headset = makeDevice(uid: "bt", transportType: .bluetooth)
        #expect(!MicrophoneSelection.shouldCapture(headset, disabledMicUIDs: [], enabledMicUIDs: []))
        #expect(MicrophoneSelection.shouldCapture(headset, disabledMicUIDs: [], enabledMicUIDs: [], inUseElsewhere: ["bt"]))
        #expect(MicrophoneSelection.shouldCapture(headset, disabledMicUIDs: [], enabledMicUIDs: ["bt"]))
        #expect(!MicrophoneSelection.shouldCapture(headset, disabledMicUIDs: ["bt"], enabledMicUIDs: [], inUseElsewhere: ["bt"]))
        let usb = makeDevice(uid: "usb", transportType: .usb)
        #expect(MicrophoneSelection.shouldCapture(usb, disabledMicUIDs: [], enabledMicUIDs: [], inUseElsewhere: []))
        // An iPhone that reports a Bluetooth transport stays opt-in only.
        let phone = makeDevice(uid: "phone", name: "Alex's iPhone Microphone", transportType: .bluetooth)
        #expect(!MicrophoneSelection.shouldCapture(phone, disabledMicUIDs: [], enabledMicUIDs: [], inUseElsewhere: ["phone"]))
    }

    @Test func needsChoiceShowsNoOrdinalAndNamesLayoutDriftAtAnyChannelCount() {
        let saved = MicrophoneLayoutFingerprint(streams: [.init(startingChannel: 1, channelCount: 10)])
        let drifted = MicrophoneLayoutFingerprint(streams: [.init(startingChannel: 1, channelCount: 2)])
        let same = MicrophoneMonitor.MicrophoneLayout(fingerprint: saved, channelCount: 10, labels: [])
        let stereo = MicrophoneMonitor.MicrophoneLayout(fingerprint: drifted, channelCount: 2, labels: [])
        let choice = MicrophoneChoice(ordinal: 7, fingerprint: saved)
        let driftedState = classifyMicrophone(
            device: makeDevice(uid: "iface", transportType: .usb),
            choice: choice,
            layoutResult: .available(stereo)
        )
        #expect(driftedState == .needsChoice(layout: stereo))
        #expect(microphonePickerSelection(interfaceState: driftedState, choice: choice) == -1)
        #expect(microphoneChoicePrompt(choice: choice, layout: stereo) == .inputsChanged)
        #expect(microphoneChoicePrompt(choice: choice, layout: same) == .pickInput)
        let fresh = classifyMicrophone(
            device: makeDevice(uid: "iface", transportType: .usb),
            choice: nil,
            layoutResult: .available(same)
        )
        #expect(microphonePickerSelection(interfaceState: fresh, choice: choice) == -1)
        #expect(microphoneChoicePrompt(choice: nil, layout: same) == .pickInput)
        let admitted = MicrophoneInterfaceState.admitted
        #expect(microphonePickerSelection(interfaceState: admitted, choice: choice) == 7)
    }

    private func makeDevice(uid: String, name: String = "Test Mic", transportType: AudioTransportType) -> AudioInputDevice {
        AudioInputDevice(
            id: 1,
            name: name,
            uid: uid,
            manufacturer: nil,
            sampleRate: 48000,
            transportType: transportType
        )
    }
}
