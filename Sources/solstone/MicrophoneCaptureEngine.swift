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
    func runningReadback() -> (status: OSStatus, running: Bool, byteSize: UInt32)
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
    func runningReadback() -> (status: OSStatus, running: Bool, byteSize: UInt32) {
        (noErr, true, UInt32(MemoryLayout<UInt32>.size))
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

    func runningReadback() -> (status: OSStatus, running: Bool, byteSize: UInt32) {
        guard let unit else { return (kAudioUnitErr_Uninitialized, false, 0) }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global, 0, &running, &size)
        return (status, running != 0, size)
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
            // Rendering and the consumer's copy share this one reusable buffer.
            // Release its lease before the outer in-flight count, on every path.
            defer { lock.withLock { state.bufferBusy = false } }
            let status = unit.render(actionFlags: flags, timeStamp: timeStamp, busNumber: 1,
                                     frameCount: frameCount, data: buffer.mutableAudioBufferList)
            let hook: (@Sendable () -> Void)? = lock.withLock {
                guard status != noErr else { return nil }
                return noteFailureLocked()
            }
            if status == noErr, lock.withLock({ state.deliveryOpen }) {
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

private final class MicrophoneNativeHeld {
    let unit: any MicrophoneInputUnit
    let context: MicrophoneRenderContext
    // Mutated only by the holder of the registry slot, outside the registry lock.
    var initialized = false
    var stopped = false
    var uninitialized = false
    var disposed = false

    init(unit: any MicrophoneInputUnit, context: MicrophoneRenderContext) {
        self.unit = unit
        self.context = context
    }
}

/// One slot covers a UID from before construction until native disposal and
/// callback quiescence. Failed cleanup never vacates the slot or evicts its owner.
private final class MicrophoneNativeOwnerRegistry: @unchecked Sendable {
    static let shared = MicrophoneNativeOwnerRegistry()
    static let maximumOwners = 64

    struct Reservation {
        let key: String
        let token: UUID
    }
    private enum Phase {
        case active
        case cleaning
        case parked(MicrophoneNativeHeld)
    }
    private struct Slot {
        let token: UUID
        var phase: Phase
    }
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    func reserve(_ key: String) -> Reservation? {
        let attempt: (Reservation, MicrophoneNativeHeld?)? = lock.withLock {
            if var slot = slots[key] {
                guard case let .parked(held) = slot.phase else { return nil }
                slot.phase = .cleaning
                slots[key] = slot
                return (Reservation(key: key, token: slot.token), held)
            }
            guard slots.count < Self.maximumOwners else { return nil }
            let token = UUID()
            slots[key] = Slot(token: token, phase: .active)
            return (Reservation(key: key, token: token), nil)
        }
        guard let (reservation, held) = attempt else { return nil }
        guard let held else { return reservation }
        let released = releaseNativeOwner(held)
        lock.withLock {
            guard slots[key]?.token == reservation.token else { return }
            slots[key]?.phase = released ? .active : .parked(held)
        }
        return released ? reservation : nil
    }

    func retire(_ reservation: Reservation, _ held: MicrophoneNativeHeld) -> Bool {
        let claimed = lock.withLock { () -> Bool in
            guard var slot = slots[reservation.key], slot.token == reservation.token,
                  case .active = slot.phase else { return false }
            slot.phase = .cleaning
            slots[reservation.key] = slot
            return true
        }
        guard claimed else { return false }
        let released = releaseNativeOwner(held)
        lock.withLock {
            guard slots[reservation.key]?.token == reservation.token else { return }
            if released {
                slots.removeValue(forKey: reservation.key)
            } else {
                slots[reservation.key]?.phase = .parked(held)
            }
        }
        return released
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    func unresolvedCount(_ key: String) -> Int {
        lock.withLock {
            guard let slot = slots[key] else { return 0 }
            if case .parked = slot.phase { return 1 }
            return 0
        }
    }
    func reset() {
        // Tests must release their fake failures. Never drop a native owner merely
        // to reset a counter; the callback's retained refCon still belongs to it.
        let keys = lock.withLock { Array(slots.keys) }
        for key in keys {
            let attempt: (Reservation, MicrophoneNativeHeld)? = lock.withLock {
                guard var slot = slots[key], case let .parked(held) = slot.phase else { return nil }
                slot.phase = .cleaning
                slots[key] = slot
                return (Reservation(key: key, token: slot.token), held)
            }
            guard let (reservation, held) = attempt else { continue }
            let released = releaseNativeOwner(held)
            lock.withLock {
                guard slots[key]?.token == reservation.token else { return }
                if released { slots.removeValue(forKey: key) }
                else { slots[key]?.phase = .parked(held) }
            }
        }
    }
    #endif
}

/// Stops, uninitializes, and disposes outside any registry or context lock.
/// A failed step leaves the owner intact for a later reclaim.
private func releaseNativeOwner(_ held: MicrophoneNativeHeld) -> Bool {
    let context = held.context
    context.closeDelivery()
    guard context.waitUntilIdle() else { return false }
    if held.initialized && !held.stopped {
        guard held.unit.stop() == noErr else { return false }
        held.stopped = true
        guard context.waitUntilIdle() else { return false }
    }
    if held.initialized && !held.uninitialized {
        guard held.unit.uninitialize() == noErr else { return false }
        held.uninitialized = true
        guard context.waitUntilIdle() else { return false }
    }
    if !held.disposed {
        guard held.unit.dispose() == noErr else { return false }
        held.disposed = true
    }
    guard context.waitUntilIdle() else { return false }
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
internal var microphoneNativeOwnerLimitForTesting: Int {
    MicrophoneNativeOwnerRegistry.maximumOwners
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
    private var currentOwner: MicrophoneNativeHeld?
    private var currentReservation: MicrophoneNativeOwnerRegistry.Reservation?
    private var admittedDevice: AudioDeviceID?
    private var admittedFormat: AVAudioFormat?
    private var isRunningState = false
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()

    private var ownerKey: String { ownerKeyOverride ?? engineKey }

    init(unitFactory: @escaping @Sendable () -> any MicrophoneInputUnit = { DefaultMicrophoneInputUnit() }) {
        self.unitFactory = unitFactory
    }

    deinit {
        _ = retireCurrent()
    }

    func setNativeOwnerKey(_ key: String) {
        lifecycleLock.withLock {
            stateLock.withLock {
                if currentOwner == nil && !key.isEmpty { ownerKeyOverride = key }
            }
        }
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let snapshot = stateLock.withLock { (isRunningState, currentUnit, admittedDevice, admittedFormat) }
        guard snapshot.0, let unit = snapshot.1 else { return true }
        let bound = unit.getBoundDevice()
        let client = unit.getClientStreamFormat()
        let running = unit.runningReadback()
        let readback = (bound.status == noErr && bound.byteSize == UInt32(MemoryLayout<AudioDeviceID>.size)) ? bound.deviceID : nil
        let formatMatches = client.status == noErr
            && client.byteSize == UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            && snapshot.3.map {
                $0.sampleRate == client.format.mSampleRate && $0.channelCount == client.format.mChannelsPerFrame
            } ?? false
        return microphoneConfigurationRequiresRecovery(
            isRunning: running.status == noErr && running.byteSize == UInt32(MemoryLayout<UInt32>.size) && running.running,
            admitted: snapshot.2,
            readback: readback,
            resolved: resolvedDeviceID,
            formatUnchanged: formatMatches
        )
    }

    func start(deviceID: AudioDeviceID, deviceName: String,
               onPCM: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if currentUnit != nil {
            guard retireCurrent() else { throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit }
        }
        guard let reservation = MicrophoneNativeOwnerRegistry.shared.reserve(ownerKey) else {
            throw ExternalMicCapture.ExternalMicCaptureError.failedToDisposeParkedUnit
        }

        let unit = unitFactory()
        let context = MicrophoneRenderContext()
        let owner = MicrophoneNativeHeld(unit: unit, context: context)
        let (epoch, hook) = stateLock.withLock { (armedEpoch, pendingFailureHook) }
        context.setOwnerEpoch(epoch)
        context.setFailureHook(hook)
        stateLock.withLock {
            currentUnit = unit
            currentContext = context
            currentOwner = owner
            currentReservation = reservation
        }

        func abandon(_ error: Error) throws -> Never {
            _ = MicrophoneNativeOwnerRegistry.shared.retire(reservation, owner)
            stateLock.withLock {
                currentUnit = nil
                currentContext = nil
                currentOwner = nil
                currentReservation = nil
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
        guard fmtStatus == noErr, nativeMicrophoneFormatIsSupported(hwASBD) else {
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
        owner.initialized = true
        let startStatus = unit.start()
        guard startStatus == noErr else { try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToStartUnit(startStatus)) }

        let bound = unit.getBoundDevice()
        guard bound.status == noErr, bound.byteSize == UInt32(MemoryLayout<AudioDeviceID>.size), bound.deviceID == deviceID else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.deviceIDMismatch(expected: deviceID, actual: bound.deviceID))
        }
        let running = unit.runningReadback()
        guard running.status == noErr, running.byteSize == UInt32(MemoryLayout<UInt32>.size), running.running else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.failedToStartUnit(
                running.status == noErr ? kAudioUnitErr_Uninitialized : running.status))
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
              slice.frames > 0, slice.frames <= 16_384,
              nativeMicrophoneBufferBytes(frames: slice.frames, format: client.format) != nil else {
            try abandon(ExternalMicCapture.ExternalMicCaptureError.invalidFormat(deviceName))
        }
        let format: AVAudioFormat?
        if client.format.mChannelsPerFrame > 2 {
            // The channel-count convenience initializer cannot infer arbitrary
            // interface layouts. Preserve HAL's observable ordinal order.
            if let layout = AVAudioChannelLayout(layoutTag:
                kAudioChannelLayoutTag_DiscreteInOrder | client.format.mChannelsPerFrame) {
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: client.format.mSampleRate, interleaved: false, channelLayout: layout)
            } else { format = nil }
        } else {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: client.format.mSampleRate, channels: client.format.mChannelsPerFrame, interleaved: false)
        }
        guard let avFormat = format,
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
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        _ = retireCurrent()
    }

    private func retireCurrent() -> Bool {
        let snapshot = stateLock.withLock { () -> (MicrophoneNativeHeld, MicrophoneNativeOwnerRegistry.Reservation)? in
            guard let held = currentOwner, let reservation = currentReservation else { return nil }
            isRunningState = false
            admittedDevice = nil
            admittedFormat = nil
            return (held, reservation)
        }
        guard let (held, reservation) = snapshot else { return true }
        // Keep the context installed until release finishes so a callback during
        // stop can still record its failure against this owner.
        let released = MicrophoneNativeOwnerRegistry.shared.retire(reservation, held)
        stateLock.withLock {
            currentUnit = nil
            currentContext = nil
            currentOwner = nil
            currentReservation = nil
        }
        return released
    }
}

private func clientFormatMatches(_ format: AudioStreamBasicDescription, expected: AudioStreamBasicDescription) -> Bool {
    nativeMicrophoneFormatIsSupported(format)
        && format.mSampleRate == expected.mSampleRate
        && format.mFormatID == kAudioFormatLinearPCM
        && format.mChannelsPerFrame == expected.mChannelsPerFrame
        && format.mBitsPerChannel == 32
        && format.mBytesPerFrame == 4
        && format.mBytesPerPacket == 4
        && format.mFramesPerPacket == 1
        && format.mFormatFlags == expected.mFormatFlags
}

/// Same rate/channel/backing policy as AudioPCMExtent. An advertised render
/// capacity is not input duration, so it does not use the one-second input guard.
private func nativeMicrophoneFormatIsSupported(_ format: AudioStreamBasicDescription) -> Bool {
    format.mSampleRate.isFinite && (1...192_000).contains(format.mSampleRate)
        && format.mChannelsPerFrame > 0 && format.mChannelsPerFrame <= 64
}

private func nativeMicrophoneBufferBytes(frames: UInt32, format: AudioStreamBasicDescription) -> Int? {
    guard frames > 0, nativeMicrophoneFormatIsSupported(format) else { return nil }
    let (samples, samplesOverflow) = Int(frames).multipliedReportingOverflow(by: Int(format.mChannelsPerFrame))
    let (bytes, bytesOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
    guard !samplesOverflow, !bytesOverflow, bytes > 0, bytes <= AudioMediaBudget.bytesPerStage else { return nil }
    return bytes
}
