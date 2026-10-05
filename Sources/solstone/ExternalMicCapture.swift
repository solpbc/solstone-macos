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
        }
    }
    private var _onAudioBuffer: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)?
    public var onCaptureError: ((Error) -> Void)? {
        get { callbackLock.withLock { _onCaptureError } }
        set { callbackLock.withLock { _onCaptureError = newValue } }
    }
    private var _onCaptureError: ((Error) -> Void)?
    private struct Destinations: @unchecked Sendable {
        let audio: ((AVAudioPCMBuffer, CMTime) -> Void)?
        let error: ((Error) -> Void)?
    }
    public func setCallbacks(audio: ((AVAudioPCMBuffer, CMTime) -> Void)?, error: ((Error) -> Void)?) {
        callbackLock.withLock { _onAudioBuffer = audio; _onCaptureError = error }
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
    /// Note: Float read/write is atomic on Apple platforms, no lock needed
    public var gainMultiplier: Float {
        didSet {
            // Clamp to valid range
            if gainMultiplier < 1.0 { gainMultiplier = 1.0 }
            else if gainMultiplier > 8.0 { gainMultiplier = 8.0 }
        }
    }

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
        self.gainMultiplier = max(1.0, min(8.0, gain))
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
        cachedConverter = nil
        cachedSourceFormat = nil
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
        try engine.start(deviceID: currentID, deviceName: device.name) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, monoFormat: monoFormat, engineEpoch: epoch)
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
        }
        if verbose { Logger.audio.debug("Stopped external mic capture: \(self.device.name, privacy: .public)") }
    }

    @objc private func handleConfigChange(_ notification: Notification) {
        guard let origin = notification.object as AnyObject? else { return }
        let admitted = callbackLock.withLock { () -> (UInt64, Destinations)? in
            guard captureRequested, origin === activeEngineObject, !recoveryAdmitted, !recoveryExhausted else { return nil }
            recoveryAdmitted = true
            return (requestedEpoch, Destinations(audio: _onAudioBuffer, error: _onCaptureError))
        }
        guard let (request, destination) = admitted else { return }
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

    /// Returns how long the mic has been recording (from first buffer to now)
    public var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Private

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat, engineEpoch admittedEpoch: UInt64? = nil) {
        // Snapshot and queue admission share the detach lock. The subsequent
        // drain barrier therefore includes every admitted old-segment buffer.
        callbackLock.withLock {
            if let admittedEpoch {
                guard captureRequested, admittedEpoch == engineEpoch else { return }
            }
            let destination = Destinations(audio: _onAudioBuffer, error: _onCaptureError)
            guard destination.audio != nil else { return }
            guard let bufferCopy = Self.copyPCMBuffer(buffer) else {
                writerQueue.async { destination.error?(NSError(domain: "SolstoneAudioConversion", code: 2)) }
                return
            }
            writerQueue.async { [weak self] in
                self?.processAndSend(buffer: bufferCopy, monoFormat: monoFormat, destination: destination)
            }
        }
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
        await withCheckedContinuation { continuation in
            writerQueue.async { continuation.resume() }
        }
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _suspendProcessingForTesting() { isRunning = true; writerQueue.suspend() }
    internal func _resumeProcessingForTesting() { writerQueue.resume() }
    internal func _enqueueForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat? = nil) {
        handleAudioBuffer(buffer, monoFormat: targetFormat ?? buffer.format)
    }
    internal func _convertForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        writerQueue.sync { convertToMono(buffer, targetFormat: targetFormat) }
    }
    internal var _converterForTesting: AVAudioConverter? { writerQueue.sync { cachedConverter } }
    internal var _captureRequestedForTesting: Bool { callbackLock.withLock { captureRequested } }
    internal var _requestedEpochForTesting: UInt64 { callbackLock.withLock { requestedEpoch } }
    internal var _startAdmissionHookForTesting: (@Sendable () -> Void)?
    #endif

    /// Process buffer and send to callback
    private func processAndSend(buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat, destination: Destinations) {
        // Admitted buffers retain their destination after engine retirement.
        // Revocation is fenced separately by MicrophoneCaptureManager.
        if !receivedFirstBuffer {
            receivedFirstBuffer = true
            recordingStartTime = Date()
            firstBufferTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        // Track buffer count for diagnostics
        bufferCount += 1

        // Get callback with lock - if nil, discard the buffer
        let callback = destination.audio

        // Log periodic status (every 60 seconds)
        let now = Date()
        if lastBufferLogTime == nil || now.timeIntervalSince(lastBufferLogTime!) >= 60 {
            Logger.audio.info("[Mic:\(self.device.name, privacy: .public)] \(self.bufferCount, privacy: .public) buffers in last minute")
            bufferCount = 0
            lastBufferLogTime = now
        }

        guard callback != nil else { return }

        guard buffer.frameLength > 0 else { return }

        // Convert to mono if needed and resample to target rate
        guard let monoBuffer = convertToMono(buffer, targetFormat: monoFormat) else {
            destination.error?(NSError(domain: "SolstoneAudioConversion", code: 1))
            Logger.audio.warning("\(self.device.name, privacy: .public): convertToMono failed")
            return
        }

        // A converter may need more input before it can emit any PCM. This is
        // neither a capture failure nor an empty sample buffer to send downstream.
        guard monoBuffer.frameLength > 0 else { return }

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

        // Pass absolute host clock time - SingleTrackAudioWriter needs this to
        // calculate proper offset from segment start for track alignment
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())

        // Send to callback (use captured callback, not property, to avoid race)
        callback?(monoBuffer, presentationTime)
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
