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
        case uploadSucceeded(segment: String, journalFingerprint: String)
        case uploadFailed(segment: String, error: String, healthReason: ObserverHealthFailureReason)
        case journalContactSucceeded
        case syncComplete
        case offline(error: String, healthReason: ObserverHealthFailureReason)
        case awaitingTunnel
    }

    private struct SegmentAliasKey: Hashable, Sendable {
        let day: String
        let submittedKey: String
    }

    private enum UploadRetryOutcome: Sendable {
        case succeeded
        case failed(error: String, healthReason: ObserverHealthFailureReason)
        case held
        case stopped
    }

    // MARK: - Dependencies

    private let client: UploadClient
    private let resolver: HomeBaseURLResolver
    private let storageManager: StorageManager

    // MARK: - Configuration

    private var journalContext: JournalUploadContext?
    private var cacheRetentionDays: Int = AppConfig.Defaults.cacheRetentionDays
    private var syncPaused: Bool = false

    // MARK: - State

    private var isSyncing = false
    private var syncTask: Task<Void, Never>?
    private var storedSegmentKeyBySubmittedKey: [SegmentAliasKey: String] = [:]

    // MARK: - Synced Days Cache

    private let syncedDaysKey = "syncedDays"
    private var syncedDays: Set<String> = []

    // MARK: - Event Stream

    private let progressContinuation: AsyncStream<ProgressEvent>.Continuation
    public let progressStream: AsyncStream<ProgressEvent>

    // MARK: - Retry Configuration

    private let retryDelays: [TimeInterval]
    private let maxRetries = 10

    // MARK: - Initialization

    init(
        storageManager: StorageManager,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver,
        retryDelays: [TimeInterval] = [5, 30, 120, 300]
    ) {
        self.storageManager = storageManager
        self.client = client
        self.resolver = resolver
        self.retryDelays = retryDelays

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

    /// Update paired-ingest configuration. The coherent journal upload context
    /// is the sync identity: changing it invalidates aliases and stops in-flight retries.
    func configure(
        pairingIdentity: TunnelPairingIdentity?,
        journalFingerprint: JournalConnectionFingerprint?,
        cacheRetentionDays: Int,
        syncPaused: Bool
    ) {
        let newContext = JournalUploadContext(
            pairing: pairingIdentity,
            suppliedFingerprint: journalFingerprint
        )
        if journalContext != newContext {
            storedSegmentKeyBySubmittedKey.removeAll()
        }
        self.journalContext = newContext
        self.cacheRetentionDays = cacheRetentionDays
        self.syncPaused = syncPaused
    }

    /// Check if sync has a coherent journal upload context
    public var isConfigured: Bool {
        journalContext != nil
    }

    /// Bounded structural visibility for race-regression tests. This deliberately
    /// exposes neither submitted nor stored segment keys.
    var storedSegmentAliasCountForTesting: Int {
        storedSegmentKeyBySubmittedKey.count
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

        guard let context = journalContext else {
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

        var terminalUploadFailure: (error: String, healthReason: ObserverHealthFailureReason)?
        let manifest: IngestProtocolV3.Manifest
        do {
            manifest = try await fetchManifest()
        } catch SyncReadError.held {
            progressContinuation.yield(.awaitingTunnel)
            return
        } catch {
            let healthReason = observerHealthFailureReason(from: error)
            Logger.upload.info("Manifest query failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
            progressContinuation.yield(.offline(error: error.localizedDescription, healthReason: healthReason))
            return
        }
        progressContinuation.yield(.journalContactSucceeded)
        var reconciledDays: [String: [String: ServerSegmentInfo]] = [:]

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

            let serverByKey: [String: ServerSegmentInfo]
            switch manifest.days[day] {
            case .error:
                Logger.upload.info("Day \(day, privacy: .public): manifest reported an error")
                progressContinuation.yield(.offline(error: "journal manifest rejected \(day)", healthReason: .uploadFailed))
                return
            case .segments:
                do {
                    serverByKey = try await fetchReconciledDay(day)
                    reconciledDays[day] = serverByKey
                    progressContinuation.yield(.journalContactSucceeded)
                } catch SyncReadError.held {
                    progressContinuation.yield(.awaitingTunnel)
                    return
                } catch {
                    let healthReason = observerHealthFailureReason(from: error)
                    Logger.upload.info("Day \(day, privacy: .public) query failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
                    progressContinuation.yield(.offline(error: error.localizedDescription, healthReason: healthReason))
                    return
                }
            case nil:
                // The manifest omits days with zero segments. No per-day request is
                // useful: every local segment must be uploaded and cannot be marked
                // synced until a later proof confirms it.
                serverByKey = [:]
            }

            Logger.upload.info("Day \(day, privacy: .public): \(localSegments.count, privacy: .public) local")

            // Track if any segments needed upload this day
            var anyNeededUpload = false

            // Walk local segments newest to oldest (already sorted descending)
            for segmentURL in localSegments {
                let (_, segment) = convertSegmentPath(segmentURL)

                // Check if segment exists on server (by key, original_key, or an in-session duplicate alias)
                let serverSegment = serverSegmentForLocalKey(day: day, segment: segment, serverByKey: serverByKey)

                let filesToUpload = selectFilesForUpload(segmentDirectory: segmentURL)
                let needsUpload = segmentNeedsUpload(
                    segment: segment,
                    filesToUpload: filesToUpload,
                    serverSegment: serverSegment
                )
                if needsUpload {
                    anyNeededUpload = true
                    guard !filesToUpload.isEmpty else {
                        Logger.upload.info("Segment \(segment, privacy: .public): no files available to establish a hold")
                        checked += 1
                        progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                        continue
                    }
                    Logger.upload.info("Segment \(segment, privacy: .public) needs upload...")
                    let metadata = readSegmentMetadata(segmentURL: segmentURL, segment: segment)
                    let outcome = await uploadSegmentWithRetry(
                        segmentURL: segmentURL,
                        day: day,
                        segment: segment,
                        metadata: metadata
                    )
                    switch outcome {
                    case .succeeded:
                        break
                    case .failed(let error, let healthReason):
                        terminalUploadFailure = (error, healthReason)
                    case .held:
                        progressContinuation.yield(.awaitingTunnel)
                        return
                    case .stopped:
                        return
                    }
                }

                checked += 1
                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
            }

            // Mark past days as synced if all segments were already on server
            if day != today && !anyNeededUpload {
                markDaySynced(day)
            }
        }

        guard await cleanupSyncedSegments(context: context, reconciledDays: reconciledDays) else {
            return
        }

        if let failure = terminalUploadFailure {
            Logger.upload.info("Sync finished with upload failures: \(sanitizedObserverHealthErrorReason(failure.healthReason), privacy: .public)")
            progressContinuation.yield(.offline(error: failure.error, healthReason: failure.healthReason))
            return
        }

        progressContinuation.yield(.syncComplete)
        Logger.upload.info("Sync complete")
    }

    // MARK: - File Comparison

    private enum SyncReadError: Error {
        case held
    }

    private func fetchManifest() async throws -> IngestProtocolV3.Manifest {
        let serverURL = try await resolvedServerURL()
        return try await client.getManifest(serverURL: serverURL)
    }

    private func fetchReconciledDay(_ day: String) async throws -> [String: ServerSegmentInfo] {
        let manifestURL = try await resolvedServerURL()
        let manifestDay = try await client.getManifestDay(serverURL: manifestURL, day: day)
        let segmentsURL = try await resolvedServerURL()
        let segmentsDay = try await client.getSegmentsDay(serverURL: segmentsURL, day: day)
        return mergeServerDay(manifestDay: manifestDay, segmentsDay: segmentsDay)
    }

    private func resolvedServerURL() async throws -> String {
        switch await resolver.resolve() {
        case .url(let resolved):
            return resolved
        case .held:
            throw SyncReadError.held
        }
    }

    /// Only file facts repeated identically by both v3 per-day reads can prove
    /// a local file. Extra or changed remote files are ignored for proof rather
    /// than preventing unrelated segments from reconciling.
    private func mergeServerDay(
        manifestDay: IngestProtocolV3.ManifestDay,
        segmentsDay: IngestProtocolV3.SegmentsDay
    ) -> [String: ServerSegmentInfo] {
        let segmentsByKey = Dictionary(uniqueKeysWithValues: segmentsDay.items.map { ($0.key, $0) })
        var result: [String: ServerSegmentInfo] = [:]

        for key in segmentsByKey.keys where manifestDay.segments[key] == nil {
            Logger.upload.info("v3 reconcile \(key, privacy: .public): \(sanitizedObserverHealthErrorReason(.uploadInvalidResponse), privacy: .public)")
        }

        for (key, manifestSegment) in manifestDay.segments {
            guard let segment = segmentsByKey[key] else {
                Logger.upload.info("v3 reconcile \(key, privacy: .public): \(sanitizedObserverHealthErrorReason(.uploadInvalidResponse), privacy: .public)")
                continue
            }
            let manifestByName = Dictionary(uniqueKeysWithValues: manifestSegment.files.map { ($0.effectiveName, $0) })
            let segmentsByName = Dictionary(uniqueKeysWithValues: segment.files.map { ($0.effectiveName, $0) })
            var matchingFiles: [ServerFileInfo] = []
            var hasDisagreement = false

            for (name, manifestFile) in manifestByName {
                guard let segmentFile = segmentsByName[name] else {
                    hasDisagreement = true
                    continue
                }
                guard manifestFile.name == segmentFile.name,
                      manifestFile.sha256 == segmentFile.sha256,
                      manifestFile.size == segmentFile.size,
                      manifestFile.status == segmentFile.status else {
                    hasDisagreement = true
                    continue
                }
                matchingFiles.append(ServerFileInfo(
                    name: manifestFile.name,
                    submittedName: manifestFile.effectiveName,
                    sha256: manifestFile.sha256,
                    size: manifestFile.size,
                    status: manifestFile.status
                ))
            }
            if manifestByName.count != segmentsByName.count {
                hasDisagreement = true
            }
            if hasDisagreement {
                Logger.upload.info("v3 reconcile \(key, privacy: .public): \(sanitizedObserverHealthErrorReason(.uploadInvalidResponse), privacy: .public)")
            }

            let serverSegment = ServerSegmentInfo(
                key: key,
                originalKey: segment.originalKey,
                files: matchingFiles
            )
            result[key] = serverSegment
            if let originalKey = segment.originalKey {
                result[originalKey] = serverSegment
            }
        }
        return result
    }

    /// Check if a segment needs upload by comparing files
    private func segmentNeedsUpload(
        segment: String,
        filesToUpload: [URL],
        serverSegment: ServerSegmentInfo?
    ) -> Bool {
        // No local files cannot earn a synced-day or cleanup decision. Retain
        // the segment until a future reconciliation can establish a file proof.
        guard !filesToUpload.isEmpty else {
            return true
        }

        guard let localFilesByFilename = localFilesByFilename(for: filesToUpload) else {
            Logger.upload.info("Segment \(segment, privacy: .public): unable to hash local upload file")
            return true
        }

        // Unproven files must heal through upload, which prevents day-synced marking and cleanup.
        let verdict = proveServerHoldsUploadFiles(localFilesByFilename: localFilesByFilename, serverSegment: serverSegment)
        guard verdict.isHeld else {
            Logger.upload.info("Segment \(segment, privacy: .public): \(verdict.reason, privacy: .public)")
            return true
        }

        return false
    }

    private func serverSegmentForLocalKey(
        day: String,
        segment: String,
        serverByKey: [String: ServerSegmentInfo]
    ) -> ServerSegmentInfo? {
        if let direct = serverByKey[segment] {
            return direct
        }
        let aliasKey = SegmentAliasKey(day: day, submittedKey: segment)
        guard let storedSegmentKey = storedSegmentKeyBySubmittedKey[aliasKey] else {
            return nil
        }
        return serverByKey[storedSegmentKey]
    }

    private func localFilesByFilename(for files: [URL]) -> [String: LocalUploadFileProof]? {
        var localFilesByFilename: [String: LocalUploadFileProof] = [:]
        for file in files {
            guard let sha = client.sha256(of: file) else {
                return nil
            }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0 else {
                return nil
            }
            localFilesByFilename[file.lastPathComponent] = LocalUploadFileProof(
                sha256: sha,
                size: UInt64(size)
            )
        }
        return localFilesByFilename
    }

    // MARK: - Upload with Retry

    private func uploadSegmentWithRetry(
        segmentURL: URL,
        day: String,
        segment: String,
        metadata: [String: IngestJSONValue]?
    ) async -> UploadRetryOutcome {
        var attempts = 0

        while attempts < maxRetries {
            // Capture before the attempt's first suspension so a later reconfigure
            // cannot relabel this attempt's bytes.
            guard !syncPaused, let attemptContext = journalContext else {
                return failClosedForConfigChange(segment: segment)
            }

            let serverURL: String
            switch await resolver.resolve() {
            case .url(let resolved):
                serverURL = resolved
            case .held:
                return .held
            }

            // Resolution suspended; a reconfigure must not proceed to POST.
            guard !syncPaused, journalContext == attemptContext else {
                return failClosedForConfigChange(segment: segment)
            }

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
                return .failed(error: "No files", healthReason: .uploadNoFiles)
            }

            let result = await client.uploadSegment(
                serverURL: serverURL,
                day: day,
                segment: segment,
                mediaFiles: mediaFiles,
                metadata: metadata
            )

            // Revalidate before alias mutation or a success event; remaining retries
            // belong to a journal that is gone.
            guard !syncPaused, journalContext == attemptContext else {
                return failClosedForConfigChange(segment: segment)
            }

            switch result {
            case .success(let info):
                if info.storedSegmentKey != segment {
                    storedSegmentKeyBySubmittedKey[
                        SegmentAliasKey(day: day, submittedKey: segment)
                    ] = info.storedSegmentKey
                }
                progressContinuation.yield(.uploadSucceeded(
                    segment: segment,
                    journalFingerprint: attemptContext.fingerprint.value
                ))
                return .succeeded
            case .failure(let error):
                let healthReason = observerHealthFailureReason(from: error)
                Logger.upload.info("Attempt \(attempts, privacy: .public) failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")

                if attempts >= maxRetries {
                    progressContinuation.yield(.uploadFailed(
                        segment: segment,
                        error: error.localizedDescription,
                        healthReason: healthReason
                    ))
                    return .failed(error: error.localizedDescription, healthReason: healthReason)
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
            }
        }
        return .failed(error: "retry exhausted", healthReason: .uploadFailed)
    }

    private func failClosedForConfigChange(segment: String) -> UploadRetryOutcome {
        Logger.upload.info("Config changed during retry, aborting: \(sanitizedObserverHealthErrorReason(.configChanged), privacy: .public)")
        progressContinuation.yield(.uploadFailed(
            segment: segment,
            error: "Config changed",
            healthReason: .configChanged
        ))
        return .stopped
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

    /// Read metadata as an object for the v3 envelope. A malformed metadata file
    /// is omitted rather than copied as an invalid nested JSON value.
    private func readSegmentMetadata(segmentURL: URL, segment: String) -> [String: IngestJSONValue]? {
        // Metadata file is named SEGMENT_meta.json
        let metaURL = segmentURL.appendingPathComponent("\(segment)_meta.json")

        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: metaURL)
            return try JSONDecoder().decode([String: IngestJSONValue].self, from: data)
        } catch {
            Logger.upload.info("Failed to read metadata file: \(error, privacy: .public)")
        }

        return nil
    }

    // MARK: - Storage Cleanup

    /// Delete synced segments older than cacheRetentionDays.
    /// Safety gates: (1) day in syncedDays, (2) age check, (3) server reachable, (4) per-segment server confirmation.
    private func cleanupSyncedSegments(
        context: JournalUploadContext,
        reconciledDays: [String: [String: ServerSegmentInfo]]
    ) async -> Bool {
        guard cacheRetentionDays >= 0 else {
            Logger.upload.info("Cache retention: keep forever, skipping cleanup")
            return true
        }

        let segmentsByDay = collectSegmentsByDay()
        guard !segmentsByDay.isEmpty else { return true }

        let fm = FileManager.default
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        // Reuse only reads from this sync. A prior sync's response never proves
        // custody after the journal may have changed.
        var serverSegmentsCache = reconciledDays

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
                    guard !syncPaused, journalContext == context else {
                        return false
                    }
                    serverSegmentsCache[day] = try await fetchReconciledDay(day)
                } catch SyncReadError.held {
                    progressContinuation.yield(.awaitingTunnel)
                    return false
                } catch {
                    Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - server query failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            let serverByKey = serverSegmentsCache[day] ?? [:]

            // Gate 4: per-segment server confirmation
            for segmentURL in segments {
                let (_, segment) = convertSegmentPath(segmentURL)

                guard let serverSegment = serverSegmentForLocalKey(day: day, segment: segment, serverByKey: serverByKey) else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - not confirmed on server")
                    continue
                }

                let filesToUpload = selectFilesForUpload(segmentDirectory: segmentURL)
                guard let localFilesByFilename = localFilesByFilename(for: filesToUpload) else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - unable to hash local upload file")
                    continue
                }

                let verdict = proveServerHoldsUploadFiles(
                    localFilesByFilename: localFilesByFilename,
                    serverSegment: serverSegment
                )
                guard verdict.isHeld else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - \(verdict.reason, privacy: .public)")
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
        return true
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

#if DEBUG
    /// Debug-only, explicit-fixture entry point. It uses the normal upload retry,
    /// three-read reconciliation, and hold proof without walking stored captures.
    func runLiveProbe(segmentURL: URL, day: String, segment: String) async throws -> ServerFileInfo {
        guard journalContext != nil, !syncPaused else {
            throw UploadError.invalidResponse
        }
        let filesToUpload = selectFilesForUpload(segmentDirectory: segmentURL)
        guard !filesToUpload.isEmpty,
              let localFiles = localFilesByFilename(for: filesToUpload) else {
            throw UploadError.noFiles
        }

        let outcome = await uploadSegmentWithRetry(
            segmentURL: segmentURL,
            day: day,
            segment: segment,
            metadata: nil
        )
        guard case .succeeded = outcome else {
            throw UploadError.invalidResponse
        }

        let serverByKey = try await fetchReconciledDay(day)
        guard let serverSegment = serverSegmentForLocalKey(
            day: day,
            segment: segment,
            serverByKey: serverByKey
        ), proveServerHoldsUploadFiles(
            localFilesByFilename: localFiles,
            serverSegment: serverSegment
        ).isHeld else {
            throw UploadError.invalidResponse
        }

        let filename = filesToUpload[0].lastPathComponent
        guard let file = serverSegment.files.first(where: { $0.submittedName == filename }) else {
            throw UploadError.invalidResponse
        }
        return file
    }
#endif
}
