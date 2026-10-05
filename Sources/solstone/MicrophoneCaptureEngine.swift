// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import ObjCHelpers
import os

/// Native operations run only on ExternalMicCapture's serial engine queue.
internal protocol MicrophoneCaptureEngine: AnyObject, Sendable {
    var configurationObject: AnyObject { get }
    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
    func removeTap() throws
}

internal final class NativeMicrophoneCaptureEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    var configurationObject: AnyObject { engine }

    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw ExternalMicCapture.ExternalMicCaptureError.noAudioUnit }
        var currentID = deviceID
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &currentID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw ExternalMicCapture.ExternalMicCaptureError.failedToSetDevice(deviceID, result) }
        Logger.audio.info("\(deviceName, privacy: .public): pinned current deviceID \(deviceID, privacy: .public)")
        engine.prepare()
        let format = input.inputFormat(forBus: 0)
        Logger.audio.info("\(deviceName, privacy: .public): hardware format \(format.sampleRate, privacy: .public)Hz, \(format.channelCount, privacy: .public)ch")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName)
        }
        do {
            try ObjCExceptionCatcher.`try` {
                input.installTap(onBus: 0, bufferSize: 4096, format: format, block: onPCM)
            }
        } catch {
            throw ExternalMicCapture.ExternalMicCaptureError.installTapFailed(deviceName, error.localizedDescription)
        }
        try engine.start()
    }

    func stop() { engine.stop() }
    func removeTap() throws {
        try ObjCExceptionCatcher.`try` { self.engine.inputNode.removeTap(onBus: 0) }
    }
}
