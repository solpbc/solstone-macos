// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreAudio

/// Transport type for audio devices
public enum AudioTransportType: String, Sendable {
    case builtin = "built-in"
    case usb = "usb"
    case bluetooth = "bluetooth"
    case virtual = "virtual"
    case aggregate = "aggregate"
    case thunderbolt = "thunderbolt"
    case firewire = "firewire"
    case pci = "pci"
    case displayPort = "displayport"
    case avb = "avb"
    case airplay = "airplay"
    case hdmi = "hdmi"
    case continuityWired = "continuity-wired"
    case continuityWireless = "continuity-wireless"
    case unknown = "unknown"

    public static let optInOnly: Set<AudioTransportType> = [.continuityWired, .continuityWireless, .aggregate]

    public var isOptInOnly: Bool {
        Self.optInOnly.contains(self)
    }
}

/// Represents an available audio input device
public struct AudioInputDevice: Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let manufacturer: String?
    public let sampleRate: Double
    public let transportType: AudioTransportType

    /// True for a device that should default to opt-in (listed, but disabled until the user
    /// explicitly enables it) rather than auto-captured: either its CoreAudio transport type is
    /// opt-in-only (`AudioTransportType.isOptInOnly` — Continuity, aggregate), or its name matches
    /// the iPhone/iPad Continuity-mic pattern.
    ///
    /// The name fallback exists because macOS does not reliably report a `ContinuityCapture*`
    /// transport type for every iPhone/iPad Continuity mic variant — some report `.usb`,
    /// `.bluetooth`, or `.unknown` instead. Without it, a misreported device falls through to
    /// auto-capture and reproduces the attach/disconnect flapping this guard exists to prevent.
    /// Heuristic contributed by github.com/howethomas, PR #1.
    public var isOptInOnlyMicrophone: Bool {
        if transportType.isOptInOnly { return true }
        let lowered = name.lowercased()
        return lowered.contains("iphone") || lowered.contains("ipad")
    }

    /// Heuristic classification for device type (e.g., "speakerphone")
    public var facet: String? {
        let speakerphoneKeywords = [
            "jabra", "poly", "polycom", "yealink", "konftel",
            "emeet", "speakerphone", "speak ", "sync "
        ]
        let searchText = (name + " " + (manufacturer ?? "")).lowercased()
        if speakerphoneKeywords.contains(where: { searchText.contains($0) }) {
            return "speakerphone"
        }
        return nil
    }

    /// Convert to dictionary for JSON serialization
    public func toMetadata() -> [String: Any] {
        var meta: [String: Any] = [
            "device_name": name,
            "device_uid": uid,
            "sample_rate": Int(sampleRate),
            "transport_type": transportType.rawValue
        ]
        if let manufacturer = manufacturer {
            meta["manufacturer"] = manufacturer
        }
        if let facet = facet {
            meta["facet"] = facet
        }
        return meta
    }
}

/// Namespace for CoreAudio microphone enumeration and lookup helpers.
public enum MicrophoneMonitor {
    /// Lists all available audio input devices
    public static func listInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            // Check if device has input channels
            guard hasInputChannels(deviceID: deviceID) else { return nil }

            // Get device name
            guard let name = getDeviceName(deviceID: deviceID) else { return nil }

            // Skip aggregate devices created by voice processing
            // These have names like "CADefaultDeviceAggregate-*"
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }

            // Get device UID
            guard let uid = getDeviceUID(deviceID: deviceID) else { return nil }

            // Get additional metadata
            let manufacturer = getDeviceManufacturer(deviceID: deviceID)
            let sampleRate = getDeviceSampleRate(deviceID: deviceID) ?? 48000.0
            let transportType = getDeviceTransportType(deviceID: deviceID)

            return AudioInputDevice(
                id: deviceID,
                name: name,
                uid: uid,
                manufacturer: manufacturer,
                sampleRate: sampleRate,
                transportType: transportType
            )
        }
    }

    /// Gets the default input device ID
    public static func getDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }

    /// Gets the device ID for a given UID
    public static func deviceIDForUID(_ uid: String) -> AudioDeviceID? {
        let devices = listInputDevices()
        return devices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private Helpers

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return false }

        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0
    }

    private static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }

        return cfName as String
    }

    private static func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }

        return cfUID as String
    }

    private static func getDeviceManufacturer(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceManufacturerCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var manufacturer: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &manufacturer)
        guard status == noErr, let cfManufacturer = manufacturer?.takeRetainedValue() else { return nil }

        return cfManufacturer as String
    }

    private static func getDeviceSampleRate(deviceID: AudioDeviceID) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &sampleRate)
        guard status == noErr else { return nil }

        return sampleRate
    }

    private static func getDeviceTransportType(deviceID: AudioDeviceID) -> AudioTransportType {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &transportType)
        guard status == noErr else { return .unknown }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtin
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeThunderbolt:
            return .thunderbolt
        case kAudioDeviceTransportTypeFireWire:
            return .firewire
        case kAudioDeviceTransportTypePCI:
            return .pci
        case kAudioDeviceTransportTypeDisplayPort:
            return .displayPort
        case kAudioDeviceTransportTypeAVB:
            return .avb
        case kAudioDeviceTransportTypeAirPlay:
            return .airplay
        case kAudioDeviceTransportTypeHDMI:
            return .hdmi
        case kAudioDeviceTransportTypeContinuityCaptureWired:
            return .continuityWired
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuityWireless
        default:
            return .unknown
        }
    }
}
