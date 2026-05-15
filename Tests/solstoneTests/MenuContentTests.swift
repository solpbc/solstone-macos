// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("MenuContent")
struct MenuContentTests {
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
