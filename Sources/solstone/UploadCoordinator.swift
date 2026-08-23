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
        case .invalidRequest:
            return .uploadFailed
        case .invalidResponse:
            return .uploadInvalidResponse
        case .serverError(let statusCode, _):
            return .httpStatus(statusCode)
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
    }

    // MARK: - Observable State

    public internal(set) var status: Status = .notSynced
    public internal(set) var pendingCount: Int = 0
    public internal(set) var lastError: String?
    public internal(set) var lastSyncedAt: Date?
    public internal(set) var recentErrorCount: Int = 0
    public internal(set) var lastErrorReason: String?
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
        journalIdentityProvider: @escaping @MainActor @Sendable () -> JournalIdentityRead = { .absent }
    ) {
        self.config = config
        self.client = client
        self.resolver = resolver
        self.pairedIngestIdentity = pairedIngestIdentity
        self.automaticSyncEnabled = automaticSyncEnabled
        self.lastContactStore = lastContactStore
        self.lastDeliveryStore = lastDeliveryStore
        self.journalIdentityProvider = journalIdentityProvider
        self.syncService = SyncService(
            storageManager: storageManager,
            client: client,
            resolver: resolver
        )

        let initialFingerprint = journalIdentityProvider().fingerprint
        self.pushedJournalFingerprint = initialFingerprint

        // Configure sync service with initial settings
        configurationTask = Task {
            await syncService.configure(
                pairingIdentity: pairedIngestIdentity,
                journalFingerprint: initialFingerprint,
                cacheRetentionDays: config.cacheRetentionDays,
                syncPaused: config.syncPaused
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
        journalIdentityProvider: @escaping @MainActor @Sendable () -> JournalIdentityRead = { .absent }
    ) {
        self.config = config
        self.client = client
        self.lastContactStore = lastContactStore
        self.lastDeliveryStore = lastDeliveryStore
        self.journalIdentityProvider = journalIdentityProvider
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
                cacheRetentionDays: newConfig.cacheRetentionDays,
                syncPaused: newConfig.syncPaused
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
        guard pairedIngestIdentity != identity || pushedJournalFingerprint != fingerprint else {
            return
        }
        pairedIngestIdentity = identity
        pushedJournalFingerprint = fingerprint
        Task {
            await syncService.configure(
                pairingIdentity: identity,
                journalFingerprint: fingerprint,
                cacheRetentionDays: config.cacheRetentionDays,
                syncPaused: config.syncPaused
            )
        }
    }

    var isPairedIngestReady: Bool {
        pairedIngestIdentity != nil
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

    /// Force a full re-sync, clearing cached synced days
    public func forceFullSync() {
        guard automaticSyncEnabled, isPairedIngestReady else {
            return
        }

        Task {
            await syncService.clearSyncedDaysCache()
            await syncService.sync(forceFullSync: true)
        }
    }

    /// Validates the currently connected paired loopback journal, not the
    /// editable legacy external-service fields.
    public func testPairedIngestConnection() async -> String? {
        guard pairedIngestIdentity != nil else { return "Not configured" }
        switch await resolver.resolve() {
        case .url(let serverURL):
            return await client.testPairedIngestConnection(serverURL: serverURL)
        case .held:
            return "Not configured"
        }
    }

#if DEBUG
    func runLiveIngestProbe(segmentURL: URL, day: String, segment: String) async throws -> ServerFileInfo {
        guard let pairedIngestIdentity else {
            throw UploadError.invalidResponse
        }
        await configurationTask?.value
        await syncService.configure(
            pairingIdentity: pairedIngestIdentity,
            journalFingerprint: journalIdentityProvider().fingerprint,
            cacheRetentionDays: config.cacheRetentionDays,
            syncPaused: config.syncPaused
        )
        return try await syncService.runLiveProbe(segmentURL: segmentURL, day: day, segment: segment)
    }
#endif

    // MARK: - Event Handling

    private func startEventListener() {
        eventTask = Task { [weak self] in
            guard let self = self else { return }

            let stream = self.syncService.progressStream
            for await event in stream {
                await MainActor.run {
                    self.handleProgressEvent(event)
                }
            }
        }
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

        case .uploadSucceeded(_, let proof):
            handleProvenDelivery(proof: proof.map { JournalConnectionFingerprint(value: $0) })

        case .uploadFailed(_, let error, let healthReason):
            let sanitizedReason = sanitizedObserverHealthErrorReason(healthReason)
            Logger.upload.info("Upload failed: \(sanitizedReason, privacy: .public)")
            lastError = error
            incrementRecentErrorCount()
            lastErrorReason = sanitizedReason
            // Continue with next segment

        case .journalContactSucceeded:
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
            lastErrorReason = nil
            lastError = nil

        case .syncComplete:
            status = .synced
            pendingCount = 0
            recentErrorCount = 0
            lastError = nil
            lastErrorReason = nil

        case .offline(let error, let healthReason):
            lastError = error
            incrementRecentErrorCount()
            lastErrorReason = sanitizedObserverHealthErrorReason(healthReason)
            status = .offline(error)
            scheduleRetry()

        case .awaitingTunnel:
            retryTask?.cancel()
            retryTask = nil
            status = .awaitingTunnel
        }
    }

    private func handleProvenDelivery(proof: JournalConnectionFingerprint?) {
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
                lastJournalDeliveryWriteFailed = true
                Logger.upload.error("delivery_write_failed")
            }
        }
        refreshLastJournalDelivery()
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
