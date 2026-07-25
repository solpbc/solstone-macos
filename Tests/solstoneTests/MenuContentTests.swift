// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SolstoneCore
import Testing
import UpdateKit
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
    private let isolatedDefaults = IsolatedUserDefaults()

    @Test @MainActor func hasPauseResumeControlTruthTable() {
        let updateController = UpdateController(
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: isolatedDefaults.defaults
        )

        let observing = AppState.forSnapshot()
        observing.isRecording = true
        #expect(MenuContent(appState: observing, updateController: updateController).hasPauseResumeControl)

        let paused = AppState.forSnapshot()
        paused.capture.handleCaptureStateChange(.paused(reasons: [.user]))
        #expect(MenuContent(appState: paused, updateController: updateController).hasPauseResumeControl)

        let environmentPaused = AppState.forSnapshot()
        environmentPaused.capture.handleCaptureStateChange(.paused(reasons: [.lock]))
        #expect(!MenuContent(appState: environmentPaused, updateController: updateController).hasPauseResumeControl)

        let starting = AppState.forSnapshot()
        #expect(!MenuContent(appState: starting, updateController: updateController).hasPauseResumeControl)

        let error = AppState.forSnapshot()
        error.errorMessage = "offline"
        #expect(!MenuContent(appState: error, updateController: updateController).hasPauseResumeControl)

        let permissionsNeeded = AppState.forSnapshot()
        permissionsNeeded.initialPermissionCheckComplete = true
        permissionsNeeded.screenRecordingGranted = false
        permissionsNeeded.microphoneGranted = false
        #expect(!MenuContent(appState: permissionsNeeded, updateController: updateController).hasPauseResumeControl)

        let wedge = AppState.forSnapshot()
        wedge.initialPermissionCheckComplete = true
        #expect(!MenuContent(appState: wedge, updateController: updateController).hasPauseResumeControl)
    }

    @Test func menubarStatusRowIconMappingIsExhaustive() {
        let cases: [(MenubarStatusRowState, MenubarIconState)] = [
            (.permissions, .error),
            (.error, .error),
            (.starting, .offline),
            (.journalMigrationNeeded, .offline),
            (.connectionWaiting, .offline),
            (.localOnly, .offline),
            (.syncPaused, .offline),
            (.offline, .offline),
            (.paused, .paused),
            (.observing, .recording),
        ]

        #expect(cases.count == MenubarStatusRowState.allCases.count)
        for (rowState, iconState) in cases {
            #expect(rowState.iconState.axToken == iconState.axToken)
        }
    }

    @Test func settingsObservationAXStateMapsFromRowState() {
        let cases: [(MenubarStatusRowState, SettingsObservationAXState)] = [
            (.permissions, .error),
            (.error, .error),
            (.starting, .starting),
            (.journalMigrationNeeded, .observing),
            (.connectionWaiting, .observing),
            (.localOnly, .observing),
            (.syncPaused, .observing),
            (.offline, .observing),
            (.paused, .paused),
            (.observing, .observing),
        ]

        #expect(cases.count == MenubarStatusRowState.allCases.count)
        for (rowState, settingsState) in cases {
            #expect(SettingsObservationAXState(rowState).axToken == settingsState.axToken)
        }
    }

    @Test func observationClassifierPrecedenceTable() {
        let cases: [(String, MenubarStatusRowState)] = [
            ("permissions", classified(permissionsNeedAttention: true, initialPermissionCheckComplete: false)),
            ("error", classified(errorMessage: "boom")),
            ("starting", classified(initialPermissionCheckComplete: false)),
            ("wedge", classified(isRecording: false)),
            ("paused", classified(isPaused: true)),
            ("journalMigrationNeeded", classified(serviceMode: .bundled, uploadStatus: .synced)),
            ("connectionWaiting", classified(uploadStatus: .awaitingTunnel)),
            ("syncPaused", classified(syncPaused: true, isUploadConfigured: false)),
            ("localOnly", classified(isUploadConfigured: false)),
            ("offline", classified(uploadStatus: .notSynced)),
            ("observing", classified(uploadStatus: .synced)),
        ]

        let expected: [String: MenubarStatusRowState] = [
            "permissions": .permissions,
            "error": .error,
            "starting": .starting,
            "wedge": .error,
            "paused": .paused,
            "journalMigrationNeeded": .journalMigrationNeeded,
            "connectionWaiting": .connectionWaiting,
            "syncPaused": .syncPaused,
            "localOnly": .localOnly,
            "offline": .offline,
            "observing": .observing,
        ]

        for (name, actual) in cases {
            #expect(actual == expected[name])
        }

        #expect(classified(uploadStatus: .retrying(segment: "s1", attempts: 2)) == .offline)
        #expect(classified(uploadStatus: .offline("offline")) == .offline)
        #expect(classified(uploadStatus: .syncing(checked: 1, total: 2)) == .observing)
        #expect(classified(uploadStatus: .uploading(segment: "s1")) == .observing)
        #expect(classified(serviceMode: .bundled, uploadStatus: .awaitingTunnel) == .journalMigrationNeeded)
        #expect(classified(isRecording: false, serviceMode: .bundled) == .journalMigrationNeeded)
        #expect(classified(isPaused: true, serviceMode: .bundled) == .journalMigrationNeeded)
    }

    @Test func pausedHeaderShowsAutoResumeCountdown() {
        #expect(pausedHeaderText(timeRemaining: "8 mins") == "paused, 8 min left")
        #expect(pausedHeaderText(timeRemaining: "1 min") == "paused, 1 min left")
        #expect(pausedHeaderText(timeRemaining: "2 hrs 5 mins") == "paused, 2 hr 5 min left")
        #expect(pausedHeaderText(timeRemaining: "45 secs") == "paused, 45 sec left")
        #expect(pausedHeaderText(timeRemaining: "1 hr") == "paused, 1 hr left")
        #expect(pausedHeaderText(timeRemaining: nil) == "paused")
    }

    @Test func pausedHeaderMappingIsNonMemoized() {
        #expect(pausedHeaderText(timeRemaining: "8 mins") != pausedHeaderText(timeRemaining: "45 secs"))
        #expect(pausedHeaderText(timeRemaining: "1 min") != pausedHeaderText(timeRemaining: nil))
    }

    @Test func openJournalMenuItemKeepsConfigurationGateAndUsesIntentPath() throws {
        let source = try readWireUpSource("Sources/solstone/MenuContent.swift")

        #expect(wireUpContains(source, "if appState.config.isUploadConfigured"))
        #expect(wireUpContains(source, "appState.requestOpenJournal(.root)"))
        #expect(!source.contains("journalURLToOpen"))
        #expect(!source.contains("NSWorkspace.shared.open"))
    }

    @Test func firstSettingsAttentionTruthTable() {
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .idle
        ) == nil)

        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .idle
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .idle
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .updateAvailable)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .failed
        ) == .updateCheckFailed)

        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: true,
            durableUpdateStatus: .idle
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .failed
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .failed
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .failedWithAvailable(version: "1.3.9")
        ) == .updateAvailable)
    }

    @Test func updatesSidebarBadgeTruthTable() {
        #expect(updatesSidebarBadge(for: .deferred(version: "1.3.9")) == .attention)
        #expect(updatesSidebarBadge(for: .staged(version: "1.3.9", releaseNotes: nil)) == .attention)
        #expect(updatesSidebarBadge(for: .failedWithAvailable(version: "1.3.9")) == .attention)
        #expect(updatesSidebarBadge(for: .available(version: "1.3.9", releaseNotes: nil)) == .attention)
        #expect(updatesSidebarBadge(for: .failed) == .attention)
        #expect(updatesSidebarBadge(for: .upToDate) == .done)
        #expect(updatesSidebarBadge(for: .idle) == .blank)
    }

    @Test func settingsAttentionSuffixToShowTruthTable() {
        #expect(settingsAttentionSuffixToShow(
            reason: .journal,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: false
        ) == .journal)
        #expect(settingsAttentionSuffixToShow(
            reason: .journal,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: true
        ) == nil)

        #expect(settingsAttentionSuffixToShow(
            reason: .permissions,
            statusRowCarriesPermissions: true,
            statusRowCarriesJournal: false
        ) == nil)
        #expect(settingsAttentionSuffixToShow(
            reason: .permissions,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: false
        ) == .permissions)

        #expect(settingsAttentionSuffixToShow(
            reason: .updateAvailable,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: false
        ) == .updateAvailable)
        #expect(settingsAttentionSuffixToShow(
            reason: .updateCheckFailed,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: false
        ) == .updateCheckFailed)

        #expect(settingsAttentionSuffixToShow(
            reason: nil,
            statusRowCarriesPermissions: false,
            statusRowCarriesJournal: false
        ) == nil)
    }

    @Test func journalClientRowsUseExpectedAXTokens() {
        #expect(MenubarStatusRowState.journalMigrationNeeded.axToken == "journal_migration_needed")
        #expect(MenubarStatusRowState.connectionWaiting.axToken == "connection_waiting")
    }
}

private func classified(
    permissionsNeedAttention: Bool = false,
    errorMessage: String? = nil,
    initialPermissionCheckComplete: Bool = true,
    isRecording: Bool = true,
    isPaused: Bool = false,
    serviceMode: ServiceMode? = .external,
    syncPaused: Bool = false,
    isUploadConfigured: Bool = true,
    uploadStatus: UploadCoordinator.Status = .synced
) -> MenubarStatusRowState {
    classifyObservationRowState(
        permissionsNeedAttention: permissionsNeedAttention,
        errorMessage: errorMessage,
        initialPermissionCheckComplete: initialPermissionCheckComplete,
        isRecording: isRecording,
        isPaused: isPaused,
        serviceMode: serviceMode,
        syncPaused: syncPaused,
        isUploadConfigured: isUploadConfigured,
        uploadStatus: uploadStatus
    )
}
