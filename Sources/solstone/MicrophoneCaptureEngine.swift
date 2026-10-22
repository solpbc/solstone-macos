// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import ObjCHelpers

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
    func uninitialize() -> OSStatus
    func start() -> OSStatus
    func stop() -> OSStatus
    func dispose() -> OSStatus
    /// Output-scope bus 1 client format, with the size CoreAudio actually wrote.
    func getClientStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription, byteSize: UInt32)
    /// Bound device, with the size CoreAudio actually wrote.
    func getBoundDevice() -> (status: OSStatus, deviceID: AudioDeviceID, byteSize: UInt32)
    /// Supported render slice, with the size CoreAudio actually wrote.
    func maximumFramesPerSlice() -> (status: OSStatus, frames: UInt32, byteSize: UInt32)
}

extension MicrophoneInputUnit {
    func uninitialize() -> OSStatus { noErr }
    func getClientStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription, byteSize: UInt32) {
        let read = getStreamFormat()
        let size = read.status == noErr ? UInt32(MemoryLayout<AudioStreamBasicDescription>.size) : 0
        return (read.status, read.format, size)
    }
    func getBoundDevice() -> (status: OSStatus, deviceID: AudioDeviceID, byteSize: UInt32) {
        let read = getDeviceID()
        let size = read.status == noErr ? UInt32(MemoryLayout<AudioDeviceID>.size) : 0
        return (read.status, read.deviceID, size)
    }
    func maximumFramesPerSlice() -> (status: OSStatus, frames: UInt32, byteSize: UInt32) {
        (noErr, 4096, UInt32(MemoryLayout<UInt32>.size))
    }
}

internal final class DefaultMicrophoneInputUnit: MicrophoneInputUnit, @unchecked Sendable {
    private var unit: AudioUnit?
    private var hasInstance = false
    private var didInitialize = false
    private var didUninitialize = false
    private var didDispose = false

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
        let status = AudioComponentInstanceNew(component, &unit)
        if status == noErr { hasInstance = true }
        return status
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
        let bound = getBoundDevice()
        return (bound.status, bound.deviceID)
    }

    func getStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, AudioStreamBasicDescription()) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, 1, &asbd, &size)
        guard status == noErr, size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            return (status == noErr ? kAudioUnitErr_FormatNotSupported : status, AudioStreamBasicDescription())
        }
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
        // Input callback registration is global scope, element 0. Render and the
        // client format use output scope of bus 1.
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
        let status = AudioUnitInitialize(unit)
        if status == noErr { didInitialize = true }
        return status
    }

    func uninitialize() -> OSStatus {
        guard let unit else { return didDispose || !hasInstance ? noErr : kAudioUnitErr_Uninitialized }
        guard didInitialize, !didUninitialize else { return noErr }
        let status = AudioUnitUninitialize(unit)
        if status == noErr { didUninitialize = true }
        return status
    }

    func start() -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStart(unit)
    }

    func stop() -> OSStatus {
        guard let unit else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStop(unit)
    }

    /// Drops the instance only after a successful dispose. A nil handle is success
    /// only when dispose already succeeded or open never created an instance.
    func dispose() -> OSStatus {
        guard let unit else { return didDispose || !hasInstance ? noErr : kAudioUnitErr_Uninitialized }
        if didInitialize && !didUninitialize { return kAudioUnitErr_Initialized }
        let status = AudioComponentInstanceDispose(unit)
        if status == noErr {
            self.unit = nil
            didDispose = true
        }
        return status
    }

    func getBoundDevice() -> (status: OSStatus, deviceID: AudioDeviceID, byteSize: UInt32) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, 0, 0) }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &dev, &size)
        return (status, dev, size)
    }

    /// Negotiated client format is the output scope of input bus 1, not the hardware input scope.
    func getClientStreamFormat() -> (status: OSStatus, format: AudioStreamBasicDescription, byteSize: UInt32) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, AudioStreamBasicDescription(), 0) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Output, 1, &asbd, &size)
        return (status, asbd, size)
    }

    func maximumFramesPerSlice() -> (status: OSStatus, frames: UInt32, byteSize: UInt32) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, 0, 0) }
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                          kAudioUnitScope_Global, 0, &frames, &size)
        return (status, frames, size)
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
    func takeRenderFailure(matching epoch: UInt64) -> Bool
    func setNativeOwnerKey(_ key: String)
    func armFailureEpoch(_ epoch: UInt64)
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
    func takeRenderFailure(matching epoch: UInt64) -> Bool { takeRenderFailure() }
    func setNativeOwnerKey(_ key: String) {}
    func armFailureEpoch(_ epoch: UInt64) {}
}

internal func microphoneConfigurationRequiresRecovery(isRunning: Bool, admitted: AudioDeviceID?,
    readback: AudioDeviceID?, resolved: AudioDeviceID?, formatUnchanged: Bool) -> Bool {
    guard isRunning, let admitted, let readback, let resolved,
          admitted == resolved, readback == resolved, formatUnchanged else { return true }
    return false
}

/// Retained across engine replacement. The render callback's refcon is this
/// object, not the engine, so a parked unit cannot call into a freed owner.
private final class MicrophoneRenderContext: @unchecked Sendable {
    struct Snapshot {
        var deliveryOpen = false
        var inFlight = 0
        var bufferBusy = false
        var buffer: AVAudioPCMBuffer?
        var unit: (any MicrophoneInputUnit)?
        var onPCM: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        var failureHook: (@Sendable () -> Void)?
        var ownerEpoch: UInt64 = 0
        var failurePendingEpoch: UInt64?
        var stoppingWait = false
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private let idle = DispatchSemaphore(value: 0)
    private var retainOutstanding = false
    private let quiescenceSeconds: TimeInterval = 2

    func markRetained() { retainOutstanding = true }

    func setUnit(_ unit: any MicrophoneInputUnit) {
        lock.withLock { state.unit = unit }
    }

    func setOwnerEpoch(_ epoch: UInt64) {
        lock.withLock { state.ownerEpoch = epoch }
    }

    func setFailureHook(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { state.failureHook = hook }
    }

    func openDelivery(buffer: AVAudioPCMBuffer, onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        lock.withLock {
            state.buffer = buffer
            state.onPCM = onPCM
            state.deliveryOpen = true
            state.failurePendingEpoch = nil
        }
    }

    func closeDelivery() {
        lock.withLock {
            state.deliveryOpen = false
            state.onPCM = nil
        }
    }

    func takeFailure(matching epoch: UInt64) -> Bool {
        lock.withLock {
            guard state.failurePendingEpoch == epoch else { return false }
            state.failurePendingEpoch = nil
            return true
        }
    }

    func takeFailure() -> Bool {
        lock.withLock {
            guard state.failurePendingEpoch != nil else { return false }
            state.failurePendingEpoch = nil
            return true
        }
    }

    /// Every callback path, including rejection and the failure hook, holds one in-flight count.
    func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                frameCount: UInt32) -> OSStatus {
        enum Step {
            case closed
            case rejected(OSStatus, (@Sendable () -> Void)?)
            case ready((any MicrophoneInputUnit), AVAudioPCMBuffer, (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void), Double)
        }
        let step: Step = lock.withLock {
            state.inFlight += 1
            guard state.deliveryOpen, let unit = state.unit, let buffer = state.buffer, let onPCM = state.onPCM else {
                return .closed
            }
            if frameCount == 0 || frameCount > buffer.frameCapacity || state.bufferBusy {
                return .rejected(kAudioHardwareBadPropertySizeError, noteFailureLocked())
            }
            state.bufferBusy = true
            buffer.frameLength = frameCount
            return .ready(unit, buffer, onPCM, buffer.format.sampleRate)
        }
        defer { finishInFlight() }

        switch step {
        case .closed:
            return noErr
        case let .rejected(status, hook):
            hook?()
            return status
        case let .ready(unit, buffer, onPCM, rate):
            let status = unit.render(actionFlags: flags, timeStamp: timeStamp, busNumber: 1,
                                     frameCount: frameCount, data: buffer.mutableAudioBufferList)
            let hook: (@Sendable () -> Void)? = lock.withLock {
                state.bufferBusy = false
                guard status != noErr else { return nil }
                return noteFailureLocked()
            }
            if status == noErr {
                onPCM(buffer, AVAudioTime(audioTimeStamp: timeStamp, sampleRate: rate))
            }
            hook?()
            return status
        }
    }

    func waitUntilIdle() -> Bool {
        let deadline = DispatchTime.now() + quiescenceSeconds
        while true {
            let waiting = lock.withLock { () -> Bool in
                if state.inFlight == 0 {
                    state.stoppingWait = false
                    return false
                }
                state.stoppingWait = true
                return true
            }
            if !waiting { return true }
            if idle.wait(timeout: deadline) == .timedOut {
                return lock.withLock { state.inFlight == 0 }
            }
        }
    }

    /// Drops the callback's `passRetained` once stop, uninitialize, and dispose have all succeeded.
    /// Caller keeps its own strong reference until this returns.
    func balanceRetain() {
        guard retainOutstanding else { return }
        retainOutstanding = false
        Unmanaged.passUnretained(self).release()
    }

    private func noteFailureLocked() -> (@Sendable () -> Void)? {
        guard state.failurePendingEpoch == nil else { return nil }
        state.failurePendingEpoch = state.ownerEpoch
        return state.failureHook
    }

    private func finishInFlight() {
        let signal = lock.withLock { () -> Bool in
            state.inFlight -= 1
            return state.inFlight == 0 && state.stoppingWait
        }
        if signal { idle.signal() }
    }
}

private let microphoneRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let context = Unmanaged<MicrophoneRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    return context.render(flags: ioActionFlags, timeStamp: inTimeStamp, frameCount: inNumberFrames)
}

private struct MicrophoneNativeHeld {
    let unit: any MicrophoneInputUnit
    let context: MicrophoneRenderContext
    let initialized: Bool
    let started: Bool
}

/// UID-scoped native owners that outlive an engine or capture instance.
/// A failed stop, uninitialize, or dispose stays here until reclaim succeeds.
private final class MicrophoneNativeOwnerRegistry: @unchecked Sendable {
    static let shared = MicrophoneNativeOwnerRegistry()
    private let lock = NSLock()
    private var unresolved: [String: [MicrophoneNativeHeld]] = [:]

    func park(_ key: String, _ held: MicrophoneNativeHeld) {
        lock.withLock {
            unresolved[key, default: []].append(held)
        }
    }

    func reclaim(_ key: String) -> Bool {
        let held = lock.withLock { unresolved.removeValue(forKey: key) ?? [] }
        guard !held.isEmpty else { return true }
        var remaining: [MicrophoneNativeHeld] = []
        for owner in held where !releaseNativeOwner(owner) {
            remaining.append(owner)
        }
        guard remaining.isEmpty else {
            lock.withLock { unresolved[key, default: []].append(contentsOf: remaining) }
            return false
        }
        return true
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    func unresolvedCount(_ key: String) -> Int {
        lock.withLock { unresolved[key]?.count ?? 0 }
    }
    func reset() {
        lock.withLock { unresolved.removeAll() }
    }
    #endif
}

/// Stops, uninitializes, and disposes outside any registry or context lock.
/// A failed step leaves the owner intact for a later reclaim.
private func releaseNativeOwner(_ held: MicrophoneNativeHeld) -> Bool {
    let context = held.context
    context.closeDelivery()
    guard context.waitUntilIdle() else { return false }
    if held.started || held.initialized {
        let stopStatus = held.unit.stop()
        guard context.waitUntilIdle() else { return false }
        if held.started && stopStatus != noErr { return false }
    }
    if held.initialized {
        guard held.unit.uninitialize() == noErr else { return false }
        guard context.waitUntilIdle() else { return false }
    }
    guard held.unit.dispose() == noErr else { return false }
    context.balanceRetain()
    return true
}

#if DEBUG || SOLSTONE_TEST_SUPPORT
internal func microphoneNativeUnresolvedCount(_ key: String) -> Int {
    MicrophoneNativeOwnerRegistry.shared.unresolvedCount(key)
}
internal func microphoneNativeResetOwnersForTesting() {
    MicrophoneNativeOwnerRegistry.shared.reset()
}
#endif

internal final class NativeMicrophoneCaptureEngine: MicrophoneCaptureEngine, @unchecked Sendable {
    private let unitFactory: @Sendable () -> any MicrophoneInputUnit
    private let engineKey = UUID().uuidString
    private var ownerKeyOverride: String?
    private var armedEpoch: UInt64 = 0
    private var pendingFailureHook: (@Sendable () -> Void)?
    private var currentUnit: (any MicrophoneInputUnit)?
    private var currentContext: MicrophoneRenderContext?
    private var unitInitialized = false
    private var unitStarted = false
    private var admittedDevice: AudioDeviceID?
    private var admittedFormat: AVAudioFormat?
    private var isRunningState = false
    private let stateLock = NSLock()

    private var ownerKey: String { ownerKeyOverride ?? engineKey }

    init(unitFactory: @escaping @Sendable () -> any MicrophoneInputUnit = { DefaultMicrophoneInputUnit() }) {
        self.unitFactory = unitFactory
    }

    deinit {
        let held = stateLock.withLock { () -> MicrophoneNativeHeld? in
            guard let unit = currentUnit, let context = currentContext else { return nil }
            currentUnit = nil
            currentContext = nil
            return MicrophoneNativeHeld(unit: unit, context: context, initialized: unitInitialized, started: unitStarted)
        }
        if let held { MicrophoneNativeOwnerRegistry.shared.park(ownerKey, held) }
    }

    func setNativeOwnerKey(_ key: String) {
        stateLock.withLock { if !key.isEmpty { ownerKeyOverride = key } }
    }

    func armFailureEpoch(_ epoch: UInt64) {
        stateLock.withLock { armedEpoch = epoch }
    }

    func setRenderFailureHook(_ hook: (@Sendable () -> Void)?) {
        let context = stateLock.withLock { () -> MicrophoneRenderContext? in
            pendingFailureHook = hook
            return currentContext
        }
        context?.setFailureHook(hook)
    }

    func takeRenderFailure() -> Bool {
        stateLock.withLock { currentContext }?.takeFailure() ?? false
    }

    func takeRenderFailure(matching epoch: UInt64) -> Bool {
        stateLock.withLock { currentContext }?.takeFailure(matching: epoch) ?? false
    }

    func requiresRecovery(resolvedDeviceID: AudioDeviceID?) -> Bool {
        let snapshot = stateLock.withLock { (isRunningState, currentUnit, admittedDevice, admittedFormat) }
        guard snapshot.0, let unit = snapshot.1 else { return true }
        let bound = unit.getBoundDevice()
        let client = unit.getClientStreamFormat()
        let readback = (bound.status == noErr && bound.byteSize == UInt32(MemoryLayout<AudioDeviceID>.size)) ? bound.deviceID : nil
        let formatMatches = client.status == noErr
            && client.byteSize == UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            && snapshot.3.map {
                $0.sampleRate == client.format.mSampleRate && $0.channelCount == client.format.mChannelsPerFrame
            } ?? false
        return microphoneConfigurationRequiresRecovery(
            isRunning: snapshot.0,
            admitted: snapshot.2,
            readback: readback,
            resolved: resolvedDeviceID,
            formatUnchanged: formatMatches
        )
    }

    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        if currentUnit != nil {
            guard retireCurrent() else { throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit }
        }
        guard MicrophoneNativeOwnerRegistry.shared.reclaim(ownerKey) else {
            throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit
        }

        let unit = unitFactory()
        let context = MicrophoneRenderContext()
        let (epoch, hook) = stateLock.withLock { (armedEpoch, pendingFailureHook) }
        context.setOwnerEpoch(epoch)
        context.setFailureHook(hook)
        var initialized = false
        var started = false
        stateLock.withLock {
            currentUnit = unit
            currentContext = context
        }

        func abandon(_ error: Error) throws -> Never {
            let held = MicrophoneNativeHeld(unit: unit, context: context, initialized: initialized, started: started)
            if !releaseNativeOwner(held) {
                MicrophoneNativeOwnerRegistry.shared.park(ownerKey, held)
            }
            stateLock.withLock {
                currentUnit = nil
                currentContext = nil
                unitInitialized = false
                unitStarted = false
                isRunningState = false
            }
            throw error
        }

        let openStatus = unit.open()
        guard openStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(openStatus)) }
        let inputEnableStatus = unit.setInputEnabled(true)
        guard inputEnableStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(inputEnableStatus)) }
        let outputDisableStatus = unit.setOutputEnabled(false)
        guard outputDisableStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(outputDisableStatus)) }
        let setDevStatus = unit.setDeviceID(deviceID)
        guard setDevStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToSetDevice(deviceID, setDevStatus)) }

        let (readStatus, readID) = unit.getDeviceID()
        guard readStatus == noErr, readID == deviceID else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.deviceIDMismatch(expected: deviceID, actual: readID))
        }
        let (fmtStatus, hwASBD) = unit.getStreamFormat()
        guard fmtStatus == noErr, hwASBD.mSampleRate > 0, hwASBD.mChannelsPerFrame > 0 else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName))
        }
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
        guard setFmtStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName)) }

        context.setUnit(unit)
        let refCon = Unmanaged.passRetained(context).toOpaque()
        context.markRetained()
        let cbStatus = unit.setRenderCallback(microphoneRenderCallback, refCon: refCon)
        guard cbStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.installTapFailed(deviceName, "setRenderCallback status \(cbStatus)")) }

        // Delivery stays closed through initialize and start. Both may invoke the callback.
        let initStatus = unit.initialize()
        guard initStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToInitializeUnit(initStatus)) }
        initialized = true
        stateLock.withLock { unitInitialized = true }
        let startStatus = unit.start()
        guard startStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToStartUnit(startStatus)) }
        started = true
        stateLock.withLock { unitStarted = true }

        let bound = unit.getBoundDevice()
        guard bound.status == noErr, bound.byteSize == UInt32(MemoryLayout<AudioDeviceID>.size), bound.deviceID == deviceID else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.deviceIDMismatch(expected: deviceID, actual: bound.deviceID))
        }
        let client = unit.getClientStreamFormat()
        guard client.status == noErr,
              client.byteSize == UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
              clientFormatMatches(client.format, expected: clientASBD) else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName))
        }
        let slice = unit.maximumFramesPerSlice()
        guard slice.status == noErr,
              slice.byteSize == UInt32(MemoryLayout<UInt32>.size),
              slice.frames > 0, slice.frames <= 16_384 else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName))
        }
        guard let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: client.format.mSampleRate,
                                           channels: client.format.mChannelsPerFrame,
                                           interleaved: false),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(slice.frames)) else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToCreateFormat)
        }
        context.openDelivery(buffer: pcmBuffer, onPCM: onPCM)
        stateLock.withLock {
            admittedDevice = deviceID
            admittedFormat = avFormat
            isRunningState = true
        }
    }

    func stop() {
        _ = retireCurrent()
    }

    private func retireCurrent() -> Bool {
        let held = stateLock.withLock { () -> MicrophoneNativeHeld? in
            guard let unit = currentUnit, let context = currentContext else { return nil }
            isRunningState = false
            admittedDevice = nil
            admittedFormat = nil
            return MicrophoneNativeHeld(unit: unit, context: context, initialized: unitInitialized, started: unitStarted)
        }
        guard let held else { return true }
        // Keep the context installed until release finishes so a callback during
        // stop can still record its failure against this owner.
        let released = releaseNativeOwner(held)
        stateLock.withLock {
            currentUnit = nil
            currentContext = nil
            unitInitialized = false
            unitStarted = false
        }
        if released { return true }
        MicrophoneNativeOwnerRegistry.shared.park(ownerKey, held)
        return false
    }
}

private func clientFormatMatches(_ format: AudioStreamBasicDescription, expected: AudioStreamBasicDescription) -> Bool {
    format.mSampleRate == expected.mSampleRate
        && format.mFormatID == kAudioFormatLinearPCM
        && format.mChannelsPerFrame == expected.mChannelsPerFrame
        && format.mBitsPerChannel == 32
        && format.mBytesPerFrame == 4
        && format.mFramesPerPacket == 1
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
}
