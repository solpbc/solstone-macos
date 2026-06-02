// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

/// Discovers orphaned .incomplete segment directories on app startup and in-session via the capture heartbeat
/// and enqueues them as orphan finalize jobs to the RemixQueue committer, skipping the active recording
/// segment by full standardized path, in-flight jobs, and segments too recent to be stale.
public final class IncompleteSegmentRecovery: IncompleteSegmentRecovering, Sendable {
    private let verbose: Bool
    private let capturesDirectory: URL?
    private let finalizer: any SegmentFinalizing

    static let stalenessMargin: TimeInterval = 60
    @MainActor
    static var minimumStaleAge: TimeInterval { SegmentWriter.segmentDuration + stalenessMargin }

    static func shouldSkipAsTooRecent(creationDate: Date?, now: Date, minimumAge: TimeInterval) -> Bool {
        guard let creationDate else { return true }
        return now.timeIntervalSince(creationDate) < minimumAge
    }

    public init(
        verbose: Bool = false,
        capturesDirectory: URL? = nil,
        finalizer: any SegmentFinalizing = RemixQueue.shared
    ) {
        self.verbose = verbose
        self.capturesDirectory = capturesDirectory
        self.finalizer = finalizer
    }

    /// Scan captures directory and enqueue any stale incomplete segments.
    /// - Returns: Number of segments enqueued for finalize.
    public func recoverAll(excludingActiveSegment activeSegmentPath: String? = nil) async -> Int {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let capturesDir = capturesDirectory ?? appSupport.appendingPathComponent("Solstone/captures", isDirectory: true)

        guard fm.fileExists(atPath: capturesDir.path) else {
            return 0
        }

        var enqueuedCount = 0
        let minimumStaleAge = await Self.minimumStaleAge
        let inFlight = await finalizer.inFlightPaths()

        // Find all date directories
        guard let dateDirs = try? fm.contentsOfDirectory(
            at: capturesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for dateDir in dateDirs {
            // Find .incomplete directories within each date directory
            guard let segmentDirs = try? fm.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for segmentDir in segmentDirs {
                guard segmentDir.lastPathComponent.hasSuffix(".incomplete") else {
                    continue
                }

                let path = segmentDir.standardizedFileURL.path
                if let activeSegmentPath, path == activeSegmentPath {
                    if verbose { Logger.storage.debug("Skipping active recording segment: \(segmentDir.lastPathComponent, privacy: .public)") }
                    continue
                }

                if inFlight.contains(path) {
                    if verbose { Logger.storage.debug("Skipping in-flight segment: \(segmentDir.lastPathComponent, privacy: .public)") }
                    continue
                }

                let creationDate = (try? fm.attributesOfItem(atPath: segmentDir.path))?[.creationDate] as? Date
                if Self.shouldSkipAsTooRecent(creationDate: creationDate, now: Date(), minimumAge: minimumStaleAge) {
                    if verbose { Logger.storage.debug("Skipping recent incomplete segment: \(segmentDir.lastPathComponent, privacy: .public)") }
                    continue
                }

                Logger.storage.info("Enqueuing incomplete segment for finalize: \(segmentDir.lastPathComponent, privacy: .public)")

                let timePrefix = String(segmentDir.lastPathComponent.dropLast(".incomplete".count))
                let job = RemixQueue.RemixJob(
                    segmentDirectory: segmentDir,
                    timePrefix: timePrefix,
                    captureStartTime: nil,
                    audioInputs: [],
                    debugKeepRejected: false,
                    silenceMusic: true,
                    micMetadataJSON: nil
                )
                await finalizer.enqueue(job)
                enqueuedCount += 1
            }
        }

        return enqueuedCount
    }
}
