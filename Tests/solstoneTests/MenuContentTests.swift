// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
    @Test func pausedHeaderShowsAutoResumeCountdown() {
        #expect(pausedHeaderText(timeRemaining: "8 mins") == "paused - resumes in 8 mins")
        #expect(pausedHeaderText(timeRemaining: "1 min") == "paused - resumes in 1 min")
        #expect(pausedHeaderText(timeRemaining: "2 hrs 5 mins") == "paused - resumes in 2 hrs 5 mins")
        #expect(pausedHeaderText(timeRemaining: "45 secs") == "paused - resumes in 45 secs")
        #expect(pausedHeaderText(timeRemaining: nil) == "paused")
    }

    @Test func pausedHeaderMappingIsNonMemoized() {
        #expect(pausedHeaderText(timeRemaining: "8 mins") != pausedHeaderText(timeRemaining: "45 secs"))
        #expect(pausedHeaderText(timeRemaining: "1 min") != pausedHeaderText(timeRemaining: nil))
    }

    @Test func settingsButtonShowsAttentionIconWhenAnyTabNeedsAttention() {
        #expect(settingsAttentionIconName(anyTabNeedsAttention: true) == "exclamationmark.circle.fill")
    }

    @Test func settingsButtonOmitsAttentionIconWhenNoTabsNeedAttention() {
        #expect(settingsAttentionIconName(anyTabNeedsAttention: false) == nil)
    }

    @Test func openJournalIgnoresInvalidConfiguredURL() {
        #expect(journalURLToOpen(from: nil) == nil)
        #expect(journalURLToOpen(from: "") == nil)
    }
}
