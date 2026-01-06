// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import CoreMedia
import Foundation

/// Captures audio from an external microphone and sends it to a callback
/// Used for routing external mic audio to MultiTrackAudioWriter
public final class ExternalMicCapture: @unchecked Sendable {
    /// The device being captured
    public let device: AudioInputDevice

    /// Native sample rate of the device
    public let nativeSampleRate: Double

    /// Callback for processed audio buffers
    public var onAudioBuffer: ((_ buffer: AVAudioPCMBuffer, _ time: CMTime) -> Void)?

    private let engine: AVAudioEngine
    private let writerQueue = DispatchQueue(label: "com.solstone.extmic.writer", qos: .userInitiated)
    private let verbose: Bool

    private var isRunning = false
    private var receivedFirstBuffer = false
    private var recordingStartTime: Date?
    private var firstBufferTime: CMTime?

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

        // Force audioUnit initialization by accessing format
        _ = inputNode.outputFormat(forBus: 0)

        // Check if this device is the system default
        let defaultDeviceID = MicrophoneMonitor.getDefaultInputDeviceID()
        let isDefaultDevice = (device.id == defaultDeviceID)

        if isDefaultDevice {
            Log.info("\(device.name): using as system default (deviceID \(device.id))")
        } else {
            try setInputDevice(device.id)
        }

        // Get the input node format
        let inputFormat = inputNode.outputFormat(forBus: 0)
        Log.info("\(device.name): input format \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

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

        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, monoFormat: monoFormat)
        }

        // Prepare and start the engine
        engine.prepare()
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
        guard onAudioBuffer != nil else { return }

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

        // Calculate presentation time relative to first buffer
        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())
        let presentationTime: CMTime
        if let firstTime = firstBufferTime {
            presentationTime = CMTimeSubtract(currentTime, firstTime)
        } else {
            presentationTime = .zero
        }

        // Send to callback
        onAudioBuffer?(monoBuffer, presentationTime)
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

        public var errorDescription: String? {
            switch self {
            case let .failedToSetDevice(deviceID, status):
                return "Failed to set input device \(deviceID): OSStatus \(status)"
            case .noAudioUnit:
                return "Input node has no audio unit"
            case .failedToCreateFormat:
                return "Failed to create audio format"
            }
        }
    }
}
