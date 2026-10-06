// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import CoreMedia
import Foundation
import ObjCHelpers
import os

/// Captures audio from an external microphone and sends it to a callback
/// Used for routing external mic audio to per-source audio writers
/// The callback can be changed while the engine is running (for segment rotation)
public final class ExternalMicCapture: @unchecked Sendable {
    /// The device being captured
    public let device: AudioInputDevice

    /// Native sample rate of the device
    public let nativeSampleRate: Double

    /// Callback for processed audio buffers - can be changed while running
    /// Uses synchronized access to allow swapping during segment rotation
    public var onAudioBuffer: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onAudioBuffer
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _onAudioBuffer = newValue
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
        }
    }
    private var _onAudioBuffer: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)?
    public var onCaptureError: ((Error) -> Void)? {
        get { callbackLock.withLock { _onCaptureError } }
        set { callbackLock.withLock { _onCaptureError = newValue } }
    }
    private var _onCaptureError: ((Error) -> Void)?
    private var _queuedAudio: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?
    private var _admissionGate: ((() -> Void) -> Bool)?
    private var _rawAdmissionError: ((Error) -> Void)?
    private var budget = AudioMediaBudget()
    public var mediaBudget: AudioMediaBudget { callbackLock.withLock { budget } }
    internal func useMediaBudget(_ value: AudioMediaBudget) {
        callbackLock.withLock {
            precondition(budget.snapshot.stages[AudioMediaBudget.Stage.raw.rawValue].jobs == 0)
            budget = value
        }
    }
    private let deliveryLedger = AudioDeliveryLedger()
    private var drainGeneration: UInt64 = 0
    private var mediaSinceBoundary = false
    private var conversionFence: (generation: UInt64, fence: AudioCaptureDrainFence)?
    private var observationFence: (generation: UInt64, fence: AudioCaptureDrainFence)?
    private struct Destinations: @unchecked Sendable {
        let audio: ((AVAudioPCMBuffer, CMTime) -> Void)?
        let error: ((Error) -> Void)?
        var queuedAudio: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)? = nil
        var admissionGate: ((() -> Void) -> Bool)? = nil
        var rawError: ((Error) -> Void)? = nil
    }
    public func setCallbacks(audio: ((AVAudioPCMBuffer, CMTime) -> Void)?, error: ((Error) -> Void)?) {
        callbackLock.withLock {
            _onAudioBuffer = audio; _onCaptureError = error
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
        }
    }
    internal func setQueuedCallbacks(audio: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?,
                                     error: ((Error) -> Void)?, rawError: ((Error) -> Void)?,
                                     admissionGate: ((() -> Void) -> Bool)?) {
        callbackLock.withLock {
            _onAudioBuffer = nil; _queuedAudio = audio; _onCaptureError = error
            _rawAdmissionError = rawError; _admissionGate = admissionGate
        }
    }
    private var running = false
    private var captureRequested = false
    public var isCapturing: Bool { callbackLock.withLock { running } }
    private let callbackLock = NSLock()

    private var engine: any MicrophoneCaptureEngine
    private let engineFactory: @Sendable () -> any MicrophoneCaptureEngine
    private let resolveDeviceID: @Sendable (String) -> AudioDeviceID?
    private let recoveryDelay: @Sendable (TimeInterval) -> Void
    private var activeEngineObject: AnyObject
    private var engineEpoch: UInt64 = 0
    private var requestedEpoch: UInt64 = 0
    private var recoveryAdmitted = false
    private var recoveryExhausted = false
    private var attemptedStart = false
    private var boundDeviceID: AudioDeviceID?
    internal var currentDeviceID: AudioDeviceID? { callbackLock.withLock { boundDeviceID } }
    private let writerQueue = DispatchQueue(label: "app.solstone.extmic.writer", qos: .userInitiated)
    private let verbose: Bool

    /// Cached audio converter for format conversion (expensive to create)
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private var bufferClock = MicrophoneBufferClock()
    private var conversionOrigin: CMTime?
    private var emittedFrames: Int64 = 0
    private var processingEpoch: UInt64?
    private var processingFormat: AVAudioFormat?
    private var conversionDestination: Destinations?

    private var isRunning: Bool {
        get { isCapturing }
        set { callbackLock.withLock { running = newValue } }
    }
    #if DEBUG || SOLSTONE_TEST_SUPPORT
    /// Test-only: records teardown call order ("engine.stop", "removeTap").
    /// Mutated only on writerQueue inside teardownEngine(). Excluded from shipping builds.
    internal private(set) var _teardownTraceForTesting: [String] = []
    private var conversionStatusForTesting: AVAudioConverterOutputStatus?
    internal var _conversionStatusForTesting: AVAudioConverterOutputStatus? {
        writerQueue.sync { conversionStatusForTesting }
    }
    #endif
    private var receivedFirstBuffer = false
    private var recordingStartTime: Date?
    private var firstBufferTime: CMTime?
    private var bufferCount: Int = 0
    private var lastBufferLogTime: Date?

    /// Gain multiplier to boost mic audio (1.0 to 8.0)
    public var gainMultiplier: Float {
        get { callbackLock.withLock { storedGain } }
        set { callbackLock.withLock { storedGain = newValue.isFinite ? max(1, min(8, newValue)) : 1 } }
    }
    private var storedGain: Float = 2

    /// Target sample rate for output (48kHz standard)
    private let targetSampleRate: Double = 48_000

    /// Creates a new external mic capture
    /// - Parameters:
    ///   - device: The audio input device to capture from
    ///   - gain: Gain multiplier for mic audio (1.0 to 8.0). Default: 2.0
    ///   - verbose: Enable verbose logging
    public convenience init(device: AudioInputDevice, gain: Float = 2.0, verbose: Bool = false) {
        self.init(device: device, gain: gain, verbose: verbose,
            engineFactory: { NativeMicrophoneCaptureEngine() },
            resolveDeviceID: { MicrophoneMonitor.deviceIDForUID($0) },
            recoveryDelay: { Thread.sleep(forTimeInterval: $0) })
    }

    internal init(device: AudioInputDevice, gain: Float = 2.0, verbose: Bool = false,
                  engineFactory: @escaping @Sendable () -> any MicrophoneCaptureEngine,
                  resolveDeviceID: @escaping @Sendable (String) -> AudioDeviceID?,
                  recoveryDelay: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.device = device
        self.engineFactory = engineFactory
        self.resolveDeviceID = resolveDeviceID
        self.recoveryDelay = recoveryDelay
        let engine = engineFactory()
        self.engine = engine
        self.activeEngineObject = engine.configurationObject
        self.storedGain = gain.isFinite ? max(1.0, min(8.0, gain)) : 1
        self.verbose = verbose
        self.nativeSampleRate = device.sampleRate
        observeEngine()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func observeEngine() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: engine.configurationObject)
    }

    private func replaceEngine() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine.configurationObject)
        engine = engineFactory()
        callbackLock.withLock {
            engineEpoch &+= 1
            activeEngineObject = engine.configurationObject
            boundDeviceID = nil
        }
        // Admitted old-engine PCM remains ahead of its boundary on writerQueue.
        // The processing epoch, rather than engine replacement, owns its tail.
        observeEngine()
    }

    public func start() throws {
        let request = callbackLock.withLock { () -> UInt64 in
            // A redundant start must not revoke a configuration recovery that
            // was already admitted for this running capture.
            if captureRequested && running { return requestedEpoch }
            captureRequested = true
            requestedEpoch &+= 1
            recoveryExhausted = false
            return requestedEpoch
        }
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        _startAdmissionHookForTesting?()
        #endif
        try writerQueue.sync {
            guard !isRunning else { return }
            if attemptedStart { teardownEngine(); replaceEngine() }
            attemptedStart = true
            do { try startCapture(request: request) }
            catch {
                callbackLock.withLock {
                    if requestedEpoch == request { captureRequested = false; recoveryExhausted = true }
                }
                teardownEngine()
                if !(error is CancellationError) { onCaptureError?(error) }
                throw error
            }
        }
    }

    private func startCapture(request: UInt64) throws {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard callbackLock.withLock({ captureRequested && requestedEpoch == request }) else { throw CancellationError() }
        guard let currentID = resolveDeviceID(device.uid) else { throw ExternalMicCaptureError.deviceUnavailable(device.uid) }
        let epoch = callbackLock.withLock { engineEpoch }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false) else { throw ExternalMicCaptureError.failedToCreateFormat }
        try engine.start(deviceID: currentID, deviceName: device.name) { [weak self] buffer, when in
            self?.handleAudioBuffer(buffer, when: MicrophoneBufferTime(when), monoFormat: monoFormat, engineEpoch: epoch)
        }
        let committed = callbackLock.withLock { () -> Bool in
            guard captureRequested && requestedEpoch == request else { return false }
            running = true; boundDeviceID = currentID
            return true
        }
        guard committed else { throw CancellationError() }
        Logger.audio.info("Started external mic capture: \(self.device.name, privacy: .public), deviceID \(currentID, privacy: .public)")
    }

    private func teardownEngine() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        engine.stop()
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        _teardownTraceForTesting.append("engine.stop")
        #endif
        try? engine.removeTap()
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        _teardownTraceForTesting.append("removeTap")
        #endif
        callbackLock.withLock { running = false }
    }

    public func stop() {
        callbackLock.withLock { captureRequested = false; requestedEpoch &+= 1 }
        writerQueue.sync {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine.configurationObject)
            teardownEngine()
            finishConversionStream()
        }
        if verbose { Logger.audio.debug("Stopped external mic capture: \(self.device.name, privacy: .public)") }
    }

    @objc private func handleConfigChange(_ notification: Notification) {
        guard let origin = notification.object as AnyObject? else { return }
        callbackLock.withLock {
            guard captureRequested, origin === activeEngineObject, !recoveryAdmitted, !recoveryExhausted else { return }
            recoveryAdmitted = true
            let request = requestedEpoch
            let destination = Destinations(audio: _onAudioBuffer, error: _onCaptureError)
            drainGeneration &+= 1
            // Recovery admission and its observation barrier share this lock.
            // A cached no-media drain must not overtake a newly queued recovery.
            writerQueue.async { [weak self] in
                guard let self else { return }
                defer { self.callbackLock.withLock { self.recoveryAdmitted = false } }
                guard self.callbackLock.withLock({ self.captureRequested && self.requestedEpoch == request }) else { return }
                self.teardownEngine()
                for delay in [0.0, 0.2, 0.5] {
                    if delay > 0 { self.recoveryDelay(delay) }
                    guard self.callbackLock.withLock({ self.captureRequested && self.requestedEpoch == request }) else { return }
                    self.replaceEngine()
                    do {
                        try self.startCapture(request: request)
                        Logger.audio.notice("Microphone recovered after configuration change")
                        return
                    } catch {
                        self.teardownEngine()
                        guard self.callbackLock.withLock({ self.captureRequested && self.requestedEpoch == request }) else { return }
                        let errorDestination = self.callbackLock.withLock { self._onCaptureError ?? destination.error }
                        errorDestination?(error)
                        Logger.audio.error("Microphone configuration recovery failed: \(error, privacy: .public)")
                    }
                }
                self.callbackLock.withLock {
                    if self.captureRequested && self.requestedEpoch == request { self.recoveryExhausted = true }
                }
            }
        }
    }

    /// Returns how long the mic has been recording (from first buffer to now)
    public var recordingDuration: TimeInterval {
        guard let start = callbackLock.withLock({ recordingStartTime }) else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Private

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, when: MicrophoneBufferTime,
                                   monoFormat: AVAudioFormat, engineEpoch admittedEpoch: UInt64? = nil) {
        // Snapshot and queue admission share the detach lock. The subsequent
        // drain barrier therefore includes every admitted old-segment buffer.
        // Selection publication takes the selection lock before callbackLock.
        // Obtain that gate before touching admission so the order never inverts.
        let gate = callbackLock.withLock { _admissionGate }
        let operation = { [self] in
            var rejected: (Destinations, Error)?
            callbackLock.withLock {
                if let admittedEpoch {
                    guard captureRequested, admittedEpoch == engineEpoch else { return }
                }
                let destination = Destinations(audio: _onAudioBuffer, error: _onCaptureError,
                    queuedAudio: _queuedAudio, admissionGate: _admissionGate, rawError: _rawAdmissionError)
                guard destination.audio != nil || destination.queuedAudio != nil else { return }
                guard buffer.frameLength > 0 else { return }
                guard let extent = AudioPCMExtent(buffer),
                      let lease = budget.reserve(.raw, bytes: extent.bytes, equivalentFrames: extent.equivalentFrames) else {
                    rejected = (destination, NSError(domain: "SolstoneAudioAdmission", code: 1))
                    return
                }
#if DEBUG || SOLSTONE_TEST_SUPPORT
                if _copyAdmissionForTesting?(extent.bytes) == false {
                    lease.release(); rejected = (destination, NSError(domain: "SolstoneAudioAdmission", code: 2)); return
                }
#endif
                guard let bufferCopy = Self.copyPCMBuffer(buffer) else {
                    lease.release(); rejected = (destination, NSError(domain: "SolstoneAudioAdmission", code: 2))
                    return
                }
                let work = AudioRawPCMWork(buffer: bufferCopy, lease: lease)
                mediaSinceBoundary = true
                drainGeneration &+= 1
                writerQueue.async { [weak self] in
                    var temporary: AudioMediaLease?
                    autoreleasepool {
                        if let buffer = work.buffer {
                            self?.processAndSend(buffer: buffer, when: when, monoFormat: monoFormat,
                                epoch: admittedEpoch ?? 0, destination: destination, budget: work.lease.budget,
                                temporaryLease: &temporary)
                        }
                    }
                    temporary?.release()
                    work.release()
                }
            }
            // rawError commits only bounded writer evidence; it is already
            // revision-qualified and runs after callbackLock was released.
            if let (destination, error) = rejected { (destination.rawError ?? destination.error)?(error) }
        }
        if let gate { _ = gate(operation) } else { operation() }
    }

    /// Copy the actual layout, including integer and interleaved hardware PCM.
    internal static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            let size = Int(source[index].mDataByteSize)
            guard size <= Int(destination[index].mDataByteSize), source[index].mNumberChannels == destination[index].mNumberChannels else { return nil }
            if size > 0 {
                guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
                memcpy(dst, src, size)
            }
        }
        return copy
    }

    public func drain() async {
        await makeDrainFence(observeWriters: true).wait()
    }

    internal func drainConversion() async {
        await makeDrainFence(observeWriters: false).wait()
    }

    private func makeDrainFence(observeWriters: Bool) -> AudioCaptureDrainFence {
        callbackLock.withLock {
            let existing = observeWriters ? observationFence : conversionFence
            if let existing, existing.generation == drainGeneration { return existing.fence }
            let fence = AudioCaptureDrainFence()
            if observeWriters { observationFence = (drainGeneration, fence) }
            else { conversionFence = (drainGeneration, fence) }
            writerQueue.async { [self] in
                if observeWriters { fence.observation = deliveryLedger.observation() }
                #if DEBUG || SOLSTONE_TEST_SUPPORT
                if observeWriters { _observationQueuedForTesting?() }
                #endif
                fence.signal.complete()
            }
            return fence
        }
    }

    /// Admission detachment is the cutoff, independently of queue/encoder waits.
    /// EOS runs after every already admitted buffer and retains its old callback.
    @discardableResult
    internal func detachForBoundary() -> CMTime {
        callbackLock.withLock {
            _onAudioBuffer = nil; _onCaptureError = nil
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
            let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
            if mediaSinceBoundary {
                mediaSinceBoundary = false
                drainGeneration &+= 1
                writerQueue.async { [self] in finishConversionStream() }
            }
            return cutoff
        }
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _suspendProcessingForTesting() { isRunning = true; writerQueue.suspend() }
    internal func _resumeProcessingForTesting() { writerQueue.resume() }
    private var testSampleCursor: Int64 = 0
    private var testHostOrigin = mach_absolute_time()
    internal func _enqueueForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat? = nil, when: AVAudioTime? = nil) {
        let captured = when ?? AVAudioTime(hostTime: testHostOrigin + AVAudioTime.hostTime(forSeconds: Double(testSampleCursor) / buffer.format.sampleRate),
            sampleTime: testSampleCursor, atRate: buffer.format.sampleRate)
        testSampleCursor += Int64(buffer.frameLength)
        handleAudioBuffer(buffer, when: MicrophoneBufferTime(captured), monoFormat: targetFormat ?? buffer.format)
    }
    internal func _convertForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        writerQueue.sync { convertToMono(buffer, targetFormat: targetFormat) }
    }
    internal var _converterForTesting: AVAudioConverter? { writerQueue.sync { cachedConverter } }
    internal var _captureRequestedForTesting: Bool { callbackLock.withLock { captureRequested } }
    internal var _requestedEpochForTesting: UInt64 { callbackLock.withLock { requestedEpoch } }
    internal var _engineIdentityForTesting: ObjectIdentifier { callbackLock.withLock { ObjectIdentifier(activeEngineObject) } }
    internal var _startAdmissionHookForTesting: (@Sendable () -> Void)?
    internal var _copyAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _observationQueuedForTesting: (@Sendable () -> Void)?
    #endif

    /// Process buffer and send to callback
    private func processAndSend(buffer: AVAudioPCMBuffer, when: MicrophoneBufferTime, monoFormat: AVAudioFormat,
                                epoch: UInt64, destination: Destinations, budget: AudioMediaBudget,
                                temporaryLease: inout AudioMediaLease?) {
        // Admitted buffers retain their destination after engine retirement.
        // Revocation is fenced separately by MicrophoneCaptureManager.
        if !receivedFirstBuffer {
            receivedFirstBuffer = true
            callbackLock.withLock { recordingStartTime = Date() }
            firstBufferTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        // Track buffer count for diagnostics
        bufferCount += 1

        // Get callback with lock - if nil, discard the buffer
        let hasCallback = destination.audio != nil || destination.queuedAudio != nil

        // Log periodic status (every 60 seconds)
        let now = Date()
        if lastBufferLogTime == nil || now.timeIntervalSince(lastBufferLogTime!) >= 60 {
            Logger.audio.info("[Mic:\(self.device.name, privacy: .public)] \(self.bufferCount, privacy: .public) buffers in last minute")
            bufferCount = 0
            lastBufferLogTime = now
        }

        guard hasCallback else { return }

        guard buffer.frameLength > 0 else { return }

        if processingEpoch != epoch || processingFormat?.isEqual(buffer.format) != true {
            finishConversionStream()
            processingEpoch = epoch; processingFormat = buffer.format
        }
        guard let captured = bufferClock.admit(when, frames: Int(buffer.frameLength), sampleRate: buffer.format.sampleRate) else {
            destination.error?(NSError(domain: "SolstoneAudioTiming", code: 1))
            return
        }
        if !captured.continuous && conversionOrigin != nil { finishConversionStream(resetClock: false) }
        if conversionOrigin == nil { conversionOrigin = captured.time; emittedFrames = 0 }
        conversionDestination = destination

        // Reserve summed/resampled output before conversion allocation.
        let outputFrames = ceil(Double(buffer.frameLength) * monoFormat.sampleRate / buffer.format.sampleRate)
        let outputBytes = outputFrames * Double(monoFormat.channelCount) * 4
        let sumBytes = buffer.format.channelCount > 2 ? Double(buffer.frameLength) * 4 : 0
        guard outputBytes.isFinite, outputBytes > 0,
              outputBytes + sumBytes <= Double(AudioMediaBudget.bytesPerStage),
              let temporary = budget.reserve(.temporary, bytes: Int(outputBytes + sumBytes)) else {
            destination.error?(NSError(domain: "SolstoneAudioAdmission", code: 3))
            return
        }
        temporaryLease = temporary
        // Convert to mono if needed and resample to target rate
        guard let monoBuffer = convertToMono(buffer, targetFormat: monoFormat) else {
            destination.error?(NSError(domain: "SolstoneAudioConversion", code: 1))
            Logger.audio.warning("\(self.device.name, privacy: .public): convertToMono failed")
            return
        }

        // A converter may need more input before it can emit any PCM. This is
        // neither a capture failure nor an empty sample buffer to send downstream.
        guard monoBuffer.frameLength > 0 else { return }

        deliverConverted(monoBuffer, destination: destination)
    }

    private func deliverConverted(_ monoBuffer: AVAudioPCMBuffer, destination: Destinations) {
        guard monoBuffer.frameLength > 0, let origin = conversionOrigin else { return }
        // Apply gain to boost audio levels using vDSP (SIMD-accelerated)
        if let monoData = monoBuffer.floatChannelData {
            let monoFrameCount = Int(monoBuffer.frameLength)
            var gain = gainMultiplier
            // Multiply all samples by gain
            vDSP_vsmul(monoData[0], 1, &gain, monoData[0], 1, vDSP_Length(monoFrameCount))
            // Clamp to [-1.0, 1.0]
            var minVal: Float = -1.0
            var maxVal: Float = 1.0
            vDSP_vclip(monoData[0], 1, &minVal, &maxVal, monoData[0], 1, vDSP_Length(monoFrameCount))
        }

        let presentationTime = CMTimeAdd(origin, CMTime(value: emittedFrames, timescale: 48_000))
        emittedFrames += Int64(monoBuffer.frameLength)
        if let queued = destination.queuedAudio {
            if let receipt = queued(monoBuffer, presentationTime) { deliveryLedger.register(receipt) }
        } else { destination.audio?(monoBuffer, presentationTime) }
    }

    private func finishConversionStream(resetClock: Bool = true) {
        if let converter = cachedConverter, let destination = conversionDestination {
            var terminated = false
            // A real boundary drains the finite converter tail; taps use noDataNow.
            for _ in 0..<64 {
                guard let temporary = mediaBudget.reserve(.temporary,
                    bytes: 4096 * Int(converter.outputFormat.channelCount) * 4) else {
                    destination.error?(NSError(domain: "SolstoneAudioAdmission", code: 3)); break
                }
                let result = autoreleasepool { () -> (terminated: Bool, failed: Bool) in
                    guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096) else {
                        destination.error?(NSError(domain: "SolstoneAudioConversion", code: 3)); return (false, true)
                    }
                    var error: NSError?
                    let status = converter.convert(to: output, error: &error) { _, status in
                        status.pointee = .endOfStream; return nil
                    }
                    if status == .error || error != nil {
                        destination.error?(error ?? NSError(domain: "SolstoneAudioConversion", code: 4)); return (false, true)
                    }
                    deliverConverted(output, destination: destination)
                    return (status == .endOfStream, false)
                }
                temporary.release()
                if result.failed { break }
                if result.terminated { terminated = true; break }
            }
            if !terminated { destination.error?(NSError(domain: "SolstoneAudioConversion", code: 5)) }
            converter.reset()
        }
        cachedConverter = nil; cachedSourceFormat = nil
        conversionOrigin = nil; emittedFrames = 0; conversionDestination = nil
        if resetClock { bufferClock.reset(); processingEpoch = nil; processingFormat = nil }
    }

    /// Convert buffer to mono at target sample rate
    /// Uses cached AVAudioConverter for efficiency
    private func convertToMono(_ captured: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffer: AVAudioPCMBuffer
        if captured.format.channelCount > 2 {
            guard let summed = Self.summedMono(captured) else { return nil }
            buffer = summed
        } else {
            buffer = captured
        }
        let sourceFormat = buffer.format

        // If formats match, just return the buffer
        if sourceFormat.isEqual(targetFormat) {
            return buffer
        }

        // Validate source format
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            return nil
        }

        // Get or create converter (cache it for reuse)
        let converter: AVAudioConverter
        if let cached = cachedConverter,
           let cachedFormat = cachedSourceFormat,
           cachedFormat.isEqual(sourceFormat),
           cached.outputFormat.isEqual(targetFormat) {
            // Reuse cached converter
            converter = cached
        } else {
            // Create new converter and cache it
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                return nil
            }
            cachedConverter = newConverter
            cachedSourceFormat = sourceFormat
            converter = newConverter
            if verbose { Logger.audio.debug("\(self.device.name, privacy: .public): Created audio converter \(sourceFormat.sampleRate, privacy: .public)Hz -> \(targetFormat.sampleRate, privacy: .public)Hz") }
        }

        // Calculate output frame count
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let requiredFrames = ceil(Double(buffer.frameLength) * ratio)
        guard requiredFrames.isFinite, requiredFrames > 0,
              requiredFrames <= Double(AVAudioFrameCount.max) else { return nil }
        let outputFrameCount = AVAudioFrameCount(requiredFrames)

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            )
        else {
            return nil
        }

        var error: NSError?
        let supplied = OSAllocatedUnfairLock(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            let shouldSupply = supplied.withLock { supplied in
                guard !supplied else { return false }
                supplied = true
                return true
            }
            guard shouldSupply else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        conversionStatusForTesting = status
        #endif

        guard status != .error, error == nil else {
            return nil
        }

        return outputBuffer
    }

    /// Sum every input of a discrete multichannel interface (>2 inputs) into one
    /// mono buffer at the hardware sample rate. AVAudioConverter has no defined
    /// mono downmix for these layouts and emits all-zero samples, so the mix is
    /// done here. Inputs are summed, not averaged, so one live mic among idle
    /// preamps keeps its level; processAndSend clamps after gain.
    internal static func summedMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData
        else { return nil }

        let frames = vDSP_Length(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        vDSP_vclr(destination[0], 1, frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vadd(destination[0], 1, source[channel], vDSP_Stride(buffer.stride), destination[0], 1, frames)
        }
        return mono
    }

    /// Get the native sample rate of a device
    private static func getDeviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &sampleRate
        )

        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    public enum ExternalMicCaptureError: Error, LocalizedError {
        case deviceUnavailable(String)
        case failedToSetDevice(AudioDeviceID, OSStatus)
        case noAudioUnit
        case failedToCreateFormat
        case invalidFormat(String)
        case installTapFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case let .deviceUnavailable(uid):
                return "Microphone is no longer available: \(uid)"
            case let .failedToSetDevice(deviceID, status):
                return "Failed to set input device \(deviceID): OSStatus \(status)"
            case .noAudioUnit:
                return "Input node has no audio unit"
            case .failedToCreateFormat:
                return "Failed to create audio format"
            case let .invalidFormat(deviceName):
                return "Device '\(deviceName)' has invalid audio format (not ready)"
            case let .installTapFailed(deviceName, reason):
                return "Failed to install audio tap on '\(deviceName)': \(reason)"
            }
        }
    }
}
