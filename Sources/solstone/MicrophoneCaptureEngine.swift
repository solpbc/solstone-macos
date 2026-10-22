// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import ObjCHelpers
import os

/// Low-level AUHAL seam for testing and production HAL interaction.
internal protocol MicrophoneInputUnit: AnyObject, Sendable {
    func open() -> OSStatus
    func setInputEnabled(_ enabled: Bool) -> OSStatus
    func setOutputEnabled(_ enabled: Bool) -> OSStatus
    func setDeviceID(_ deviceID: AudioDeviceID) -> OSStatus
    func getDeviceID() -> (status: OSStatus, deviceID: AudioDeviceID)
    func getStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription)
    func setStreamFormat(_ asbd: AudioStreamBasicDescription) -> OSStatus
    func setRenderCallback(_ callback: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer?) -> OSStatus
    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frameCount: UInt32,
                data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus
    func initialize() -> OSStatus
    func start() -> OSStatus
    func stop() -> OSStatus
    func dispose() -> OSStatus
}

internal final class DefaultMicrophoneInputUnit: MicrophoneInputUnit, @unchecked Sendable {
    private var unit: AudioUnit?

    func open() -> OSStatus {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            return kAudioUnitErr_FormatNotSupported
        }
        return AudioComponentInstanceNew(component, &unit)
    }

    func setInputEnabled(_ enabled: Bool) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        var value: UInt32 = enabled ? 1 : 0
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Input, 1, &value, UInt32(MemoryLayout<UInt32>.size))
    }

    func setOutputEnabled(_ enabled: Bool) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        var value: UInt32 = enabled ? 1 : 0
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                    kAudioUnitScope_Output, 0, &value, UInt32(MemoryLayout<UInt32>.size))
    }

    func setDeviceID(_ deviceID: AudioDeviceID) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        var dev = deviceID
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    func getDeviceID() -> (status: OSStatus, deviceID: AudioDeviceID) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, 0) }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev, &size)
        return (status, dev)
    }

    func getStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, AudioStreamBasicDescription()) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, 1, &asbd, &size)
        return (status, asbd)
    }

    func setStreamFormat(_ asbd: AudioStreamBasicDescription) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        var desc = asbd
        return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output, 1, &desc, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    }

    func setRenderCallback(_ callback: @escaping AURenderCallback, refCon: UnsafeMutableRawPointer?) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        var cb = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: refCon)
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                    kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }

    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frameCount: UInt32,
                data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frameCount, data)
    }

    func initialize() -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioUnitInitialize(unit)
    }

    func start() -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStart(unit)
    }

    func stop() -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStop(unit)
    }

    func dispose() -> OSStatus {
        guard let unit else { return noErr }
        AudioUnitUninitialize(unit)
        let status = AudioComponentInstanceDispose(unit)
        self.unit = nil
        return status
    }
}

/// Native operations run only on ExternalMicCapture's serial engine queue.
internal protocol MicrophoneCaptureEngine: AnyObject, Sendable {
    func requiresRecovery(resolvedDeviceID: AudioDeviceID?) -> Bool
    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
    func setRenderFailureHook(_ hook: (@Sendable () -> Void)?)
    func takeRenderFailure() -> Bool
}

#if DEBUG || SOLSTONE_TEST_SUPPORT
public protocol MicrophoneEngineRecoveryHookable: AnyObject, Sendable {
    func setRecoveryHook(_ hook: (@Sendable () -> Void)?)
}
#endif

extension MicrophoneCaptureEngine {
    func requiresRecovery(resolvedDeviceID: AudioDeviceID?) -> Bool { true }
    func setRenderFailureHook(_ hook: (@Sendable () -> Void)?) {}
    func takeRenderFailure() -> Bool { false }
}

internal func microphoneConfigurationRequiresRecovery(isRunning: Bool, admitted: AudioDeviceID?,
    readback: AudioDeviceID?, resolved: AudioDeviceID?, formatUnchanged: Bool) -> Bool {
    guard isRunning, let admitted, let readback, let resolved,
          admitted == resolved, readback == resolved, formatUnchanged else { return true }
    return false
}

private let microphoneRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
    let engine = Unmanaged<NativeMicrophoneCaptureEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return engine.handleRender(flags: ioActionFlags, timeStamp: inTimeStamp, busNumber: inBusNumber, frameCount: inNumberFrames)
}

internal final class NativeMicrophoneCaptureEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    private let unitFactory: @Sendable () -> any MicrophoneInputUnit
    private let renderLock: os_unfair_lock_t = {
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    private var currentUnit: (any MicrophoneInputUnit)?
    private var parkedUndisposedUnit: (any MicrophoneInputUnit)?
    private var admittedDevice: AudioDeviceID?
    private var admittedFormat: AVAudioFormat?
    private var isRunningState = false
    private var renderBuffer: AVAudioPCMBuffer?
    private var onPCMCallback: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var hasUnreportedRenderFailure = false
    private var inFlightRenders: Int = 0
    private var isStoppingWait = false
    private let renderCompletionSemaphore = DispatchSemaphore(value: 0)
    private var renderFailureHook: (@Sendable () -> Void)?

    init(unitFactory: @escaping @Sendable () -> any MicrophoneInputUnit = { DefaultMicrophoneInputUnit() }) {
        self.unitFactory = unitFactory
    }

    deinit {
        renderLock.deallocate()
    }

    func setRenderFailureHook(_ hook: (@Sendable () -> Void)?) {
        os_unfair_lock_lock(renderLock)
        renderFailureHook = hook
        os_unfair_lock_unlock(renderLock)
    }

    func takeRenderFailure() -> Bool {
        os_unfair_lock_lock(renderLock)
        defer { os_unfair_lock_unlock(renderLock) }
        let failure = hasUnreportedRenderFailure
        hasUnreportedRenderFailure = false
        return failure
    }

    func requiresRecovery(resolvedDeviceID: AudioDeviceID?) -> Bool {
        os_unfair_lock_lock(renderLock)
        let isRunning = isRunningState
        let unit = currentUnit
        let admDevice = admittedDevice
        let admFormat = admittedFormat
        os_unfair_lock_unlock(renderLock)

        guard isRunning, let unit else { return true }
        let (status, readbackID) = unit.getDeviceID()
        let checkedReadback = (status == noErr) ? readbackID : nil
        let (formatStatus, currentASBD) = unit.getStreamFormat()
        let formatMatches = formatStatus == noErr && admFormat.map {
            $0.sampleRate == currentASBD.mSampleRate && $0.channelCount == currentASBD.mChannelsPerFrame
        } ?? false
        return microphoneConfigurationRequiresRecovery(
            isRunning: isRunning,
            admitted: admDevice,
            readback: checkedReadback,
            resolved: resolvedDeviceID,
            formatUnchanged: formatMatches
        )
    }

    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        // Enforce maximumUndisposedInputUnits = 1
        if let parked = parkedUndisposedUnit {
            if parked.dispose() == noErr {
                parkedUndisposedUnit = nil
            } else {
                throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit
            }
        }

        if currentUnit != nil {
            quiesceCurrentUnit()
        }

        if parkedUndisposedUnit != nil {
            throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit
        }

        let unit = unitFactory()
        let openStatus = unit.open()
        guard openStatus == noErr else {
            throw ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(openStatus)
        }

        let inputEnableStatus = unit.setInputEnabled(true)
        guard inputEnableStatus == noErr else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(inputEnableStatus)
        }

        let outputDisableStatus = unit.setOutputEnabled(false)
        guard outputDisableStatus == noErr else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(outputDisableStatus)
        }

        let setDevStatus = unit.setDeviceID(deviceID)
        guard setDevStatus == noErr else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToSetDevice(deviceID, setDevStatus)
        }

        // Readback check
        let (readStatus, readID) = unit.getDeviceID()
        guard readStatus == noErr, readID == deviceID else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.deviceIDMismatch(expected: deviceID, actual: readID)
        }

        // Format negotiation: read hardware format
        let (fmtStatus, hwASBD) = unit.getStreamFormat()
        guard fmtStatus == noErr, hwASBD.mSampleRate > 0, hwASBD.mChannelsPerFrame > 0 else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName)
        }

        // Set output stream format on bus 1 to Float32 non-interleaved
        let clientASBD = AudioStreamBasicDescription(
            mSampleRate: hwASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: hwASBD.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let setFmtStatus = unit.setStreamFormat(clientASBD)
        guard setFmtStatus == noErr else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName)
        }

        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: hwASBD.mSampleRate,
                                           channels: hwASBD.mChannelsPerFrame,
                                           interleaved: false) else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToCreateFormat
        }

        let bufferCapacity: AVAudioFrameCount = 4096
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: bufferCapacity) else {
            _ = unit.dispose()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToCreateFormat
        }

        os_unfair_lock_lock(renderLock)
        self.renderBuffer = pcmBuffer
        self.onPCMCallback = onPCM
        self.currentUnit = unit
        self.admittedDevice = deviceID
        self.admittedFormat = avFormat
        self.isRunningState = true
        self.hasUnreportedRenderFailure = false
        os_unfair_lock_unlock(renderLock)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let cbStatus = unit.setRenderCallback(microphoneRenderCallback, refCon: selfPtr)
        guard cbStatus == noErr else {
            stop()
            throw ExternalMicCapture.ExternalMicCaptureError.installTapFailed(deviceName, "setRenderCallback status \(cbStatus)")
        }

        let initStatus = unit.initialize()
        guard initStatus == noErr else {
            stop()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(initStatus)
        }

        let startStatus = unit.start()
        guard startStatus == noErr else {
            stop()
            throw ExternalMicCapture.ExternalMicCaptureError.failedToStartUnit(startStatus)
        }
    }

    fileprivate func handleRender(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                  timeStamp: UnsafePointer<AudioTimeStamp>,
                                  busNumber: UInt32,
                                  frameCount: UInt32) -> OSStatus {
        os_unfair_lock_lock(renderLock)
        guard isRunningState, let currentUnit, let renderBuffer, let onPCMCallback else {
            os_unfair_lock_unlock(renderLock)
            return noErr
        }
        guard frameCount <= renderBuffer.frameCapacity else {
            let notify = !hasUnreportedRenderFailure
            hasUnreportedRenderFailure = true
            let hook = renderFailureHook
            os_unfair_lock_unlock(renderLock)
            if notify { hook?() }
            return kAudioHardwareBadPropertySizeError
        }

        inFlightRenders += 1
        renderBuffer.frameLength = frameCount
        let abl = renderBuffer.mutableAudioBufferList
        let unit = currentUnit
        let cb = onPCMCallback
        let buf = renderBuffer
        let rate = renderBuffer.format.sampleRate
        os_unfair_lock_unlock(renderLock)

        var failureStatus: OSStatus?
        let status = unit.render(actionFlags: flags, timeStamp: timeStamp, busNumber: 1, frameCount: frameCount, data: abl)
        if status != noErr {
            failureStatus = status
        } else {
            let time = AVAudioTime(audioTimeStamp: timeStamp, sampleRate: rate)
            cb(buf, time)
        }

        os_unfair_lock_lock(renderLock)
        inFlightRenders -= 1
        let shouldSignal = (inFlightRenders == 0 && isStoppingWait)
        var hookToCall: (@Sendable () -> Void)?
        if failureStatus != nil {
            if !hasUnreportedRenderFailure {
                hasUnreportedRenderFailure = true
                hookToCall = renderFailureHook
            }
        }
        os_unfair_lock_unlock(renderLock)

        if shouldSignal {
            renderCompletionSemaphore.signal()
        }
        hookToCall?()

        return failureStatus ?? noErr
    }

    private func quiesceCurrentUnit() {
        os_unfair_lock_lock(renderLock)
        isRunningState = false
        let unitToStop = currentUnit
        currentUnit = nil
        onPCMCallback = nil
        renderBuffer = nil
        renderFailureHook = nil

        let mustWait = inFlightRenders > 0
        if mustWait {
            isStoppingWait = true
        }
        os_unfair_lock_unlock(renderLock)

        if mustWait {
            renderCompletionSemaphore.wait()
            os_unfair_lock_lock(renderLock)
            isStoppingWait = false
            os_unfair_lock_unlock(renderLock)
        }

        if let unit = unitToStop {
            _ = unit.stop()
            if unit.dispose() != noErr {
                if let parked = parkedUndisposedUnit {
                    if parked.dispose() == noErr {
                        parkedUndisposedUnit = unit
                    }
                } else {
                    parkedUndisposedUnit = unit
                }
            }
        }
    }

    func stop() {
        quiesceCurrentUnit()
    }
}
