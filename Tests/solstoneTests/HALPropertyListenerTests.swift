import CoreAudio
import Testing
@testable import solstone

@Suite("HALPropertyListener")
@MainActor
struct HALPropertyListenerTests {
    @Test func doubleInvalidateIsNoop() async throws {
        var callCount = 0
        let listener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectUnknown),
            selector: kAudioHardwarePropertyDevices,
            onChange: {
                callCount += 1
            }
        )

        listener.invalidate()
        listener.invalidate()
        listener.simulateChangeForTesting()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        #expect(callCount == 0)
    }

    @Test func invalidateAfterFailedAddIsNoop() async throws {
        var callCount = 0
        let listener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectUnknown),
            selector: kAudioHardwarePropertyDevices,
            onChange: {
                callCount += 1
            }
        )

        listener.invalidate()
        listener.simulateChangeForTesting()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        #expect(callCount == 0)
    }

    @Test func deinitAfterInvalidateDoesNotCrash() {
        var listener: HALPropertyListener? = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectUnknown),
            selector: kAudioHardwarePropertyDevices,
            onChange: {}
        )

        listener?.invalidate()
        listener = nil

        #expect(listener == nil)
    }

    @Test func simulatedChangeAfterInvalidateDoesNotCallOnChange() async throws {
        var callCount = 0
        let listener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectUnknown),
            selector: kAudioHardwarePropertyDevices,
            onChange: {
                callCount += 1
            }
        )

        listener.invalidate()
        listener.simulateChangeForTesting()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        #expect(callCount == 0)
    }

    @Test func simulatedChangeBeforeInvalidateCallsOnChange() async throws {
        var callCount = 0
        let listener = HALPropertyListener(
            objectID: AudioObjectID(kAudioObjectUnknown),
            selector: kAudioHardwarePropertyDevices,
            onChange: {
                callCount += 1
            }
        )

        listener.simulateChangeForTesting()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        #expect(callCount == 1)
    }
}
