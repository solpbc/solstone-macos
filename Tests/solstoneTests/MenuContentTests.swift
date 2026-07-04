// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
    private let isolatedDefaults = IsolatedUserDefaults()

    @Test @MainActor func hasPauseResumeControlTruthTable() {
        let updateController = UpdateController(defaults: isolatedDefaults.defaults)

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
            (.journalSetupNeeded, .offline),
            (.journalRestarting, .offline),
            (.journalStopped, .offline),
            (.journalUnknown, .offline),
            (.journalStoppedByUser, .offline),
            (.journalWaiting, .offline),
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
            (.journalSetupNeeded, .observing),
            (.journalRestarting, .observing),
            (.journalStopped, .observing),
            (.journalUnknown, .observing),
            (.journalStoppedByUser, .observing),
            (.journalWaiting, .observing),
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
            ("journalWaiting", classified(captureQueuedForJournalReadiness: true)),
            ("journalUnobserved", classified(bundledJournalStatusAvailable: true, journalRuntimeStatus: .unobserved)),
            ("journalSetupNeeded", classified(bundledJournalStatusAvailable: true, journalRuntimeStatus: .setupNeeded)),
            ("journalRestarting", classified(bundledJournalStatusAvailable: true, journalRuntimeStatus: .restarting)),
            (
                "journalStopped",
                classified(
                    bundledJournalStatusAvailable: true,
                    journalRuntimeStatus: .stopped(JournalDiagnostic(commandLabel: "journal health"))
                )
            ),
            (
                "journalUnknown",
                classified(
                    bundledJournalStatusAvailable: true,
                    journalRuntimeStatus: .unknown(JournalDiagnostic(commandLabel: "journal health"))
                )
            ),
            ("journalStoppedByUser", classified(bundledJournalStatusAvailable: true, journalRuntimeStatus: .stoppedByUser)),
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
            "journalWaiting": .journalWaiting,
            "journalUnobserved": .starting,
            "journalSetupNeeded": .journalSetupNeeded,
            "journalRestarting": .journalRestarting,
            "journalStopped": .journalStopped,
            "journalUnknown": .journalUnknown,
            "journalStoppedByUser": .journalStoppedByUser,
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

    @Test func openJournalIgnoresInvalidConfiguredURL() {
        #expect(journalURLToOpen(from: nil) == nil)
        #expect(journalURLToOpen(from: "") == nil)
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

    @Test func journalRuntimeStatusPresentationTruthTable() {
        let setupNeeded = JournalRuntimeStatus.setupNeeded.menuRowPresentation
        #expect(setupNeeded?.text == UICopy.JOURNAL_SETUP_NEEDED_OPEN_SETTINGS)
        #expect(setupNeeded?.isEnabled == true)
        #expect(setupNeeded?.state == .journalSetupNeeded)
        #expect(JournalRuntimeStatus.setupNeeded.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_SETUP_NEEDED)
        #expect(JournalRuntimeStatus.setupNeeded.settingsPresentation.axValue == MenubarStatusRowState.journalSetupNeeded.axToken)
        #expect(JournalRuntimeStatus.setupNeeded.settingsPresentation.severity == .attention)
        #expect(!JournalRuntimeStatus.setupNeeded.canOfferRestart)

        let restarting = JournalRuntimeStatus.restarting.menuRowPresentation
        #expect(restarting?.text == UICopy.JOURNAL_RESTARTING)
        #expect(restarting?.isEnabled == false)
        #expect(restarting?.state == .journalRestarting)
        #expect(JournalRuntimeStatus.restarting.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_RESTARTING)
        #expect(JournalRuntimeStatus.restarting.settingsPresentation.axValue == MenubarStatusRowState.journalRestarting.axToken)
        #expect(JournalRuntimeStatus.restarting.settingsPresentation.severity == .warning)
        #expect(!JournalRuntimeStatus.restarting.canOfferRestart)

        let stoppedStatus = JournalRuntimeStatus.stopped(JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "down"))
        let stopped = stoppedStatus.menuRowPresentation
        #expect(stopped?.text == UICopy.JOURNAL_NEEDS_ATTENTION_OPEN_SETTINGS)
        #expect(stopped?.isEnabled == true)
        #expect(stopped?.state == .journalStopped)
        #expect(stoppedStatus.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_NEEDS_ATTENTION)
        #expect(stoppedStatus.settingsPresentation.axValue == MenubarStatusRowState.journalStopped.axToken)
        #expect(stoppedStatus.settingsPresentation.severity == .attention)
        #expect(stoppedStatus.settingsPresentation.reason == "down")
        #expect(stoppedStatus.canOfferRestart)

        let stoppedByUserStatus = JournalRuntimeStatus.stoppedByUser
        let stoppedByUser = stoppedByUserStatus.menuRowPresentation
        #expect(stoppedByUser?.text == UICopy.MENUBAR_JOURNAL_STOPPED_BY_USER)
        #expect(stoppedByUser?.isEnabled == true)
        #expect(stoppedByUser?.state == .journalStoppedByUser)
        #expect(stoppedByUserStatus.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_STOPPED)
        #expect(stoppedByUserStatus.settingsPresentation.axValue == MenubarStatusRowState.journalStoppedByUser.axToken)
        #expect(stoppedByUserStatus.settingsPresentation.severity == .neutral)
        #expect(stoppedByUserStatus.settingsPresentation.reason == nil)
        #expect(!stoppedByUserStatus.canOfferRestart)
        #expect(stoppedByUserStatus.settingsPresentation.severity != .attention)
        #expect(stoppedByUserStatus.settingsPresentation.shortText != UICopy.JOURNAL_STATUS_NEEDS_ATTENTION)

        let unknownStatus = JournalRuntimeStatus.unknown(JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "unclear"))
        let unknown = unknownStatus.menuRowPresentation
        #expect(unknown?.text == UICopy.JOURNAL_NEEDS_ATTENTION_OPEN_SETTINGS)
        #expect(unknown?.isEnabled == true)
        #expect(unknown?.state == .journalUnknown)
        #expect(unknownStatus.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_NEEDS_ATTENTION)
        #expect(unknownStatus.settingsPresentation.axValue == MenubarStatusRowState.journalUnknown.axToken)
        #expect(unknownStatus.settingsPresentation.severity == .attention)
        #expect(unknownStatus.settingsPresentation.reason == "unclear")
        #expect(unknownStatus.canOfferRestart)

        #expect(JournalRuntimeStatus.unobserved.menuRowPresentation == nil)
        #expect(JournalRuntimeStatus.unobserved.settingsPresentation.shortText == UICopy.SETTINGS_OBSERVATION_STARTING)
        #expect(JournalRuntimeStatus.unobserved.settingsPresentation.axValue == MenubarStatusRowState.starting.axToken)
        #expect(JournalRuntimeStatus.unobserved.settingsPresentation.severity == .neutral)
        #expect(JournalRuntimeStatus.unobserved.settingsPresentation.reason == nil)
        #expect(!JournalRuntimeStatus.unobserved.canOfferRestart)

        #expect(JournalRuntimeStatus.running.menuRowPresentation == nil)
        #expect(JournalRuntimeStatus.running.settingsPresentation.shortText == UICopy.JOURNAL_STATUS_RUNNING)
        #expect(JournalRuntimeStatus.running.settingsPresentation.axValue == "running")
        #expect(JournalRuntimeStatus.running.settingsPresentation.severity == .neutral)
        #expect(!JournalRuntimeStatus.running.canOfferRestart)
    }

    @Test func journalRuntimeStatusMenuAndSettingsShareAXState() throws {
        let statuses: [JournalRuntimeStatus] = [
            .setupNeeded,
            .restarting,
            .stopped(JournalDiagnostic(commandLabel: "journal health")),
            .unknown(JournalDiagnostic(commandLabel: "journal health")),
            .stoppedByUser,
        ]

        for status in statuses {
            let menu = try #require(status.menuRowPresentation)
            #expect(menu.state.axToken == status.settingsPresentation.axValue)
        }
    }
}

private func classified(
    permissionsNeedAttention: Bool = false,
    errorMessage: String? = nil,
    initialPermissionCheckComplete: Bool = true,
    isRecording: Bool = true,
    isPaused: Bool = false,
    captureQueuedForJournalReadiness: Bool = false,
    bundledJournalStatusAvailable: Bool = false,
    journalRuntimeStatus: JournalRuntimeStatus = .running,
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
        captureQueuedForJournalReadiness: captureQueuedForJournalReadiness,
        bundledJournalStatusAvailable: bundledJournalStatusAvailable,
        journalRuntimeStatus: journalRuntimeStatus,
        syncPaused: syncPaused,
        isUploadConfigured: isUploadConfigured,
        uploadStatus: uploadStatus
    )
}
