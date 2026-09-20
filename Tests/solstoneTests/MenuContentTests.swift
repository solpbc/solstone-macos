// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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
        permissionsNeeded.capture.publishScreenRecordingPermission(.notGranted)
        permissionsNeeded.microphoneAuthorizationCause = .denied
        #expect(!MenuContent(appState: permissionsNeeded, updateController: updateController).hasPauseResumeControl)

        let wedge = AppState.forSnapshot()
        wedge.initialPermissionCheckComplete = true
        #expect(!MenuContent(appState: wedge, updateController: updateController).hasPauseResumeControl)
    }

    @Test func menubarStatusRowIconMappingIsExhaustive() {
        let cases: [(MenubarStatusRowState, String)] = [
            (.observing, "sol-ring-template"),
            (.starting, "sol-ring-icon-connecting-template"),
            (.connectionWaiting, "sol-ring-icon-connecting-template"),
            (.paused, "sol-ring-icon-paused-template"),
            (.stopped, "sol-ring-icon-paused-template"),
            (.syncPaused, "sol-ring-icon-paused-template"),
            (.localOnly, "sol-ring-icon-paused-template"),
            (.journalMigrationNeeded, "sol-ring-icon-attention-template"),
            (.permissions, "sol-ring-icon-attention-template"),
            (.offline, "sol-ring-icon-offline-template"),
            (.error, "sol-ring-icon-error-template"),
        ]

        #expect(cases.count == MenubarStatusRowState.allCases.count)
        for (rowState, iconName) in cases {
            #expect(rowState.iconState.iconName == iconName)
        }
    }

    @Test func menubarStatusRowIconMappingNegativeTwins() {
        #expect(MenubarStatusRowState.permissions.iconState.iconName == "sol-ring-icon-attention-template")
        #expect(MenubarStatusRowState.permissions.iconState.iconName != "sol-ring-icon-error-template")
        #expect(MenubarStatusRowState.journalMigrationNeeded.iconState.iconName != "sol-ring-icon-offline-template")
        #expect(MenubarStatusRowState.localOnly.iconState.iconName == "sol-ring-icon-paused-template")
        #expect(MenubarStatusRowState.syncPaused.iconState.iconName == "sol-ring-icon-paused-template")
        #expect(MenubarStatusRowState.starting.iconState.iconName == "sol-ring-icon-connecting-template")
        #expect(MenubarStatusRowState.connectionWaiting.iconState.iconName == "sol-ring-icon-connecting-template")
    }

    @Test func settingsObservationAXStateMapsFromRowState() {
        let cases: [(MenubarStatusRowState, SettingsObservationAXState)] = [
            (.observing, .observing),
            (.starting, .connecting),
            (.connectionWaiting, .connecting),
            (.paused, .paused),
            (.stopped, .off),
            (.syncPaused, .notReaching),
            (.localOnly, .noJournal),
            (.journalMigrationNeeded, .attention),
            (.permissions, .attention),
            (.offline, .savedLocally),
            (.error, .error),
        ]

        #expect(cases.count == MenubarStatusRowState.allCases.count)
        for (rowState, settingsState) in cases {
            #expect(SettingsObservationAXState(rowState).axToken == settingsState.axToken)
        }
    }

    @Test func settingsObservationAXStateNegativeTwins() {
        let localOnly = SettingsObservationAXState(.localOnly).axToken
        let syncPaused = SettingsObservationAXState(.syncPaused).axToken
        #expect(localOnly != "on")
        #expect(localOnly != "paused")
        #expect(localOnly != syncPaused)
        #expect(syncPaused != "on")
        #expect(syncPaused != "paused")
        #expect(SettingsObservationAXState(.journalMigrationNeeded).axToken != "on")
        #expect(SettingsObservationAXState(.connectionWaiting).axToken != "on")
        #expect(SettingsObservationAXState(.offline).axToken != "on")
        #expect(SettingsObservationAXState(.permissions).axToken != "error")
        #expect(SettingsObservationAXState(.error).axToken == "error")
        #expect(SettingsObservationAXState(.error).axToken != "attention")
    }

    @Test func settingsObservationAXStateVocabularyDropsStarting() {
        let tokens = SettingsObservationAXState.allCases.map(\.axToken)
        #expect(tokens.count == 9)
        #expect(!tokens.contains("starting"))
        #expect(SettingsObservationAXState(.starting).axToken == "connecting")
        #expect(SettingsObservationAXState(.connectionWaiting).axToken == "connecting")
    }

    @Test func settingsObservationHeadlinesDistinguishCaptureAndJournalAxes() {
        let paused = SettingsObservationAXState(.paused).headline
        let syncPaused = SettingsObservationAXState(.syncPaused).headline
        let localOnly = SettingsObservationAXState(.localOnly).headline
        let observing = SettingsObservationAXState(.observing).headline
        #expect(paused != syncPaused)
        #expect(paused != localOnly)
        #expect(paused != observing)
        #expect(syncPaused != localOnly)
        #expect(syncPaused != observing)
        #expect(localOnly != observing)

        #expect(
            SettingsObservationAXState(.starting).headline
                == SettingsObservationAXState(.connectionWaiting).headline
        )

        let permissions = SettingsObservationAXState(.permissions).headline
        let journalMigrationNeeded = SettingsObservationAXState(.journalMigrationNeeded).headline
        let error = SettingsObservationAXState(.error).headline
        #expect(permissions == journalMigrationNeeded)
        #expect(permissions != error)
        #expect(journalMigrationNeeded != error)
    }

    @Test func observationClassifierPrecedenceTable() {
        // Never-set-up is no journal on record, not "unconfigured address + not ingest-ready".
        let cases: [(String, MenubarStatusRowState)] = [
            ("permissions", classified(permissionsNeedAttention: true, initialPermissionCheckComplete: false)),
            ("error", classified(errorMessage: "boom")),
            ("starting", classified(initialPermissionCheckComplete: false)),
            ("wedge", classified(isRecording: false)),
            ("paused", classified(isPaused: true)),
            ("journalMigrationNeeded", classified(serviceMode: .bundled, uploadStatus: .synced)),
            ("connectionWaiting", classified(uploadStatus: .awaitingTunnel)),
            ("syncPaused", classified(syncPaused: true)),
            ("localOnly", classified(hasJournalOnRecord: false)),
            ("offline", classified(uploadStatus: .notSynced)),
            ("observing", classified(uploadStatus: .synced)),
        ]

        let expected: [String: MenubarStatusRowState] = [
            "permissions": .permissions,
            "error": .error,
            "starting": .starting,
            "wedge": .stopped,
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

        for status in representativeUploadStatuses() {
            #expect(classified(uploadStatus: status) == row(forUploadStatus: status))
        }
        #expect(classified(serviceMode: .bundled, uploadStatus: .awaitingTunnel) == .journalMigrationNeeded)
        #expect(classified(isRecording: false, serviceMode: .bundled) == .journalMigrationNeeded)
        #expect(classified(isPaused: true, serviceMode: .bundled) == .journalMigrationNeeded)
    }

    @Test @MainActor func pairedNotReadyObservationMatrix() {
        // Red-first: cached identity without on-record is still never-set-up (pre-fix tree).
        #expect(classified(hasJournalOnRecord: false, uploadStatus: .synced) == .localOnly)

        let connecting = connectingVerdict()
        let connectingRow = classified(
            hasJournalOnRecord: true,
            journalConnectionAXToken: connecting.axToken,
            uploadStatus: .synced
        )
        #expect(connectingRow == .connectionWaiting)
        #expect(connectingRow != .localOnly)
        #expect(connectingRow != .observing)

        // Revoked = delete-failed: pairing present + revoked error.
        // Unreadable = failed identity + keychain-unavailable.
        for cause in ownerProducedFailureCauses() {
            let verdict = journalVerdict(for: cause)
            let row = classified(
                hasJournalOnRecord: true,
                journalFailureCause: verdict.failureCause,
                uploadStatus: .synced
            )
            #expect(row == .offline, "\(String(describing: cause)) should be offline, not observing from last-sync")
            #expect(row != .localOnly)
            #expect(row != .observing)
        }

        // Remaining cell (nil token, nil cause) follows the upload-status switch and may be observing.
        for status in representativeUploadStatuses() {
            let actual = classified(hasJournalOnRecord: true, uploadStatus: status)
            #expect(actual == row(forUploadStatus: status))
            #expect(actual != .localOnly)
        }
    }

    @Test func noJournalOnRecordIsLocalOnlyAndThirdBucketFollowsUploadStatus() {
        #expect(classified(hasJournalOnRecord: false, uploadStatus: .synced) == .localOnly)

        for status in representativeUploadStatuses() {
            let actual = classified(hasJournalOnRecord: true, uploadStatus: status)
            #expect(actual == row(forUploadStatus: status))
            #expect(actual != .localOnly)
            if status != .awaitingTunnel {
                #expect(actual != .connectionWaiting || row(forUploadStatus: status) == .connectionWaiting)
            }
        }
    }

    @Test func pairedKeylessClientIsNotPresentedAsLocalOnly() {
        #expect(classified(
            isPairedIngestReady: true,
            uploadStatus: .syncing(checked: 0, total: 1)
        ) == .observing)
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

        #expect(wireUpContains(source, "if appState.canOpenJournal"))
        #expect(wireUpContains(source, "appState.requestOpenJournal(.root)"))
        #expect(!source.contains("journalURLToOpen"))
        #expect(!source.contains("NSWorkspace.shared.open"))
    }

    @Test func menubarPresentationAttentionTruthTable() {
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .idle
        ) == nil)

        #expect(presentationAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .idle
        ) == .permissions)
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .idle
        ) == .journal)
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .updateAvailable)
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            durableUpdateStatus: .failed
        ) == .updateCheckFailed)

        #expect(presentationAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: true,
            durableUpdateStatus: .idle
        ) == .permissions)
        #expect(presentationAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .permissions)
        #expect(presentationAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            durableUpdateStatus: .failed
        ) == .permissions)
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .available(version: "1.3.9", releaseNotes: nil)
        ) == .journal)
        #expect(presentationAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            durableUpdateStatus: .failed
        ) == .journal)
        #expect(presentationAttention(
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

    @Test @MainActor func attentionToSurfaceDerivesSuppressionFromObservationRow() {
        // AX / shared attentionToSurface policy: Connecting has no journal suffix. Offline suppresses noRoute/unreachable and surfaces the rest.
        #expect(attentionToSurface(.journal, alreadySaidBy: .observing) == .journal)
        #expect(attentionToSurface(.journal, alreadySaidBy: .journalMigrationNeeded) == nil)
        #expect(attentionToSurface(.journal, alreadySaidBy: .localOnly) == nil)
        #expect(attentionToSurface(.journal, alreadySaidBy: .connectionWaiting) == nil)

        #expect(attentionToSurface(.permissions, alreadySaidBy: .permissions) == nil)
        #expect(attentionToSurface(.permissions, alreadySaidBy: .observing) == .permissions)

        #expect(attentionToSurface(.updateAvailable, alreadySaidBy: .permissions) == .updateAvailable)
        #expect(attentionToSurface(.updateCheckFailed, alreadySaidBy: .localOnly) == .updateCheckFailed)
        #expect(attentionToSurface(nil, alreadySaidBy: .observing) == nil)

        for cause in allJournalConnectionFailureCauses() {
            let offline = attentionToSurface(
                .journal,
                alreadySaidBy: .offline,
                journalFailureCause: cause
            )
            if offlineSuppressesJournalSuffix(cause) {
                #expect(offline == nil, "\(String(describing: cause)) should suppress on offline")
            } else {
                #expect(offline == .journal, "\(String(describing: cause)) should surface on offline")
            }
            #expect(attentionToSurface(
                .journal,
                alreadySaidBy: .connectionWaiting,
                journalFailureCause: cause
            ) == nil)
        }
    }

    @Test @MainActor func attentionSuffixUsesVerdictMessageForJournalCause() {
        for cause in allJournalConnectionFailureCauses() {
            let verdict = journalVerdict(for: cause)
            #expect(attentionSuffix(.journal, verdict: verdict) == verdict.message)

            let shown = attentionToSurface(
                .journal,
                alreadySaidBy: .offline,
                journalFailureCause: cause
            )
            if shown == .journal {
                #expect(attentionSuffix(.journal, verdict: verdict) == verdict.message)
            }
        }

        #expect(attentionSuffix(.journal) == UICopy.SETTINGS_ATTENTION_JOURNAL)
        #expect(
            attentionToSurface(.journal, alreadySaidBy: .paused) == .journal
        )
        #expect(
            attentionToSurface(.journal, alreadySaidBy: .stopped) == .journal
        )
        #expect(attentionSuffix(.journal) == UICopy.SETTINGS_ATTENTION_JOURNAL)
        #expect(attentionToSurface(.journal, alreadySaidBy: .connectionWaiting) == nil)
    }

    @Test @MainActor func statusAccessibilityLabelNamesEveryAttentionReason() {
        // Journal reason may carry verdict.message when a failure cause is present.
        var suffixes = Set<String>()
        var labels = Set<String>()
        let journalVerdict = journalVerdict(for: .revoked)

        for reason in AttentionReason.allCases {
            let suffix = attentionSuffix(reason, verdict: reason == .journal ? journalVerdict : nil)
            let label = statusAccessibilityLabel(
                presentation: MenubarPresentation(
                    observation: .observing,
                    attention: reason
                ),
                errorMessage: nil,
                journalVerdict: reason == .journal ? journalVerdict : nil
            )

            #expect(!suffix.isEmpty, "\(String(describing: reason)) should have a non-empty suffix")
            #expect(suffixes.insert(suffix).inserted, "\(String(describing: reason)) should have a distinct suffix")
            #expect(label.contains(suffix))
            #expect(labels.insert(label).inserted, "\(String(describing: reason)) should have a distinct label")
        }

        #expect(labels.count == AttentionReason.allCases.count)
    }

    @Test func statusAccessibilityLabelSuppressesAlreadySaidAttention() {
        let permissions = statusAccessibilityLabel(
            presentation: MenubarPresentation(observation: .permissions, attention: .permissions),
            errorMessage: nil
        )
        let localOnly = statusAccessibilityLabel(
            presentation: MenubarPresentation(observation: .localOnly, attention: .journal),
            errorMessage: nil
        )

        #expect(permissions == UICopy.MENUBAR_A11Y_PERMISSIONS_NEEDED)
        #expect(localOnly == UICopy.MENUBAR_A11Y_JOURNAL_SETUP_NEEDED)
    }

    @Test func journalClientRowsUseExpectedAXTokens() {
        #expect(MenubarStatusRowState.journalMigrationNeeded.axToken == "journal_migration_needed")
        #expect(MenubarStatusRowState.connectionWaiting.axToken == "connection_waiting")
    }

    @Test @MainActor func settingsRowLabelTargetCellsSurfaced() {
        let targetCauses: [JournalConnectionFailureCause] = [
            .noRoute,
            .unreachable(nil),
            .unreachable("timeout"),
        ]

        for cause in targetCauses {
            let verdict = journalVerdict(for: cause)
            let label = settingsRowLabel(
                observation: .offline,
                attention: .journal,
                verdict: verdict
            )
            #expect(label.showsAttentionIcon == true)
            #expect(label.title == "settings… · \(verdict.message)")
            #expect(label.title != "settings… · \(UICopy.SETTINGS_ATTENTION_JOURNAL)")
        }

        let nilCauseLabel = settingsRowLabel(
            observation: .offline,
            attention: .journal,
            verdict: nil
        )
        #expect(nilCauseLabel.showsAttentionIcon == true)
        #expect(nilCauseLabel.title == "settings… · \(UICopy.SETTINGS_ATTENTION_JOURNAL)")
    }

    @Test @MainActor func settingsRowLabelExhaustiveCrossProductMatchesContract() {
        let attentionOptions: [AttentionReason?] = [nil] + AttentionReason.allCases.map(Optional.some)
        let causes: [JournalConnectionFailureCause?] = [nil] + allJournalConnectionFailureCauses().map(Optional.some)
        var checked = 0

        for rowState in MenubarStatusRowState.allCases {
            for attention in attentionOptions {
                for cause in causes {
                    let verdict: JournalConnectionVerdict? = cause.map { journalVerdict(for: $0) }
                    let label = settingsRowLabel(
                        observation: rowState,
                        attention: attention,
                        verdict: verdict
                    )

                    let isTargetCell = rowState == .offline && attention == .journal && isTargetOfflineJournalCause(cause)
                    if isTargetCell {
                        let expectedVerdict = verdict!
                        #expect(label.showsAttentionIcon == true)
                        #expect(label.title == "settings… · \(expectedVerdict.message)")
                        #expect(label.title != "settings… · \(UICopy.SETTINGS_ATTENTION_JOURNAL)")
                    } else {
                        let surfaced = attentionToSurface(attention, alreadySaidBy: rowState, journalFailureCause: cause)
                        if let surfaced {
                            let expectedSuffix = attentionSuffix(surfaced, verdict: verdict)
                            #expect(label.showsAttentionIcon == true)
                            #expect(label.title == "settings… · \(expectedSuffix)")
                        } else {
                            #expect(label.showsAttentionIcon == false)
                            #expect(label.title == "settings…")
                        }
                    }
                    checked += 1
                }
            }
        }

        #expect(checked == MenubarStatusRowState.allCases.count * (AttentionReason.allCases.count + 1) * (allJournalConnectionFailureCauses().count + 1))
    }

    @Test @MainActor func statusAccessibilityLabelOfflineUnreachablePreservesA11yLabelWithoutLeakingVerdictMessage() {
        let offlineCauses: [JournalConnectionFailureCause] = [
            .noRoute,
            .unreachable(nil),
            .unreachable("timeout"),
        ]

        for cause in offlineCauses {
            let verdict = journalVerdict(for: cause)
            let label = statusAccessibilityLabel(
                presentation: MenubarPresentation(observation: .offline, attention: .journal),
                errorMessage: nil,
                journalVerdict: verdict
            )

            #expect(label == UICopy.MENUBAR_A11Y_OBSERVING_SAVED_LOCALLY)
            #expect(!label.contains(verdict.message))
        }
    }
}

private func presentationAttention(
    permissionsNeedAttention: Bool,
    journalNeedsAttention: Bool,
    durableUpdateStatus: DurableUpdateStatus
) -> AttentionReason? {
    classifyMenubarPresentation(
        observation: .observing,
        permissionsNeedAttention: permissionsNeedAttention,
        journalNeedsAttention: journalNeedsAttention,
        durableUpdateStatus: durableUpdateStatus
    ).attention
}

private func classified(
    permissionsNeedAttention: Bool = false,
    errorMessage: String? = nil,
    initialPermissionCheckComplete: Bool = true,
    isRecording: Bool = true,
    isPaused: Bool = false,
    serviceMode: ServiceMode? = .external,
    syncPaused: Bool = false,
    hasJournalOnRecord: Bool = true,
    journalConnectionAXToken: String? = nil,
    journalFailureCause: JournalConnectionFailureCause? = nil,
    isPairedIngestReady: Bool = false,
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
        isPairedIngestReady: isPairedIngestReady,
        uploadStatus: uploadStatus,
        hasJournalOnRecord: hasJournalOnRecord,
        journalConnectionAXToken: journalConnectionAXToken,
        journalFailureCause: journalFailureCause
    )
}

private func representativeUploadStatuses() -> [UploadCoordinator.Status] {
    let probe: UploadCoordinator.Status = .notSynced
    switch probe {
    case .notSynced, .syncing, .synced, .uploading, .retrying, .offline, .awaitingTunnel:
        return [
            .notSynced,
            .syncing(checked: 1, total: 2),
            .synced,
            .uploading(segment: "s1"),
            .retrying(segment: "s1", attempts: 2),
            .offline("offline"),
            .awaitingTunnel,
        ]
    }
}

private func row(forUploadStatus status: UploadCoordinator.Status) -> MenubarStatusRowState {
    switch status {
    case .synced, .syncing, .uploading:
        return .observing
    case .awaitingTunnel:
        return .connectionWaiting
    case .notSynced, .retrying, .offline:
        return .offline
    }
}

@MainActor
private func connectingVerdict() -> JournalConnectionVerdict {
    TunnelLifecycleOwner.reduceConnectionVerdict(
        state: .connecting,
        hasPersistedPairing: true,
        isTunnelManaged: true,
        supervisorAttemptState: .idle,
        isProxyStarting: true,
        establishedLoopbackPort: nil,
        hasTransport: false
    )
}

private func ownerProducedFailureCauses() -> [JournalConnectionFailureCause] {
    [
        .noRoute,
        .revoked,
        .notEntitled,
        .keychainUnavailable,
        .loopbackUnavailable,
        .unreachable(nil),
    ]
}

private func allJournalConnectionFailureCauses() -> [JournalConnectionFailureCause] {
    let probe: JournalConnectionFailureCause = .noRoute
    switch probe {
    case .noRoute, .revoked, .notEntitled, .keychainUnavailable, .loopbackUnavailable,
         .unreachable, .mismatch, .notServing:
        return [
            .noRoute,
            .revoked,
            .notEntitled,
            .keychainUnavailable,
            .loopbackUnavailable,
            .unreachable(nil),
            .unreachable("timeout"),
            .mismatch,
            .notServing,
        ]
    }
}

private func offlineSuppressesJournalSuffix(_ cause: JournalConnectionFailureCause) -> Bool {
    switch cause {
    case .noRoute, .unreachable:
        return true
    case .revoked, .keychainUnavailable, .notEntitled, .loopbackUnavailable, .mismatch, .notServing:
        return false
    }
}

private func isTargetOfflineJournalCause(_ cause: JournalConnectionFailureCause?) -> Bool {
    guard let cause else { return false }
    switch cause {
    case .noRoute, .unreachable:
        return true
    case .revoked, .keychainUnavailable, .notEntitled, .loopbackUnavailable, .mismatch, .notServing:
        return false
    }
}

@MainActor
private func journalVerdict(for cause: JournalConnectionFailureCause) -> JournalConnectionVerdict {
    switch cause {
    case .noRoute:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: true,
            isTunnelManaged: false,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .revoked:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.revoked),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .notEntitled:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.notEntitled),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .keychainUnavailable:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.keychainUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .loopbackUnavailable:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .error(.loopbackUnavailable),
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .unreachable:
        return TunnelLifecycleOwner.reduceConnectionVerdict(
            state: .disconnected,
            hasPersistedPairing: true,
            isTunnelManaged: true,
            supervisorAttemptState: .idle,
            isProxyStarting: false,
            establishedLoopbackPort: nil,
            hasTransport: false
        )
    case .mismatch:
        return journalConnectionVerdictPresentation(tunnel: .neutral, pairingMismatch: true)
    case .notServing:
        return JournalConnectionVerdict(
            severity: .attention,
            message: "journal is not serving",
            caption: nil,
            axToken: PairingConnectionAXState.notServing.axToken,
            failureCause: .notServing
        )
    }
}
