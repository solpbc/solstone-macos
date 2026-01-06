// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCaptureCore

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
    }

    // MARK: - Observable State

    public private(set) var status: Status = .notSynced
    public private(set) var pendingCount: Int = 0

    /// Whether syncing is paused - reads from config as single source of truth
    public var syncPaused: Bool {
        config.syncPaused
    }

    // MARK: - Private State

    private let syncService: SyncService
    private var config: AppConfig
    private var eventTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(storageManager: StorageManager, config: AppConfig) {
        self.config = config
        self.syncService = SyncService(storageManager: storageManager)

        // Configure sync service with initial settings
        Task {
            await syncService.configure(
                serverURL: config.serverURL,
                serverKey: config.serverKey,
                localRetentionMB: config.localRetentionMB,
                microphonePriority: config.microphonePriority,
                syncPaused: config.syncPaused
            )
        }

        // Start listening to sync events
        startEventListener()
    }

    // MARK: - Public API

    /// Update configuration (called when settings change)
    public func updateConfig(_ newConfig: AppConfig) {
        let wasPaused = config.syncPaused
        self.config = newConfig

        Task {
            await syncService.configure(
                serverURL: newConfig.serverURL,
                serverKey: newConfig.serverKey,
                localRetentionMB: newConfig.localRetentionMB,
                microphonePriority: newConfig.microphonePriority,
                syncPaused: newConfig.syncPaused
            )

            // If sync was re-enabled, trigger a sync
            if wasPaused && !newConfig.syncPaused {
                await syncService.triggerSync()
            }
        }
    }

    /// Trigger sync on startup
    public func syncOnStartup() async {
        guard !syncPaused else {
            Log.upload("Sync paused, skipping startup sync")
            return
        }

        guard config.isUploadConfigured else {
            Log.upload("Not configured, skipping startup sync")
            return
        }

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

    private func handleProgressEvent(_ event: SyncService.ProgressEvent) {
        switch event {
        case .syncStarted:
            status = .syncing(checked: 0, total: 0)

        case .syncProgress(let checked, let total):
            pendingCount = total - checked
            status = .syncing(checked: checked, total: total)

        case .uploadStarted(let segment):
            status = .uploading(segment: segment)

        case .uploadRetrying(let segment, let attempt):
            status = .retrying(segment: segment, attempts: attempt)

        case .uploadSucceeded:
            // Will get syncProgress or syncComplete next
            break

        case .uploadFailed(let segment, let error):
            Log.upload("Upload failed for \(segment): \(error)")
            // Continue with next segment

        case .syncComplete:
            status = .synced
            pendingCount = 0

        case .offline(let error):
            status = .offline(error)
        }
    }
}
