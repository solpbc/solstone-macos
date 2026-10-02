// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation
import os

/// Manages individual audio writers per source
/// Handles dynamic microphone additions/removals during segment
/// Uses MicrophoneCaptureManager for persistent mic captures across segments
public final class PerSourceAudioManager: @unchecked Sendable {
    /// Active source writer (capture is managed by MicrophoneCaptureManager for mics)
    private struct SourceWriter {
        let writer: SingleTrackAudioWriter
        var attached: Bool = true
        var legacyCapture: ExternalMicCapture?
    }

    private var sourceWriters: [String: SourceWriter] = [:]  // keyed by source ID
    private var micMetadata: [String: AudioInputDevice] = [:]  // keyed by device UID
    private let outputDirectory: URL
    private let timePrefix: String
    private var segmentStartTime: CMTime?
    private let verbose: Bool
    private let lock = NSLock()

    /// Shared capture manager for persistent mic captures
    private let captureManager: MicrophoneCaptureManager?
    private let startMicrophoneCapture: (@Sendable (AudioInputDevice) throws -> Void)?

    /// Microphone gain for legacy path (when captureManager is nil)
    private let gain: Float

    private var isFinishing = false
    private var diagnostics: AudioCaptureRecorder?

    public func bindDiagnostics(_ recorder: AudioCaptureRecorder) {
        lock.withLock { diagnostics = recorder }
    }

    /// Initialize with shared capture manager (preferred - keeps mics running across segments)
    public init(
        outputDirectory: URL,
        timePrefix: String,
        captureManager: MicrophoneCaptureManager,
        verbose: Bool = false,
        startMicrophoneCapture: (@Sendable (AudioInputDevice) throws -> Void)? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.captureManager = captureManager
        self.startMicrophoneCapture = startMicrophoneCapture ?? { try captureManager.startCapture(for: $0) }
        self.gain = 2.0  // Not used when captureManager is provided
        self.verbose = verbose
    }

    /// Initialize without shared capture manager (legacy - creates/destroys captures each segment)
    public init(
        outputDirectory: URL,
        timePrefix: String,
        gain: Float = 2.0,
        verbose: Bool = false
    ) {
        self.outputDirectory = outputDirectory
        self.timePrefix = timePrefix
        self.captureManager = nil
        self.startMicrophoneCapture = nil
        self.gain = gain
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
        guard !isFinishing else { throw SegmentWriter.SegmentError.segmentFinishing }

        let sourceID = AudioTrackType.systemSourceID

        guard sourceWriters[sourceID] == nil else {
            return sourceID
        }

        let url = makeURL(for: sourceID)
        let startTime = segmentStartTime ?? CMClockGetTime(CMClockGetHostTimeClock())

        let writer = try SingleTrackAudioWriter(
            url: url,
            trackType: .systemAudio,
            segmentStartTime: startTime,
            verbose: verbose,
            onStatistics: { [diagnostics] in diagnostics?.statistics(sourceID, $0) }
        )

        sourceWriters[sourceID] = SourceWriter(writer: writer)
        Logger.audio.info("Started system audio writer: \(url.lastPathComponent, privacy: .public)")

        return sourceID
    }

    /// Append system audio sample buffer
    public func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let source = sourceWriters[AudioTrackType.systemSourceID], !isFinishing else {
            lock.unlock()
            return
        }
        let writer = source.writer
        lock.unlock()

        writer.appendAudio(sampleBuffer)
    }

    /// Add a microphone mid-segment (can be called anytime)
    /// - Parameter device: The audio input device
    /// - Returns: The source ID (device UID)
    public func addMicrophone(_ device: AudioInputDevice) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { throw SegmentWriter.SegmentError.segmentFinishing }

        let sourceID = device.uid
        diagnostics?.expect(sourceID, kind: "microphone")

        // Already exists
        if sourceWriters[sourceID]?.attached == true {
            return sourceID
        }

        let url = makeURL(for: sourceID)
        let startTime = segmentStartTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        let existing = sourceWriters[sourceID]
        let writer = try existing?.writer ?? SingleTrackAudioWriter(
            url: url,
            trackType: .microphone(name: device.name, deviceUID: device.uid),
            segmentStartTime: startTime,
            verbose: verbose,
            onStatistics: { [diagnostics] in diagnostics?.statistics(sourceID, $0) }
        )

        do {
            var legacyCapture: ExternalMicCapture?
            // Use shared capture manager if available (keeps engine running across segments)
            if let captureManager = captureManager {
                // Start capture if not already running
                try startMicrophoneCapture?(device)

                // Wire callback to this segment's writer
                captureManager.setCallback(for: device.uid, callback: { [weak writer] buffer, time in
                    writer?.appendPCMBuffer(buffer, presentationTime: time)
                }, onError: { [diagnostics] in diagnostics?.failure(sourceID, stage: "capture", error: $0) })
                Logger.audio.info("Wired mic callback: \(device.name, privacy: .public)")
            } else {
                // Legacy path: create capture per segment
                let capture = ExternalMicCapture(device: device, gain: gain, verbose: verbose)
                capture.setCallbacks(audio: { [weak writer] buffer, time in
                    writer?.appendPCMBuffer(buffer, presentationTime: time)
                }, error: { [diagnostics] in diagnostics?.failure(sourceID, stage: "capture", error: $0) })
                try capture.start()
                legacyCapture = capture
                Logger.audio.info("Started mic capture (legacy): \(device.name, privacy: .public)")
            }

            sourceWriters[sourceID] = SourceWriter(writer: writer, legacyCapture: legacyCapture)
            micMetadata[sourceID] = device
            diagnostics?.started(sourceID)
        } catch {
            if existing == nil { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        return sourceID
    }

    /// Remove a microphone mid-segment (graceful stop)
    /// Keep the writer until segment finish so a rejoin cannot replace prior audio.
    /// Called when a mic is disconnected during recording
    public func removeMicrophone(deviceUID: String) {
        lock.lock()
        guard var source = sourceWriters[deviceUID], source.attached, !isFinishing else {
            lock.unlock()
            return
        }

        source.attached = false
        sourceWriters[deviceUID] = source
        diagnostics?.failure(deviceUID, stage: "disconnect", error: NSError(domain: "SolstoneAudioDevice", code: 1))

        lock.unlock()

        // Clear callback and stop capture (device is disconnected)
        if let captureManager = captureManager {
            captureManager.setCallback(for: deviceUID, callback: nil)
            captureManager.stopCapture(deviceUID: deviceUID)
        }
        source.legacyCapture?.stop()
    }

    /// Check if a microphone is currently being recorded
    public func hasMicrophone(deviceUID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sourceWriters[deviceUID]?.attached == true && !isFinishing
    }

    /// Get list of currently active microphone UIDs
    public func activeMicrophoneUIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sourceWriters.compactMap { key, source in
            key != AudioTrackType.systemSourceID && source.attached && !isFinishing ? key : nil
        }
    }

    /// Finish all writers and return their inputs for remix
    /// Note: Mic captures are NOT stopped here - they persist across segments
    /// - Returns: Array of remix inputs with timing info
    public func finishAll() async -> [AudioRemixerInput] {
        let writers = takeWritersForFinish()
        guard !writers.isEmpty else { return [] }

        // Clear all mic callbacks (engines keep running, just no destination)
        // This prevents audio from being written to the old segment's writers
        await captureManager?.clearAllCallbacksAndDrain()

        // Finish all writers and collect timing info
        var inputs: [AudioRemixerInput] = []

        for (_, source) in writers {
            source.legacyCapture?.stop()
            let timingInfo = await source.writer.finish()
            let input = AudioRemixerInput(url: source.writer.url, timingInfo: timingInfo)
            inputs.append(input)
        }

        // Sort by source ID to ensure consistent track order
        // System audio first, then mics alphabetically by UID
        inputs.sort { a, b in
            let aIsSystem = a.timingInfo.trackType.sourceID == AudioTrackType.systemSourceID
            let bIsSystem = b.timingInfo.trackType.sourceID == AudioTrackType.systemSourceID

            if aIsSystem && !bIsSystem { return true }
            if !aIsSystem && bIsSystem { return false }
            return a.timingInfo.trackType.sourceID < b.timingInfo.trackType.sourceID
        }

        clearState()

        return inputs
    }

    private func takeWritersForFinish() -> [String: SourceWriter] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinishing else { return [:] }
        isFinishing = true
        let writers = sourceWriters
        sourceWriters.removeAll()
        return writers
    }

    /// Clear all state after finishAll (thread-safe helper for async context)
    private func clearState() {
        lock.lock()
        sourceWriters.removeAll()
        micMetadata.removeAll()
        lock.unlock()
    }

    /// Get metadata for all mics that were active during this segment
    /// Returns array of mic metadata dictionaries suitable for JSON serialization
    public func getMicMetadata() -> [[String: Any]] {
        lock.lock()
        let mics = Array(micMetadata.values)
        lock.unlock()
        return mics.map { $0.toMetadata() }
    }

    // MARK: - Private

    private func makeURL(for sourceID: String) -> URL {
        // Sanitize sourceID for filename (replace special chars)
        let safeID = sourceID.replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let filename = "\(timePrefix)_audio_\(safeID).m4a"
        return outputDirectory.appendingPathComponent(filename)
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _sourceWriterForTesting(_ sourceID: String) -> SingleTrackAudioWriter? {
        lock.withLock { sourceWriters[sourceID]?.writer }
    }
    /// Test-only: inject a pre-built source writer + device metadata directly into
    /// segment state, bypassing addMicrophone's hardware capture. Excluded from shipping builds.
    internal func _addSourceWriterForTesting(_ writer: SingleTrackAudioWriter, device: AudioInputDevice) {
        lock.lock()
        sourceWriters[device.uid] = SourceWriter(writer: writer)
        micMetadata[device.uid] = device
        lock.unlock()
    }
#endif
}
