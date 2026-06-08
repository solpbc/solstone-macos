// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
    @Test @MainActor func hasPauseResumeStartControlTruthTable() {
        let updateController = UpdateController()

        let observing = AppState.forSnapshot()
        observing.isRecording = true
        #expect(MenuContent(appState: observing, updateController: updateController).hasPauseResumeStartControl)

        let paused = AppState.forSnapshot()
        paused.isRecording = true
        paused.pauseManager.pause(for: .indefinite)
        #expect(MenuContent(appState: paused, updateController: updateController).hasPauseResumeStartControl)

        let stopped = AppState.forSnapshot()
        #expect(MenuContent(appState: stopped, updateController: updateController).hasPauseResumeStartControl)

        let stoppedWithError = AppState.forSnapshot()
        stoppedWithError.errorMessage = "offline"
        #expect(!MenuContent(appState: stoppedWithError, updateController: updateController).hasPauseResumeStartControl)

        let permissionsNeeded = AppState.forSnapshot()
        permissionsNeeded.initialPermissionCheckComplete = true
        permissionsNeeded.screenRecordingGranted = false
        permissionsNeeded.microphoneGranted = false
        #expect(!MenuContent(appState: permissionsNeeded, updateController: updateController).hasPauseResumeStartControl)
    }

    @Test func pausedHeaderShowsAutoResumeCountdown() {
        #expect(pausedHeaderText(timeRemaining: "8 mins") == "paused - 8 min left")
        #expect(pausedHeaderText(timeRemaining: "1 min") == "paused - 1 min left")
        #expect(pausedHeaderText(timeRemaining: "2 hrs 5 mins") == "paused - 2 hr 5 min left")
        #expect(pausedHeaderText(timeRemaining: "45 secs") == "paused - 45 sec left")
        #expect(pausedHeaderText(timeRemaining: "1 hr") == "paused - 1 hr left")
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
            updateIsAvailable: false,
            updateCheckFailed: false
        ) == nil)

        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            updateIsAvailable: false,
            updateCheckFailed: false
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            updateIsAvailable: false,
            updateCheckFailed: false
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            updateIsAvailable: true,
            updateCheckFailed: false
        ) == .updateAvailable)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            updateIsAvailable: false,
            updateCheckFailed: true
        ) == .updateCheckFailed)

        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: true,
            updateIsAvailable: false,
            updateCheckFailed: false
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            updateIsAvailable: true,
            updateCheckFailed: false
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: true,
            journalNeedsAttention: false,
            updateIsAvailable: false,
            updateCheckFailed: true
        ) == .permissions)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            updateIsAvailable: true,
            updateCheckFailed: false
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: true,
            updateIsAvailable: false,
            updateCheckFailed: true
        ) == .journal)
        #expect(firstSettingsAttention(
            permissionsNeedAttention: false,
            journalNeedsAttention: false,
            updateIsAvailable: true,
            updateCheckFailed: true
        ) == .updateAvailable)
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
        ]

        for status in statuses {
            let menu = try #require(status.menuRowPresentation)
            #expect(menu.state.axToken == status.settingsPresentation.axValue)
        }
    }
}
