// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public enum ObserverHealthFailureReason: Sendable, Equatable {
    case urlErrorCode(Int)
    case httpStatus(Int)
    case uploadInvalidURL
    case uploadNoFiles
    case uploadInvalidResponse
    case configChanged
    case notConfigured
    case uploadFailed
    /// The journal answered, and reported that it could not read this day's
    /// stored files. `reasonCode` is the journal's own token for why.
    case journalRejectedDay(day: String, reasonCode: String)
    case pairingRevoked
    case journalNotServing
    case journalRefused(reasonCode: String)
}

internal func observerHealthFailureReason(from error: Error) -> ObserverHealthFailureReason {
    if let urlError = error as? URLError {
        return .urlErrorCode(urlError.code.rawValue)
    }

    if let uploadError = error as? UploadError {
        switch uploadError {
        case .invalidURL:
            return .uploadInvalidURL
        case .noFiles:
            return .uploadNoFiles
        case .invalidRequest, .preparationFailed:
            return .uploadFailed
        case .invalidResponse:
            return .uploadInvalidResponse
        case .serverError(let serverError):
            return .httpStatus(serverError.statusCode)
        }
    }

    return .uploadFailed
}

internal func sanitizedObserverHealthErrorReason(_ reason: ObserverHealthFailureReason) -> String {
    let token: String
    switch reason {
    case .urlErrorCode(let code):
        token = "url_error_\(code)"
    case .httpStatus(let statusCode):
        token = "http_\(statusCode)"
    case .uploadInvalidURL:
        token = "upload_invalid_url"
    case .uploadNoFiles:
        token = "upload_no_files"
    case .uploadInvalidResponse:
        token = "upload_invalid_response"
    case .configChanged:
        token = "config_changed"
    case .notConfigured:
        token = "not_configured"
    case .uploadFailed:
        token = "upload_failed"
    case .journalRejectedDay(let day, let reasonCode):
        let safeCode = reasonCode.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.lowercased()
        token = "journal_rejected_day_\(day)_\(safeCode.isEmpty ? "unknown" : safeCode)"
    case .pairingRevoked:
        token = "pairing_revoked"
    case .journalNotServing:
        token = "journal_not_serving"
    case .journalRefused(let reasonCode):
        let safeCode = reasonCode.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.lowercased()
        token = "journal_refused_\(safeCode.isEmpty ? "unknown" : safeCode)"
    }
    return String(token.prefix(200))
}

/// UI-facing coordinator for upload/sync status
/// Thin @MainActor layer that observes SyncService events and exposes state for SwiftUI
@MainActor
@Observable
public final class UploadCoordinator {
    /// Current sync/upload status for UI
    public enum Status: Sendable, Equatable {
        case notSynced          // Initial state
        case syncing(checked: Int, total: Int)
        case synced             // Successfully verified with server
        case uploading(segment: String)
        case retrying(segment: String, attempts: Int)
        case offline(String)    // Can't reach server
        case awaitingTunnel
        case blocked(String)    // Preserved local capture needs attention
    }

    // MARK: - Observable State

    public internal(set) var status: Status = .notSynced
    public internal(set) var pendingCount: Int = 0
    public internal(set) var lastError: String?
    public internal(set) var lastSyncedAt: Date?
    public internal(set) var recentErrorCount: Int = 0
    public internal(set) var lastErrorReason: String?
    public internal(set) var lastHealthReason: ObserverHealthFailureReason?
    public internal(set) var lastRequestedIngestPath: String?
    internal private(set) var lastSuccessfulJournalContactOutcome: SetupLastSyncOutcome = .notLinked
    internal private(set) var lastJournalDeliveryOutcome: LastJournalDeliveryOutcome = .notLinked
    internal private(set) var lastJournalDeliveryWriteFailed: Bool = false

    internal var nowProvider: @MainActor () -> Date = { Date() }

    // MARK: - Retry State

    private var retryTask: Task<Void, Never>?

    /// Whether syncing is paused - reads from config as single source of truth
    public var syncPaused: Bool {
        config.syncPaused
    }

    // MARK: - Private State

    private let syncService: SyncService
    private let client: UploadClient
    private let resolver: HomeBaseURLResolver
    private let lastContactStore: any LastSuccessfulJournalContactStoring
    private let lastDeliveryStore: any LastJournalDeliveryStoring
    private let journalIdentityProvider: @MainActor @Sendable () -> JournalIdentityRead
    private let ordinaryAdmission: @MainActor @Sendable () -> Bool
    private let pairingCredentialStore: PairingCredentialStore?
    private var ordinaryTrafficRevoked = false
    private var minimumProgressEpoch: UInt64 = 0
    private let recorder: DiagnosticEvidenceRecorder
    private let logAdapter: DiagnosticEvidenceLoggingAdapter
    private let classifiedLog: any ClassifiedLogSinking
    private var config: AppConfig
    private var pairedIngestIdentity: TunnelPairingIdentity?
    private var pushedJournalFingerprint: JournalConnectionFingerprint?
    private let automaticSyncEnabled: Bool
    private var eventTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        storageManager: StorageManager,
        config: AppConfig,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver,
        pairedIngestIdentity: TunnelPairingIdentity? = nil,
        automaticSyncEnabled: Bool = true,
        lastContactStore: any LastSuccessfulJournalContactStoring = UserDefaultsLastSuccessfulJournalContactStore(),
        lastDeliveryStore: any LastJournalDeliveryStoring = UserDefaultsLastJournalDeliveryStore(),
        journalIdentityProvider: @escaping @MainActor @Sendable () -> JournalIdentityRead = { .absent },
        ordinaryAdmission: @escaping @MainActor @Sendable () -> Bool = { true },
        pairingCredentialStore: PairingCredentialStore? = nil,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink.upload
    ) {
        self.config = config
        self.client = client
        self.resolver = resolver
        self.pairedIngestIdentity = pairedIngestIdentity
        self.automaticSyncEnabled = automaticSyncEnabled
        self.lastContactStore = lastContactStore
        self.lastDeliveryStore = lastDeliveryStore
        self.journalIdentityProvider = journalIdentityProvider
        self.ordinaryAdmission = ordinaryAdmission
        self.pairingCredentialStore = pairingCredentialStore
        self.recorder = recorder
        self.logAdapter = logAdapter
        self.classifiedLog = classifiedLog
        self.syncService = SyncService(
            storageManager: storageManager,
            client: client,
            resolver: resolver,
            pairingCredentialStore: pairingCredentialStore
        )

        let initialFingerprint = journalIdentityProvider().fingerprint
        self.pushedJournalFingerprint = initialFingerprint

        // Configure sync service with initial settings
        configurationTask = Task {
            await syncService.configure(
                pairingIdentity: pairedIngestIdentity,
                journalFingerprint: initialFingerprint,
                syncPaused: config.syncPaused,
            preserveSyncedSegments: config.preserveSyncedSegments
            )
        }

        // Start listening to sync events
        refreshLastSuccessfulJournalContact()
        refreshLastJournalDelivery()
        startEventListener()
    }

    /// Internal init for snapshot/testing — creates SyncService but skips configuration Tasks and event listener
    internal init(
        forSnapshot storageManager: StorageManager,
        config: AppConfig,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver? = nil,
        lastContactStore: any LastSuccessfulJournalContactStoring = InMemoryLastSuccessfulJournalContactStore(),
        lastDeliveryStore: any LastJournalDeliveryStoring = InMemoryLastJournalDeliveryStore(),
        journalIdentityProvider: @escaping @MainActor @Sendable () -> JournalIdentityRead = { .absent },
        ordinaryAdmission: @escaping @MainActor @Sendable () -> Bool = { true },
        recorder: DiagnosticEvidenceRecorder = .dormant,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        classifiedLog: any ClassifiedLogSinking = LoggerClassifiedLogSink.upload
    ) {
        self.config = config
        self.client = client
        self.lastContactStore = lastContactStore
        self.lastDeliveryStore = lastDeliveryStore
        self.journalIdentityProvider = journalIdentityProvider
        self.ordinaryAdmission = ordinaryAdmission
        self.pairingCredentialStore = nil
        self.recorder = recorder
        self.logAdapter = logAdapter
        self.classifiedLog = classifiedLog
        let snapshotResolver = resolver ?? HomeBaseURLResolver { .held }
        self.syncService = SyncService(
            storageManager: storageManager,
            client: client,
            resolver: snapshotResolver
        )
        self.resolver = snapshotResolver
        self.pairedIngestIdentity = nil
        self.automaticSyncEnabled = false
        refreshLastSuccessfulJournalContact()
        refreshLastJournalDelivery()
    }

    // MARK: - Public API

    /// Update configuration (called when settings change)
    public func updateConfig(_ newConfig: AppConfig) {
        let wasPaused = config.syncPaused
        if newConfig.serverURL != config.serverURL {
            lastSyncedAt = nil
        }
        self.config = newConfig

        let fingerprint = journalIdentityProvider().fingerprint
        pushedJournalFingerprint = fingerprint
        Task {
            await syncService.configure(
                pairingIdentity: pairedIngestIdentity,
                journalFingerprint: fingerprint,
                syncPaused: newConfig.syncPaused,
                preserveSyncedSegments: newConfig.preserveSyncedSegments
            )

            // If sync was re-enabled, trigger a sync
            if automaticSyncEnabled, wasPaused && !newConfig.syncPaused {
                await syncService.triggerSync()
            }
        }
        refreshLastSuccessfulJournalContact()
        refreshLastJournalDelivery()
    }

    /// The paired tunnel identity is the only readiness credential for v3 sync.
    /// This snapshot is supplied by AppState's existing tunnel-state observation.
    func updatePairedIngestIdentity(_ identity: TunnelPairingIdentity?) {
        refreshLastJournalDelivery()
        let fingerprint = journalIdentityProvider().fingerprint
        if identity != nil, ordinaryAdmission() {
            ordinaryTrafficRevoked = false
        }
        guard pairedIngestIdentity != identity || pushedJournalFingerprint != fingerprint else {
            return
        }
        pairedIngestIdentity = identity
        pushedJournalFingerprint = fingerprint
        Task {
            await syncService.configure(
                pairingIdentity: identity,
                journalFingerprint: fingerprint,
                syncPaused: config.syncPaused,
            preserveSyncedSegments: config.preserveSyncedSegments
            )
        }
    }

    func revokeOrdinaryTraffic() async {
        ordinaryTrafficRevoked = true
        minimumProgressEpoch = await syncService.revokeOrdinaryTraffic()
    }

    var isPairedIngestReady: Bool {
        pairedIngestIdentity != nil && ordinaryAdmission()
    }

    internal func refreshLastSuccessfulJournalContact() {
        lastSuccessfulJournalContactOutcome = resolveLastSuccessfulJournalContactOutcome(
            read: lastContactStore.read(),
            currentFingerprint: journalIdentityProvider().fingerprint
        )
    }

    internal func refreshLastJournalDelivery() {
        lastJournalDeliveryOutcome = resolveLastJournalDeliveryOutcome(
            read: lastDeliveryStore.read(),
            identity: journalIdentityProvider(),
            now: nowProvider(),
            persistenceFailed: lastJournalDeliveryWriteFailed
        )
    }

    internal func clearLastSuccessfulJournalContact() {
        lastContactStore.clear()
        refreshLastSuccessfulJournalContact()
    }

    /// Trigger sync on startup
    public func syncOnStartup() async {
        guard automaticSyncEnabled else {
            return
        }
        guard !syncPaused else {
            Logger.upload.info("Sync paused, skipping startup sync")
            return
        }

        guard isPairedIngestReady else {
            Logger.upload.info("Not configured, skipping startup sync")
            return
        }

        await configurationTask?.value
        await syncService.sync()
    }

    /// Trigger sync (called when segment completes)
    public func triggerSync() {
        guard automaticSyncEnabled, !syncPaused, isPairedIngestReady else {
            return
        }

        Task {
            await syncService.triggerSync()
        }
    }

    /// Force a sync
    public func forceFullSync() {
        guard automaticSyncEnabled, isPairedIngestReady else {
            return
        }

        Task {
            await syncService.sync()
        }
    }

    /// Validates the currently connected paired loopback journal, not the
    /// editable legacy external-service fields.
    public func testPairedIngestConnection() async -> String? {
        guard pairedIngestIdentity != nil, ordinaryAdmission() else { return "Not configured" }
        switch await resolver.resolve() {
        case .url(let serverURL):
            let today = IngestDayKey.string(from: nowProvider())
            return await client.testPairedIngestConnection(serverURL: serverURL, day: today)
        case .held:
            return "Not configured"
        }
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    func runLiveIngestProbe(segmentURL: URL, day: String, segment: String) async throws -> ServerFileInfo {
        guard let pairedIngestIdentity else {
            throw UploadError.invalidResponse
        }
        await configurationTask?.value
        await syncService.configure(
            pairingIdentity: pairedIngestIdentity,
            journalFingerprint: journalIdentityProvider().fingerprint,
            syncPaused: config.syncPaused,
            preserveSyncedSegments: config.preserveSyncedSegments
        )
        return try await syncService.runLiveProbe(segmentURL: segmentURL, day: day, segment: segment)
    }
#endif

    // MARK: - Event Handling

    public func readDiagnosticBacklog() async -> SyncService.DiagnosticBacklog {
        await syncService.readDiagnosticBacklog()
    }

    private func startEventListener() {
        eventTask = Task { [weak self] in
            guard let self = self else { return }

            let stream = self.syncService.progressEnvelopeStream
            for await envelope in stream {
                await MainActor.run {
                    self.handleProgressEnvelope(envelope)
                }
            }
        }
    }

    internal func handleProgressEnvelope(_ envelope: SyncService.ProgressEnvelope) {
        guard envelope.epoch == minimumProgressEpoch,
              ordinaryProgressIsCurrent(envelope.context) else { return }
        handleProgressEvent(envelope.event)
    }

    internal func handleProgressEvent(_ event: SyncService.ProgressEvent) {
        switch event {
        case .syncStarted:
            retryTask?.cancel()
            retryTask = nil
            status = .syncing(checked: 0, total: 0)

        case .syncProgress(let checked, let total):
            pendingCount = total - checked
            status = .syncing(checked: checked, total: total)

        case .uploadStarted(let segment):
            status = .uploading(segment: segment)

        case .uploadRetrying(let segment, let attempt):
            status = .retrying(segment: segment, attempts: attempt)

        case .uploadSucceeded(_, let proof, let context):
            guard ordinaryProgressIsCurrent(context) else { return }
            handleProvenDelivery(proof: JournalConnectionFingerprint(value: proof))

        case .uploadFailed(_, _, let healthReason, let requestedPath, let context):
            guard ordinaryProgressIsCurrent(context) else { return }
            recordIngestFailure(healthReason: healthReason, requestedPath: requestedPath)
            // Continue with next segment

        case .journalContactSucceeded(let context):
            guard ordinaryProgressIsCurrent(context) else { return }
            let now = nowProvider()
            lastSyncedAt = now
            if let fingerprint = journalIdentityProvider().fingerprint {
                lastContactStore.write(LastSuccessfulJournalContactPayload(
                    date: now,
                    fingerprint: fingerprint.value
                ))
                lastSuccessfulJournalContactOutcome = .synced(now)
            } else {
                refreshLastSuccessfulJournalContact()
            }
            recentErrorCount = 0
            clearIngestFailure()

        case .syncComplete(let context):
            guard ordinaryProgressIsCurrent(context) else { return }
            status = .synced
            pendingCount = 0
            recentErrorCount = 0
            clearIngestFailure()

        case .syncBlocked(let count, let reason):
            pendingCount = count
            let message = reason.localizedDescription
            status = .blocked(message)
            lastError = message
            lastErrorReason = reason == .invalidRequest ? "capture.upload_exceeds_limits" : "capture.upload_preparation_failed"
            recorder.enqueue(reason == .invalidRequest ? .syncUploadExceedsLimits : .syncUploadPreparationFailed)

        case .offline(_, let healthReason, let requestedPath):
            recordIngestFailure(healthReason: healthReason, requestedPath: requestedPath)
            status = .offline(classifiedObserverHealthOwnerCopy(healthReason))
            scheduleRetry()

        case .awaitingTunnel:
            retryTask?.cancel()
            retryTask = nil
            status = .awaitingTunnel

        case .segmentUnprovable:
            recorder.enqueue(.syncSegmentUnprovable)
        }
    }

    private func ordinaryProgressIsCurrent(_ context: JournalUploadContext?) -> Bool {
        guard !ordinaryTrafficRevoked, ordinaryAdmission() else { return false }
        guard let context else { return pairingCredentialStore == nil }
        guard pairedIngestIdentity == context.pairing,
              journalIdentityProvider().fingerprint == context.fingerprint else { return false }
        return pairingCredentialStore?.ordinarySyncIsCurrent(context) ?? true
    }

    private func handleProvenDelivery(proof: JournalConnectionFingerprint) {
        let identity = journalIdentityProvider()
        if case .identified(let current) = identity, proof == current {
            let payload = LastJournalDeliveryPayload(
                date: nowProvider(),
                fingerprint: current.value
            )
            switch lastDeliveryStore.write(payload) {
            case .confirmed:
                lastJournalDeliveryWriteFailed = false
            case .failed:
                let wasFailed = lastJournalDeliveryWriteFailed
                lastJournalDeliveryWriteFailed = true
                recorder.enqueue(.deliveryWriteFailed)
                if !wasFailed {
                    logAdapter.deliveryWriteFailed()
                }
            }
        }
        refreshLastJournalDelivery()
    }

    private func recordIngestFailure(
        healthReason: ObserverHealthFailureReason,
        requestedPath: String
    ) {
        let sanitizedReason = sanitizedObserverHealthErrorReason(healthReason)
        classifiedLog.emit(
            ClassifiedLogEmission(
                level: .notice,
                classification: "upload-failing",
                publicFields: ["reason": sanitizedReason]
            )
        )
        lastError = classifiedObserverHealthOwnerCopy(healthReason)
        lastErrorReason = sanitizedReason
        lastHealthReason = healthReason
        lastRequestedIngestPath = requestedPath
        incrementRecentErrorCount()
    }

    private func clearIngestFailure() {
        lastError = nil
        lastErrorReason = nil
        lastHealthReason = nil
        lastRequestedIngestPath = nil
    }

    private func incrementRecentErrorCount() {
        recentErrorCount = min(recentErrorCount + 1, 99)
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.triggerSync()
        }
    }
}
