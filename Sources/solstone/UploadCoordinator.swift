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
    private var bundledLastIngestAt: Date?

    internal var nowProvider: @MainActor () -> Date = { Date() }
    internal var bundledAvailabilityProvider: @MainActor () -> Bool = { false }

    /// Time the app last handled a successful segment upload into the active bundled journal.
    /// nil whenever the bundled status surface is unavailable (external mode, or bundled before installed).
    public var bundledJournalLastIngestAt: Date? {
        bundledAvailabilityProvider() ? bundledLastIngestAt : nil
    }

    // MARK: - Retry State

    private var retryTask: Task<Void, Never>?

    /// Whether syncing is paused - reads from config as single source of truth
    public var syncPaused: Bool {
        config.syncPaused
    }

    // MARK: - Private State

    private let syncService: SyncService
    private let lastContactStore: any LastSuccessfulJournalContactStoring
    private let journalFingerprintProvider: @MainActor @Sendable () -> JournalConnectionFingerprint?
    private var config: AppConfig
    private var eventTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        storageManager: StorageManager,
        config: AppConfig,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver,
        lastContactStore: any LastSuccessfulJournalContactStoring = UserDefaultsLastSuccessfulJournalContactStore(),
        journalFingerprintProvider: @escaping @MainActor @Sendable () -> JournalConnectionFingerprint? = { nil }
    ) {
        self.config = config
        self.lastContactStore = lastContactStore
        self.journalFingerprintProvider = journalFingerprintProvider
        self.syncService = SyncService(
            storageManager: storageManager,
            client: client,
            resolver: resolver
        )

        // Configure sync service with initial settings
        configurationTask = Task {
            await syncService.configure(
                serverURL: config.serverURL,
                serverKey: config.serverKey,
                cacheRetentionDays: config.cacheRetentionDays,
                syncPaused: config.syncPaused
            )
        }

        // Start listening to sync events
        refreshLastSuccessfulJournalContact()
        startEventListener()
    }

    /// Internal init for snapshot/testing — creates SyncService but skips configuration Tasks and event listener
    internal init(
        forSnapshot storageManager: StorageManager,
        config: AppConfig,
        client: UploadClient = UploadClient(),
        resolver: HomeBaseURLResolver? = nil,
        lastContactStore: any LastSuccessfulJournalContactStoring = InMemoryLastSuccessfulJournalContactStore(),
        journalFingerprintProvider: @escaping @MainActor @Sendable () -> JournalConnectionFingerprint? = { nil }
    ) {
        self.config = config
        self.lastContactStore = lastContactStore
        self.journalFingerprintProvider = journalFingerprintProvider
        let resolvedBase = config.serverURL
        self.syncService = SyncService(
            storageManager: storageManager,
            client: client,
            resolver: resolver ?? HomeBaseURLResolver {
                if let resolvedBase {
                    return .url(resolvedBase)
                }
                return .held
            }
        )
        refreshLastSuccessfulJournalContact()
    }

    // MARK: - Public API

    /// Update configuration (called when settings change)
    public func updateConfig(_ newConfig: AppConfig) {
        let wasPaused = config.syncPaused
        if newConfig.serverURL != config.serverURL {
            lastSyncedAt = nil
        }
        self.config = newConfig

        Task {
            await syncService.configure(
                serverURL: newConfig.serverURL,
                serverKey: newConfig.serverKey,
                cacheRetentionDays: newConfig.cacheRetentionDays,
                syncPaused: newConfig.syncPaused
            )

            // If sync was re-enabled, trigger a sync
            if wasPaused && !newConfig.syncPaused {
                await syncService.triggerSync()
            }
        }
        refreshLastSuccessfulJournalContact()
    }

    internal func refreshLastSuccessfulJournalContact() {
        lastSuccessfulJournalContactOutcome = resolveLastSuccessfulJournalContactOutcome(
            read: lastContactStore.read(),
            currentFingerprint: journalFingerprintProvider()
        )
    }

    internal func clearLastSuccessfulJournalContact() {
        lastContactStore.clear()
        refreshLastSuccessfulJournalContact()
    }

    /// Trigger sync on startup
    public func syncOnStartup() async {
        guard !syncPaused else {
            Logger.upload.info("Sync paused, skipping startup sync")
            return
        }

        guard config.isUploadConfigured else {
            Logger.upload.info("Not configured, skipping startup sync")
            return
        }

        await configurationTask?.value
        await syncService.sync()
    }

    /// Trigger sync (called when segment completes)
    public func triggerSync() {
        guard !syncPaused, config.isUploadConfigured else {
            return
        }

        Task {
            await syncService.triggerSync()
        }
    }

    /// Force a full re-sync, clearing cached synced days
    public func forceFullSync() {
        guard config.isUploadConfigured else {
            return
        }

        Task {
            await syncService.clearSyncedDaysCache()
            await syncService.sync(forceFullSync: true)
        }
    }

    /// Test connection to server (for settings UI)
    public func testConnection() async -> String? {
        guard let serverURL = config.serverURL,
              let serverKey = config.serverKey else {
            return "Not configured"
        }
        return await UploadClient().testConnection(serverURL: serverURL, serverKey: serverKey)
    }

    /// Test connection with explicit URL and key (for settings validation)
    public static func testConnection(serverURL: String, serverKey: String) async -> String? {
        return await UploadClient().testConnection(serverURL: serverURL, serverKey: serverKey)
    }

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

        case .uploadSucceeded:
            if bundledAvailabilityProvider() {
                bundledLastIngestAt = nowProvider()
            }

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
            if let fingerprint = journalFingerprintProvider() {
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
