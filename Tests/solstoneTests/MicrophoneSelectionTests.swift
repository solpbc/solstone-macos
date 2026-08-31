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
