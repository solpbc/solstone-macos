// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

/// Background sync service that walks days and uploads missing segments
/// All operations run off the main actor
public actor SyncService {
    public enum SyncKeepReason: Sendable, Equatable {
        case unproven
        case listingFailed
        case segmentRemoved
    }

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
        case segmentKept(SyncKeepReason)
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
        case transport(Error)
        case deviceScoped(DeviceScope, Error)
        case segmentScoped(SegmentScope, Error)
        case held
        case stopped
    }

    private struct SegmentAddress: Hashable, Sendable {
        let fingerprint: String
        let day: String
        let segment: String
    }

    private struct DayAddress: Hashable, Sendable {
        let fingerprint: String
        let day: String
    }

    private enum SegmentBoundKind: Sendable, Equatable {
        case deterministic(status: Int, reasonCode: String?)
        case receivedNotWritten
    }

    private struct SegmentBound: Sendable {
        let kind: SegmentBoundKind
        var consecutive: Int
        var quietUntil: Date
    }

    // MARK: - Dependencies

    private let client: UploadClient
    private let resolver: HomeBaseURLResolver
    private let storageManager: StorageManager
    private let now: @Sendable () -> Date
    private let persistAcknowledgment: @Sendable (IngestAcknowledgment, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private let listDirectory: @Sendable (URL) throws -> [URL]
    private let classifyEntry: @Sendable (URL) throws -> DiscoveredEntryKind

    // MARK: - Configuration

    private var journalContext: JournalUploadContext?
    private var cacheRetentionDays: Int = AppConfig.Defaults.cacheRetentionDays
    private var syncPaused: Bool = false

    // MARK: - Actor Memory (keyed by context)

    private var deviceQuietUntil: Date?
    private var segmentBounds: [SegmentAddress: SegmentBound] = [:]
    private var segmentRemoved: Set<SegmentAddress> = []
    private var keepThrottle: [SegmentAddress: Date] = [:]
    private var dayListingThrottle: [DayAddress: Date] = [:]

    // MARK: - State

    private var isSyncing = false
    private var followUpSyncRequested = false
    private var syncTask: Task<Void, Never>?

    // MARK: - Event Stream

    private let progressContinuation: AsyncStream<ProgressEvent>.Continuation
    public let progressStream: AsyncStream<ProgressEvent>

    // MARK: - Retry Configuration

    private let retryDelays: [TimeInterval]
    private let maxAttemptsPerPass: Int

    // MARK: - Initialization

    init(
        storageManager: StorageManager,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver,
        now: @escaping @Sendable () -> Date = Date.init,
        retryDelays: [TimeInterval] = [5, 30, 120, 300],
        maxAttemptsPerPass: Int = 3,
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
        self.now = now
        self.retryDelays = retryDelays
        self.maxAttemptsPerPass = max(maxAttemptsPerPass, 1)
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
    /// is the sync identity: changing it stops in-flight retries and clears the quiet-until maps.
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
        if newContext != self.journalContext {
            self.deviceQuietUntil = nil
            self.segmentBounds.removeAll()
            self.segmentRemoved.removeAll()
            self.keepThrottle.removeAll()
            self.dayListingThrottle.removeAll()
        }
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
            followUpSyncRequested = true
            Logger.upload.info("Sync already in progress; a follow-up pass will run when it finishes")
            return
        }

        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    // MARK: - Full Sync

    /// Perform full sync: local discovery, unacknowledged segment upload, idle probe, cleanup
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

        let serverURL: String
        switch await resolver.resolve() {
        case .url(let resolved):
            serverURL = resolved
        case .held:
            progressContinuation.yield(.awaitingTunnel)
            return
        }

        let currentTime = self.now()
        let today = IngestDayKey.string(from: currentTime)

        // Pass-local day reads cache: never store a listing on the actor.
        // A prior pass's response is not custody after the journal may have changed.
        var passDayReads: [String: Result<IngestProtocolV3.SegmentsDay, DayReadClass>] = [:]

        // Device-quiet window active: skip upload walk and cleanup, probe today only
        if let quietUntil = self.deviceQuietUntil, currentTime < quietUntil {
            Logger.upload.info("Device quiet until \(quietUntil, privacy: .public), probing today only")
            let probeResult = await self.readDayCached(day: today, serverURL: serverURL, client: client, cache: &passDayReads)
            switch probeResult {
            case .success:
                progressContinuation.yield(.journalContactSucceeded)
                progressContinuation.yield(.syncComplete)
            case .failure(let classification):
                handleProbeFailure(classification: classification, day: today)
            }
            return
        }

        var checked = 0
        var didPOST = false
        var hasYieldedContact = false

        // Walk candidates newest day to oldest day, newest segment to oldest segment
        for (day, localCandidates) in snapshot.candidatesByDay.sorted(by: { $0.key > $1.key }) {
            progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))

            for candidate in localCandidates {
                let segmentURL = candidate.segmentURL
                let (_, segment) = convertSegmentPath(segmentURL)
                let address = SegmentAddress(fingerprint: context.fingerprint.value, day: day, segment: segment)
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
                                // Settled remnant
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
                    if self.segmentRemoved.contains(address) {
                        Logger.upload.info("Segment \(segment, privacy: .public): skipped (segment_removed)")
                        checked += 1
                        progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                        continue
                    }

                    if let bound = self.segmentBounds[address], bound.quietUntil > self.now() {
                        Logger.upload.info("Segment \(segment, privacy: .public): skipped (bound active)")
                        checked += 1
                        progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
                        continue
                    }

                    Logger.upload.info("Segment \(segment, privacy: .public) needs upload...")
                    didPOST = true
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
                        progressContinuation.yield(.journalContactSucceeded)
                        hasYieldedContact = true

                    case .held:
                        progressContinuation.yield(.awaitingTunnel)
                        return

                    case .stopped:
                        return

                    case .deviceScoped(let scope, let error):
                        let healthReason: ObserverHealthFailureReason
                        switch scope {
                        case .revoked:
                            healthReason = .pairingRevoked
                        case .notServing:
                            healthReason = .journalNotServing
                        case .journalRefused(let reasonCode):
                            healthReason = .journalRefused(reasonCode: reasonCode)
                        }
                        if case .journalRefused = scope {
                            if let uploadErr = error as? UploadError, case .serverError(let s) = uploadErr, s.statusCode == 503 {
                                // 503 does not set deviceQuietUntil
                            } else {
                                self.deviceQuietUntil = self.now().addingTimeInterval(3600)
                            }
                        } else {
                            self.deviceQuietUntil = self.now().addingTimeInterval(3600)
                        }
                        progressContinuation.yield(.offline(
                            error: error.localizedDescription,
                            healthReason: healthReason,
                            requestedPath: IngestProtocolV3.uploadPath
                        ))
                        return

                    case .segmentScoped(let scope, let error):
                        progressContinuation.yield(.journalContactSucceeded)
                        hasYieldedContact = true
                        let nowTime = self.now()
                        switch scope {
                        case .segmentRemoved:
                            self.segmentRemoved.insert(address)
                            Logger.upload.notice("Segment \(segment, privacy: .public) day=\(day, privacy: .public): segment_removed")
                            progressContinuation.yield(.segmentKept(.segmentRemoved))

                        case .receivedNotWritten:
                            self.segmentBounds[address] = SegmentBound(
                                kind: .receivedNotWritten,
                                consecutive: 1,
                                quietUntil: nowTime.addingTimeInterval(86400)
                            )
                            Logger.upload.info("Segment \(segment, privacy: .public) day=\(day, privacy: .public): disposition_received_not_written")

                        case .deterministic(let status, let reasonCode):
                            if let uploadErr = error as? UploadError, case .serverError(let s) = uploadErr, s.bodyStatus == "retryable" {
                                let currentConsecutive = self.segmentBounds[address]?.consecutive ?? 0
                                self.segmentBounds[address] = SegmentBound(
                                    kind: .deterministic(status: status, reasonCode: reasonCode),
                                    consecutive: currentConsecutive,
                                    quietUntil: nowTime.addingTimeInterval(3600)
                                )
                            } else {
                                var consecutive = 1
                                if let existing = self.segmentBounds[address], existing.kind == .deterministic(status: status, reasonCode: reasonCode) {
                                    consecutive = existing.consecutive + 1
                                }
                                let windowSecs: TimeInterval = consecutive >= 3 ? 86400 : 3600
                                self.segmentBounds[address] = SegmentBound(
                                    kind: .deterministic(status: status, reasonCode: reasonCode),
                                    consecutive: consecutive,
                                    quietUntil: nowTime.addingTimeInterval(windowSecs)
                                )
                            }
                            let token = reasonCode.map { "http_\(status)_\($0)" } ?? "http_\(status)"
                            Logger.upload.info("Segment \(segment, privacy: .public) day=\(day, privacy: .public): \(token, privacy: .public)")
                        }

                    case .transport(let error):
                        let liveness = await self.readDayCached(day: today, serverURL: serverURL, client: client, cache: &passDayReads)
                        switch liveness {
                        case .success:
                            if !hasYieldedContact {
                                progressContinuation.yield(.journalContactSucceeded)
                                hasYieldedContact = true
                            }
                        case .failure(let classification):
                            handleProbeFailure(classification: classification, day: today, fallbackError: error)
                            return
                        }
                    }
                }

                checked += 1
                progressContinuation.yield(.syncProgress(checked: checked, total: totalSegments))
            }
        }

        // Idle probe: if no POST was made and today was not read and discovery succeeded
        if !didPOST && passDayReads[today] == nil && snapshot.failure == nil {
            let probeResult = await self.readDayCached(day: today, serverURL: serverURL, client: client, cache: &passDayReads)
            switch probeResult {
            case .success:
                progressContinuation.yield(.journalContactSucceeded)
            case .failure(let classification):
                handleProbeFailure(classification: classification, day: today)
                return
            }
        }

        // Discovery failure after walk
        if let failure = snapshot.failure {
            Logger.upload.info("Sync finished with discovery failure: \(failure.localizedDescription, privacy: .public)")
            progressContinuation.yield(.offline(
                error: failure.localizedDescription,
                healthReason: .uploadFailed,
                requestedPath: ""
            ))
            return
        }

        // Storage cleanup
        let cleanupOutcome = await cleanupSyncedSegments(
            context: context,
            serverURL: serverURL,
            candidatesByDay: snapshot.candidatesByDay,
            client: client,
            cache: &passDayReads
        )
        guard cleanupOutcome == .finished else {
            return
        }

        progressContinuation.yield(.syncComplete)
        Logger.upload.info("Sync complete")
    }

    private func handleProbeFailure(
        classification: DayReadClass,
        day: String,
        fallbackError: Error? = nil
    ) {
        switch classification {
        case .journalRejectedDay(let d, let reason):
            progressContinuation.yield(.offline(
                error: "journal rejected day \(d)",
                healthReason: .journalRejectedDay(day: d, reasonCode: reason),
                requestedPath: IngestProtocolV3.segmentsDayPath(d)
            ))
        case .notServing:
            self.deviceQuietUntil = self.now().addingTimeInterval(3600)
            progressContinuation.yield(.offline(
                error: "not serving",
                healthReason: .journalNotServing,
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        case .journalRefused(let reason):
            if reason == "pairing_identity_unavailable" || reason == "foreign_stream_binding" {
                self.deviceQuietUntil = self.now().addingTimeInterval(3600)
            }
            progressContinuation.yield(.offline(
                error: "journal refused",
                healthReason: .journalRefused(reasonCode: reason),
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        case .revoked:
            self.deviceQuietUntil = self.now().addingTimeInterval(3600)
            progressContinuation.yield(.offline(
                error: "revoked",
                healthReason: .pairingRevoked,
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        case .undecoded:
            progressContinuation.yield(.offline(
                error: "undecoded response",
                healthReason: .uploadInvalidResponse,
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        case .listingFailed:
            progressContinuation.yield(.offline(
                error: fallbackError?.localizedDescription ?? "listing failed",
                healthReason: .httpStatus(500),
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        case .transport:
            let healthReason = fallbackError.map { observerHealthFailureReason(from: $0) } ?? .uploadFailed
            progressContinuation.yield(.offline(
                error: fallbackError?.localizedDescription ?? "transport failure",
                healthReason: healthReason,
                requestedPath: IngestProtocolV3.segmentsDayPath(day)
            ))
        }
    }

    private func resolvedServerURL() async throws -> String {
        switch await resolver.resolve() {
        case .url(let resolved):
            return resolved
        case .held:
            throw UploadError.invalidResponse
        }
    }

    // MARK: - File Comparison

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
            return .segmentScoped(
                .deterministic(status: 400, reasonCode: "unreadable_metadata"),
                UploadError.invalidResponse
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
            return .transport(error)
        }

        var attempts = 0

        while attempts < maxAttemptsPerPass {
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

            guard !syncPaused, journalContext == attemptContext else {
                return failClosedForConfigChange(segment: segment)
            }

            guard let uploadURL = URL(string: "\(serverURL)\(IngestProtocolV3.uploadPath)") else {
                return .transport(UploadError.invalidURL)
            }
            prepared.request.url = uploadURL

            attempts += 1

            if attempts == 1 {
                progressContinuation.yield(.uploadStarted(segment: segment))
            } else {
                progressContinuation.yield(.uploadRetrying(segment: segment, attempt: attempts))
            }

            let result = await client.uploadStaged(prepared: prepared)

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
                        localVersion: stagedByName[descriptor.submitted]?.localVersion,
                        disposition: descriptor.disposition
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
                    return .transport(error)
                }

                progressContinuation.yield(.uploadSucceeded(
                    segment: segment,
                    journalFingerprint: attemptContext.fingerprint.value
                ))
                return .succeeded

            case .failure(let error):
                let classification = classifyUpload(error)
                switch classification {
                case .deviceScoped(let scope):
                    Logger.upload.info("Upload attempt failed (device-scoped): \(sanitizedObserverHealthErrorReason(observerHealthFailureReason(from: error)), privacy: .public)")
                    return .deviceScoped(scope, error)

                case .segmentScoped(let scope):
                    Logger.upload.info("Upload attempt failed (segment-scoped): \(sanitizedObserverHealthErrorReason(observerHealthFailureReason(from: error)), privacy: .public)")
                    return .segmentScoped(scope, error)

                case .transport:
                    let healthReason = observerHealthFailureReason(from: error)
                    Logger.upload.info("Attempt \(attempts, privacy: .public) failed: \(sanitizedObserverHealthErrorReason(healthReason), privacy: .public)")

                    if attempts >= maxAttemptsPerPass {
                        progressContinuation.yield(.uploadFailed(
                            segment: segment,
                            error: error.localizedDescription,
                            healthReason: healthReason,
                            requestedPath: IngestProtocolV3.uploadPath
                        ))
                        return .transport(error)
                    }

                    let delay: TimeInterval
                    if attempts <= retryDelays.count {
                        delay = retryDelays[attempts - 1]
                    } else {
                        delay = 300
                    }

                    Logger.upload.info("Retrying in \(Int(delay), privacy: .public)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        return .transport(UploadError.invalidResponse)
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

    private enum CleanupOutcome {
        case finished
        case stoppedForConfigChange
        case deviceScopedError
    }

    /// Delete media files from acknowledged segments older than cacheRetentionDays.
    private func cleanupSyncedSegments(
        context: JournalUploadContext,
        serverURL: String,
        candidatesByDay: [String: [DiscoveredCandidate]],
        client: UploadClient,
        cache: inout [String: Result<IngestProtocolV3.SegmentsDay, DayReadClass>]
    ) async -> CleanupOutcome {
        guard cacheRetentionDays >= 0 else {
            Logger.upload.info("Cache retention: keep forever, skipping cleanup")
            return .finished
        }

        guard !candidatesByDay.isEmpty else { return .finished }

        let calendar = IngestDayKey.calendar
        let todayDate = IngestDayKey.startOfDay(self.now())

        for (day, candidates) in candidatesByDay.sorted(by: { $0.key < $1.key }) {
            // Gate 1: age check
            guard let dayDate = IngestDayKey.startOfDay(dayKey: day) else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - cannot parse date")
                continue
            }
            let age = calendar.dateComponents([.day], from: dayDate, to: todayDate).day ?? 0
            guard cacheRetentionDays == 0 || age > cacheRetentionDays else {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - within retention window (\(age, privacy: .public)d <= \(self.cacheRetentionDays, privacy: .public)d)")
                continue
            }

            let dayAddress = DayAddress(fingerprint: context.fingerprint.value, day: day)
            if let quietUntil = self.dayListingThrottle[dayAddress], quietUntil > self.now() {
                Logger.upload.info("Cleanup: skipping day \(day, privacy: .public) - dayListingThrottle active")
                continue
            }

            // Pre-filter eligible segments on this day
            var eligibleCandidates: [(candidate: DiscoveredCandidate, segment: String, ack: IngestAcknowledgment)] = []
            for candidate in candidates {
                let segmentURL = candidate.segmentURL
                let (_, segment) = convertSegmentPath(segmentURL)
                let address = SegmentAddress(fingerprint: context.fingerprint.value, day: day, segment: segment)

                if self.segmentRemoved.contains(address) {
                    continue
                }
                if let quietUntil = self.keepThrottle[address], quietUntil > self.now() {
                    continue
                }

                let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
                guard let ack = IngestAcknowledgmentStore.read(from: ackURL),
                      ack.journalFingerprint == context.fingerprint.value,
                      ack.day == day,
                      ack.submittedSegment == segment else {
                    continue
                }

                let metadataState = readSegmentMetadata(segmentURL: segmentURL, segment: segment)
                let localMedia = candidate.media
                guard metadataState != .unreadable,
                      !localMedia.isEmpty,
                      !segmentNeedsUpload(
                        segmentURL: segmentURL, day: day, segment: segment,
                        filesToUpload: localMedia, metadataState: metadataState, context: context
                      ) else {
                    continue
                }

                eligibleCandidates.append((candidate, segment, ack))
            }

            guard !eligibleCandidates.isEmpty else {
                continue
            }

            // Query day listing
            guard !syncPaused, journalContext == context else { return .stoppedForConfigChange }
            let dayResult = await self.readDayCached(day: day, serverURL: serverURL, client: client, cache: &cache)

            let segmentsDay: IngestProtocolV3.SegmentsDay
            switch dayResult {
            case .success(let s):
                segmentsDay = s
            case .failure(let classification):
                switch classification {
                case .transport:
                    // A cleanup transport failure sets no quiet-until, deletes nothing further, stops the rest of cleanup, and does not end the pass.
                    Logger.upload.info("Cleanup: transport failure reading day \(day, privacy: .public), stopping cleanup for this pass")
                    return .finished
                case .notServing:
                    self.deviceQuietUntil = self.now().addingTimeInterval(3600)
                    progressContinuation.yield(.offline(
                        error: "not serving",
                        healthReason: .journalNotServing,
                        requestedPath: IngestProtocolV3.segmentsDayPath(day)
                    ))
                    return .deviceScopedError
                case .revoked:
                    self.deviceQuietUntil = self.now().addingTimeInterval(3600)
                    progressContinuation.yield(.offline(
                        error: "revoked",
                        healthReason: .pairingRevoked,
                        requestedPath: IngestProtocolV3.segmentsDayPath(day)
                    ))
                    return .deviceScopedError
                case .journalRefused(let reason):
                    if reason == "pairing_identity_unavailable" || reason == "foreign_stream_binding" {
                        self.deviceQuietUntil = self.now().addingTimeInterval(3600)
                    }
                    progressContinuation.yield(.offline(
                        error: "journal refused",
                        healthReason: .journalRefused(reasonCode: reason),
                        requestedPath: IngestProtocolV3.segmentsDayPath(day)
                    ))
                    return .deviceScopedError
                case .listingFailed, .undecoded, .journalRejectedDay:
                    self.dayListingThrottle[dayAddress] = self.now().addingTimeInterval(86400)
                    for _ in eligibleCandidates {
                        progressContinuation.yield(.segmentKept(.listingFailed))
                    }
                    continue
                }
            }

            let segmentsByKey = Dictionary(uniqueKeysWithValues: segmentsDay.items.map { ($0.key, $0) })

            for (candidate, segment, ack) in eligibleCandidates {
                guard !syncPaused, journalContext == context else { return .stoppedForConfigChange }
                let segmentURL = candidate.segmentURL
                let address = SegmentAddress(fingerprint: context.fingerprint.value, day: day, segment: segment)

                guard let serverSegment = segmentsByKey[ack.storedSegmentKey] else {
                    Logger.upload.info("Cleanup: keeping \(segment, privacy: .public) - stored segment key \(ack.storedSegmentKey, privacy: .public) not found on server")
                    self.keepThrottle[address] = self.now().addingTimeInterval(86400)
                    progressContinuation.yield(.segmentKept(.unproven))
                    continue
                }

                let localMedia = candidate.media
                let localNames = Set(localMedia.map(\.lastPathComponent))

                // Pre-check dispositions across all ack files before any hashing:
                let hasInvalidDisposition = ack.payload.files.contains { fileProof in
                    if let disp = fileProof.disposition, disp != .written && disp != .alreadyHeld {
                        return true
                    }
                    return false
                }
                if hasInvalidDisposition {
                    self.keepThrottle[address] = self.now().addingTimeInterval(86400)
                    progressContinuation.yield(.segmentKept(.unproven))
                    continue
                }

                var allFilesProven = true

                for fileProof in ack.payload.files {
                    guard localNames.contains(fileProof.submitted) else { continue }

                    guard !fileProof.submitted.isEmpty,
                          !fileProof.submitted.contains("/"),
                          fileProof.submitted != ".",
                          fileProof.submitted != "..",
                          (fileProof.submitted as NSString).lastPathComponent == fileProof.submitted else {
                        allFilesProven = false
                        break
                    }

                    let targetURL = segmentURL.appendingPathComponent(fileProof.submitted)
                    guard let values = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]),
                          values.isSymbolicLink != true,
                          values.isRegularFile == true,
                          let size = values.fileSize,
                          UInt64(size) == fileProof.size else {
                        allFilesProven = false
                        break
                    }

                    guard let localSHA = client.sha256(of: targetURL),
                          localSHA == fileProof.sha256 else {
                        allFilesProven = false
                        break
                    }

                    guard let serverFile = serverSegment.files.first(where: {
                        $0.name == fileProof.written
                    }),
                          serverFile.sha256 == fileProof.sha256,
                          serverFile.size == fileProof.size,
                          serverFile.status.provesHold else {
                        allFilesProven = false
                        break
                    }
                }

                if !allFilesProven {
                    self.keepThrottle[address] = self.now().addingTimeInterval(86400)
                    progressContinuation.yield(.segmentKept(.unproven))
                    continue
                }

                // Delete proven media files
                for fileProof in ack.payload.files {
                    guard localNames.contains(fileProof.submitted) else { continue }
                    let targetURL = segmentURL.appendingPathComponent(fileProof.submitted)
                    guard !syncPaused, journalContext == context else { return .stoppedForConfigChange }
                    do {
                        try removeItem(targetURL)
                        Logger.upload.info("Cleanup: deleted media file \(fileProof.submitted, privacy: .public) from \(segment, privacy: .public)")
                    } catch {
                        Logger.upload.info("Cleanup: failed to delete \(fileProof.submitted, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        return .finished
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

        let serverURL = try await resolvedServerURL()
        let segmentsDay = try await client.getSegmentsDay(serverURL: serverURL, day: day)
        let ackURL = IngestAcknowledgmentStore.acknowledgmentURL(segmentDirectory: segmentURL, segment: segment)
        guard !syncPaused, journalContext == context,
              let ack = IngestAcknowledgmentStore.read(from: ackURL),
              ack.journalFingerprint == context.fingerprint.value,
              ack.day == day, ack.submittedSegment == segment,
              let serverSegment = segmentsDay.items.first(where: { $0.key == ack.storedSegmentKey }) else {
            throw UploadError.invalidResponse
        }
        for proof in ack.payload.files {
            guard let remote = serverSegment.files.first(where: { $0.name == proof.written }),
                  remote.sha256 == proof.sha256, remote.size == proof.size, remote.status.provesHold,
                  client.sha256(of: segmentURL.appendingPathComponent(proof.submitted)) == proof.sha256 else {
                throw UploadError.invalidResponse
            }
        }
        guard let proof = ack.payload.files.first,
              let readFile = serverSegment.files.first(where: { $0.name == proof.written }) else {
            throw UploadError.invalidResponse
        }
        return ServerFileInfo(
            name: readFile.name,
            submittedName: readFile.submittedName ?? readFile.name,
            sha256: readFile.sha256,
            size: readFile.size,
            status: readFile.status
        )
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

    private func readDayCached(
        day: String,
        serverURL: String,
        client: UploadClient,
        cache: inout [String: Result<IngestProtocolV3.SegmentsDay, DayReadClass>]
    ) async -> Result<IngestProtocolV3.SegmentsDay, DayReadClass> {
        if let cached = cache[day] {
            return cached
        }
        do {
            let segments = try await client.getSegmentsDay(serverURL: serverURL, day: day)
            let res = Result<IngestProtocolV3.SegmentsDay, DayReadClass>.success(segments)
            cache[day] = res
            return res
        } catch {
            let classification = classifyDayRead(error, day: day)
            let res = Result<IngestProtocolV3.SegmentsDay, DayReadClass>.failure(classification)
            cache[day] = res
            return res
        }
    }
}
