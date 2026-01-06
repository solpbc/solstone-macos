// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCaptureCore

/// Background sync service that walks days and uploads missing segments
/// All operations run off the main actor
public actor SyncService {
    /// Progress event for UI updates
    public enum ProgressEvent: Sendable {
        case syncStarted
        case syncProgress(checked: Int, total: Int)
        case uploadStarted(segment: String)
        case uploadRetrying(segment: String, attempt: Int)
        case uploadSucceeded(segment: String)
        case uploadFailed(segment: String, error: String)
        case syncComplete
        case offline(error: String)
    }

    // MARK: - Dependencies

    private let client: UploadClient
    private let storageManager: StorageManager

    // MARK: - Configuration

    private var serverURL: String?
    private var serverKey: String?
    private var localRetentionMB: Int = 200
    private var microphonePriority: [MicrophoneEntry] = []
    private var syncPaused: Bool = false

    // MARK: - State

    private var isSyncing = false
    private var syncTask: Task<Void, Never>?

    // MARK: - Event Stream

    private let progressContinuation: AsyncStream<ProgressEvent>.Continuation
    public let progressStream: AsyncStream<ProgressEvent>

    // MARK: - Retry Configuration

    private let retryDelays: [TimeInterval] = [5, 30, 120, 300]
    private let maxRetries = 10

    // MARK: - Initialization

    public init(storageManager: StorageManager) {
        self.storageManager = storageManager
        self.client = UploadClient()

        var continuation: AsyncStream<ProgressEvent>.Continuation!
        self.progressStream = AsyncStream { continuation = $0 }
        self.progressContinuation = continuation
    }

    // MARK: - Configuration

    /// Update server configuration
    public func configure(
        serverURL: String?,
        serverKey: String?,
        localRetentionMB: Int,
        microphonePriority: [MicrophoneEntry],
        syncPaused: Bool
    ) {
        self.serverURL = serverURL
        self.serverKey = serverKey
        self.localRetentionMB = localRetentionMB
        self.microphonePriority = microphonePriority
        self.syncPaused = syncPaused
    }

    /// Check if sync is configured and not paused
    public var isConfigured: Bool {
        serverURL != nil && serverKey != nil && !syncPaused
    }

    // MARK: - Sync Trigger

    /// Trigger a sync (debounced - coalesces rapid calls)
    public func triggerSync() {
        guard !isSyncing else {
            Log.upload("Sync already in progress, skipping trigger")
            return
        }

        syncTask?.cancel()
        syncTask = Task {
            // Small delay to coalesce rapid triggers
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    // MARK: - Full Sync

    /// Perform full sync: walk all days newest to oldest, upload missing segments
    public func sync() async {
        guard !syncPaused else {
            Log.upload("Sync paused, skipping")
            return
        }

        guard let serverURL = serverURL, let serverKey = serverKey else {
            Log.upload("Sync not configured, skipping")
            return
        }

        guard !isSyncing else {
            Log.upload("Sync already in progress")
            return
        }

        isSyncing = true
        progressContinuation.yield(.syncStarted)

        defer {
            isSyncing = false
        }

        // Test connection first
        if let error = await client.testConnection(serverURL: serverURL, serverKey: serverKey) {
            Log.upload("Connection test failed: \(error)")
            progressContinuation.yield(.offline(error: error))
            return
        }

        // Collect all segments grouped by day
        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else {
            Log.upload("No local segments found")
            progressContinuation.yield(.syncComplete)
            return
        }

        let totalSegments = segmentsByDay.values.reduce(0) { $0 + $1.count }
        var checked = 0

        // Walk days from newest to oldest
        for (day, localSegments) in segmentsByDay.sorted(by: { $0.key > $1.key }) {
            progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))

            // Query server for all segments on this day
            guard let serverSegments = await client.getServerSegments(
                serverURL: serverURL,
                serverKey: serverKey,
                day: day
            ) else {
                Log.upload("Failed to query server for day \(day), skipping")
                checked += localSegments.count
                continue
            }

            Log.upload("Day \(day): \(localSegments.count) local, \(serverSegments.count) on server")

            // Build lookup for server segments (by both key and original_key)
            var serverByKey: [String: ServerSegmentInfo] = [:]
            for seg in serverSegments {
                serverByKey[seg.key] = seg
                if let originalKey = seg.originalKey {
                    serverByKey[originalKey] = seg
                }
            }

            // Walk local segments newest to oldest (already sorted descending)
            for segmentURL in localSegments {
                let (_, segment) = convertSegmentPath(segmentURL)

                // Check if segment exists on server (by key or original_key)
                let serverSegment = serverByKey[segment]

                if segmentNeedsUpload(segmentURL: segmentURL, segment: segment, serverSegment: serverSegment) {
                    Log.upload("Segment \(segment) needs upload...")
                    await uploadSegmentWithRetry(
                        serverURL: serverURL,
                        serverKey: serverKey,
                        segmentURL: segmentURL,
                        day: day,
                        segment: segment
                    )
                } else {
                    Log.upload("Segment \(segment) verified on server")
                }

                checked += 1
                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
            }
        }

        // TODO: Re-enable cleanup once sync is working reliably
        // await cleanupOldSegments(serverURL: serverURL, serverKey: serverKey)

        progressContinuation.yield(.syncComplete)
        Log.upload("Sync complete")
    }

    // MARK: - File Comparison

    /// Check if a segment needs upload by comparing files
    private func segmentNeedsUpload(
        segmentURL: URL,
        segment: String,
        serverSegment: ServerSegmentInfo?
    ) -> Bool {
        // If no server segment, definitely need upload
        guard let serverSegment = serverSegment, !serverSegment.files.isEmpty else {
            Log.upload("Segment \(segment): not on server")
            return true
        }

        // Build map of server files by simplified name
        var serverFileMap: [String: ServerFileInfo] = [:]
        for file in serverSegment.files {
            serverFileMap[file.name] = file
        }

        // Get local media files
        let fm = FileManager.default
        guard let localFiles = try? fm.contentsOfDirectory(at: segmentURL, includingPropertiesForKeys: nil) else {
            return true
        }

        let mediaFiles = localFiles.filter { $0.pathExtension == "mp4" || $0.pathExtension == "m4a" }

        // Check each local file against server (strip segment prefix for comparison)
        for localFile in mediaFiles {
            let localFilename = localFile.lastPathComponent
            let simplifiedName = client.stripSegmentPrefix(localFilename, segment: segment)

            guard serverFileMap[simplifiedName] != nil else {
                Log.upload("Segment \(segment): file \(simplifiedName) not on server")
                return true
            }
        }

        return false
    }

    // MARK: - Upload with Retry

    private func uploadSegmentWithRetry(
        serverURL: String,
        serverKey: String,
        segmentURL: URL,
        day: String,
        segment: String
    ) async {
        var attempts = 0

        while attempts < maxRetries {
            attempts += 1

            if attempts == 1 {
                progressContinuation.yield(.uploadStarted(segment: segment))
            } else {
                progressContinuation.yield(.uploadRetrying(segment: segment, attempt: attempts))
            }

            // Select files to upload
            let mediaFiles = selectFilesForUpload(segmentDirectory: segmentURL)
            guard !mediaFiles.isEmpty else {
                Log.upload("No files to upload for segment \(segment)")
                progressContinuation.yield(.uploadFailed(segment: segment, error: "No files"))
                return
            }

            let result = await client.uploadSegment(
                serverURL: serverURL,
                serverKey: serverKey,
                segmentURL: segmentURL,
                day: day,
                segment: segment,
                mediaFiles: mediaFiles
            )

            switch result {
            case .success, .skipped:
                progressContinuation.yield(.uploadSucceeded(segment: segment))
                return
            case .failure(let error):
                Log.upload("Attempt \(attempts) failed: \(error)")

                if attempts >= maxRetries {
                    progressContinuation.yield(.uploadFailed(segment: segment, error: error.localizedDescription))
                    return
                }

                // Calculate delay with exponential backoff
                let delay: TimeInterval
                if attempts <= retryDelays.count {
                    delay = retryDelays[attempts - 1]
                } else {
                    delay = 300  // 5 minutes
                }

                Log.upload("Retrying in \(Int(delay))s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Check if still configured
                if syncPaused || serverURL != self.serverURL {
                    Log.upload("Config changed during retry, aborting")
                    progressContinuation.yield(.uploadFailed(segment: segment, error: "Config changed"))
                    return
                }
            case .notConfigured:
                progressContinuation.yield(.uploadFailed(segment: segment, error: "Not configured"))
                return
            }
        }
    }

    // MARK: - File Selection

    /// Select files to upload from a segment directory
    private func selectFilesForUpload(segmentDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: segmentDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let allMediaFiles = files.filter { $0.pathExtension == "mp4" || $0.pathExtension == "m4a" }
        guard !allMediaFiles.isEmpty else {
            return []
        }

        // Separate mic files from other media files
        let micFiles = allMediaFiles.filter { $0.lastPathComponent.contains("_mic") }
        let nonMicFiles = allMediaFiles.filter { !$0.lastPathComponent.contains("_mic") }

        // Select which mic files to upload
        let selectedMicFiles = selectMicFilesForUpload(from: micFiles, segmentDirectory: segmentDirectory)

        return nonMicFiles + selectedMicFiles
    }

    /// Mic metadata entry from mics.json
    private struct MicEntry: Codable {
        let name: String
        let file: String
        let startOffset: Double
        let duration: Double
    }

    /// Mics metadata from segment
    private struct MicsMetadata: Codable {
        let segmentDuration: Double
        let mics: [MicEntry]
    }

    /// Select mic files to upload based on priority and completeness
    private func selectMicFilesForUpload(
        from allMicFiles: [URL],
        segmentDirectory: URL
    ) -> [URL] {
        // Read mics.json metadata
        let metadataURL = segmentDirectory.appendingPathComponent("mics.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(MicsMetadata.self, from: data) else {
            // No metadata - fallback to first mic file
            Log.upload("No mics.json found, using first mic file")
            return allMicFiles.isEmpty ? [] : [allMicFiles[0]]
        }

        guard !metadata.mics.isEmpty else {
            return []
        }

        // Create lookup from filename to URL
        var fileURLsByName: [String: URL] = [:]
        for url in allMicFiles {
            fileURLsByName[url.lastPathComponent] = url
        }

        // Sort mics by priority
        let priorityOrder = microphonePriority.map { $0.name }
        let sortedMics = metadata.mics.sorted { mic1, mic2 in
            let idx1 = priorityOrder.firstIndex(of: mic1.name) ?? Int.max
            let idx2 = priorityOrder.firstIndex(of: mic2.name) ?? Int.max
            return idx1 < idx2
        }

        // Get highest priority mic that has a file
        guard let topMic = sortedMics.first(where: { fileURLsByName[$0.file] != nil }),
              let topMicURL = fileURLsByName[topMic.file] else {
            return allMicFiles.isEmpty ? [] : [allMicFiles[0]]
        }

        // Check if top mic has complete coverage
        let startThreshold: Double = 5.0
        let durationThreshold: Double = 0.9

        let isComplete = topMic.startOffset <= startThreshold &&
                         topMic.duration >= (metadata.segmentDuration * durationThreshold)

        if isComplete {
            Log.upload("Mic \(topMic.name) has full coverage, uploading single mic")
            return [topMicURL]
        }

        // Top mic is partial - also include next-priority mic
        Log.upload("Mic \(topMic.name) is partial, including backup")

        var result = [topMicURL]
        for mic in sortedMics where mic.file != topMic.file {
            if let url = fileURLsByName[mic.file] {
                result.append(url)
                Log.upload("Adding backup mic: \(mic.name)")
                break
            }
        }

        return result
    }

    // MARK: - Segment Collection

    /// Collect segments grouped by day (YYYYMMDD format)
    /// Returns segments sorted newest to oldest within each day
    private func collectSegmentsByDay() -> [String: [URL]] {
        let fm = FileManager.default
        var segmentsByDay: [String: [URL]] = [:]

        guard let dateDirs = try? fm.contentsOfDirectory(
            at: storageManager.baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        for dateDir in dateDirs {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dateDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Convert date folder to server format (YYYY-MM-DD -> YYYYMMDD)
            let dayFolder = dateDir.lastPathComponent
            let day = dayFolder.replacingOccurrences(of: "-", with: "")

            guard let segmentDirs = try? fm.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var segments: [URL] = []
            for segmentDir in segmentDirs {
                isDirectory = false
                guard fm.fileExists(atPath: segmentDir.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }

                // Skip incomplete segments
                if segmentDir.lastPathComponent.hasSuffix(".incomplete") {
                    continue
                }

                segments.append(segmentDir)
            }

            if !segments.isEmpty {
                // Sort segments newest to oldest (descending by path/name)
                segmentsByDay[day] = segments.sorted { $0.path > $1.path }
            }
        }

        return segmentsByDay
    }

    /// Convert local segment path to server format
    private func convertSegmentPath(_ segmentURL: URL) -> (day: String, segment: String) {
        let segmentFolder = segmentURL.lastPathComponent
        let dayFolder = segmentURL.deletingLastPathComponent().lastPathComponent
        let day = dayFolder.replacingOccurrences(of: "-", with: "")
        return (day, segmentFolder)
    }

    // MARK: - Storage Cleanup

    private func cleanupOldSegments(serverURL: String, serverKey: String) async {
        let retentionBytes = Int64(localRetentionMB) * 1024 * 1024
        let fm = FileManager.default

        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else { return }

        // Flatten to list (oldest first for cleanup)
        var segments = segmentsByDay.keys.sorted().flatMap { day in
            segmentsByDay[day]?.reversed() ?? []  // Reverse to get oldest first
        }
        guard !segments.isEmpty else { return }

        // Calculate total size
        var totalSize: Int64 = 0
        var segmentSizes: [URL: Int64] = [:]

        for segmentURL in segments {
            let size = directorySize(segmentURL)
            segmentSizes[segmentURL] = size
            totalSize += size
        }

        Log.upload("Total storage: \(totalSize / 1024 / 1024) MB, limit: \(localRetentionMB) MB")

        // Cache server segments by day
        var serverSegmentsCache: [String: [String: ServerSegmentInfo]] = [:]

        // Delete oldest uploaded segments until under limit
        while totalSize > retentionBytes && segments.count > 1 {
            let oldestSegment = segments.removeFirst()
            let (day, segment) = convertSegmentPath(oldestSegment)

            // Get server segments for this day (cached)
            if serverSegmentsCache[day] == nil {
                if let serverSegments = await client.getServerSegments(
                    serverURL: serverURL,
                    serverKey: serverKey,
                    day: day
                ) {
                    var byKey: [String: ServerSegmentInfo] = [:]
                    for seg in serverSegments {
                        byKey[seg.key] = seg
                        if let originalKey = seg.originalKey {
                            byKey[originalKey] = seg
                        }
                    }
                    serverSegmentsCache[day] = byKey
                } else {
                    serverSegmentsCache[day] = [:]
                }
            }
            let serverSegments = serverSegmentsCache[day] ?? [:]

            // Check if this segment exists on server
            if serverSegments[segment] != nil {
                let size = segmentSizes[oldestSegment] ?? 0
                do {
                    try fm.removeItem(at: oldestSegment)
                    totalSize -= size
                    Log.upload("Deleted old segment: \(oldestSegment.lastPathComponent) (\(size / 1024) KB)")

                    // Clean up empty date directory
                    let dateDir = oldestSegment.deletingLastPathComponent()
                    if let contents = try? fm.contentsOfDirectory(atPath: dateDir.path), contents.isEmpty {
                        try? fm.removeItem(at: dateDir)
                    }
                } catch {
                    Log.upload("Failed to delete segment: \(error)")
                }
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var size: Int64 = 0
        for fileURL in contents {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
}
