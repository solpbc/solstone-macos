// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

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
        case uploadFailed(segment: String, error: String, healthReason: ObserverHealthFailureReason)
        case journalContactSucceeded
        case syncComplete
        case offline(error: String, healthReason: ObserverHealthFailureReason)
    }

    // MARK: - Dependencies

    private let client: UploadClient
    private let storageManager: StorageManager

    // MARK: - Configuration

    private var serverURL: String?
    private var serverKey: String?
    private var cacheRetentionDays: Int = AppConfig.Defaults.cacheRetentionDays
    private var syncPaused: Bool = false

    // MARK: - State

    private var isSyncing = false
    private var syncTask: Task<Void, Never>?

    // MARK: - Synced Days Cache

    private let syncedDaysKey = "syncedDays"
    private var syncedDays: Set<String> = []

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

        // Load cached synced days
        if let data = UserDefaults.standard.data(forKey: syncedDaysKey),
           let days = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.syncedDays = days
        }
    }

    // MARK: - Configuration

    /// Update server configuration
    public func configure(
        serverURL: String?,
        serverKey: String?,
        cacheRetentionDays: Int,
        syncPaused: Bool
    ) {
        self.serverURL = serverURL
        self.serverKey = serverKey
        self.cacheRetentionDays = cacheRetentionDays
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
            Logger.upload.info("Sync already in progress, skipping trigger")
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
    /// - Parameter forceFullSync: When true, ignores cached synced days and checks all days
    public func sync(forceFullSync: Bool = false) async {
        guard !syncPaused else {
            Logger.upload.info("Sync paused, skipping")
            return
        }

        guard let serverURL = serverURL, let serverKey = serverKey else {
            Logger.upload.info("Sync not configured, skipping")
            return
        }

        guard !isSyncing else {
            Logger.upload.info("Sync already in progress")
            return
        }

        isSyncing = true
        progressContinuation.yield(.syncStarted)

        defer {
            isSyncing = false
        }

        // Collect all segments grouped by day
        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else {
            Logger.upload.info("No local segments found")
            progressContinuation.yield(.syncComplete)
            return
        }

        let totalSegments = segmentsByDay.values.reduce(0) { $0 + $1.count }
        var checked = 0

        // Get today's date for comparison (never cache today)
        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            return f.string(from: Date())
        }()

        // Walk days from newest to oldest
        for (day, localSegments) in segmentsByDay.sorted(by: { $0.key > $1.key }) {
            // Skip past days that are already fully synced (unless forcing)
            if day != today && syncedDays.contains(day) && !forceFullSync {
                Logger.upload.info("Day \(day, privacy: .public): skipping (already synced)")
                checked += localSegments.count
                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                continue
            }

            progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))

            // Query server for all segments on this day
            let serverSegments: [ServerSegmentInfo]?
            do {
                serverSegments = try await client.getServerSegments(
                    serverURL: serverURL,
                    serverKey: serverKey,
                    day: day
                )
            } catch {
                let healthReason = observerHealthFailureReason(from: error)
                Logger.upload.info("Network error querying server: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
                progressContinuation.yield(.offline(
                    error: error.localizedDescription,
                    healthReason: healthReason
                ))
                return
            }
            guard let serverSegments else {
                Logger.upload.info("Failed to query server for day \(day, privacy: .public), skipping")
                checked += localSegments.count
                continue
            }
            progressContinuation.yield(.journalContactSucceeded)

            Logger.upload.info("Day \(day, privacy: .public): \(localSegments.count, privacy: .public) local, \(serverSegments.count, privacy: .public) on server")

            // Build lookup for server segments (by both key and original_key)
            var serverByKey: [String: ServerSegmentInfo] = [:]
            for seg in serverSegments {
                serverByKey[seg.key] = seg
                if let originalKey = seg.originalKey {
                    serverByKey[originalKey] = seg
                }
            }

            // Track if any segments needed upload this day
            var anyNeededUpload = false

            // Walk local segments newest to oldest (already sorted descending)
            for segmentURL in localSegments {
                let (_, segment) = convertSegmentPath(segmentURL)

                // Check if segment exists on server (by key or original_key)
                let serverSegment = serverByKey[segment]

                if segmentNeedsUpload(segmentURL: segmentURL, segment: segment, serverSegment: serverSegment) {
                    anyNeededUpload = true
                    Logger.upload.info("Segment \(segment, privacy: .public) needs upload...")
                    let metadataJSON = readSegmentMetadataJSON(segmentURL: segmentURL, segment: segment)
                    await uploadSegmentWithRetry(
                        serverURL: serverURL,
                        serverKey: serverKey,
                        segmentURL: segmentURL,
                        day: day,
                        segment: segment,
                        metadataJSON: metadataJSON
                    )
                }

                checked += 1
                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
            }

            // Mark past days as synced if all segments were already on server
            if day != today && !anyNeededUpload {
                markDaySynced(day)
            }
        }

        await cleanupSyncedSegments(serverURL: serverURL, serverKey: serverKey)

        progressContinuation.yield(.syncComplete)
        Logger.upload.info("Sync complete")
    }

    // MARK: - File Comparison

    /// Check if a segment needs upload by comparing files
    private func segmentNeedsUpload(
        segmentURL: URL,
        segment: String,
        serverSegment: ServerSegmentInfo?
    ) -> Bool {
        // Get files we would actually upload (video + combined audio only)
        let filesToUpload = selectFilesForUpload(segmentDirectory: segmentURL)

        // If no files to upload, segment is "complete" (nothing to do)
        guard !filesToUpload.isEmpty else {
            return false
        }

        // If no server segment, definitely need upload
        guard let serverSegment = serverSegment, !serverSegment.files.isEmpty else {
            Logger.upload.info("Segment \(segment, privacy: .public): not on server")
            return true
        }

        // Build map of server files by submitted name (original filename as uploaded)
        var serverFileMap: [String: ServerFileInfo] = [:]
        for file in serverSegment.files {
            serverFileMap[file.submittedName] = file
        }

        // Check each file we would upload against server
        for localFile in filesToUpload {
            let localFilename = localFile.lastPathComponent

            guard serverFileMap[localFilename] != nil else {
                Logger.upload.info("Segment \(segment, privacy: .public): file \(localFilename, privacy: .public) not on server")
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
        segment: String,
        metadataJSON: String?
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
                Logger.upload.info("No files to upload for segment \(segment, privacy: .public)")
                progressContinuation.yield(.uploadFailed(
                    segment: segment,
                    error: "No files",
                    healthReason: .uploadNoFiles
                ))
                return
            }

            let result = await client.uploadSegment(
                serverURL: serverURL,
                serverKey: serverKey,
                segmentURL: segmentURL,
                day: day,
                segment: segment,
                mediaFiles: mediaFiles,
                metadataJSON: metadataJSON
            )

            switch result {
            case .success, .skipped:
                progressContinuation.yield(.uploadSucceeded(segment: segment))
                return
            case .failure(let error):
                let healthReason = observerHealthFailureReason(from: error)
                Logger.upload.info("Attempt \(attempts, privacy: .public) failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")

                if attempts >= maxRetries {
                    progressContinuation.yield(.uploadFailed(
                        segment: segment,
                        error: error.localizedDescription,
                        healthReason: healthReason
                    ))
                    return
                }

                // Calculate delay with exponential backoff
                let delay: TimeInterval
                if attempts <= retryDelays.count {
                    delay = retryDelays[attempts - 1]
                } else {
                    delay = 300  // 5 minutes
                }

                Logger.upload.info("Retrying in \(Int(delay), privacy: .public)s...")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Check if still configured
                if syncPaused || serverURL != self.serverURL {
                    Logger.upload.info("Config changed during retry, aborting")
                    progressContinuation.yield(.uploadFailed(
                        segment: segment,
                        error: "Config changed",
                        healthReason: .configChanged
                    ))
                    return
                }
            case .notConfigured:
                progressContinuation.yield(.uploadFailed(
                    segment: segment,
                    error: "Not configured",
                    healthReason: .notConfigured
                ))
                return
            }
        }
    }

    // MARK: - File Selection

    /// Select files to upload from a segment directory
    /// Only uploads: video files (*_display_*_screen.mp4) and combined audio (*_audio.m4a)
    /// Skips: individual source audio files (*_audio_system.m4a, *_audio_<device>.m4a, *_mic_*.m4a)
    private func selectFilesForUpload(segmentDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: segmentDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let segment = segmentDirectory.lastPathComponent

        var result: [URL] = []

        for file in files {
            let name = file.lastPathComponent

            // Include video files
            if name.hasSuffix("_screen.mp4") {
                result.append(file)
                continue
            }

            // Include combined audio file (exact pattern: SEGMENT_audio.m4a)
            // Skip individual source files like SEGMENT_audio_system.m4a or SEGMENT_audio_<device>.m4a
            if name == "\(segment)_audio.m4a" {
                result.append(file)
                continue
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

                // Skip incomplete and failed segments
                let dirName = segmentDir.lastPathComponent
                if dirName.hasSuffix(".incomplete") || dirName.hasSuffix(".failed") {
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

    /// Read metadata file from segment directory as JSON string
    /// Returns nil if no metadata file exists or if reading fails
    private func readSegmentMetadataJSON(segmentURL: URL, segment: String) -> String? {
        // Metadata file is named SEGMENT_meta.json
        let metaURL = segmentURL.appendingPathComponent("\(segment)_meta.json")

        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metaURL)
            // Return as string (already JSON formatted)
            return String(data: data, encoding: .utf8)
        } catch {
            Logger.upload.info("Failed to read metadata file: \(error, privacy: .public)")
        }

        return nil
    }

    // MARK: - Storage Cleanup

    /// Delete synced segments older than cacheRetentionDays.
    /// Safety gates: (1) day in syncedDays, (2) age check, (3) server reachable, (4) per-segment server confirmation.
    private func cleanupSyncedSegments(serverURL: String, serverKey: String) async {
        guard cacheRetentionDays >= 0 else {
            Logger.upload.info("Cache retention: keep forever, skipping cleanup")
            return
        }

        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else { return }

        let fm = FileManager.default
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        // Cache server segments per day to avoid redundant requests
        var serverSegmentsCache: [String: [String: ServerSegmentInfo]] = [:]

        for (day, segments) in segmentsByDay.sorted(by: { $0.key < $1.key }) {
            // Gate 1: day must be fully synced
            guard syncedDays.contains(day) else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - not fully synced")
                continue
            }

            // Gate 2: age check
            guard let dayDate = dateFormatter.date(from: day) else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - cannot parse date")
                continue
            }
            let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: dayDate), to: today).day ?? 0
            guard cacheRetentionDays == 0 || age > cacheRetentionDays else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - within retention window (\(age, privacy: .public)d <= \(self.cacheRetentionDays, privacy: .public)d)")
                continue
            }

            // Gate 3: server must be reachable and return segment data
            if serverSegmentsCache[day] == nil {
                do {
                    guard let serverSegments = try await client.getServerSegments(
                        serverURL: serverURL,
                        serverKey: serverKey,
                        day: day
                    ) else {
                        Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - server returned nil")
                        continue
                    }
                    var byKey: [String: ServerSegmentInfo] = [:]
                    for seg in serverSegments {
                        byKey[seg.key] = seg
                        if let originalKey = seg.originalKey {
                            byKey[originalKey] = seg
                        }
                    }
                    serverSegmentsCache[day] = byKey
                } catch {
                    Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - server unreachable: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            let serverByKey = serverSegmentsCache[day] ?? [:]

            // Gate 4: per-segment server confirmation
            for segmentURL in segments {
                let (_, segment) = convertSegmentPath(segmentURL)

                guard serverByKey[segment] != nil else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - not confirmed on server")
                    continue
                }

                do {
                    try fm.removeItem(at: segmentURL)
                    Logger.upload.info("Cleanup: deleted \(segment, privacy: .public) (day \(day, privacy: .public))")
                } catch {
                    Logger.upload.info("Cleanup: failed to delete \(segment, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            // Clean up empty date directory
            let dateDir = segments.first?.deletingLastPathComponent()
            if let dateDir, let contents = try? fm.contentsOfDirectory(atPath: dateDir.path), contents.isEmpty {
                try? fm.removeItem(at: dateDir)
                Logger.upload.info("Cleanup: removed empty date directory \(dateDir.lastPathComponent, privacy: .public)")
            }
        }
    }

    // MARK: - Synced Days Persistence

    /// Save synced days to UserDefaults
    private func saveSyncedDays() {
        if let data = try? JSONEncoder().encode(syncedDays) {
            UserDefaults.standard.set(data, forKey: syncedDaysKey)
        }
    }

    /// Mark a day as fully synced
    private func markDaySynced(_ day: String) {
        syncedDays.insert(day)
        saveSyncedDays()
        Logger.upload.info("Marked day \(day, privacy: .public) as fully synced")
    }

    /// Clear the synced days cache (for force re-sync)
    public func clearSyncedDaysCache() {
        syncedDays.removeAll()
        UserDefaults.standard.removeObject(forKey: syncedDaysKey)
        Logger.upload.info("Cleared synced days cache")
    }
}
