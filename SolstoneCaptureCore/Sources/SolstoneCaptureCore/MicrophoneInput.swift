// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Accelerate
@preconcurrency import AVFAudio
import CoreAudio
import Foundation

/// Represents a single microphone being captured via AVAudioEngine
public final class MicrophoneInput: @unchecked Sendable {
    /// The device being captured
    public let device: AudioInputDevice

    /// Index of this mic in the multi-mic array (for file naming)
    public let deviceIndex: Int

    /// Native sample rate of the device
    public let nativeSampleRate: Double

    private let engine: AVAudioEngine
    private let silenceDetector: SilenceDetector
    private var audioWriter: MicAudioWriter?
    private let outputURL: URL
    private let writerQueue = DispatchQueue(label: "com.solstone.mic.writer", qos: .userInitiated)
    private let verbose: Bool

    private var isRunning = false
    private var receivedFirstBuffer = false
    private var recordingStartTime: Date?

    /// Gain multiplier to boost mic audio
    /// 4.0 = +12dB boost
    private let gainMultiplier: Float = 4.0

    /// Creates a new microphone input
    /// - Parameters:
    ///   - device: The audio input device to capture from
    ///   - deviceIndex: Index for file naming
    ///   - outputURL: URL to write the audio file
    ///   - silenceConfig: Configuration for silence detection
    ///   - verbose: Enable verbose logging
    public init(
        device: AudioInputDevice,
        deviceIndex: Int,
        outputURL: URL,
        silenceConfig: SilenceDetectionConfig = SilenceDetectionConfig(),
        verbose: Bool = false
    ) {
        self.device = device
        self.deviceIndex = deviceIndex
        self.outputURL = outputURL
        self.engine = AVAudioEngine()
        self.silenceDetector = SilenceDetector(config: silenceConfig)
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
            // For the default device, don't call setInputDevice - AVAudioEngine will use it
            Log.info("\(device.name): using as system default (deviceID \(device.id))")
        } else {
            // For non-default devices, explicitly set the input device
            try setInputDevice(device.id)
        }

        // Get the input node format (this will be the device's native format)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        Log.info("\(device.name): input format \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Create audio writer at 48kHz (our standard output rate)
        let targetSampleRate: Double = 48_000
        audioWriter = try MicAudioWriter(url: outputURL, sampleRate: targetSampleRate, verbose: verbose)

        // Create a mono format for writing
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw MicrophoneInputError.failedToCreateFormat
        }

        // Install tap on input node
        // Use a reasonable buffer size (4096 samples at input rate)
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, monoFormat: monoFormat)
        }

        // Prepare and start the engine
        engine.prepare()
        try engine.start()
        isRunning = true

        Log.info("Started mic capture: \(device.name), engine.isRunning=\(engine.isRunning)")
    }

    /// Stop capturing and finalize the file
    public func stop() {
        // Stop engine first to prevent new callbacks
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Flush pending writes and clean up on writer queue
        writerQueue.sync {
            guard isRunning else { return }
            isRunning = false
            audioWriter?.finish()
            audioWriter = nil
        }

        Log.debug("Stopped capture for: \(device.name)", verbose: verbose)
    }

    /// Rotates the output file to a new URL without stopping the engine
    /// This enables gapless recording across segment boundaries
    /// Returns: (url, hadAudio, duration) for the previous segment
    public func rotate(to newURL: URL) throws -> (url: URL, hadAudio: Bool, duration: TimeInterval) {
        return try writerQueue.sync {
            let oldWriter = audioWriter
            let oldHadAudio = silenceDetector.hadMeaningfulAudio
            let oldDuration = recordingDuration

            // Create the new writer first to ensure it's valid before dropping the old one
            let targetSampleRate: Double = 48_000
            let newWriter = try MicAudioWriter(url: newURL, sampleRate: targetSampleRate, verbose: verbose)

            // Swap writers and reset for new segment
            audioWriter = newWriter
            silenceDetector.reset()
            recordingStartTime = Date()  // Reset start time for new segment

            // Finalize old writer (still on writerQueue, so pending writes complete first)
            let oldURL = oldWriter?.url ?? outputURL
            oldWriter?.finish()

            Log.info("\(device.name): Rotated audio file to \(newURL.lastPathComponent)")

            return (oldURL, oldHadAudio, oldDuration)
        }
    }

    /// Returns true if this mic had meaningful audio
    public var hadMeaningfulAudio: Bool {
        silenceDetector.hadMeaningfulAudio
    }

    /// Returns the output file URL
    public var fileURL: URL {
        outputURL
    }

    /// Returns the total duration of active (non-silent) audio
    public var activeDuration: TimeInterval {
        silenceDetector.activeDuration
    }

    /// Returns the time when recording started (first buffer received)
    public var startTime: Date? {
        recordingStartTime
    }

    /// Returns how long the mic has been recording (from first buffer to now)
    public var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Private

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        // Get the audio unit from the input node
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw MicrophoneInputError.noAudioUnit
        }

        // Set the HAL audio unit's input device
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
            throw MicrophoneInputError.failedToSetDevice(deviceID, status)
        }

        Log.info("\(device.name): setInputDevice succeeded for deviceID \(deviceID)")
    }

    /// Counter for periodic RMS logging
    private var bufferCount = 0

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        // Log first buffer received and record start time
        if !receivedFirstBuffer {
            receivedFirstBuffer = true
            recordingStartTime = Date()
            Log.info("\(device.name): Receiving audio buffers")
        }

        // Deep copy buffer (fast, memory-only operation safe for real-time thread)
        guard let bufferCopy = deepCopy(buffer) else { return }

        // Dispatch processing and I/O to writer queue
        writerQueue.async { [weak self] in
            self?.processAndWrite(buffer: bufferCopy, monoFormat: monoFormat)
        }
    }

    /// Deep copy an audio buffer (memory-only, safe for real-time thread)
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

    /// Process buffer and write to file (runs on writerQueue)
    private func processAndWrite(buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        guard isRunning else { return }

        guard let channelData = buffer.floatChannelData else {
            Log.warn("\(device.name): No channel data in buffer")
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            Log.warn("\(device.name): Empty buffer (frameCount=0)")
            return
        }

        let sampleRate = buffer.format.sampleRate
        let bufferDuration = Double(frameCount) / sampleRate

        // Log RMS every ~30 seconds (assuming ~10 buffers/sec)
        bufferCount += 1
        if bufferCount % 300 == 1 {
            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameCount))
            Log.info("\(device.name): RMS=\(String(format: "%.6f", rms)) channels=\(buffer.format.channelCount)")
        }

        // Process for silence detection (use first channel)
        silenceDetector.processBuffer(channelData[0], count: frameCount, bufferDuration: bufferDuration)

        // Convert to mono if needed and resample to target rate
        guard let monoBuffer = convertToMono(buffer, targetFormat: monoFormat) else {
            Log.warn("\(device.name): convertToMono failed - source: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch, target: \(monoFormat.sampleRate)Hz \(monoFormat.channelCount)ch")
            return
        }

        // Apply gain to boost audio levels (since voice processing AGC is disabled)
        if let monoData = monoBuffer.floatChannelData {
            let monoFrameCount = Int(monoBuffer.frameLength)
            for i in 0..<monoFrameCount {
                monoData[0][i] = min(1.0, max(-1.0, monoData[0][i] * gainMultiplier))
            }
        }

        // Write to file
        do {
            try audioWriter?.write(monoBuffer)
        } catch {
            Log.warn("Failed to write audio for \(device.name): \(error)")
        }
    }

    /// Convert buffer to mono at target sample rate
    private func convertToMono(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format

        // If formats match (same rate, mono), just return the buffer
        if sourceFormat.sampleRate == targetFormat.sampleRate && sourceFormat.channelCount == 1 {
            return buffer
        }

        // Validate source format
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            Log.warn("\(device.name): Invalid source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount)ch")
            return nil
        }

        // Create converter if needed
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            Log.warn("\(device.name): Failed to create AVAudioConverter from \(sourceFormat) to \(targetFormat)")
            return nil
        }

        // Calculate output frame count based on sample rate ratio
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

    public enum MicrophoneInputError: Error, LocalizedError {
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
