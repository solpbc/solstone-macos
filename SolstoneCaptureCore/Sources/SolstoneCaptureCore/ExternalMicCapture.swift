// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import CoreMedia
import Foundation
import ObjCHelpers

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
    private let callbackLock = NSLock()

    private let engine: AVAudioEngine
    private let writerQueue = DispatchQueue(label: "com.solstone.extmic.writer", qos: .userInitiated)
    private let verbose: Bool

    private var isRunning = false
    private var isRecovering = false  // Prevents recursive recovery attempts
    private var receivedFirstBuffer = false
    private var recordingStartTime: Date?
    private var firstBufferTime: CMTime?
    private var bufferCount: Int = 0
    private var lastBufferLogTime: Date?

    /// Gain multiplier to boost mic audio
    /// 4.0 = +12dB boost
    private let gainMultiplier: Float = 4.0

    /// Target sample rate for output (48kHz standard)
    private let targetSampleRate: Double = 48_000

    /// Creates a new external mic capture
    /// - Parameters:
    ///   - device: The audio input device to capture from
    ///   - verbose: Enable verbose logging
    public init(
        device: AudioInputDevice,
        verbose: Bool = false
    ) {
        self.device = device
        self.engine = AVAudioEngine()
        self.verbose = verbose
        self.nativeSampleRate = Self.getDeviceSampleRate(device.id) ?? 48_000

        // Listen for audio configuration changes (e.g., AirPods connecting)
        // When the system default device changes, AVAudioEngine internally resets
        // even for pinned devices, so we need to re-initialize
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Start capturing from this microphone
    public func start() throws {
        try writerQueue.sync {
            guard !isRunning else { return }
            try startCapture()
        }
    }

    /// Internal start implementation (must be called on writerQueue)
    private func startCapture() throws {
        // Access inputNode first to ensure engine is initialized
        let inputNode = engine.inputNode

        // Always explicitly set the input device to pin this engine to the specific hardware.
        // Without this, AVAudioEngine follows the system default, which causes issues when
        // the default changes (e.g., AirPods connect and become the new default).
        try setInputDevice(device.id)

        // Prepare the engine - this acquires hardware resources and syncs with device
        engine.prepare()

        // Use inputFormat (what hardware actually provides) instead of outputFormat
        // outputFormat can return cached/default values, but inputFormat reflects actual hardware
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        Log.info("\(device.name): hardware format \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount)ch")

        // Validate format - newly connected devices may not be ready yet
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw ExternalMicCaptureError.invalidFormat(device.name)
        }

        // Create a mono format for output
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw ExternalMicCaptureError.failedToCreateFormat
        }

        // Install tap BEFORE starting the engine, using the HARDWARE format
        // This prevents "sampleRate == inputHWFormat.sampleRate" crashes
        let bufferSize: AVAudioFrameCount = 4096

        do {
            try ObjCExceptionCatcher.`try` {
                inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
                    [weak self] buffer, _ in
                    self?.handleAudioBuffer(buffer, monoFormat: monoFormat)
                }
            }
        } catch {
            throw ExternalMicCaptureError.installTapFailed(device.name, error.localizedDescription)
        }

        // Now start the engine with tap in place
        try engine.start()
        isRunning = true

        Log.info("Started external mic capture: \(device.name)")
    }

    /// Stop capturing
    public func stop() {
        // Stop engine first to prevent new callbacks
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        writerQueue.sync {
            guard isRunning else { return }
            isRunning = false
        }

        Log.debug("Stopped external mic capture: \(device.name)", verbose: verbose)
    }

    /// Handle audio configuration changes (e.g., AirPods connecting as default device)
    /// AVAudioEngine internally resets when the system default changes, breaking pinned devices
    @objc private func handleConfigChange() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isRunning, !self.isRecovering else { return }

            self.isRecovering = true
            Log.info("\(self.device.name): Config change detected, re-pinning to hardware...")

            // Teardown current state
            self.engine.stop()
            do {
                try ObjCExceptionCatcher.`try` {
                    self.engine.inputNode.removeTap(onBus: 0)
                }
            } catch {
                // Tap may already be gone, that's fine
            }

            // Re-initialize with our pinned device
            do {
                self.isRunning = false  // Allow startCapture to proceed
                try self.startCapture()
                Log.info("\(self.device.name): Successfully recovered after config change")
            } catch {
                Log.error("\(self.device.name): Failed to recover after config change: \(error)")
            }

            self.isRecovering = false
        }
    }

    /// Returns how long the mic has been recording (from first buffer to now)
    public var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Private

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw ExternalMicCaptureError.noAudioUnit
        }

        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw ExternalMicCaptureError.failedToSetDevice(deviceID, status)
        }

        Log.info("\(device.name): setInputDevice succeeded for deviceID \(deviceID)")
    }

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        // Record start time on first buffer
        if !receivedFirstBuffer {
            receivedFirstBuffer = true
            recordingStartTime = Date()
            firstBufferTime = CMClockGetTime(CMClockGetHostTimeClock())
            Log.info("\(device.name): Receiving audio buffers")
        }

        // Deep copy buffer
        guard let bufferCopy = deepCopy(buffer) else { return }

        // Dispatch processing to writer queue
        writerQueue.async { [weak self] in
            self?.processAndSend(buffer: bufferCopy, monoFormat: monoFormat)
        }
    }

    /// Deep copy an audio buffer
    private func deepCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength

        if let srcData = buffer.floatChannelData, let dstData = copy.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            for ch in 0..<channelCount {
                memcpy(dstData[ch], srcData[ch], frameLength * MemoryLayout<Float>.size)
            }
        }
        return copy
    }

    /// Process buffer and send to callback
    private func processAndSend(buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        guard isRunning else { return }

        // Track buffer count for diagnostics
        bufferCount += 1

        // Get callback with lock - if nil, discard the buffer
        let callback = onAudioBuffer

        // Log periodic status (every 10 seconds) - debug only
        let now = Date()
        if lastBufferLogTime == nil || now.timeIntervalSince(lastBufferLogTime!) >= 10 {
            let hasCallback = callback != nil
            Log.debug("\(device.name): buffer heartbeat - \(bufferCount) buffers, callback=\(hasCallback)", verbose: true)
            lastBufferLogTime = now
        }

        guard callback != nil else { return }

        // Convert to mono if needed and resample to target rate
        guard let monoBuffer = convertToMono(buffer, targetFormat: monoFormat) else {
            Log.warn("\(device.name): convertToMono failed")
            return
        }

        // Apply gain to boost audio levels
        if let monoData = monoBuffer.floatChannelData {
            let monoFrameCount = Int(monoBuffer.frameLength)
            for i in 0..<monoFrameCount {
                monoData[0][i] = min(1.0, max(-1.0, monoData[0][i] * gainMultiplier))
            }
        }

        // Pass absolute host clock time - SingleTrackAudioWriter needs this to
        // calculate proper offset from segment start for track alignment
        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())

        // Send to callback (use captured callback, not property, to avoid race)
        callback?(monoBuffer, presentationTime)
    }

    /// Convert buffer to mono at target sample rate
    private func convertToMono(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format

        // If formats match, just return the buffer
        if sourceFormat.sampleRate == targetFormat.sampleRate && sourceFormat.channelCount == 1 {
            return buffer
        }

        // Validate source format
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            return nil
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }

        // Calculate output frame count
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            )
        else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil else {
            return nil
        }

        return outputBuffer
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
        case failedToSetDevice(AudioDeviceID, OSStatus)
        case noAudioUnit
        case failedToCreateFormat
        case invalidFormat(String)
        case installTapFailed(String, String)

        public var errorDescription: String? {
            switch self {
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
