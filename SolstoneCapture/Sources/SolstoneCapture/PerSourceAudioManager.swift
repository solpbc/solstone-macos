// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import SolstoneCaptureCore

/// Manages individual audio writers per source
/// Handles dynamic microphone additions/removals during segment
/// Uses MicrophoneCaptureManager for persistent mic captures across segments
public final class PerSourceAudioManager: @unchecked Sendable {
    /// Active source writer (capture is managed by MicrophoneCaptureManager for mics)
    private struct SourceWriter {
        let writer: SingleTrackAudioWriter
        var finished: Bool = false
    }

    private var sourceWriters: [String: SourceWriter] = [:]  // keyed by source ID
    private let outputDirectory: URL
    private let timePrefix: String
    private var segmentStartTime: CMTime?
    private let verbose: Bool
    private let lock = NSLock()

    /// Closure to check if audio is muted (samples discarded when true)
    private let isAudioMuted: () -> Bool

    /// Shared capture manager for persistent mic captures
    private let captureManager: MicrophoneCaptureManager?

    /// Microphone gain for legacy path (when captureManager is nil)
    private let gain: Float

    /// Completed track inputs for remix (populated during finishAll)
    private var completedInputs: [AudioRemixerInput] = []

    /// Initialize with shared capture manager (preferred - keeps mics running across segments)
    public init(
        outputDirectory: URL,
        timePrefix: String,
        captureManager: MicrophoneCaptureManager,
        isAudioMuted: @escaping @Sendable () -> Bool = { false },
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.captureManager = captureManager
        self.gain = 2.0  // Not used when captureManager is provided
        self.isAudioMuted = isAudioMuted
        self.verbose = verbose
    }

    /// Initialize without shared capture manager (legacy - creates/destroys captures each segment)
    public init(
        outputDirectory: URL,
        timePrefix: String,
        gain: Float = 2.0,
        isAudioMuted: @escaping @Sendable () -> Bool = { false },
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.captureManager = nil
        self.gain = gain
        self.isAudioMuted = isAudioMuted
        self.verbose = verbose
    }

    /// Set segment start time (call when segment begins)
    public func setSegmentStartTime(_ time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        segmentStartTime = time
    }

    /// Start system audio writer
    /// - Returns: The source ID ("system")
    public func startSystemAudio() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let sourceID = "system"

        guard sourceWriters[sourceID] == nil else {
            return sourceID
        }

        let url = makeURL(for: sourceID)
        let startTime = segmentStartTime ?? CMClockGetTime(CMClockGetHostTimeClock())

        let writer = try SingleTrackAudioWriter(
            url: url,
            trackType: .systemAudio,
            segmentStartTime: startTime,
            verbose: verbose
        )

        sourceWriters[sourceID] = SourceWriter(writer: writer)
        Log.info("Started system audio writer: \(url.lastPathComponent)")

        return sourceID
    }

    /// Append system audio sample buffer
    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        // When muted, write silence to maintain timing continuity
        let bufferToWrite: CMSampleBuffer
        if isAudioMuted() {
            guard let silentBuffer = silencedBuffer(from: sampleBuffer) else { return }
            bufferToWrite = silentBuffer
        } else {
            bufferToWrite = sampleBuffer
        }

        lock.lock()
        guard let source = sourceWriters["system"], !source.finished else {
            lock.unlock()
            return
        }
        let writer = source.writer
        lock.unlock()

        writer.appendAudio(bufferToWrite)
    }

    /// Add a microphone mid-segment (can be called anytime)
    /// - Parameter device: The audio input device
    /// - Returns: The source ID (device UID)
    public func addMicrophone(_ device: AudioInputDevice) throws -> String {
        lock.lock()

        let sourceID = device.uid

        // Already exists
        if sourceWriters[sourceID] != nil {
            lock.unlock()
            return sourceID
        }

        let url = makeURL(for: sourceID)
        let startTime = segmentStartTime ?? CMClockGetTime(CMClockGetHostTimeClock())

        let writer = try SingleTrackAudioWriter(
            url: url,
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: startTime,
            verbose: verbose
        )

        sourceWriters[sourceID] = SourceWriter(writer: writer)
        lock.unlock()

        // Use shared capture manager if available (keeps engine running across segments)
        let isMuted = isAudioMuted
        if let captureManager = captureManager {
            // Start capture if not already running
            try captureManager.startCapture(for: device)

            // Wire callback to this segment's writer
            // When muted, write silence to maintain timing continuity
            captureManager.setCallback(for: device.uid) { [weak writer] buffer, time in
                let outputBuffer = isMuted() ? Self.silencedPCMBuffer(from: buffer) ?? buffer : buffer
                writer?.appendPCMBuffer(outputBuffer, presentationTime: time)
            }
            Log.info("Wired mic callback: \(device.name)")
        } else {
            // Legacy path: create capture per segment
            let capture = ExternalMicCapture(device: device, gain: gain, verbose: verbose)
            capture.onAudioBuffer = { [weak writer] buffer, time in
                let outputBuffer = isMuted() ? Self.silencedPCMBuffer(from: buffer) ?? buffer : buffer
                writer?.appendPCMBuffer(outputBuffer, presentationTime: time)
            }
            try capture.start()
            Log.info("Started mic capture (legacy): \(device.name)")
        }

        return sourceID
    }

    /// Remove a microphone mid-segment (graceful stop)
    /// The writer will be finished and its timing info preserved for remix
    /// Called when a mic is disconnected during recording
    public func removeMicrophone(deviceUID: String) {
        lock.lock()
        guard var source = sourceWriters[deviceUID], !source.finished else {
            lock.unlock()
            return
        }

        // Mark as finished to prevent further writes
        source.finished = true
        sourceWriters[deviceUID] = source

        let writer = source.writer
        lock.unlock()

        // Clear callback and stop capture (device is disconnected)
        if let captureManager = captureManager {
            captureManager.setCallback(for: deviceUID, callback: nil)
            captureManager.stopCapture(deviceUID: deviceUID)
        }

        // Finish writer asynchronously and store result
        Task {
            let timingInfo = await writer.finish()
            let input = AudioRemixerInput(url: writer.url, timingInfo: timingInfo)

            self.storeCompletedInput(input, deviceUID: deviceUID)

            Log.info("Removed mic mid-segment: \(timingInfo.trackType.displayName)")
        }
    }

    /// Store a completed input (thread-safe helper for async context)
    private func storeCompletedInput(_ input: AudioRemixerInput, deviceUID: String) {
        lock.lock()
        completedInputs.append(input)
        sourceWriters.removeValue(forKey: deviceUID)
        lock.unlock()
    }

    /// Check if a microphone is currently being recorded
    public func hasMicrophone(deviceUID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sourceWriters[deviceUID] != nil
    }

    /// Get list of currently active microphone UIDs
    public func activeMicrophoneUIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sourceWriters.keys.filter { $0 != "system" }
    }

    /// Finish all writers and return their inputs for remix
    /// Note: Mic captures are NOT stopped here - they persist across segments
    /// - Returns: Array of remix inputs with timing info
    public func finishAll() async -> [AudioRemixerInput] {
        let (writers, previousInputs) = extractWritersAndInputs()

        // Clear all mic callbacks (engines keep running, just no destination)
        // This prevents audio from being written to the old segment's writers
        captureManager?.clearAllCallbacks()

        // Finish all writers and collect timing info
        var inputs = previousInputs  // Include any previously completed (mid-segment removed mics)

        for (_, source) in writers {
            guard !source.finished else { continue }

            let timingInfo = await source.writer.finish()
            let input = AudioRemixerInput(url: source.writer.url, timingInfo: timingInfo)
            inputs.append(input)
        }

        // Sort by source ID to ensure consistent track order
        // System audio first, then mics alphabetically by UID
        inputs.sort { a, b in
            let aIsSystem = a.timingInfo.trackType.sourceID == "system"
            let bIsSystem = b.timingInfo.trackType.sourceID == "system"

            if aIsSystem && !bIsSystem { return true }
            if !aIsSystem && bIsSystem { return false }
            return a.timingInfo.trackType.sourceID < b.timingInfo.trackType.sourceID
        }

        clearState()

        return inputs
    }

    /// Extract writers and completed inputs (thread-safe helper for async context)
    private func extractWritersAndInputs() -> ([String: SourceWriter], [AudioRemixerInput]) {
        lock.lock()
        let writers = sourceWriters
        let inputs = completedInputs
        lock.unlock()
        return (writers, inputs)
    }

    /// Clear all state after finishAll (thread-safe helper for async context)
    private func clearState() {
        lock.lock()
        sourceWriters.removeAll()
        completedInputs.removeAll()
        lock.unlock()
    }

    /// Finish all writers, remix to single file, and optionally delete source files
    /// - Parameters:
    ///   - outputURL: The final combined audio file URL
    ///   - debugKeepRejected: Move rejected tracks to rejected/ subfolder instead of deleting
    ///   - deleteSourceFiles: Delete individual source files after remix
    ///   - silenceMusic: Silence music-only portions of system audio
    /// - Returns: The remix result
    public func finishAndRemix(
        to outputURL: URL,
        debugKeepRejected: Bool = false,
        deleteSourceFiles: Bool = true,
        silenceMusic: Bool = true
    ) async throws -> AudioRemixerResult {
        let inputs = await finishAll()

        guard !inputs.isEmpty else {
            throw AudioRemixerError.noInputs
        }

        let remixer = AudioRemixer(verbose: verbose, debugKeepRejected: debugKeepRejected)
        return try await remixer.remix(
            inputs: inputs,
            to: outputURL,
            deleteSourceFiles: deleteSourceFiles,
            silenceMusic: silenceMusic
        )
    }

    // MARK: - Mute Silence Helpers

    /// Create a silent version of a CMSampleBuffer (same timing, zero audio data)
    private func silencedBuffer(from buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(buffer)
        guard numSamples > 0 else { return nil }

        // Get timing info from original buffer
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timingInfo)

        // Get audio format details
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        let bytesPerSample = Int(asbd?.mBytesPerFrame ?? 2)
        let dataSize = numSamples * bytesPerSample

        // Allocate memory that CMBlockBuffer will own and free
        guard let silentMemory = calloc(1, dataSize) else { return nil }

        // Create block buffer that owns the memory (kCFAllocatorMalloc will call free())
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: silentMemory,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else {
            free(silentMemory)
            return nil
        }

        var silentBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            presentationTimeStamp: timingInfo.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &silentBuffer
        )

        return silentBuffer
    }

    /// Create a silent version of an AVAudioPCMBuffer (same format/length, zero audio data)
    private static func silencedPCMBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silentBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        silentBuffer.frameLength = buffer.frameLength

        // Zero-fill all channels
        if let floatData = silentBuffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            for channel in 0..<channelCount {
                memset(floatData[channel], 0, frameCount * MemoryLayout<Float>.size)
            }
        }

        return silentBuffer
    }

    // MARK: - Private

    private func makeURL(for sourceID: String) -> URL {
        // Sanitize sourceID for filename (replace special chars)
        let safeID = sourceID.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let filename = "\(timePrefix)_audio_\(safeID).m4a"
        return outputDirectory.appendingPathComponent(filename)
    }
}
