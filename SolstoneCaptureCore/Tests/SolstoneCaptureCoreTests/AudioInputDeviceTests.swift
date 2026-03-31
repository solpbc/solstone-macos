// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import Testing
@testable import SolstoneCaptureCore

@Suite("AudioInputDevice")
struct AudioInputDeviceTests {
    private func makeDevice(
        name: String = "Test Mic",
        manufacturer: String? = nil,
        transportType: AudioTransportType = .usb
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: AudioDeviceID(1),
            name: name,
            uid: "test-uid",
            manufacturer: manufacturer,
            sampleRate: 48000,
            transportType: transportType
        )
    }

    // MARK: - facet

    @Test func facetDetectsJabra() {
        let device = makeDevice(name: "Jabra Speak 750")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetDetectsPoly() {
        let device = makeDevice(name: "Poly Sync 20")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetDetectsEmeet() {
        let device = makeDevice(name: "eMeet Luna")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetDetectsYealink() {
        let device = makeDevice(name: "Yealink CP900")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetDetectsKonftel() {
        let device = makeDevice(name: "Konftel 70")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetDetectsGenericSpeakerphone() {
        let device = makeDevice(name: "USB Speakerphone")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetIsCaseInsensitive() {
        let device = makeDevice(name: "JABRA SPEAK 750")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetChecksManufacturer() {
        let device = makeDevice(name: "Generic USB Mic", manufacturer: "Jabra")
        #expect(device.facet == "speakerphone")
    }

    @Test func facetReturnsNilForNonSpeakerphone() {
        let device = makeDevice(name: "MacBook Pro Microphone")
        #expect(device.facet == nil)
    }

    @Test func facetReturnsNilForBlueYeti() {
        let device = makeDevice(name: "Blue Yeti", manufacturer: "Blue Microphones")
        #expect(device.facet == nil)
    }

    // MARK: - toMetadata

    @Test func toMetadataIncludesRequiredKeys() {
        let device = makeDevice(name: "Test Mic", transportType: .usb)
        let meta = device.toMetadata()
        #expect(meta["device_name"] as? String == "Test Mic")
        #expect(meta["device_uid"] as? String == "test-uid")
        #expect(meta["sample_rate"] as? Int == 48000)
        #expect(meta["transport_type"] as? String == "usb")
    }

    @Test func toMetadataIncludesManufacturerWhenPresent() {
        let device = makeDevice(manufacturer: "Shure")
        let meta = device.toMetadata()
        #expect(meta["manufacturer"] as? String == "Shure")
    }

    @Test func toMetadataExcludesManufacturerWhenNil() {
        let device = makeDevice(manufacturer: nil)
        let meta = device.toMetadata()
        #expect(meta["manufacturer"] == nil)
    }

    @Test func toMetadataIncludesFacetWhenPresent() {
        let device = makeDevice(name: "Jabra Speak 750")
        let meta = device.toMetadata()
        #expect(meta["facet"] as? String == "speakerphone")
    }

    @Test func toMetadataExcludesFacetWhenNil() {
        let device = makeDevice(name: "Regular Mic")
        let meta = device.toMetadata()
        #expect(meta["facet"] == nil)
    }
}
