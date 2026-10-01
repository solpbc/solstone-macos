// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if SOLSTONE_BROWSER_INTAKE_PREVIEW

import Testing
@testable import solstone

@Suite("BrowserRetirementWarning")
struct BrowserRetirementWarningTests {
    @Test func materialArrivingWhileOpenWarnsUntilAnAnswer() {
        var warning = BrowserRetirementWarning()
        warning.observe(isPromptOpen: true, hasPendingMaterial: false)
        #expect(!warning.isShown)
        warning.observe(isPromptOpen: true, hasPendingMaterial: true)
        #expect(warning.isShown)
        warning.observe(isPromptOpen: true, hasPendingMaterial: false)
        #expect(warning.isShown)
        warning.observe(isPromptOpen: true, hasPendingMaterial: nil)
        #expect(warning.isShown)
        warning.observe(isPromptOpen: false, hasPendingMaterial: true)
        #expect(!warning.isShown)
        warning.observe(isPromptOpen: true, hasPendingMaterial: false)
        #expect(!warning.isShown)
    }

    @Test func unknownMaterialDoesNotInventAWarning() {
        var warning = BrowserRetirementWarning()
        warning.observe(isPromptOpen: true, hasPendingMaterial: nil)
        #expect(!warning.isShown)
        warning.observe(isPromptOpen: true, hasPendingMaterial: true)
        #expect(warning.isShown)
    }
}

#endif
