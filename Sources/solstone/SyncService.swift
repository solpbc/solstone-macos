// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
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
        case uploadFailed(segment: String, error: String, healthReason: ObserverHealthFailureReason, requestedPath: String)
        case journalContactSucceeded
        case syncComplete
        case offline(error: String, healthReason: ObserverHealthFailureReason, requestedPath: String)
        case awaitingTunnel
        /// Local content cannot establish a complete transfer: no selectable media,
        /// changed metadata after media offload, or unreadable metadata. Independent
        /// segments can still sync.
        case segmentUnprovable(segment: String)
    }

    internal enum DiscoveredEntryKind: Sendable, Equatable {
        case directory
        case regularFile
        case unsupported
    }

    private struct DiscoveredCandidate: Sendable {
        let day: String
        let segmentURL: URL
        let media: [URL]
    }

    private struct DiscoverySnapshot: Sendable {
        var candidatesByDay: [String: [DiscoveredCandidate]]
        var failure: Error?
    }

    internal enum SegmentMetadataState: Sendable, Equatable {
        case missing
        case present([String: IngestJSONValue])
        case unreadable
    }

    private enum UploadRetryOutcome: Sendable {
        case succeeded
        case failed(error: String, healthReason: ObserverHealthFailureReason, requestedPath: String)
        case held
        case stopped
    }

    // MARK: - Dependencies

    private let client: UploadClient
    private let resolver: HomeBaseURLResolver
    private let storageManager: StorageManager
    private let persistAcknowledgment: @Sendable (IngestAcknowledgment, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private let listDirectory: @Sendable (URL) throws -> [URL]
    private let classifyEntry: @Sendable (URL) throws -> DiscoveredEntryKind

    // MARK: - Configuration

    private var journalContext: JournalUploadContext?
    private var cacheRetentionDays: Int = AppConfig.Defaults.cacheRetentionDays
    private var syncPaused: Bool = false

    // MARK: - State

    private var isSyncing = false
    private var followUpSyncRequested = false
    private var syncTask: Task<Void, Never>?

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
        retryDelays: [TimeInterval] = [5, 30, 120, 300],
        persistAcknowledgment: @escaping @Sendable (IngestAcknowledgment, URL) throws -> Void = IngestAcknowledgmentStore.write,
        removeItem: @escaping @Sendable (URL) throws -> Void = { url in
            guard Darwin.unlink(url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        },
        listDirectory: @escaping @Sendable (URL) throws -> [URL] = { url in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        },
        classifyEntry: @escaping @Sendable (URL) throws -> DiscoveredEntryKind = { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let fileType = info.st_mode & mode_t(S_IFMT)
            if fileType == mode_t(S_IFDIR) {
                return .directory
            } else if fileType == mode_t(S_IFREG) {
                return .regularFile
            } else {
                return .unsupported
            }
        }
    ) {
        self.storageManager = storageManager
        self.client = client
        self.resolver = resolver
        self.retryDelays = retryDelays
        self.persistAcknowledgment = persistAcknowledgment
        self.removeItem = removeItem
        self.listDirectory = listDirectory
        self.classifyEntry = classifyEntry

        var continuation: AsyncStream<ProgressEvent>.Continuation!
        self.progressStream = AsyncStream { continuation = $0 }
        self.progressContinuation = continuation
    }

    // MARK: - Configuration

    /// Update paired-ingest configuration. The coherent journal upload context
    /// is the sync identity: changing it stops in-flight retries.
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
        self.journalContext = newContext
        self.cacheRetentionDays = cacheRetentionDays
        self.syncPaused = syncPaused
    }

    /// Check if sync has a coherent journal upload context
    public var isConfigured: Bool {
        journalContext != nil
    }

    // MARK: - Sync Trigger

    /// Trigger a sync (debounced - coalesces rapid calls)
    public func triggerSync() {
        guard !isSyncing else {
            // A segment that completed after this pass snapshotted the local set would
            // otherwise wait for the next external trigger. Run one follow-up pass instead.
            followUpSyncRequested = true
            Logger.upload.info("Sync already in progress; a follow-up pass will run when it finishes")
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
            if followUpSyncRequested {
                followUpSyncRequested = false
                triggerSync()
            }
        }

        let snapshot = discover()
        let totalSegments = snapshot.candidatesByDay.values.reduce(0) { $0 + $1.count }

        if let failure = snapshot.failure, totalSegments == 0 {
            Logger.upload.info("Discovery incomplete: \(failure.localizedDescription, privacy: .public)")
            progressContinuation.yield(.offline(
                error: failure.localizedDescription,
                healthReason: .uploadFailed,
                requestedPath: ""
            ))
            return
        }

        if snapshot.failure == nil && totalSegments == 0 {
            Logger.upload.info("No local segments found")
            progressContinuation.yield(.syncComplete)
            return
        }

        var checked = 0

        var terminalUploadFailure: (error: String, healthReason: ObserverHealthFailureReason, requestedPath: String)?
        let manifest: IngestProtocolV3.Manifest
        do {
            manifest = try await fetchManifest()
        } catch SyncReadError.held {
            progressContinuation.yield(.awaitingTunnel)
            return
        } catch {
            let healthReason = observerHealthFailureReason(from: error)
            Logger.upload.info("Manifest query failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
            progressContinuation.yield(.offline(
                error: error.localizedDescription,
                healthReason: healthReason,
                requestedPath: IngestProtocolV3.manifestPath
            ))
            return
        }
        progressContinuation.yield(.journalContactSucceeded)
        var reconciledDays: [String: [String: ServerSegmentInfo]] = [:]

        // Walk days from newest to oldest
        for (day, localCandidates) in snapshot.candidatesByDay.sorted(by: { $0.key > $1.key }) {
            progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))

            switch manifest.days[day] {
            case .error:
                Logger.upload.info("Day \(day, privacy: .public): manifest reported an error")
                progressContinuation.yield(.offline(
                    error: "journal manifest rejected \(day)",
                    healthReason: .uploadFailed,
                    requestedPath: IngestProtocolV3.manifestPath
                ))
                return
            case .segments:
                do {
                    let serverByKey = try await fetchReconciledDay(day)
                    reconciledDays[day] = serverByKey
                    progressContinuation.yield(.journalContactSucceeded)
                } catch SyncReadError.held {
                    progressContinuation.yield(.awaitingTunnel)
                    return
                } catch let SyncReadError.ingest(path, error) {
                    let healthReason = observerHealthFailureReason(from: error)
                    Logger.upload.info("Day \(day, privacy: .public) query failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
                    progressContinuation.yield(.offline(
                        error: error.localizedDescription,
                        healthReason: healthReason,
                        requestedPath: path
                    ))
                    return
                } catch {
                    let healthReason = observerHealthFailureReason(from: error)
                    Logger.upload.info("Day \(day, privacy: .public) query failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")
                    progressContinuation.yield(.offline(
                        error: error.localizedDescription,
                        healthReason: healthReason,
                        requestedPath: IngestProtocolV3.manifestDayPath(day)
                    ))
                    return
                }
            case nil:
                // The manifest omits days with zero segments.
                break
            }

            Logger.upload.info("Day \(day, privacy: .public): \(localCandidates.count, privacy: .public) local")

            // Walk local segments newest to oldest (already sorted descending)
            for candidate in localCandidates {
                let segmentURL = candidate.segmentURL
                let (_, segment) = convertSegmentPath(segmentURL)
                let metaState = readSegmentMetadata(segmentURL: segmentURL, segment: segment)
                let filesToUpload = candidate.media

                if filesToUpload.isEmpty {
                    if metaState != .unreadable {
                        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
                        if let ack = IngestAcknowledgmentStore.read(from: ackURL),
                           ack.journalFingerprint == context.fingerprint.value,
                           ack.day == day,
                           ack.submittedSegment == segment {
                            let expectedMeta: [String: IngestJSONValue]
                            if case .present(let m) = metaState {
                                expectedMeta = m
                            } else {
                                expectedMeta = [:]
                            }
                            if ack.payload.meta == expectedMeta {
                                // Settled remnant: already acknowledged media deleted by cleanup
                                checked += 1
                                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                                continue
                            }
                        }
                    }

                    Logger.upload.info("Segment \(segment, privacy: .public): no files available to establish a hold")
                    progressContinuation.yield(.segmentUnprovable(segment: segment))
                    checked += 1
                    progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                    continue
                }

                if metaState == .unreadable {
                    Logger.upload.info("Segment \(segment, privacy: .public): unreadable metadata, marking unprovable")
                    progressContinuation.yield(.segmentUnprovable(segment: segment))
                    checked += 1
                    progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                    continue
                }

                let needsUpload = segmentNeedsUpload(
                    segmentURL: segmentURL,
                    day: day,
                    segment: segment,
                    filesToUpload: filesToUpload,
                    metadataState: metaState,
                    context: context
                )

                if needsUpload {
                    Logger.upload.info("Segment \(segment, privacy: .public) needs upload...")
                    let outcome = await uploadSegmentWithRetry(
                        segmentURL: segmentURL,
                        day: day,
                        segment: segment,
                        filesToUpload: filesToUpload,
                        metadataState: metaState,
                        context: context
                    )
                    switch outcome {
                    case .succeeded:
                        break
                    case .failed(let error, let healthReason, let requestedPath):
                        terminalUploadFailure = (error, healthReason, requestedPath)
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
        }

        if let failure = snapshot.failure {
            Logger.upload.info("Sync finished with discovery failure: \(failure.localizedDescription, privacy: .public)")
            progressContinuation.yield(.offline(
                error: failure.localizedDescription,
                healthReason: .uploadFailed,
                requestedPath: ""
            ))
            return
        }

        guard await cleanupSyncedSegments(context: context, reconciledDays: reconciledDays, candidatesByDay: snapshot.candidatesByDay) else {
            return
        }

        if let failure = terminalUploadFailure {
            Logger.upload.info("Sync finished with upload failures: \(sanitizedObserverHealthErrorReason(failure.healthReason), privacy: .public)")
            progressContinuation.yield(.offline(
                error: failure.error,
                healthReason: failure.healthReason,
                requestedPath: failure.requestedPath
            ))
            return
        }

        progressContinuation.yield(.syncComplete)
        Logger.upload.info("Sync complete")
    }

    // MARK: - File Comparison

    private enum SyncReadError: Error {
        case held
        case ingest(path: String, underlying: Error)
    }

    private func fetchManifest() async throws -> IngestProtocolV3.Manifest {
        let serverURL = try await resolvedServerURL()
        return try await client.getManifest(serverURL: serverURL)
    }

    private func fetchReconciledDay(_ day: String) async throws -> [String: ServerSegmentInfo] {
        let manifestURL = try await resolvedServerURL()
        let manifestDay: IngestProtocolV3.ManifestDay
        do {
            manifestDay = try await client.getManifestDay(serverURL: manifestURL, day: day)
        } catch {
            throw SyncReadError.ingest(path: IngestProtocolV3.manifestDayPath(day), underlying: error)
        }
        let segmentsURL = try await resolvedServerURL()
        let segmentsDay: IngestProtocolV3.SegmentsDay
        do {
            segmentsDay = try await client.getSegmentsDay(serverURL: segmentsURL, day: day)
        } catch {
            throw SyncReadError.ingest(path: IngestProtocolV3.segmentsDayPath(day), underlying: error)
        }
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

    /// Check if a segment needs upload by checking durable acknowledgment sidecar.
    /// Without a usable acknowledgment covering local files and metadata for the
    /// current journal, upload is needed.
    private func segmentNeedsUpload(
        segmentURL: URL,
        day: String,
        segment: String,
        filesToUpload: [URL],
        metadataState: SegmentMetadataState,
        context: JournalUploadContext
    ) -> Bool {
        guard metadataState != .unreadable else {
            return false
        }
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
        guard let ack = IngestAcknowledgmentStore.read(from: ackURL) else {
            return true
        }
        guard ack.journalFingerprint == context.fingerprint.value,
              ack.day == day,
              ack.submittedSegment == segment else {
            return true
        }

        let expectedMeta: [String: IngestJSONValue]
        if case .present(let m) = metadataState {
            expectedMeta = m
        } else {
            expectedMeta = [:]
        }
        guard ack.payload.meta == expectedMeta else {
            return true
        }

        let ackFilesByName = Dictionary(uniqueKeysWithValues: ack.payload.files.map { ($0.submitted, $0) })
        for fileURL in filesToUpload {
            let name = fileURL.lastPathComponent
            guard let proof = ackFilesByName[name] else {
                return true
            }
            guard proof.matchesLocalFileForUpload(fileURL, sha256Calculator: client.sha256) else {
                return true
            }
        }

        return false
    }

    // MARK: - Upload with Retry

    private func uploadSegmentWithRetry(
        segmentURL: URL,
        day: String,
        segment: String,
        filesToUpload: [URL],
        metadataState: SegmentMetadataState,
        context: JournalUploadContext
    ) async -> UploadRetryOutcome {
        guard metadataState != .unreadable else {
            return .failed(
                error: "Unreadable metadata",
                healthReason: .uploadFailed,
                requestedPath: IngestProtocolV3.uploadPath
            )
        }

        let meta: [String: IngestJSONValue]? = {
            switch metadataState {
            case .present(let m): return m
            case .missing: return nil
            case .unreadable: return nil
            }
        }()

        let fm = FileManager.default
        let tempBodyURL = fm.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tempBodyURL) }

        var prepared: PreparedIngestV3Upload
        do {
            prepared = try client.prepareUpload(
                day: day,
                segment: segment,
                mediaFiles: filesToUpload,
                metadata: meta,
                bodyURL: tempBodyURL
            )
        } catch {
            let healthReason = observerHealthFailureReason(from: error)
            progressContinuation.yield(.uploadFailed(
                segment: segment,
                error: error.localizedDescription,
                healthReason: healthReason,
                requestedPath: IngestProtocolV3.uploadPath
            ))
            return .failed(
                error: error.localizedDescription,
                healthReason: healthReason,
                requestedPath: IngestProtocolV3.uploadPath
            )
        }

        var attempts = 0

        while attempts < maxRetries {
            // Capture before the attempt's first suspension so a later reconfigure
            // cannot relabel this attempt's bytes.
            guard !syncPaused, let attemptContext = journalContext, attemptContext == context else {
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

            guard let uploadURL = URL(string: "\(serverURL)\(IngestProtocolV3.uploadPath)") else {
                return .failed(
                    error: "Invalid upload URL",
                    healthReason: .uploadInvalidURL,
                    requestedPath: IngestProtocolV3.uploadPath
                )
            }
            prepared.request.url = uploadURL

            attempts += 1

            if attempts == 1 {
                progressContinuation.yield(.uploadStarted(segment: segment))
            } else {
                progressContinuation.yield(.uploadRetrying(segment: segment, attempt: attempts))
            }

            let result = await client.uploadStaged(prepared: prepared)

            // Revalidate before sidecar persist or success event; remaining retries
            // belong to a journal that is gone.
            guard !syncPaused, journalContext == attemptContext else {
                return failClosedForConfigChange(segment: segment)
            }

            switch result {
            case .success(let info):
                let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
                let previousAck = IngestAcknowledgmentStore.read(from: ackURL)
                let stagedByName = Dictionary(uniqueKeysWithValues: prepared.stagedParts.map { ($0.submitted, $0) })
                let acknowledgedFiles = info.response.fileDescriptors.map { descriptor in
                    IngestAcknowledgedFileProof(
                        submitted: descriptor.submitted,
                        sha256: descriptor.sha256,
                        size: descriptor.size,
                        written: descriptor.written,
                        localVersion: stagedByName[descriptor.submitted]?.localVersion
                    )
                }
                let newPayload = IngestAcknowledgmentPayload(files: acknowledgedFiles, meta: info.response.meta)
                let newAck = IngestAcknowledgment.successor(
                    previous: previousAck,
                    journalFingerprint: attemptContext.fingerprint.value,
                    day: day,
                    submittedSegment: segment,
                    storedSegmentKey: info.storedSegmentKey,
                    status: info.status,
                    newPayload: newPayload,
                    segmentDirectory: segmentURL,
                    sha256Calculator: client.sha256
                )

                do {
                    try persistAcknowledgment(newAck, ackURL)
                } catch {
                    Logger.upload.error("Failed to persist ingest acknowledgment for \(segment, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    progressContinuation.yield(.uploadFailed(
                        segment: segment,
                        error: "Ingest acknowledgment persistence failed: \(error.localizedDescription)",
                        healthReason: .uploadFailed,
                        requestedPath: IngestProtocolV3.uploadPath
                    ))
                    return .failed(
                        error: "Ingest acknowledgment persistence failed: \(error.localizedDescription)",
                        healthReason: .uploadFailed,
                        requestedPath: IngestProtocolV3.uploadPath
                    )
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
                        healthReason: healthReason,
                        requestedPath: IngestProtocolV3.uploadPath
                    ))
                    return .failed(
                        error: error.localizedDescription,
                        healthReason: healthReason,
                        requestedPath: IngestProtocolV3.uploadPath
                    )
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
        return .failed(
            error: "retry exhausted",
            healthReason: .uploadFailed,
            requestedPath: IngestProtocolV3.uploadPath
        )
    }

    private func failClosedForConfigChange(segment: String) -> UploadRetryOutcome {
        Logger.upload.info("Config changed during retry, aborting: \(sanitizedObserverHealthErrorReason(.configChanged), privacy: .public)")
        progressContinuation.yield(.uploadFailed(
            segment: segment,
            error: "Config changed",
            healthReason: .configChanged,
            requestedPath: IngestProtocolV3.uploadPath
        ))
        return .stopped
    }

    // MARK: - Discovery

    /// Perform a single non-following discovery walk of the capture hierarchy.
    private func discover() -> DiscoverySnapshot {
        var candidatesByDay: [String: [DiscoveredCandidate]] = [:]
        var firstFailure: Error?

        func recordFailure(_ error: Error) {
            if firstFailure == nil {
                firstFailure = error
                Logger.upload.info("Discovery incomplete: \(error.localizedDescription, privacy: .public)")
            } else {
                Logger.upload.info("Discovery encountered additional error: \(error.localizedDescription, privacy: .public)")
            }
        }

        let dateURLs: [URL]
        do {
            dateURLs = try listDirectory(storageManager.baseDirectory)
        } catch {
            recordFailure(error)
            return DiscoverySnapshot(candidatesByDay: [:], failure: firstFailure)
        }

        for dateURL in dateURLs {
            let dateKind: DiscoveredEntryKind
            do {
                dateKind = try classifyEntry(dateURL)
            } catch {
                recordFailure(error)
                continue
            }

            guard dateKind == .directory else { continue }

            let dayFolder = dateURL.lastPathComponent
            let day = dayFolder.replacingOccurrences(of: "-", with: "")

            let segmentURLs: [URL]
            do {
                segmentURLs = try listDirectory(dateURL)
            } catch {
                recordFailure(error)
                continue
            }

            var candidatesForDay: [DiscoveredCandidate] = []
            for segmentURL in segmentURLs {
                let segmentKind: DiscoveredEntryKind
                do {
                    segmentKind = try classifyEntry(segmentURL)
                } catch {
                    recordFailure(error)
                    continue
                }

                guard segmentKind == .directory else { continue }

                let dirName = segmentURL.lastPathComponent
                if dirName.hasSuffix(".incomplete") || dirName.hasSuffix(".failed") {
                    continue
                }

                let segment = dirName
                let fileURLs: [URL]
                do {
                    fileURLs = try listDirectory(segmentURL)
                } catch {
                    recordFailure(error)
                    continue
                }

                var mediaFiles: [URL] = []
                for fileURL in fileURLs {
                    let name = fileURL.lastPathComponent
                    guard IngestAcknowledgment.isUploadMediaName(name, segment: segment) else {
                        continue
                    }
                    let fileKind: DiscoveredEntryKind
                    do {
                        fileKind = try classifyEntry(fileURL)
                    } catch {
                        recordFailure(error)
                        continue
                    }
                    if fileKind == .regularFile {
                        mediaFiles.append(fileURL)
                    }
                }

                candidatesForDay.append(DiscoveredCandidate(
                    day: day,
                    segmentURL: segmentURL,
                    media: mediaFiles
                ))
            }

            if !candidatesForDay.isEmpty {
                // Sort segments newest to oldest (descending by path/name)
                candidatesByDay[day] = candidatesForDay.sorted { $0.segmentURL.path > $1.segmentURL.path }
            }
        }

        return DiscoverySnapshot(candidatesByDay: candidatesByDay, failure: firstFailure)
    }

    /// Convert local segment path to server format
    private func convertSegmentPath(_ segmentURL: URL) -> (day: String, segment: String) {
        let segmentFolder = segmentURL.lastPathComponent
        let dayFolder = segmentURL.deletingLastPathComponent().lastPathComponent
        let day = dayFolder.replacingOccurrences(of: "-", with: "")
        return (day, segmentFolder)
    }

    /// Read metadata from disk as 3-state enum.
    private func readSegmentMetadata(segmentURL: URL, segment: String) -> SegmentMetadataState {
        let metaURL = segmentURL.appendingPathComponent("\(segment)_meta.json")

        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: metaURL)
            let decoded = try JSONDecoder().decode([String: IngestJSONValue].self, from: data)
            return .present(decoded)
        } catch {
            Logger.upload.info("Failed to read metadata file: \(error, privacy: .public)")
            return .unreadable
        }
    }

    // MARK: - Storage Cleanup

    /// Delete media files from acknowledged segments older than cacheRetentionDays.
    /// Safety gates: (1) age check, (2) server reachable, (3) usable acknowledgment sidecar, (4) per-file server hold proof.
    /// Never deletes sidecars, metadata, source audio, or segment/date directories.
    private func cleanupSyncedSegments(
        context: JournalUploadContext,
        reconciledDays: [String: [String: ServerSegmentInfo]],
        candidatesByDay: [String: [DiscoveredCandidate]]
    ) async -> Bool {
        guard cacheRetentionDays >= 0 else {
            Logger.upload.info("Cache retention: keep forever, skipping cleanup")
            return true
        }

        guard !candidatesByDay.isEmpty else { return true }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"

        // Reuse only reads from this sync. A prior sync's response never proves
        // custody after the journal may have changed.
        var serverSegmentsCache = reconciledDays

        for (day, candidates) in candidatesByDay.sorted(by: { $0.key < $1.key }) {
            // Gate 1: age check
            guard let dayDate = dateFormatter.date(from: day) else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - cannot parse date")
                continue
            }
            let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: dayDate), to: today).day ?? 0
            guard cacheRetentionDays == 0 || age > cacheRetentionDays else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - within retention window (\(age, privacy: .public)d <= \(self.cacheRetentionDays, privacy: .public)d)")
                continue
            }

            // Gate 2: server must be reachable and return segment data
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
            guard !syncPaused, journalContext == context else { return false }
            let serverByKey = serverSegmentsCache[day] ?? [:]

            // Gate 3 & 4: per-segment acknowledgment and per-file proof
            for candidate in candidates {
                let segmentURL = candidate.segmentURL
                let (_, segment) = convertSegmentPath(segmentURL)

                let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
                guard let ack = IngestAcknowledgmentStore.read(from: ackURL),
                      ack.journalFingerprint == context.fingerprint.value,
                      ack.day == day,
                      ack.submittedSegment == segment else {
                    Logger.upload.info("Cleanup: skipping \(segment, privacy: .public) - no usable acknowledgment for current journal")
                    continue
                }

                let metadataState = readSegmentMetadata(segmentURL: segmentURL, segment: segment)
                let localMedia = candidate.media
                guard metadataState != .unreadable,
                      !segmentNeedsUpload(
                        segmentURL: segmentURL, day: day, segment: segment,
                        filesToUpload: localMedia, metadataState: metadataState, context: context
                      ) else {
                    continue
                }
                let localNames = Set(localMedia.map(\.lastPathComponent))

                guard let serverSegment = serverByKey[ack.storedSegmentKey] else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - stored segment key \(ack.storedSegmentKey, privacy: .public) not found on server")
                    continue
                }

                for fileProof in ack.payload.files {
                    guard localNames.contains(fileProof.submitted),
                          !fileProof.submitted.isEmpty,
                          !fileProof.submitted.contains("/"),
                          fileProof.submitted != ".",
                          fileProof.submitted != "..",
                          (fileProof.submitted as NSString).lastPathComponent == fileProof.submitted else {
                        continue
                    }

                    let targetURL = segmentURL.appendingPathComponent(fileProof.submitted)
                    guard let values = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
                          values.isSymbolicLink != true,
                          values.isRegularFile == true,
                          let size = values.fileSize,
                          UInt64(size) == fileProof.size else {
                        continue
                    }

                    guard let localSHA = client.sha256(of: targetURL),
                          localSHA == fileProof.sha256 else {
                        continue
                    }

                    guard let serverFile = serverSegment.files.first(where: {
                        ($0.submittedName.isEmpty ? $0.name : $0.submittedName) == fileProof.written
                    }),
                          serverFile.sha256 == fileProof.sha256,
                          serverFile.size == fileProof.size,
                          serverFile.status.provesHold else {
                        Logger.upload.info("Cleanup: keeping file \(fileProof.submitted, privacy: .public) - server hold not proved")
                        continue
                    }

                    do {
                        try removeItem(targetURL)
                        Logger.upload.info("Cleanup: deleted media file \(fileProof.submitted, privacy: .public) from \(segment, privacy: .public)")
                    } catch {
                        Logger.upload.info("Cleanup: failed to delete \(fileProof.submitted, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        return true
    }

#if DEBUG
    /// Debug-only, explicit-fixture entry point.
    func runLiveProbe(segmentURL: URL, day: String, segment: String) async throws -> ServerFileInfo {
        guard let context = journalContext, !syncPaused else {
            throw UploadError.invalidResponse
        }
        let filesToUpload = selectFilesForUploadLive(segmentDirectory: segmentURL)
        guard !filesToUpload.isEmpty else {
            throw UploadError.noFiles
        }
        let metaState = readSegmentMetadata(segmentURL: segmentURL, segment: segment)

        let outcome = await uploadSegmentWithRetry(
            segmentURL: segmentURL,
            day: day,
            segment: segment,
            filesToUpload: filesToUpload,
            metadataState: metaState,
            context: context
        )
        guard case .succeeded = outcome else {
            throw UploadError.invalidResponse
        }

        let serverByKey = try await fetchReconciledDay(day)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
        guard !syncPaused, journalContext == context,
              let ack = IngestAcknowledgmentStore.read(from: ackURL),
              ack.journalFingerprint == context.fingerprint.value,
              ack.day == day, ack.submittedSegment == segment,
              let serverSegment = serverByKey[ack.storedSegmentKey] else {
            throw UploadError.invalidResponse
        }
        for proof in ack.payload.files {
            guard let remote = serverSegment.files.first(where: { $0.submittedName == proof.written }),
                  remote.sha256 == proof.sha256, remote.size == proof.size, remote.status.provesHold,
                  client.sha256(of: segmentURL.appendingPathComponent(proof.submitted)) == proof.sha256 else {
                throw UploadError.invalidResponse
            }
        }
        guard let proof = ack.payload.files.first,
              let file = serverSegment.files.first(where: { $0.submittedName == proof.written }) else {
            throw UploadError.invalidResponse
        }
        return file
    }

    private func selectFilesForUploadLive(segmentDirectory: URL) -> [URL] {
        let files: [URL]
        do {
            files = try listDirectory(segmentDirectory)
        } catch {
            return []
        }
        let segment = segmentDirectory.lastPathComponent
        var result: [URL] = []
        for file in files {
            let name = file.lastPathComponent
            guard IngestAcknowledgment.isUploadMediaName(name, segment: segment) else { continue }
            if let kind = try? classifyEntry(file), kind == .regularFile {
                result.append(file)
            }
        }
        return result
    }
#endif
}
