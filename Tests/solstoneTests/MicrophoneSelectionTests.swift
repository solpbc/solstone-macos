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

    private func makeDevice(uid: String, transportType: AudioTransportType) -> AudioInputDevice {
        AudioInputDevice(
            id: 1,
            name: "Test Mic",
            uid: uid,
            manufacturer: nil,
            sampleRate: 48000,
            transportType: transportType
        )
    }
}
