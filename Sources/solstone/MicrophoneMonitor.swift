// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore
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
    /// UIDs of input devices that a process other than this one is running input on.
    /// Uses the HAL process objects (macOS 14+). Any read failure yields an empty set,
    /// which keeps a following microphone off rather than opening it.
    public static func inputDeviceUIDsInUseByOtherProcesses() -> Set<String> {
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr
        else { return [] }
        let ownPID = getpid()
        var uids = Set<String>()
        for process in processes {
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != ownPID else { continue }
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var devicesSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &devicesAddress, 0, nil, &devicesSize) == noErr, devicesSize > 0 else { continue }
            var devices = [AudioObjectID](repeating: 0, count: Int(devicesSize) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(process, &devicesAddress, 0, nil, &devicesSize, &devices) == noErr else { continue }
            for device in devices { if let uid = getDeviceUID(deviceID: device) { uids.insert(uid) } }
        }
        return uids
    }

    private static let lastKnownLock = NSLock()
    nonisolated(unsafe) private static var lastKnownInputDevices: [AudioInputDevice] = []

    /// Current input devices. A failed HAL query returns the last list that was read
    /// successfully, so a transient query error never looks like every device unplugged.
    public static func listInputDevices() -> [AudioInputDevice] {
        if let devices = queryInputDevices() {
            lastKnownLock.withLock { lastKnownInputDevices = devices }
            return devices
        }
        Logger.audio.warning("Input device query failed; keeping the last known devices")
        return lastKnownLock.withLock { lastKnownInputDevices }
    }

    /// Nil when the HAL device list itself cannot be read.
    public static func queryInputDevices() -> [AudioInputDevice]? {
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

        guard status == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return nil }

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
        guard let devices = queryInputDevices() else { return nil }
        return devices.first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private Helpers

    public enum MicrophoneLayoutResult: Equatable, Sendable {
        case available(MicrophoneLayout)
        case unavailable
    }

    /// Full-list order plus active membership. Query failure on a known aggregate is `.unavailable`.
    internal enum AggregateMembership: Equatable, Sendable {
        case notAggregate
        case unavailable
        case members(full: [MicrophoneLayoutFingerprint.AggregateMemberSpan],
                     active: [MicrophoneLayoutFingerprint.AggregateMemberSpan])
    }

    public struct MicrophoneLayout: Equatable, Sendable {
        public let fingerprint: MicrophoneLayoutFingerprint
        public let channelCount: Int
        public let labels: [String?]

        public init(fingerprint: MicrophoneLayoutFingerprint, channelCount: Int, labels: [String?]) {
            self.fingerprint = fingerprint
            self.channelCount = channelCount
            self.labels = labels
        }
    }

    /// Pure reader for audio device input layout and channel labels.
    internal static func readLayout(
        deviceID: AudioDeviceID,
        queryStreams: ((AudioDeviceID) -> [AudioStreamID]?)? = nil,
        queryStreamSpan: ((AudioStreamID) -> (startingChannel: Int, channelCount: Int)?)? = nil,
        queryStreamConfigChannels: ((AudioDeviceID) -> Int?)? = nil,
        queryAggregateMembers: ((AudioDeviceID) -> AggregateMembership)? = nil,
        queryMemberNested: ((String) -> Bool)? = nil,
        queryChannelLabel: ((AudioDeviceID, Int) -> String?)? = nil
    ) -> MicrophoneLayoutResult {
        let bufferListHeaderSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!

        // 1. Read input streams
        let streamIDs: [AudioStreamID]
        if let queryStreams {
            guard let ids = queryStreams(deviceID) else { return .unavailable }
            streamIDs = ids
        } else {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
                return .unavailable
            }
            let count = Int(dataSize) / MemoryLayout<AudioStreamID>.size
            var ids = [AudioStreamID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ids) == noErr else {
                return .unavailable
            }
            streamIDs = ids
        }
        guard !streamIDs.isEmpty else { return .unavailable }

        // 2. Read each stream span (startingChannel + channelCount)
        var streamSpans: [MicrophoneLayoutFingerprint.StreamSpan] = []
        for streamID in streamIDs {
            let span: (startingChannel: Int, channelCount: Int)
            if let queryStreamSpan {
                guard let s = queryStreamSpan(streamID) else { return .unavailable }
                span = s
            } else {
                var dirAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyDirection,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var direction: UInt32 = 0
                var dirSize = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(streamID, &dirAddress, 0, nil, &dirSize, &direction) == noErr,
                      direction == 1 else { continue }

                var chanAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyStartingChannel,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var startChan: UInt32 = 0
                var startSize = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(streamID, &chanAddress, 0, nil, &startSize, &startChan) == noErr else {
                    return .unavailable
                }

                var formatAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyVirtualFormat,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var asbd = AudioStreamBasicDescription()
                var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                guard AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &asbd) == noErr,
                      asbd.mChannelsPerFrame > 0 else {
                    return .unavailable
                }
                span = (startingChannel: Int(startChan), channelCount: Int(asbd.mChannelsPerFrame))
            }
            guard span.channelCount > 0, span.startingChannel > 0 else { return .unavailable }
            streamSpans.append(MicrophoneLayoutFingerprint.StreamSpan(startingChannel: span.startingChannel, channelCount: span.channelCount))
        }
        guard !streamSpans.isEmpty else { return .unavailable }

        // Sort stream spans by starting channel
        streamSpans.sort { $0.startingChannel < $1.startingChannel }

        // 3. Verify contiguous spans with no gaps and no overlap
        guard streamSpans[0].startingChannel == 1 else { return .unavailable }
        var expectedNextChannel = 1 + streamSpans[0].channelCount
        for i in 1..<streamSpans.count {
            guard streamSpans[i].startingChannel == expectedNextChannel else { return .unavailable }
            expectedNextChannel += streamSpans[i].channelCount
        }
        let totalStreamChannels = expectedNextChannel - 1

        // 4. Validate against device stream configuration
        let configChannels: Int
        if let queryStreamConfigChannels {
            guard let count = queryStreamConfigChannels(deviceID) else { return .unavailable }
            configChannels = count
        } else {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var queriedSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &queriedSize) == noErr,
                  Int(queriedSize) >= MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! else {
                return .unavailable
            }
            let capacity = max(Int(queriedSize), MemoryLayout<AudioBufferList>.size)
            let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            memset(storage, 0, capacity)
            var returnedSize = UInt32(capacity)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returnedSize, storage) == noErr else {
                return .unavailable
            }
            let headerSize = bufferListHeaderSize
            guard Int(returnedSize) >= headerSize else { return .unavailable }
            let bufferCount = Int(storage.load(as: UInt32.self))
            let (bufferBytes, overflow) = bufferCount.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.stride)
            let (requiredBytes, addOverflow) = headerSize.addingReportingOverflow(bufferBytes)
            guard !overflow, !addOverflow, requiredBytes <= Int(returnedSize) else { return .unavailable }
            var sum = 0
            for i in 0..<bufferCount {
                let buf = storage.load(fromByteOffset: headerSize + i * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self)
                sum += Int(buf.mNumberChannels)
            }
            configChannels = sum
        }
        guard configChannels == totalStreamChannels else { return .unavailable }

        // 5. Aggregate identity: full-list order and active membership.
        let aggregateMembers: [MicrophoneLayoutFingerprint.AggregateMemberSpan]?
        let activeMembers: [MicrophoneLayoutFingerprint.AggregateMemberSpan]?
        let membership = queryAggregateMembers?(deviceID) ?? readAggregateMembership(deviceID: deviceID)
        switch reconcileAggregate(membership, totalChannels: totalStreamChannels, memberIsNested: queryMemberNested) {
        case .notAggregate:
            aggregateMembers = nil
            activeMembers = nil
        case .unavailable:
            return .unavailable
        case .members(let full, let active):
            aggregateMembers = full
            activeMembers = active
        }

        // 6. Channel labels (1-based element number, 0-based ordinal)
        var labels: [String?] = []
        for ordinal in 0..<totalStreamChannels {
            if let queryChannelLabel {
                labels.append(queryChannelLabel(deviceID, ordinal))
            } else {
                var labelAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyElementName,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: AudioObjectPropertyElement(ordinal + 1)
                )
                var nameCF: Unmanaged<CFString>?
                var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                let nameStatus = AudioObjectGetPropertyData(deviceID, &labelAddress, 0, nil, &nameSize, &nameCF)
                if nameStatus == noErr, let name = nameCF?.takeRetainedValue() as String?, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    labels.append(name)
                } else {
                    labels.append(nil)
                }
            }
        }

        let fingerprint = MicrophoneLayoutFingerprint(streams: streamSpans, aggregateMembers: aggregateMembers,
                                                     activeMembers: activeMembers)
        return .available(MicrophoneLayout(fingerprint: fingerprint, channelCount: totalStreamChannels, labels: labels))
    }

    /// HAL's stream configuration contains a variable-length AudioBufferList.
    /// Keep the allocated capacity separate from the bytes HAL actually returned.
    internal static func hasInputChannels(
        deviceID: AudioDeviceID,
        querySize: ((inout UInt32) -> OSStatus)? = nil,
        readData: ((inout UInt32, UnsafeMutableRawPointer) -> OSStatus)? = nil,
        allocate: (Int, Int) -> UnsafeMutableRawPointer = {
            UnsafeMutableRawPointer.allocate(byteCount: $0, alignment: $1)
        },
        release: (UnsafeMutableRawPointer) -> Void = { $0.deallocate() },
        diagnostic: ((String, OSStatus?) -> Void)? = nil
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        func report(_ stage: String, _ status: OSStatus? = nil) {
            if let diagnostic {
                diagnostic(stage, status)
            } else {
                Logger.audio.warning("Input configuration device \(deviceID, privacy: .public), stage \(stage, privacy: .public), status \(status ?? noErr, privacy: .public)")
            }
        }
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        for attempt in 0..<3 {
            var queriedSize: UInt32 = 0
            let queryStatus = querySize?(&queriedSize)
                ?? AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &queriedSize)
            guard queryStatus == noErr else { report("size", queryStatus); return false }
            guard Int(queriedSize) >= headerSize else { report("layout"); return false }

            let capacity = max(Int(queriedSize), MemoryLayout<AudioBufferList>.size)
            let storage = allocate(capacity, MemoryLayout<AudioBufferList>.alignment)
            defer { release(storage) }
            memset(storage, 0, capacity)
            var returnedSize = UInt32(capacity)
            let readStatus = readData?(&returnedSize, storage)
                ?? AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returnedSize, storage)
            if readStatus == kAudioHardwareBadPropertySizeError {
                if attempt == 2 { report("size_changed", readStatus) }
                continue
            }
            guard readStatus == noErr else { report("read", readStatus); return false }
            guard Int(returnedSize) >= headerSize, Int(returnedSize) <= capacity else {
                report("layout"); return false
            }
            // Reading only the header is safe even for HAL's zero-buffer response.
            let count = Int(storage.load(as: UInt32.self))
            let (bufferBytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.stride)
            let (requiredBytes, additionOverflow) = headerSize.addingReportingOverflow(bufferBytes)
            guard !overflow, !additionOverflow, requiredBytes <= Int(returnedSize) else {
                report("layout"); return false
            }
            return (0..<count).contains {
                storage.load(fromByteOffset: headerSize + $0 * MemoryLayout<AudioBuffer>.stride,
                             as: AudioBuffer.self).mNumberChannels > 0
            }
        }
        return false
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

    private static func allHALDeviceIDs() -> [AudioDeviceID]? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &ids
        ) == noErr else { return nil }
        return ids
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

    private static let maxAggregateMembers = 32

    private static func reconcileAggregate(_ membership: AggregateMembership, totalChannels: Int,
                                           memberIsNested: ((String) -> Bool)?) -> AggregateMembership {
        guard case .members(let full, let active) = membership else { return membership }
        guard !full.isEmpty, full.count <= maxAggregateMembers, active.count <= maxAggregateMembers else { return .unavailable }
        var seen: Set<String> = []
        var counts: [String: Int] = [:]
        var sum = 0
        for member in full {
            guard member.inputChannelCount >= 0, seen.insert(member.uid).inserted else { return .unavailable }
            if memberIsNested?(member.uid) == true { return .unavailable }
            counts[member.uid] = member.inputChannelCount
            sum += member.inputChannelCount
        }
        guard sum == totalChannels else { return .unavailable }
        var activeSeen: Set<String> = []
        for member in active {
            guard activeSeen.insert(member.uid).inserted,
                  counts[member.uid] == member.inputChannelCount else { return .unavailable }
        }
        return membership
    }

    /// A transport-aggregate whose full or active list cannot be read is unavailable.
    /// An ordinary device whose aggregate property is absent stays an ordinary device.
    private static func readAggregateMembership(deviceID: AudioDeviceID) -> AggregateMembership {
        let knownAggregate = getDeviceTransportType(deviceID: deviceID) == .aggregate
        guard let fullUIDs = readAggregateUIDList(deviceID: deviceID, knownAggregate: knownAggregate) else {
            return knownAggregate ? .unavailable : .notAggregate
        }
        guard let deviceByUID = halDevicesByUID() else { return .unavailable }
        var full: [MicrophoneLayoutFingerprint.AggregateMemberSpan] = []
        for uid in fullUIDs {
            guard let subID = deviceByUID[uid] else { return .unavailable }
            if getDeviceTransportType(deviceID: subID) == .aggregate { return .unavailable }
            guard let channels = inputChannelCount(deviceID: subID) else { return .unavailable }
            full.append(MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: uid, inputChannelCount: channels))
        }
        guard let activeIDs = readActiveAggregateMemberIDs(deviceID: deviceID) else { return .unavailable }
        var active: [MicrophoneLayoutFingerprint.AggregateMemberSpan] = []
        for subID in activeIDs {
            guard let uid = getDeviceUID(deviceID: subID),
                  let channels = full.first(where: { $0.uid == uid })?.inputChannelCount else { return .unavailable }
            active.append(MicrophoneLayoutFingerprint.AggregateMemberSpan(uid: uid, inputChannelCount: channels))
        }
        return .members(full: full, active: active)
    }

    /// Nil when the property is absent, or when a device that is not a known aggregate cannot be read.
    /// A known aggregate that fails the read returns an empty list. Reconciliation then rejects that
    /// memberless result as unavailable, so a failed query does not become an ordinary device.
    private static func readAggregateUIDList(deviceID: AudioDeviceID, knownAggregate: Bool) -> [String]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        if sizeStatus == kAudioHardwareUnknownPropertyError || sizeStatus == kAudioHardwareBadObjectError {
            return nil
        }
        guard sizeStatus == noErr else { return knownAggregate ? [] : nil }
        // An empty list is a successful read of no members. Callers that required an aggregate
        // still fail reconciliation when the channel sum does not match. A zero-size success
        // with a non-aggregate transport is not a member list.
        guard size > 0 else { return knownAggregate ? [] : nil }
        var subdeviceList: Unmanaged<CFArray>?
        var propSize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let readStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, &subdeviceList)
        guard readStatus == noErr, propSize == UInt32(MemoryLayout<Unmanaged<CFArray>?>.size),
              let cfArray = subdeviceList?.takeRetainedValue() else {
            return knownAggregate ? [] : nil
        }
        let count = CFArrayGetCount(cfArray)
        guard count >= 0, count <= maxAggregateMembers else { return knownAggregate ? [] : nil }
        var uids: [String] = []
        uids.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(cfArray, index),
                  let uid = cfStringValue(pointer) else { return knownAggregate ? [] : nil }
            uids.append(uid)
        }
        return uids
    }

    private static func readActiveAggregateMemberIDs(deviceID: AudioDeviceID) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
        let element = UInt32(MemoryLayout<AudioObjectID>.size)
        guard size > 0, element > 0, size <= element * UInt32(maxAggregateMembers), size % element == 0 else {
            return size == 0 ? [] : nil
        }
        let count = Int(size / element)
        var ids = [AudioObjectID](repeating: 0, count: count)
        var returned = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returned, &ids) == noErr,
              returned > 0, returned <= size, returned % element == 0 else { return nil }
        return Array(ids.prefix(Int(returned / element)))
    }

    private static func cfStringValue(_ pointer: UnsafeRawPointer) -> String? {
        let typeRef = Unmanaged<CFTypeRef>.fromOpaque(UnsafeMutableRawPointer(mutating: pointer)).takeUnretainedValue()
        guard CFGetTypeID(typeRef) == CFStringGetTypeID() else { return nil }
        return typeRef as? String
    }

    private static func halDevicesByUID() -> [String: AudioDeviceID]? {
        guard let ids = allHALDeviceIDs() else { return nil }
        var deviceByUID: [String: AudioDeviceID] = [:]
        deviceByUID.reserveCapacity(ids.count)
        for id in ids {
            guard let uid = getDeviceUID(deviceID: id) else { continue }
            if deviceByUID[uid] == nil { deviceByUID[uid] = id }
        }
        return deviceByUID
    }

    /// Nil when the input layout cannot be read. Zero is a readable input with no channels.
    private static func inputChannelCount(deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var queriedSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &queriedSize) == noErr else { return nil }
        let headerSize = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(queriedSize) >= headerSize else { return nil }
        let capacity = max(Int(queriedSize), MemoryLayout<AudioBufferList>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        memset(storage, 0, capacity)
        var returned = UInt32(capacity)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &returned, storage) == noErr,
              Int(returned) >= headerSize else { return nil }
        let bufferCount = Int(storage.load(as: UInt32.self))
        let (bufferBytes, overflow) = bufferCount.multipliedReportingOverflow(by: MemoryLayout<AudioBuffer>.stride)
        let (required, addOverflow) = headerSize.addingReportingOverflow(bufferBytes)
        guard !overflow, !addOverflow, required <= Int(returned), bufferCount <= maxAggregateMembers else { return nil }
        var sum = 0
        for index in 0..<bufferCount {
            let buffer = storage.load(fromByteOffset: headerSize + index * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self)
            sum += Int(buffer.mNumberChannels)
        }
        return sum
    }
}
