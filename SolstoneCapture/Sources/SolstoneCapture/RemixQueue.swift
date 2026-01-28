// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCaptureCore

/// Manages background audio remix operations
/// Processes jobs sequentially to avoid CPU contention
public actor RemixQueue {
    /// Data needed to process a remix in the background
    public struct RemixJob: Sendable {
        let segmentDirectory: URL
        let timePrefix: String
        let captureStartTime: Date
        let audioInputs: [AudioRemixerInput]
        let debugKeepRejected: Bool
        let silenceMusic: Bool
        let micMetadataJSON: String?
    }

    /// Pending jobs waiting to be processed
    private var pendingJobs: [RemixJob] = []

    /// Task handling sequential job processing
    private var processingTask: Task<Void, Never>?

    /// Flag indicating if processing is active
    private var isProcessing = false

    /// Callback invoked when a segment completes (for triggering upload)
    private var onSegmentComplete: (@Sendable (URL) async -> Void)?

    /// Shared instance
    public static let shared = RemixQueue()

    private init() {}

    /// Set the callback for when segments complete remixing
    public func setOnSegmentComplete(_ callback: (@Sendable (URL) async -> Void)?) {
        onSegmentComplete = callback
    }

    /// Enqueue a remix job for background processing
    public func enqueue(_ job: RemixJob) {
        pendingJobs.append(job)
        startProcessingIfNeeded()
    }

    /// Wait for all pending remixes to complete (for graceful shutdown)
    public func waitForCompletion() async {
        await processingTask?.value
    }

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
        let fm = FileManager.default

        // Calculate actual duration and segment key
        let actualDuration = Int(Date().timeIntervalSince(job.captureStartTime))
        let segmentKey = "\(job.timePrefix)_\(actualDuration)"

        Log.info("Background remix: \(job.timePrefix) -> \(segmentKey)")

        // Remix audio if we have inputs
        // Create output with final name directly (no rename needed)
        let audioOutputURL = job.segmentDirectory.appendingPathComponent("\(segmentKey)_audio.m4a")

        if !job.audioInputs.isEmpty {
            do {
                let remixer = AudioRemixer(verbose: false, debugKeepRejected: job.debugKeepRejected)
                let result = try await remixer.remix(
                    inputs: job.audioInputs,
                    to: audioOutputURL,
                    deleteSourceFiles: true,
                    silenceMusic: job.silenceMusic
                )
                Log.info("Remix complete: \(result.tracksWritten) tracks, \(result.tracksSkipped) skipped")
            } catch AudioRemixerError.noTracksToWrite {
                Log.info("No audio tracks to write (all silent)")
            } catch {
                Log.error("Background remix failed: \(error)")
                // Continue with rename anyway - video is still valid
            }
        }

        // Write metadata file if we have mic metadata
        if let metadataJSON = job.micMetadataJSON {
            let metaURL = job.segmentDirectory.appendingPathComponent("\(segmentKey)_meta.json")
            do {
                try metadataJSON.write(to: metaURL, atomically: true, encoding: .utf8)
                Log.debug("Wrote metadata file: \(metaURL.lastPathComponent)", verbose: false)
            } catch {
                Log.warn("Failed to write metadata file: \(error)")
            }
        }

        // Rename video files to include duration (only .mp4 files need renaming)
        do {
            let files = try fm.contentsOfDirectory(at: job.segmentDirectory, includingPropertiesForKeys: nil)
            for fileURL in files {
                let filename = fileURL.lastPathComponent

                // Only rename video files (mp4) that have the old prefix
                guard filename.hasPrefix("\(job.timePrefix)_") && filename.hasSuffix(".mp4") else {
                    continue
                }

                // Replace timePrefix_ with segmentKey_ in filename
                let suffix = filename.dropFirst(job.timePrefix.count + 1)  // +1 for underscore
                let newFilename = "\(segmentKey)_\(suffix)"
                let newFileURL = job.segmentDirectory.appendingPathComponent(newFilename)

                try fm.moveItem(at: fileURL, to: newFileURL)
            }
        } catch {
            Log.warn("Failed to rename video files: \(error)")
        }

        // Rename directory from HHMMSS.incomplete to HHMMSS_duration
        let parentDir = job.segmentDirectory.deletingLastPathComponent()
        let finalDirectory = parentDir.appendingPathComponent(segmentKey)

        do {
            try fm.moveItem(at: job.segmentDirectory, to: finalDirectory)
            Log.info("Renamed segment: \(job.timePrefix).incomplete -> \(segmentKey)")

            // Trigger upload callback
            await onSegmentComplete?(finalDirectory)
        } catch {
            Log.warn("Failed to rename segment directory: \(error)")
            // Try to trigger upload with original path anyway
            await onSegmentComplete?(job.segmentDirectory)
        }
    }
}
