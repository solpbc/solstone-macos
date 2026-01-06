// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CoreAudio

/// Represents an available audio input device
public struct AudioInputDevice: Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
}

/// Monitors microphone device status using CoreAudio
/// Detects device disconnection and notifies via callback
public final class MicrophoneMonitor: @unchecked Sendable {
    private let onDisconnect: () -> Void
    private let lock = NSLock()
    private var monitoredDeviceID: AudioDeviceID?
    private var isMonitoring = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    public init(onDisconnect: @escaping () -> Void) {
        self.onDisconnect = onDisconnect
    }

    deinit {
        stopMonitoring()
    }

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

            return AudioInputDevice(id: deviceID, name: name, uid: uid)
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

    /// Starts monitoring the specified device for disconnection
    public func startMonitoring(deviceID: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }

        guard !isMonitoring else { return }

        monitoredDeviceID = deviceID
        isMonitoring = true

        // Create listener block for device alive status
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.checkDeviceStatus()
        }
        listenerBlock = block

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &propertyAddress,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            fputs("[WARN] Failed to add device listener: \(status)\n", stderr)
        }
    }

    /// Stops monitoring
    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        guard isMonitoring, let deviceID = monitoredDeviceID, let block = listenerBlock else {
            return
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(deviceID, &propertyAddress, DispatchQueue.main, block)

        isMonitoring = false
        monitoredDeviceID = nil
        listenerBlock = nil
    }

    /// Checks if the monitored device is still alive
    private func checkDeviceStatus() {
        lock.lock()
        let deviceID = monitoredDeviceID
        lock.unlock()

        guard let deviceID = deviceID else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isAlive: UInt32 = 1
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &isAlive
        )

        if status != noErr || isAlive == 0 {
            // Device is disconnected
            onDisconnect()
        }
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
}
