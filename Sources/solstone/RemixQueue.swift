// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import os

public protocol AudioRemixing: Sendable {
    func remix(
        inputs: [AudioRemixerInput],
        to outputURL: URL,
        deleteSourceFiles: Bool,
        silenceMusic: Bool
    ) async throws -> AudioRemixerResult
}

extension AudioRemixer: AudioRemixing {}

public protocol SegmentFinalizing: Sendable {
    func enqueue(_ job: RemixQueue.RemixJob) async
    func inFlightPaths() async -> Set<String>
    func waitForCompletion() async
}

public enum SegmentReconciliation: Sendable {
    case normal
    case recovered(Int)
    case failed(String)
}

/// Manages background audio remix operations
/// Processes jobs sequentially to avoid CPU contention
public actor RemixQueue {
    public typealias RemixerFactory = @Sendable (_ verbose: Bool, _ debugKeepRejected: Bool) -> any AudioRemixing

    /// Data needed to process a remix in the background
    public struct RemixJob: Sendable {
        let segmentDirectory: URL
        let timePrefix: String
        let captureStartTime: Date?
        let audioInputs: [AudioRemixerInput]
        let debugKeepRejected: Bool
        let silenceMusic: Bool
        let micMetadataJSON: String?
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

    private let remixerFactory: RemixerFactory

    /// Shared instance
    public static let shared = RemixQueue()

    init(remixerFactory: @escaping RemixerFactory = { verbose, debugKeepRejected in
        AudioRemixer(verbose: verbose, debugKeepRejected: debugKeepRejected)
    }) {
        self.remixerFactory = remixerFactory
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
        defer { inFlightDirectoryPaths.remove(key) }

        let fm = FileManager.default

        // Calculate actual duration and segment key
        let actualDuration: Int
        if let start = job.captureStartTime {
            actualDuration = Int(Date().timeIntervalSince(start))
        } else {
            do {
                let primaryMP4 = try fm.contentsOfDirectory(at: job.segmentDirectory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "mp4" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .first

                guard let primaryMP4 else {
                    await markIncompleteSegmentAsFailed(job.segmentDirectory)
                    return
                }

                let duration = try await AVURLAsset(url: primaryMP4).load(.duration)
                actualDuration = Int(CMTimeGetSeconds(duration))
                guard actualDuration > 0 else {
                    await markIncompleteSegmentAsFailed(job.segmentDirectory)
                    return
                }
            } catch {
                await markIncompleteSegmentAsFailed(job.segmentDirectory)
                return
            }
        }
        let segmentKey = "\(job.timePrefix)_\(actualDuration)"

        Logger.storage.info("Background remix: \(job.timePrefix, privacy: .public) -> \(segmentKey, privacy: .public)")

        // Remix audio if we have inputs
        // Create output with final name directly (no rename needed)
        let audioOutputURL = job.segmentDirectory.appendingPathComponent("\(segmentKey)_audio.m4a")
        var reconciliation: SegmentReconciliation = .normal

        if !job.audioInputs.isEmpty {
            do {
                let remixer = remixerFactory(false, job.debugKeepRejected)
                let result = try await withTimeout(seconds: 60) {
                    try await remixer.remix(
                        inputs: job.audioInputs,
                        to: audioOutputURL,
                        deleteSourceFiles: true,
                        silenceMusic: job.silenceMusic
                    )
                }
                Logger.storage.info("Remix complete: \(result.tracksWritten, privacy: .public) tracks, \(result.tracksSkipped, privacy: .public) skipped")
            } catch AudioRemixerError.noTracksToWrite {
                Logger.storage.info("No audio tracks to write (all silent)")
            } catch is TimeoutError {
                Logger.storage.error("Background remix timed out for \(job.segmentDirectory.lastPathComponent, privacy: .public); marking segment failed")
                await markIncompleteSegmentAsFailed(job.segmentDirectory)
                return
            } catch {
                Logger.storage.error("Background remix failed for \(job.segmentDirectory.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                await markIncompleteSegmentAsFailed(job.segmentDirectory)
                return
            }
        } else {
            let files = (try? fm.contentsOfDirectory(at: job.segmentDirectory, includingPropertiesForKeys: nil)) ?? []
            let timePrefixAudioURL = job.segmentDirectory.appendingPathComponent("\(job.timePrefix)_audio.m4a")
            let hasConsolidatedAudio = fm.fileExists(atPath: audioOutputURL.path)
                || fm.fileExists(atPath: timePrefixAudioURL.path)
            if !hasConsolidatedAudio {
                switch await classifyAudioSources(in: files, timePrefix: job.timePrefix, verbose: false) {
                case .noSources:
                    break  // genuinely audio-less: finalize screen-only
                case .ready(let inputs):
                    Logger.storage.warning("audioInputs empty but \(inputs.count, privacy: .public) readable audio source(s) on disk for \(job.timePrefix, privacy: .public); reconstructing")
                    do {
                        let remixer = remixerFactory(false, job.debugKeepRejected)
                        let result = try await withTimeout(seconds: 60) {
                            try await remixer.remix(
                                inputs: inputs,
                                to: audioOutputURL,
                                deleteSourceFiles: true,
                                silenceMusic: job.silenceMusic
                            )
                        }
                        Logger.storage.info("reconstruction recovered \(result.tracksWritten, privacy: .public) track(s) for \(job.timePrefix, privacy: .public)")
                        reconciliation = .recovered(result.tracksWritten)
                    } catch AudioRemixerError.noTracksToWrite {
                        Logger.storage.info("reconstruction found all sources silent for \(job.timePrefix, privacy: .public); finalizing screen-only")
                    } catch {
                        Logger.storage.error("reconstruction remix failed for \(job.timePrefix, privacy: .public), marking segment failed: \(error, privacy: .public)")
                        await markIncompleteSegmentAsFailed(job.segmentDirectory)
                        await onSegmentComplete?(job.segmentDirectory, .failed("audio reconciliation failed; segment preserved for recovery"))
                        return
                    }
                case .unreadable:
                    Logger.storage.error("audio source(s) present but unreadable for \(job.timePrefix, privacy: .public); marking segment failed (closes req_3f7idhvd)")
                    await markIncompleteSegmentAsFailed(job.segmentDirectory)
                    await onSegmentComplete?(job.segmentDirectory, .failed("audio sources unreadable; segment preserved for recovery"))
                    return
                }
            }
        }

        // Write metadata file if we have mic metadata
        if let metadataJSON = job.micMetadataJSON {
            let metaURL = job.segmentDirectory.appendingPathComponent("\(segmentKey)_meta.json")
            do {
                try metadataJSON.write(to: metaURL, atomically: true, encoding: .utf8)
                if false { Logger.storage.debug("Wrote metadata file: \(metaURL.lastPathComponent, privacy: .public)") }
            } catch {
                Logger.storage.warning("Failed to write metadata file: \(error, privacy: .public)")
            }
        }

        // Rename segment files to include duration
        do {
            let files = try fm.contentsOfDirectory(at: job.segmentDirectory, includingPropertiesForKeys: nil)
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
            Logger.storage.warning("Failed to rename segment files: \(error, privacy: .public)")
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
        }
    }
}

extension RemixQueue: SegmentFinalizing {}
