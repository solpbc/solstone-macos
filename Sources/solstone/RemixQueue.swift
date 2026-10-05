// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os
import SolstoneCore

public protocol AudioRemixing: Sendable {
    func remix(
        inputs: [AudioRemixerInput],
        to outputURL: URL,
        silenceMusic: Bool
    ) async throws -> AudioRemixerResult
}

extension AudioRemixer: AudioRemixing {}

public protocol SegmentFinalizing: Sendable {
    func enqueue(_ job: RemixQueue.RemixJob) async
    func inFlightPaths() async -> Set<String>
    func waitForCompletion() async
}

public protocol TerminationDraining: Sendable {
    func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) async
    func waitForCompletion() async
}

public enum SegmentReconciliation: Sendable {
    case normal
    case recovered(Int)
    case audioLoss(Int)
    case failed(String)
}

/// Manages background audio remix operations
/// Processes jobs sequentially to avoid CPU contention
public actor RemixQueue {
    public typealias RemixerFactory = @Sendable (_ verbose: Bool) -> any AudioRemixing
    public typealias DurationLoader = @Sendable (_ url: URL) async throws -> CMTime
    public typealias DirectoryLister = @Sendable (_ url: URL) throws -> [URL]

    /// Data needed to process a remix in the background
    public struct RemixJob: Sendable {
        let segmentDirectory: URL
        let timePrefix: String
        let capturedDurationSeconds: Int?
        let audioInputs: [AudioRemixerInput]
        let silenceMusic: Bool
        let micMetadataJSON: String?
        let audioDiagnostics: AudioCaptureRecorder?
        let audioOwnership: AudioNativeOwnership?

        public init(segmentDirectory: URL, timePrefix: String, capturedDurationSeconds: Int?,
                    audioInputs: [AudioRemixerInput], silenceMusic: Bool, micMetadataJSON: String?,
                    audioDiagnostics: AudioCaptureRecorder? = nil, audioOwnership: AudioNativeOwnership? = nil) {
            self.segmentDirectory = segmentDirectory
            self.timePrefix = timePrefix
            self.capturedDurationSeconds = capturedDurationSeconds
            self.audioInputs = audioInputs
            self.silenceMusic = silenceMusic
            self.micMetadataJSON = micMetadataJSON
            self.audioDiagnostics = audioDiagnostics
            self.audioOwnership = audioOwnership
        }
    }

    /// Pending jobs waiting to be processed
    private var pendingJobs: [RemixJob] = []

    /// Standardized segment directory paths currently queued or processing
    private var inFlightDirectoryPaths: Set<String> = []

    /// Task handling sequential job processing
    private var processingTask: Task<Void, Never>?

    /// Flag indicating if processing is active
    private var isProcessing = false

    /// Callback invoked when a segment completes (for triggering upload)
    private var onSegmentComplete: (@Sendable (URL, SegmentReconciliation) async -> Void)?

    private let remixTimeoutSeconds: TimeInterval
    private let durationProbeTimeoutSeconds: TimeInterval
    private let durationLoader: DurationLoader
    private let remixerFactory: RemixerFactory
    private let directoryLister: DirectoryLister
    private let nativeQuiescenceTimeoutSeconds: TimeInterval

    /// Shared instance
    public static let shared = RemixQueue()

    init(
        remixTimeoutSeconds: TimeInterval = 60,
        durationProbeTimeoutSeconds: TimeInterval = 3,
        directoryLister: @escaping DirectoryLister = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) },
        durationLoader: @escaping DurationLoader = { url in
            try await AVURLAsset(url: url).load(.duration)
        },
        nativeQuiescenceTimeoutSeconds: TimeInterval = 1,
        remixerFactory: @escaping RemixerFactory = { verbose in
            AudioRemixer(verbose: verbose)
        }
    ) {
        self.remixTimeoutSeconds = remixTimeoutSeconds
        self.durationProbeTimeoutSeconds = durationProbeTimeoutSeconds
        self.durationLoader = durationLoader
        self.remixerFactory = remixerFactory
        self.directoryLister = directoryLister
        self.nativeQuiescenceTimeoutSeconds = nativeQuiescenceTimeoutSeconds
    }

    init(remixerFactory: @escaping RemixerFactory) {
        self.init(
            durationLoader: { url in
                try await AVURLAsset(url: url).load(.duration)
            },
            remixerFactory: remixerFactory
        )
    }

    init(
        remixTimeoutSeconds: TimeInterval,
        remixerFactory: @escaping RemixerFactory
    ) {
        self.init(
            remixTimeoutSeconds: remixTimeoutSeconds,
            durationLoader: { url in
                try await AVURLAsset(url: url).load(.duration)
            },
            remixerFactory: remixerFactory
        )
    }

    /// Set the callback for when segments complete remixing
    public func setOnSegmentComplete(_ callback: (@Sendable (URL, SegmentReconciliation) async -> Void)?) {
        onSegmentComplete = callback
    }

    /// Enqueue a remix job for background processing
    public func enqueue(_ job: RemixJob) {
        let key = job.segmentDirectory.standardizedFileURL.path
        guard !inFlightDirectoryPaths.contains(key) else {
            Logger.storage.debug("Duplicate enqueue ignored for \(job.segmentDirectory.lastPathComponent, privacy: .public)")
            return
        }
        inFlightDirectoryPaths.insert(key)
        pendingJobs.append(job)
        startProcessingIfNeeded()
    }

    /// Wait for all pending remixes to complete (for graceful shutdown)
    public func waitForCompletion() async {
        await processingTask?.value
    }

    internal var isProcessingForTesting: Bool { isProcessing }

    internal var remixTimeoutSecondsForTesting: TimeInterval { remixTimeoutSeconds }

    public func inFlightPaths() -> Set<String> { inFlightDirectoryPaths }

    /// Start processing if not already running
    private func startProcessingIfNeeded() {
        guard !isProcessing else { return }

        processingTask = Task {
            isProcessing = true
            defer { isProcessing = false }

            while let job = pendingJobs.first {
                pendingJobs.removeFirst()
                await processJob(job)
            }
        }
    }

    /// Process a single remix job
    private func processJob(_ job: RemixJob) async {
        let key = job.segmentDirectory.standardizedFileURL.path
        var releaseInFlight = true
        defer { if releaseInFlight { inFlightDirectoryPaths.remove(key) } }

        let quiescent = await waitForNativeQuiescence(job.audioOwnership)
        do { try job.audioDiagnostics?.handoff() }
        catch {
            let quarantined = await preserveTerminalFailure(job, stage: "metadata_handoff", error: error,
                message: "segment metadata could not be saved; segment preserved for recovery")
            releaseInFlight = quiescent || quarantined
            return
        }
        guard quiescent else {
            // A readable fragment prefix is not a stable snapshot of a file
            // still owned by AVAssetWriter. Never remix, delete or promote it.
            releaseInFlight = await preserveTerminalFailure(job, stage: "native_ownership",
                error: NSError(domain: "SolstoneAudioWriter", code: 2),
                message: "audio finalization is incomplete; segment preserved for recovery")
            return
        }

        let fm = FileManager.default

        // Calculate actual duration and segment key
        let actualDuration: Int
        if let capturedDurationSeconds = job.capturedDurationSeconds {
            actualDuration = await clampedSegmentDurationSeconds(TimeInterval(capturedDurationSeconds))
        } else {
            do {
                let files = try directoryLister(job.segmentDirectory)
                let screenCandidates = files
                    .filter { $0.pathExtension == "mp4" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                let audioCandidates = files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let videoDuration = await resolveOrphanDuration(candidates: screenCandidates)
                let resolved: Int?
                if let videoDuration { resolved = videoDuration }
                else { resolved = await resolveOrphanDuration(candidates: audioCandidates) }
                guard let resolved else {
                    await preserveTerminalFailure(job, stage: "duration", error: NSError(domain: "SolstoneSegmentDuration", code: 1),
                        message: "segment duration could not be measured; segment preserved for recovery",
                        sourceFiles: audioSourceFiles(in: files, timePrefix: job.timePrefix))
                    return
                }
                actualDuration = resolved
            } catch {
                await preserveTerminalFailure(job, stage: "listing", error: error,
                    message: "segment files could not be read; segment preserved for recovery")
                return
            }
        }
        let segmentKey = "\(job.timePrefix)_\(actualDuration)"

        Logger.storage.info("Background remix: \(job.timePrefix, privacy: .public) -> \(segmentKey, privacy: .public)")

        // Remix audio if we have inputs
        // Create output with final name directly (no rename needed)
        let audioOutputURL = job.segmentDirectory.appendingPathComponent("\(segmentKey)_audio.m4a")
        var reconciliation: SegmentReconciliation = .normal
        var unreadableSourceIDs: [String]?
        var remixResult: AudioRemixerResult?
        var discoveryFailures: [AudioSourceRemixResult] = []

        if !job.audioInputs.isEmpty {
            do {
                let remixer = remixerFactory(false)
                let result = try await withTimeout(seconds: remixTimeoutSeconds) {
                    try await remixer.remix(
                        inputs: job.audioInputs,
                        to: audioOutputURL,
                        silenceMusic: job.silenceMusic
                    )
                }
                remixResult = result
                Logger.storage.info("Remix complete: \(result.tracksWritten, privacy: .public) tracks, \(result.tracksSkipped, privacy: .public) skipped")
            } catch AudioRemixerError.unreadableSources(let sourceIDs) {
                Logger.storage.error("audio source(s) unreadable for \(job.timePrefix, privacy: .public): \(sourceIDs.joined(separator: ", "), privacy: .public); finalizing screen-only with loss record")
                reconciliation = .audioLoss(sourceIDs.count)
                unreadableSourceIDs = sourceIDs
                discoveryFailures += sourceIDs.map { .failure(sourceID: $0, stage: "reader", error: nil) }
            } catch let error as TimeoutError {
                Logger.storage.error("Background remix timed out for \(job.segmentDirectory.lastPathComponent, privacy: .public); marking segment failed")
                await preserveFailedRemix(job, segmentKey: segmentKey, inputs: job.audioInputs, stage: "remix_timeout", error: error,
                    message: "audio remix timed out; segment preserved for recovery")
                return
            } catch {
                Logger.storage.error("Background remix failed for \(job.segmentDirectory.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                await preserveFailedRemix(job, segmentKey: segmentKey, inputs: job.audioInputs, stage: "remix", error: error,
                    message: "audio remix failed; segment preserved for recovery")
                return
            }
        } else {
            let files: [URL]
            do { files = try directoryLister(job.segmentDirectory) }
            catch {
                await preserveTerminalFailure(job, stage: "listing", error: error,
                    message: "segment files could not be read; segment preserved for recovery")
                return
            }
            let timePrefixAudioURL = job.segmentDirectory.appendingPathComponent("\(job.timePrefix)_audio.m4a")
            let hasConsolidatedAudio = fm.fileExists(atPath: audioOutputURL.path)
                || fm.fileExists(atPath: timePrefixAudioURL.path)
            if !hasConsolidatedAudio {
                switch await classifyAudioSources(in: files, timePrefix: job.timePrefix, verbose: false) {
                case .noSources:
                    break  // genuinely audio-less: finalize screen-only
                case .ready(let inputs, let unreadableFiles):
                    discoveryFailures = unreadableFiles.map {
                        .failure(sourceID: parseTrackType(from: $0.lastPathComponent, timePrefix: job.timePrefix).sourceID,
                                 stage: "reconstruction", error: nil)
                    }
                    Logger.storage.warning("audioInputs empty but \(inputs.count, privacy: .public) readable audio source(s) on disk for \(job.timePrefix, privacy: .public); reconstructing")
                    do {
                        let remixer = remixerFactory(false)
                        let result = try await withTimeout(seconds: remixTimeoutSeconds) {
                            try await remixer.remix(
                                inputs: inputs,
                                to: audioOutputURL,
                                silenceMusic: job.silenceMusic
                            )
                        }
                        remixResult = result
                        Logger.storage.info("reconstruction recovered \(result.tracksWritten, privacy: .public) track(s) for \(job.timePrefix, privacy: .public)")
                        reconciliation = .recovered(result.tracksWritten)
                    } catch AudioRemixerError.unreadableSources(let sourceIDs) {
                        Logger.storage.error("reconstruction audio source(s) unreadable for \(job.timePrefix, privacy: .public): \(sourceIDs.joined(separator: ", "), privacy: .public); finalizing screen-only with loss record")
                        reconciliation = .audioLoss(sourceIDs.count)
                        unreadableSourceIDs = sourceIDs
                        discoveryFailures += sourceIDs.map { .failure(sourceID: $0, stage: "reader", error: nil) }
                    } catch {
                        Logger.storage.error("reconstruction remix failed for \(job.timePrefix, privacy: .public), marking segment failed: \(error, privacy: .public)")
                        await preserveFailedRemix(job, segmentKey: segmentKey, inputs: inputs, stage: "reconstruction", error: error,
                            message: "audio reconciliation failed; segment preserved for recovery")
                        return
                    }
                case .unreadable:
                    let unreadableFiles = audioSourceFiles(in: files, timePrefix: job.timePrefix)
                    let sourceIDs = unreadableFiles.map { parseTrackType(from: $0.lastPathComponent, timePrefix: job.timePrefix).sourceID }
                    Logger.storage.info("audio source(s) present but unreadable for \(job.timePrefix, privacy: .public): \(sourceIDs.joined(separator: ", "), privacy: .public); finalizing screen-only with loss record")
                    reconciliation = .audioLoss(sourceIDs.count)
                    unreadableSourceIDs = sourceIDs
                    discoveryFailures += sourceIDs.map { .failure(sourceID: $0, stage: "reader", error: nil) }
                    // fall through — no markIncompleteSegmentAsFailed, no return
                }
            }
        }

        let results = discoveryFailures + (remixResult?.sources ?? [])
        let unreadable = Set((unreadableSourceIDs ?? []) + results.filter { $0.state == "unreadable" }.map(\.sourceID))
        if !unreadable.isEmpty {
            unreadableSourceIDs = unreadable.sorted()
            reconciliation = .audioLoss(unreadable.count)
        }
        do {
            try writeMetadataIfNeeded(segmentDirectory: job.segmentDirectory, timePrefix: job.timePrefix,
                                      segmentKey: segmentKey, micMetadataJSON: job.micMetadataJSON,
                                      unreadableSourceIDs: unreadableSourceIDs, remixSources: results)
        } catch {
            Logger.storage.error("Segment metadata could not be saved; preserving audio sources: \(error, privacy: .public)")
            await markIncompleteSegmentAsFailed(job.segmentDirectory)
            await onSegmentComplete?(job.segmentDirectory, .failed("segment metadata could not be saved; segment preserved for recovery"))
            return
        }
        // Cleanup is authorized only after output completion and durable outcomes.
        for source in remixResult?.sourceFiles ?? [] {
            do { try fm.removeItem(at: source) }
            catch { Logger.storage.warning("Could not remove remixed source: \(error, privacy: .public)") }
        }

        // Rename segment files to include duration
        do {
            let files = try directoryLister(job.segmentDirectory)
            for fileURL in files {
                let filename = fileURL.lastPathComponent

                if filename.hasPrefix("\(segmentKey)_") {
                    continue
                }

                guard filename.hasPrefix("\(job.timePrefix)_") else {
                    continue
                }

                let suffix = filename.dropFirst(job.timePrefix.count + 1)  // +1 for underscore
                let newFilename = "\(segmentKey)_\(suffix)"
                let newFileURL = job.segmentDirectory.appendingPathComponent(newFilename)

                try fm.moveItem(at: fileURL, to: newFileURL)
            }
        } catch {
            Logger.storage.error("Failed to rename segment files: \(error, privacy: .public)")
            await markIncompleteSegmentAsFailed(job.segmentDirectory)
            await onSegmentComplete?(job.segmentDirectory, .failed("segment files could not be finalized; segment preserved for recovery"))
            return
        }

        // Rename directory from HHMMSS.incomplete to HHMMSS_duration
        let parentDir = job.segmentDirectory.deletingLastPathComponent()
        let finalDirectory = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: job.segmentDirectory, to: finalDirectory)
            Logger.storage.info("Renamed segment: \(job.timePrefix, privacy: .public).incomplete -> \(segmentKey, privacy: .public)")

            // Trigger upload callback
            await onSegmentComplete?(finalDirectory, reconciliation)
        } catch {
            Logger.storage.warning("Failed to rename segment directory: \(error, privacy: .public)")
            await markIncompleteSegmentAsFailed(job.segmentDirectory)
            await onSegmentComplete?(job.segmentDirectory, .failed("segment files could not be finalized; segment preserved for recovery"))
        }
    }

    private func resolveOrphanDuration(candidates: [URL]) async -> Int? {
        var realSeconds: [TimeInterval] = []

        for candidate in candidates {
            do {
                let duration = try await withTimeout(seconds: durationProbeTimeoutSeconds) {
                    try await self.durationLoader(candidate)
                }
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite && seconds > 0 {
                    realSeconds.append(seconds)
                }
            } catch {
                // unusable — continue to the next candidate
            }
        }

        if let maxReal = realSeconds.max() {
            return await clampedSegmentDurationSeconds(maxReal)
        } else {
            return nil
        }
    }

    private func waitForNativeQuiescence(_ ownership: AudioNativeOwnership?) async -> Bool {
        guard let ownership else { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(nativeQuiescenceTimeoutSeconds))
        while !ownership.isQuiescent && clock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ownership.isQuiescent
    }

    @discardableResult
    private func preserveTerminalFailure(_ job: RemixJob, stage: String, error: Error, message: String,
                                         sourceFiles: [URL] = []) async -> Bool {
        let native = error as NSError
        let failure = AudioRecordingFailure(stage: stage, domain: String(native.domain.prefix(128)), code: native.code)
        let sourceIDs = Array(Set(job.audioInputs.map { $0.timingInfo.trackType.sourceID }
            + sourceFiles.map { parseTrackType(from: $0.lastPathComponent, timePrefix: job.timePrefix).sourceID })).sorted()
        do {
            try writeMetadataIfNeeded(segmentDirectory: job.segmentDirectory, timePrefix: job.timePrefix,
                segmentKey: job.timePrefix, micMetadataJSON: job.micMetadataJSON, unreadableSourceIDs: nil,
                remixSources: [], terminalFailure: failure, failedSourceIDs: sourceIDs)
        } catch { Logger.storage.error("Could not persist terminal segment failure; keeping all source files: \(error, privacy: .public)") }
        let quarantined = await markIncompleteSegmentAsFailed(job.segmentDirectory)
        await onSegmentComplete?(job.segmentDirectory, .failed(message))
        return quarantined
    }

    private func preserveFailedRemix(_ job: RemixJob, segmentKey: String, inputs: [AudioRemixerInput],
                                     stage: String, error: Error, message: String) async {
        let outcomes = inputs.map { AudioSourceRemixResult.failure(sourceID: $0.timingInfo.trackType.sourceID,
            stage: stage, error: error, state: "failed") }
        do {
            try writeMetadataIfNeeded(segmentDirectory: job.segmentDirectory, timePrefix: job.timePrefix,
                segmentKey: segmentKey, micMetadataJSON: job.micMetadataJSON, unreadableSourceIDs: nil, remixSources: outcomes)
        } catch { Logger.storage.error("Could not persist terminal remix failure; keeping all audio sources") }
        await markIncompleteSegmentAsFailed(job.segmentDirectory)
        await onSegmentComplete?(job.segmentDirectory, .failed(message))
    }

    private func writeMetadataIfNeeded(segmentDirectory: URL, timePrefix: String, segmentKey: String,
                                       micMetadataJSON: String?, unreadableSourceIDs: [String]?,
                                       remixSources: [AudioSourceRemixResult], terminalFailure: AudioRecordingFailure? = nil,
                                       failedSourceIDs: [String] = []) throws {
        let metaURL = segmentDirectory.appendingPathComponent("\(timePrefix)_meta.json")
        let finalMetaURL = segmentDirectory.appendingPathComponent("\(segmentKey)_meta.json")
        let fm = FileManager.default
        var root: [String: Any] = [:]
        // Interrupted finalization may already have the duration-stamped sidecar.
        for url in [finalMetaURL, metaURL] where fm.fileExists(atPath: url.path) {
            let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let dictionary = existing as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            if let older = root["audio_capture"] as? [String: Any], let newer = dictionary["audio_capture"] as? [String: Any] {
                let capture = mergeAudioCaptureMetadata(older, newer)
                root.merge(dictionary) { _, current in current }
                root["audio_capture"] = capture
            } else { root.merge(dictionary) { _, current in current } }
        }
        if let json = micMetadataJSON, let data = json.data(using: .utf8) {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root.merge(dictionary) { _, current in current }
        }
        if let terminalFailure {
            let failure = try JSONSerialization.jsonObject(with: JSONEncoder().encode(terminalFailure)) as! [String: Any]
            var capture = root["audio_capture"] as? [String: Any] ?? ["version": 1, "state": "unknown", "sources": []]
            var sources = capture["sources"] as? [[String: Any]] ?? []
            for id in failedSourceIDs where !sources.contains(where: { $0["source_id"] as? String == id }) && sources.count < AudioCaptureRecorder.sourceLimit {
                sources.append(["source_id": id, "kind": id == AudioTrackType.systemSourceID ? "system" : "microphone",
                    "expected": true, "started": false, "state": "unknown", "received_frames": 0, "accepted_frames": 0,
                    "dropped_frames": 0, "writer_status": "unknown", "statistics_available": false,
                    "statistics_complete": false, "failures": [failure]])
            }
            for index in sources.indices {
                if !["partial", "failed"].contains(sources[index]["state"] as? String ?? "") { sources[index]["state"] = "unknown" }
                if sources[index]["statistics_complete"] as? Bool != true {
                    sources[index]["writer_status"] = "unknown"
                    sources[index]["statistics_available"] = sources[index]["statistics_available"] as? Bool ?? false
                    sources[index]["statistics_complete"] = false
                }
                sources[index]["failures"] = mergeAudioFailures(sources[index]["failures"] as? [[String: Any]] ?? [], [failure])
            }
            capture["sources"] = Array(sources.prefix(AudioCaptureRecorder.sourceLimit))
            capture["failures"] = mergeAudioFailures(capture["failures"] as? [[String: Any]] ?? [], [failure])
            capture["state"] = "failed"
            root["audio_capture"] = capture
        }
        if !remixSources.isEmpty {
            var capture = root["audio_capture"] as? [String: Any] ?? ["version": 1, "state": "unknown", "sources": []]
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(remixSources)) as! [[String: Any]]
            capture = mergeAudioCaptureMetadata(capture, ["remix": encoded, "state": capture["state"] ?? "unknown"])
            if (capture["state"] as? String) == "recording" { capture["state"] = "interrupted" }
            root["audio_capture"] = capture
        } else if var capture = root["audio_capture"] as? [String: Any], (capture["state"] as? String) == "recording" {
            capture["state"] = "interrupted"
            root["audio_capture"] = capture
        }
        // An orphan has no live writer capable of completing its statistics.
        // A successful copy is separate evidence; it cannot bless capture rows
        // left in "recording" by process death.
        if var capture = root["audio_capture"] as? [String: Any], var sources = capture["sources"] as? [[String: Any]] {
            for index in sources.indices where sources[index]["writer_status"] as? String == "recording" {
                sources[index]["writer_status"] = "unknown"
                sources[index]["statistics_available"] = sources[index]["statistics_available"] as? Bool ?? false
                sources[index]["statistics_complete"] = false
                if sources[index]["state"] as? String == "recording" { sources[index]["state"] = "interrupted" }
            }
            capture["sources"] = sources
            root["audio_capture"] = capture
        }
        if unreadableSourceIDs != nil || root["unreadable_audio_sources"] != nil {
            let ids = unreadableSourceIDs ?? []
            let previous = (root["unreadable_audio_sources"] as? [String: Any])?["source_ids"] as? [String] ?? []
            let currentRows = (root["audio_capture"] as? [String: Any])?["remix"] as? [[String: Any]] ?? []
            let readable = Set(currentRows.filter { ($0["state"] as? String) != "unreadable" }.compactMap { $0["source_id"] as? String })
            let merged = Array(Set(previous + ids).subtracting(readable)).sorted()
            if merged.isEmpty { root.removeValue(forKey: "unreadable_audio_sources") }
            else { root["unreadable_audio_sources"] = ["count": merged.count, "source_ids": merged] }
        }
        guard !root.isEmpty else { return }
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: metaURL, options: .atomic)
        if finalMetaURL != metaURL, fm.fileExists(atPath: finalMetaURL.path) { try fm.removeItem(at: finalMetaURL) }
    }
}

extension RemixQueue: SegmentFinalizing {}

extension RemixQueue: TerminationDraining {}
