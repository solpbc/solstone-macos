// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
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

    @Test func pipelineStatusRowHelperTruthTable() {
        let binaryMissing = pipelineStatusRowModel(
            pipelineDead: true,
            isRestartingPipeline: false,
            pipelineBinaryMissing: true
        )
        #expect(binaryMissing?.text == "solstone is not fully installed")
        #expect(binaryMissing?.isEnabled == false)
        #expect(binaryMissing?.state == .pipelineMissing)

        let restarting = pipelineStatusRowModel(
            pipelineDead: true,
            isRestartingPipeline: true,
            pipelineBinaryMissing: false
        )
        #expect(restarting?.text == "restarting…")
        #expect(restarting?.isEnabled == false)
        #expect(restarting?.state == .pipelineRestarting)

        let dead = pipelineStatusRowModel(
            pipelineDead: true,
            isRestartingPipeline: false,
            pipelineBinaryMissing: false
        )
        #expect(dead?.text == "pipeline stopped — click to restart")
        #expect(dead?.isEnabled == true)
        #expect(dead?.state == .pipelineDead)

        #expect(pipelineStatusRowModel(
            pipelineDead: false,
            isRestartingPipeline: false,
            pipelineBinaryMissing: false
        ) == nil)
    }
}
