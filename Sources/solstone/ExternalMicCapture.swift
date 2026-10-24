// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import CoreMedia
import Foundation
import ObjCHelpers
import os

/// Holds an admission failure until the caller has left the selection gate and callbackLock.
private final class AdmissionRejection: @unchecked Sendable {
    var error: Error?
    var target: ((Error) -> Void)?
}

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
            destinationRevision &+= 1
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
    private var destinationRevision: UInt64 = 0
    /// Choice and revocation. Ordinary rotation does not advance this.
    private var policyGeneration: UInt64 = 0
    /// False after a cleared or drifted choice. Mono capture without a stale choice stays true.
    private var recordingEnabled = true
    /// Policy generation of the buffer currently being handed to a writer. Writer admission re-reads it.
    private var deliveryPolicy: UInt64 = 0
    private var converterEpoch: UInt64 = 0
    private struct Destinations: @unchecked Sendable {
        let audio: ((AVAudioPCMBuffer, CMTime) -> Void)?
        let error: ((Error) -> Void)?
        var queuedAudio: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)? = nil
        var admissionGate: ((() -> Void) -> Bool)? = nil
        var rawError: ((Error) -> Void)? = nil
        var revision: UInt64 = 0
        var policy: UInt64 = 0
        var request: UInt64 = 0
        var ordinal: Int? = nil
        var conversionEpoch: UInt64 = 0
    }
    public func setCallbacks(audio: ((AVAudioPCMBuffer, CMTime) -> Void)?, error: ((Error) -> Void)?) {
        callbackLock.withLock {
            _onAudioBuffer = audio; _onCaptureError = error
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
            destinationRevision &+= 1
        }
    }
    internal func setQueuedCallbacks(audio: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?,
                                     error: ((Error) -> Void)?, rawError: ((Error) -> Void)?,
                                     admissionGate: ((() -> Void) -> Bool)?) {
        callbackLock.withLock {
            _onAudioBuffer = nil; _queuedAudio = audio; _onCaptureError = error
            _rawAdmissionError = rawError; _admissionGate = admissionGate
            destinationRevision &+= 1
        }
    }
    private var running = false
    private var captureRequested = false
    public var isCapturing: Bool { callbackLock.withLock { running } }
    private var lastTapArrival: TimeInterval = 0
    /// A configuration change is being checked; it either leaves the engine alone or reports.
    internal var isRecoveringConfiguration: Bool { callbackLock.withLock { recoveryAdmitted } }
    /// Seconds since the running engine last delivered a tap buffer (or started); nil when not running.
    internal var secondsSinceLastTap: TimeInterval? {
        callbackLock.withLock { running ? max(0, monotonicNow() - lastTapArrival) : nil }
    }
    internal func recentPeak() -> Float? {
        let now = monotonicNow()
        return peakLock.withLock { stored in
            guard let stored, now - stored.at <= 0.5 else { return nil }
            return stored.peak
        }
    }
    private let callbackLock = NSLock()

    private var engine: any MicrophoneCaptureEngine
    private let engineFactory: @Sendable () -> any MicrophoneCaptureEngine
    private let resolveDeviceID: @Sendable (String) -> AudioDeviceID?
    private var engineEpoch: UInt64 = 0
    private var requestedEpoch: UInt64 = 0
    private var recoveryAdmitted = false
    private let monotonicNow: @Sendable () -> TimeInterval
    private var _onRecoveryNeeded: (@Sendable () -> Void)?
    /// Told when this capture stopped and needs a restart. It never retries itself;
    /// the recovery manager decides when to start it again.
    internal var onRecoveryNeeded: (@Sendable () -> Void)? {
        get { callbackLock.withLock { _onRecoveryNeeded } }
        set { callbackLock.withLock { _onRecoveryNeeded = newValue } }
    }
    private var attemptedStart = false
    private var boundDeviceID: AudioDeviceID?
    internal var currentDeviceID: AudioDeviceID? { callbackLock.withLock { boundDeviceID } }
    private var deviceListeners: [HALPropertyListener] = []
    private var admittedChoice: MicrophoneChoice?
    public var currentAdmittedChoice: MicrophoneChoice? { callbackLock.withLock { admittedChoice } }
    private var admittedOrdinal: Int?
    private var admittedFingerprint: MicrophoneLayoutFingerprint?
    private let writerQueue = DispatchQueue(label: "app.solstone.extmic.writer", qos: .userInitiated)
    private let verbose: Bool

    /// Cached audio converter for format conversion (expensive to create)
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private var appliedConverterEpoch: UInt64 = 0
    private var bufferClock = MicrophoneBufferClock()
    private var conversionOrigin: CMTime?
    private var emittedFrames: Int64 = 0
    private var processingEpoch: UInt64?
    private var processingFormat: AVAudioFormat?
    private var conversionDestination: Destinations?

    private struct HandedOnPeak { var peak: Float; var at: TimeInterval }
    // It is separate so recentPeak never takes callbackLock.
    private let peakLock = OSAllocatedUnfairLock<HandedOnPeak?>(initialState: nil)

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
    private let layoutReader: @Sendable (AudioDeviceID) -> MicrophoneMonitor.MicrophoneLayoutResult

    /// Creates a new external mic capture
    /// - Parameters:
    ///   - device: The audio input device to capture from
    ///   - gain: Gain multiplier for mic audio (1.0 to 8.0). Default: 2.0
    ///   - verbose: Enable verbose logging
    public convenience init(device: AudioInputDevice, gain: Float = 2.0, verbose: Bool = false) {
        self.init(device: device, gain: gain, verbose: verbose,
            engineFactory: { NativeMicrophoneCaptureEngine() },
            resolveDeviceID: { MicrophoneMonitor.deviceIDForUID($0) },
            layoutReader: { MicrophoneMonitor.readLayout(deviceID: $0) })
    }

    internal init(device: AudioInputDevice, gain: Float = 2.0, verbose: Bool = false,
                  engineFactory: @escaping @Sendable () -> any MicrophoneCaptureEngine = { NativeMicrophoneCaptureEngine() },
                  resolveDeviceID: @escaping @Sendable (String) -> AudioDeviceID?,
                  layoutReader: @escaping @Sendable (AudioDeviceID) -> MicrophoneMonitor.MicrophoneLayoutResult = { MicrophoneMonitor.readLayout(deviceID: $0) },
                  monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.device = device
        self.engineFactory = engineFactory
        self.resolveDeviceID = resolveDeviceID
        self.layoutReader = layoutReader
        self.monotonicNow = monotonicNow
        let engine = engineFactory()
        engine.setNativeOwnerKey(device.uid)
        self.engine = engine
        self.storedGain = gain.isFinite ? max(1.0, min(8.0, gain)) : 1
        self.verbose = verbose
        self.nativeSampleRate = device.sampleRate
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        (engine as? (any MicrophoneEngineRecoveryHookable))?.setRecoveryHook { [weak self] in
            self?.triggerRecoveryCheck()
        }
        #endif
    }

    deinit {
        for listener in deviceListeners {
            listener.invalidate()
        }
    }

    private func replaceEngine() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        (engine as? (any MicrophoneEngineRecoveryHookable))?.setRecoveryHook(nil)
        #endif
        engine = engineFactory()
        engine.setNativeOwnerKey(device.uid)
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        (engine as? (any MicrophoneEngineRecoveryHookable))?.setRecoveryHook { [weak self] in
            self?.triggerRecoveryCheck()
        }
        #endif
        callbackLock.withLock {
            engineEpoch &+= 1
            boundDeviceID = nil
        }
        peakLock.withLock { $0 = nil }
    }

    @discardableResult
    public func authorizeChoice(_ choice: MicrophoneChoice?) -> Bool {
        let changed = callbackLock.withLock { () -> Bool in
            guard admittedChoice != choice else { return false }
            admittedChoice = choice
            recordingEnabled = false
            admittedOrdinal = nil
            admittedFingerprint = nil
            policyGeneration &+= 1
            converterEpoch &+= 1
            return true
        }
        if changed {
            writerQueue.async { [weak self] in
                self?.clearConverterWithoutDraining()
            }
        }
        // A repeat of the current choice still re-evaluates admission. Revocation
        // leaves the saved ordinal nil and recording disabled; a mono clear has
        // to turn recording back on without inventing a different choice.
        return checkChoiceAdmission()
    }

    @discardableResult
    public func authorizeChoice(ordinal: Int, fingerprint: MicrophoneLayoutFingerprint) -> Bool {
        authorizeChoice(MicrophoneChoice(ordinal: ordinal, fingerprint: fingerprint))
    }

    public func revokeUnacceptedAudio() {
        callbackLock.withLock {
            admittedOrdinal = nil
            admittedFingerprint = nil
            recordingEnabled = false
            policyGeneration &+= 1
            converterEpoch &+= 1
        }
        writerQueue.async { [weak self] in
            self?.clearConverterWithoutDraining()
        }
    }

    /// Writer admission holds the manager lock, then this lock, then accepts the buffer.
    internal func performIfPolicyCurrent<T>(_ body: () -> T?) -> T? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard deliveryPolicy == policyGeneration else { return nil }
        return body()
    }

    private func clearConverterWithoutDraining(for epoch: UInt64? = nil) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        let liveEpoch = epoch ?? callbackLock.withLock { converterEpoch }
        guard appliedConverterEpoch != liveEpoch else { return }
        appliedConverterEpoch = liveEpoch
        cachedConverter?.reset()
        cachedConverter = nil
        cachedSourceFormat = nil
        conversionOrigin = nil
        emittedFrames = 0
        conversionDestination = nil
        bufferClock.reset()
        processingEpoch = nil
        processingFormat = nil
    }

    private func checkChoiceAdmission() -> Bool {
        guard let currentID = resolveDeviceID(device.uid) else {
            return callbackLock.withLock { denyChoiceAdmissionLocked() }
        }
        let result = layoutReader(currentID)
        switch result {
        case .unavailable:
            return callbackLock.withLock { denyChoiceAdmissionLocked() }
        case .available(let layout):
            return callbackLock.withLock {
                if let choice = admittedChoice {
                    guard choice.fingerprint == layout.fingerprint,
                          choice.ordinal >= 0, choice.ordinal < layout.channelCount else {
                        return denyChoiceAdmissionLocked()
                    }
                    admittedOrdinal = choice.ordinal
                    admittedFingerprint = choice.fingerprint
                    recordingEnabled = true
                    return true
                }
                if layout.channelCount <= 2 {
                    admittedOrdinal = nil
                    admittedFingerprint = layout.fingerprint
                    recordingEnabled = true
                    return true
                }
                return denyChoiceAdmissionLocked()
            }
        }
    }

    /// Called with callbackLock held. A failed re-read revokes queued raw media,
    /// as well as disabling future callbacks, before another writer can accept it.
    private func denyChoiceAdmissionLocked() -> Bool {
        if recordingEnabled || admittedFingerprint != nil {
            policyGeneration &+= 1
            converterEpoch &+= 1
        }
        admittedOrdinal = nil
        admittedFingerprint = nil
        recordingEnabled = false
        return false
    }

    public func start() throws {
        let request = callbackLock.withLock { () -> UInt64 in
            // A redundant start must not revoke a configuration recovery that
            // was already admitted for this running capture.
            if captureRequested && running { return requestedEpoch }
            captureRequested = true
            requestedEpoch &+= 1
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
                    if requestedEpoch == request { captureRequested = false }
                }
                teardownEngine()
                let isChoiceNotAdmitted: Bool = {
                    if let micErr = error as? ExternalMicCaptureError, case .choiceNotAdmitted = micErr { return true }
                    return false
                }()
                if !(error is CancellationError) && !isChoiceNotAdmitted {
                    onCaptureError?(error)
                }
                throw error
            }
        }
    }

    private func startCapture(request: UInt64) throws {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        guard callbackLock.withLock({ captureRequested && requestedEpoch == request }) else { throw CancellationError() }
        guard let currentID = resolveDeviceID(device.uid) else { throw ExternalMicCaptureError.deviceUnavailable(device.uid) }
        guard checkChoiceAdmission() else {
            callbackLock.withLock {
                if requestedEpoch == request { captureRequested = false }
            }
            throw ExternalMicCaptureError.choiceNotAdmitted
        }
        let epoch = callbackLock.withLock { engineEpoch }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false) else { throw ExternalMicCaptureError.failedToCreateFormat }
        let queue = self.writerQueue
        let startingFingerprint = callbackLock.withLock { admittedFingerprint }
        engine.armFailureEpoch(epoch)
        engine.setRenderFailureHook { [weak self, queue] in
            queue.async { [weak self] in
                self?.flushRenderFailure(admittedEpoch: epoch)
            }
        }
        try engine.start(deviceID: currentID, deviceName: device.name) { [weak self] buffer, when in
            self?.handleAudioBuffer(buffer, when: MicrophoneBufferTime(when), monoFormat: monoFormat, engineEpoch: epoch)
        }
        deviceListeners = makeDeviceListeners(objectID: currentID)
        try verifyStartedLayout(deviceID: currentID, fingerprint: startingFingerprint)
        let committed = callbackLock.withLock { () -> Bool in
            guard captureRequested && requestedEpoch == request else { return false }
            running = true; boundDeviceID = currentID; lastTapArrival = monotonicNow()
            return true
        }
        guard committed else { throw CancellationError() }
        Logger.audio.info("Started external mic capture: \(self.device.name, privacy: .public), deviceID \(currentID, privacy: .public)")
    }

    internal func rebind(deviceID: AudioDeviceID, deviceName: String) throws {
        try writerQueue.sync {
            guard isRunning else { return }
            teardownEngine()
            replaceEngine()
            guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
                channels: 1, interleaved: false) else { throw ExternalMicCaptureError.failedToCreateFormat }
            guard checkChoiceAdmission() else {
                callbackLock.withLock {
                    captureRequested = false
                }
                throw ExternalMicCaptureError.choiceNotAdmitted
            }
            let epoch = callbackLock.withLock { engineEpoch }
            let queue = self.writerQueue
            let startingFingerprint = callbackLock.withLock { admittedFingerprint }
            engine.armFailureEpoch(epoch)
            engine.setRenderFailureHook { [weak self, queue] in
                queue.async { [weak self] in
                    self?.flushRenderFailure(admittedEpoch: epoch)
                }
            }
            try engine.start(deviceID: deviceID, deviceName: deviceName) { [weak self] buffer, when in
                self?.handleAudioBuffer(buffer, when: MicrophoneBufferTime(when), monoFormat: monoFormat, engineEpoch: epoch)
            }
            deviceListeners = makeDeviceListeners(objectID: deviceID)
            try verifyStartedLayout(deviceID: deviceID, fingerprint: startingFingerprint)
            callbackLock.withLock {
                running = true
                boundDeviceID = deviceID
                lastTapArrival = monotonicNow()
            }
        }
    }

    private func verifyStartedLayout(deviceID: AudioDeviceID, fingerprint: MicrophoneLayoutFingerprint?) throws {
        // Listeners are installed before this second read, closing the startup
        // window in which a same-count layout can change without a notification.
        guard resolveDeviceID(device.uid) == deviceID, checkChoiceAdmission(),
              callbackLock.withLock({ admittedFingerprint == fingerprint }) else {
            revokeUnacceptedAudio()
            teardownEngine()
            callbackLock.withLock { captureRequested = false }
            throw ExternalMicCaptureError.choiceNotAdmitted
        }
    }

    private func flushRenderFailure(admittedEpoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        // An older queued hook must not consume a replacement engine's failure.
        let current = callbackLock.withLock { captureRequested && engineEpoch == admittedEpoch }
        guard current else { return }
        guard engine.takeRenderFailure(matching: admittedEpoch) else { return }
        let errorCallback = callbackLock.withLock { _rawAdmissionError ?? _onCaptureError }
        errorCallback?(ExternalMicCaptureError.renderFailed)
    }

    private func makeDeviceListeners(objectID: AudioDeviceID) -> [HALPropertyListener] {
        let id = AudioObjectID(objectID)
        var listeners = [
            HALPropertyListener(objectID: id, selector: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                self?.triggerRecoveryCheck()
            },
            HALPropertyListener(objectID: id, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput) { [weak self] in
                self?.triggerRecoveryCheck()
            },
            HALPropertyListener(objectID: id, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                self?.triggerRecoveryCheck()
            }
        ]
        // Member reorder keeps the same device id and stream configuration. Only the aggregate lists notify.
        if device.transportType == .aggregate {
            listeners.append(HALPropertyListener(objectID: id, selector: kAudioAggregateDevicePropertyFullSubDeviceList) { [weak self] in
                self?.aggregateTopologyChanged()
            })
            listeners.append(HALPropertyListener(objectID: id, selector: kAudioAggregateDevicePropertyActiveSubDeviceList) { [weak self] in
                self?.aggregateTopologyChanged()
            })
        }
        return listeners
    }

    /// Stop admitting the old ordinal before the layout read. A matching layout admits again.
    /// A changed layout stops this capture and does not ask recovery to restart it.
    private func aggregateTopologyChanged() {
        let request = callbackLock.withLock { () -> UInt64? in
            guard captureRequested else { return nil }
            recordingEnabled = false
            admittedOrdinal = nil
            policyGeneration &+= 1
            converterEpoch &+= 1
            return requestedEpoch
        }
        guard let request else { return }
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.clearConverterWithoutDraining()
            guard self.callbackLock.withLock({ self.captureRequested && self.requestedEpoch == request }) else { return }
            if self.layoutRequiresNewChoice() {
                Logger.audio.notice("Microphone \(self.device.uid, privacy: .public) input layout no longer admits the saved choice; stopping")
                self.teardownEngine()
                self.revokeUnacceptedAudio()
                self.callbackLock.withLock {
                    if self.requestedEpoch == request { self.captureRequested = false }
                }
                return
            }
            _ = self.checkChoiceAdmission()
        }
    }

    private func teardownEngine() {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        for listener in deviceListeners {
            listener.invalidate()
        }
        deviceListeners.removeAll()
        engine.setRenderFailureHook(nil)
        engine.stop()
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        _teardownTraceForTesting.append("engine.stop")
        #endif
        callbackLock.withLock { running = false }
    }

    public func stop() {
        callbackLock.withLock { captureRequested = false; requestedEpoch &+= 1 }
        writerQueue.sync {
            teardownEngine()
            finishConversionStream()
            // The conversion tail runs before the clear.
            peakLock.withLock { $0 = nil }
        }
        if verbose { Logger.audio.debug("Stopped external mic capture: \(self.device.name, privacy: .public)") }
    }

    /// A saved fingerprint that no longer matches, an unreadable layout, or a multichannel
    /// interface without a choice. Device loss is left to the recovery path.
    private func layoutRequiresNewChoice() -> Bool {
        guard let id = resolveDeviceID(device.uid) else { return false }
        let result = layoutReader(id)
        switch result {
        case .unavailable:
            return true
        case .available(let layout):
            return callbackLock.withLock {
                if let choice = admittedChoice,
                   choice.fingerprint != layout.fingerprint || choice.ordinal < 0 || choice.ordinal >= layout.channelCount { return true }
                if layout.channelCount > 2 {
                    guard let choice = admittedChoice,
                          choice.ordinal >= 0, choice.ordinal < layout.channelCount,
                          choice.fingerprint == layout.fingerprint else { return true }
                }
                if let admittedFingerprint, admittedFingerprint != layout.fingerprint { return true }
                return false
            }
        }
    }

    internal func triggerRecoveryCheck() {
        callbackLock.withLock {
            guard captureRequested, !recoveryAdmitted else { return }
            recoveryAdmitted = true
            let request = requestedEpoch
            let admittedEngineEpoch = engineEpoch
            drainGeneration &+= 1
            writerQueue.async { [weak self] in
                guard let self else { return }
                defer { self.callbackLock.withLock { self.recoveryAdmitted = false } }
                guard self.callbackLock.withLock({ self.captureRequested && self.requestedEpoch == request &&
                    admittedEngineEpoch == self.engineEpoch }) else { return }
                if self.layoutRequiresNewChoice() {
                    Logger.audio.notice("Microphone \(self.device.uid, privacy: .public) input layout no longer admits the saved choice; stopping")
                    self.teardownEngine()
                    self.revokeUnacceptedAudio()
                    self.callbackLock.withLock {
                        if self.requestedEpoch == request { self.captureRequested = false }
                    }
                    return
                }
                guard self.engine.requiresRecovery(resolvedDeviceID: self.resolveDeviceID(self.device.uid)) else { return }
                self.teardownEngine()
                let needsRecovery = self.callbackLock.withLock { () -> (@Sendable () -> Void)? in
                    guard self.captureRequested && self.requestedEpoch == request else { return nil }
                    self.captureRequested = false; self.recoveryAdmitted = false
                    return self._onRecoveryNeeded
                }
                Logger.audio.notice("Microphone configuration changed; asking for a fresh engine")
                needsRecovery?()
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
        let arrival = monotonicNow()
        // Selection publication takes the selection lock before callbackLock.
        // Obtain that gate before touching admission so the order never inverts.
        let gate = callbackLock.withLock { () -> ((() -> Void) -> Bool)? in lastTapArrival = arrival; return _admissionGate }
        let rejected = AdmissionRejection()
        let operation = { [self] in
            callbackLock.withLock {
                if let admittedEpoch {
                    guard captureRequested, admittedEpoch == engineEpoch else { return }
                }
                guard recordingEnabled else { return }
                let destination = Destinations(audio: _onAudioBuffer, error: _onCaptureError,
                    queuedAudio: _queuedAudio, admissionGate: _admissionGate, rawError: _rawAdmissionError,
                    revision: destinationRevision, policy: policyGeneration, request: requestedEpoch,
                    ordinal: admittedOrdinal, conversionEpoch: converterEpoch)
                guard destination.audio != nil || destination.queuedAudio != nil else { return }
                guard buffer.frameLength > 0 else { return }
                guard let extent = AudioPCMExtent(buffer),
                      let lease = budget.reserve(.raw, bytes: extent.bytes, equivalentFrames: extent.equivalentFrames) else {
                    rejected.error = NSError(domain: "SolstoneAudioAdmission", code: 1)
                    rejected.target = destination.rawError ?? destination.error
                    return
                }
#if DEBUG || SOLSTONE_TEST_SUPPORT
                if _copyAdmissionForTesting?(extent.bytes) == false {
                    lease.release()
                    rejected.error = NSError(domain: "SolstoneAudioAdmission", code: 2)
                    rejected.target = destination.rawError ?? destination.error
                    return
                }
                _willCopyPCMForTesting?()
#endif
                guard let inputCopy = Self.copyPCMBuffer(buffer) else {
                    lease.release()
                    rejected.error = NSError(domain: "SolstoneAudioAdmission", code: 2)
                    rejected.target = destination.rawError ?? destination.error
                    return
                }
                let work = AudioRawPCMWork(buffer: inputCopy, lease: lease)
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
        }
        if let gate { _ = gate(operation) } else { operation() }
        // Outside the admission gate and callbackLock, so the callback can reenter selection.
        if let error = rejected.error { rejected.target?(error) }
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
        detachForBoundary(successor: nil, admissionGate: nil).cutoff
    }

    /// A rotation detaches and, in the same step, sends later audio to
    /// `successor`, so no buffer falls between the old and new destinations.
    /// The returned revision identifies that successor for `clearDestination`.
    internal func detachForBoundary(successor: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?,
                                    admissionGate: ((() -> Void) -> Bool)?) -> (cutoff: CMTime, revision: UInt64) {
        callbackLock.withLock {
            _onAudioBuffer = nil; _onCaptureError = nil
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
            let cutoff = CMClockGetTime(CMClockGetHostTimeClock())
            if mediaSinceBoundary {
                mediaSinceBoundary = false
                drainGeneration &+= 1
                writerQueue.async { [self] in finishConversionStream() }
            }
            if let successor {
                _queuedAudio = successor; _admissionGate = admissionGate
                destinationRevision &+= 1
            }
            return (cutoff, destinationRevision)
        }
    }

    /// Clears the destination only if it is still the one `revision` names.
    internal func clearDestination(ifRevision revision: UInt64) {
        callbackLock.withLock {
            guard destinationRevision == revision else { return }
            _onAudioBuffer = nil; _onCaptureError = nil
            _queuedAudio = nil; _admissionGate = nil; _rawAdmissionError = nil
            destinationRevision &+= 1
        }
    }

    #if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _suspendProcessingForTesting() { isRunning = true; writerQueue.suspend() }
    internal func _resumeProcessingForTesting() { writerQueue.resume() }
    private var testSampleCursor: Int64 = 0
    private var testHostOrigin = mach_absolute_time()
    internal func _onWriterQueueForTesting(_ body: () -> Void) {
        writerQueue.sync(execute: body)
    }
    internal func _rearmForTesting() throws {
        dispatchPrecondition(condition: .onQueue(writerQueue))
        teardownEngine()
        replaceEngine()
        let request = callbackLock.withLock { requestedEpoch }
        try startCapture(request: request)
    }
    internal func _enqueueForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat? = nil, when: AVAudioTime? = nil) {
        let captured = when ?? AVAudioTime(hostTime: testHostOrigin + AVAudioTime.hostTime(forSeconds: Double(testSampleCursor) / buffer.format.sampleRate),
            sampleTime: testSampleCursor, atRate: buffer.format.sampleRate)
        testSampleCursor += Int64(buffer.frameLength)
        handleAudioBuffer(buffer, when: MicrophoneBufferTime(captured), monoFormat: targetFormat ?? buffer.format)
    }
    internal func _convertForTesting(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        writerQueue.sync {
            clearConverterWithoutDraining()
            return convertToMono(buffer, targetFormat: targetFormat, ordinal: callbackLock.withLock { admittedOrdinal })
        }
    }
    internal var _converterForTesting: AVAudioConverter? { writerQueue.sync { cachedConverter } }
    internal var _captureRequestedForTesting: Bool { callbackLock.withLock { captureRequested } }
    internal var _requestedEpochForTesting: UInt64 { callbackLock.withLock { requestedEpoch } }
    internal var _engineIdentityForTesting: ObjectIdentifier { callbackLock.withLock { ObjectIdentifier(engine) } }
    internal var _startAdmissionHookForTesting: (@Sendable () -> Void)?
    internal var _copyAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _willCopyPCMForTesting: (@Sendable () -> Void)?
    internal var _recordingEnabledForTesting: Bool { callbackLock.withLock { recordingEnabled } }
    internal var deviceListenerSelectorsForTesting: [AudioObjectPropertySelector] {
        deviceListeners.map(\.selector)
    }
    internal func simulateDevicePropertyChangeForTesting(_ selector: AudioObjectPropertySelector) {
        deviceListeners.first { $0.selector == selector }?.simulateChangeForTesting()
    }
    internal var _conversionAdmissionForTesting: (@Sendable () -> Bool)?
    internal var _observationQueuedForTesting: (@Sendable () -> Void)?
    #endif

    /// Process buffer and send to callback
    private func processAndSend(buffer: AVAudioPCMBuffer, when: MicrophoneBufferTime, monoFormat: AVAudioFormat,
                                epoch: UInt64, destination: Destinations, budget: AudioMediaBudget,
                                temporaryLease: inout AudioMediaLease?) {
        let policyMatches = callbackLock.withLock { destination.policy == policyGeneration }
        guard policyMatches else { return }
        // Reset old policy history before establishing this buffer's clock and
        // origin. A later queued reset must not erase new-generation conversion.
        clearConverterWithoutDraining(for: destination.conversionEpoch)

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
        let sumBytes = destination.ordinal != nil ? Double(buffer.frameLength) * 4 : 0
        guard outputBytes.isFinite, outputBytes > 0,
              outputBytes + sumBytes <= Double(AudioMediaBudget.bytesPerStage),
              let temporary = budget.reserve(.temporary, bytes: Int(outputBytes + sumBytes)) else {
            destination.error?(NSError(domain: "SolstoneAudioAdmission", code: 3))
            return
        }
        temporaryLease = temporary
        // Convert to mono if needed and resample to target rate
        guard let monoBuffer = convertToMono(buffer, targetFormat: monoFormat, ordinal: destination.ordinal) else {
            destination.error?(NSError(domain: "SolstoneAudioConversion", code: 1))
            Logger.audio.warning("\(self.device.name, privacy: .public): convertToMono failed")
            return
        }

        // A converter may need more input before it can emit any PCM. This is
        // neither a capture failure nor an empty sample buffer to send downstream.
        guard monoBuffer.frameLength > 0 else { return }

        deliverConverted(monoBuffer, destination: destination)
    }

    @discardableResult
    private func deliverConverted(_ monoBuffer: AVAudioPCMBuffer, destination: Destinations) -> Bool {
        guard monoBuffer.frameLength > 0, let origin = conversionOrigin else { return false }
        // Apply gain to boost audio levels using vDSP (SIMD-accelerated)
        var peak: Float = 0
        if let monoData = monoBuffer.floatChannelData {
            let monoFrameCount = Int(monoBuffer.frameLength)
            var gain = gainMultiplier
            // Multiply all samples by gain
            vDSP_vsmul(monoData[0], 1, &gain, monoData[0], 1, vDSP_Length(monoFrameCount))
            // Clamp to [-1.0, 1.0]
            var minVal: Float = -1.0
            var maxVal: Float = 1.0
            vDSP_vclip(monoData[0], 1, &minVal, &maxVal, monoData[0], 1, vDSP_Length(monoFrameCount))
            vDSP_maxmgv(monoData[0], 1, &peak, vDSP_Length(monoFrameCount))
        }
        let deliveredPeak = peak

        let presentationTime = CMTimeAdd(origin, CMTime(value: emittedFrames, timescale: 48_000))
        deliveryPolicy = destination.policy
        if let queued = destination.queuedAudio {
            let policyMatches = callbackLock.withLock { destination.policy == policyGeneration }
            guard policyMatches else { return false }
            emittedFrames += Int64(monoBuffer.frameLength)
            guard let receipt = queued(monoBuffer, presentationTime) else { return false }
            peakLock.withLock { $0 = HandedOnPeak(peak: deliveredPeak, at: monotonicNow()) }
            deliveryLedger.register(receipt)
            return true
        } else if let audio = destination.audio {
            let policyMatches = callbackLock.withLock { destination.policy == policyGeneration }
            guard policyMatches else { return false }
            emittedFrames += Int64(monoBuffer.frameLength)
            audio(monoBuffer, presentationTime)
            peakLock.withLock { $0 = HandedOnPeak(peak: deliveredPeak, at: monotonicNow()) }
            return true
        }
        return false
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
    private func convertToMono(_ captured: AVAudioPCMBuffer, targetFormat: AVAudioFormat, ordinal: Int?) -> AVAudioPCMBuffer? {
        #if DEBUG || SOLSTONE_TEST_SUPPORT
        guard _conversionAdmissionForTesting?() != false else { return nil }
        #endif
        let buffer: AVAudioPCMBuffer
        if let ordinal {
            guard let extracted = Self.extractChosenChannel(captured, ordinal: ordinal) else { return nil }
            buffer = extracted
        } else {
            guard captured.format.channelCount <= 2 else { return nil }
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

    /// Extract the chosen channel from a multi-channel buffer at exact amplitude.
    /// Handles both planar (non-interleaved) and interleaved Float32 PCM.
    public static func extractChosenChannel(_ buffer: AVAudioPCMBuffer, ordinal: Int) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        guard ordinal >= 0, ordinal < channelCount else { return nil }
        let frames = buffer.frameLength
        guard frames > 0 else { return nil }

        let abl = buffer.mutableAudioBufferList
        let numBuffers = Int(abl.pointee.mNumberBuffers)
        let bufListPtr = UnsafeMutableAudioBufferListPointer(abl)

        if buffer.format.isInterleaved {
            guard numBuffers == 1, bufListPtr[0].mNumberChannels == UInt32(channelCount) else { return nil }
        } else {
            guard numBuffers == channelCount else { return nil }
            for b in bufListPtr {
                guard b.mNumberChannels == 1 else { return nil }
            }
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
        let destination = mono.floatChannelData?[0] else {
            return nil
        }
        mono.frameLength = frames

        if buffer.format.isInterleaved {
            guard let sourceData = buffer.floatChannelData?[0] else { return nil }
            let stride = buffer.stride
            guard stride >= channelCount else { return nil }
            for frame in 0..<Int(frames) {
                destination[frame] = sourceData[frame * stride + ordinal]
            }
        } else {
            guard let channelPointers = buffer.floatChannelData else { return nil }
            let sourceChannel = channelPointers[ordinal]
            let stride = buffer.stride
            if stride == 1 {
                memcpy(destination, sourceChannel, Int(frames) * MemoryLayout<Float>.size)
            } else {
                for frame in 0..<Int(frames) {
                    destination[frame] = sourceChannel[frame * stride]
                }
            }
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
        case failedToInitializeUnit(OSStatus)
        case failedToStartUnit(OSStatus)
        case failedToDisposeParkedUnit
        case deviceIDMismatch(expected: AudioDeviceID, actual: AudioDeviceID)
        case renderFailed
        case choiceNotAdmitted

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
            case let .failedToInitializeUnit(status):
                return "Failed to initialize audio unit: OSStatus \(status)"
            case let .failedToStartUnit(status):
                return "Failed to start audio unit: OSStatus \(status)"
            case .failedToDisposeParkedUnit:
                return "A previously undisposed audio unit is still pending disposal"
            case let .deviceIDMismatch(expected, actual):
                return "Device ID mismatch: expected \(expected), readback \(actual)"
            case .renderFailed:
                return "Audio unit render failed"
            case .choiceNotAdmitted:
                return "Microphone choice not admitted"
            }
        }
    }
}
