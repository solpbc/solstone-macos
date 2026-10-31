// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
@testable import solstone

@Suite("SiteExclusionConfig")
@MainActor
struct SiteExclusionConfigTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "site-exclusion-test-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func excludedSitesRoundTripsThroughUserDefaults() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        var config = AppConfig()
        let sites200 = (1...200).map { "site\($0).com" }
        config.excludedSites = sites200
        try config.save(to: defaults)

        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites == sites200)
    }

    @Test func storedListExceedingCapIsNotTruncatedOnLoad() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        let sites205 = (1...205).map { "site\($0).com" }
        defaults.set(sites205, forKey: "excludedSites")

        let loaded = AppConfig.load(from: defaults)
        #expect(loaded.excludedSites.count == 205)
        #expect(loaded.excludedSites == sites205)
    }

    @Test func invalidAddressDoesNotPromptAndReturnsError() {
        let promptCalled = OSAllocatedUnfairLock(initialState: 0)
        let probe = AccessibilityProbe(
            readWorks: { false },
            prompt: { promptCalled.withLock { $0 += 1 } }
        )
        let state = AppState.forSnapshot(config: AppConfig())
        state.accessibilityProbe = probe

        let error = state.addExcludedSite("bank .com")
        #expect(error == UICopy.Websites.ERROR_INVALID_ADDRESS)
        #expect(promptCalled.withLock { $0 } == 0)
    }

    @Test func addEnforcesTwoHundredCap() {
        var config = AppConfig()
        config.excludedSites = (1...200).map { "site\($0).com" }
        let state = AppState.forSnapshot(config: config)

        let error = state.addExcludedSite("overflow.com")
        #expect(error == UICopy.Websites.ERROR_LIMIT_REACHED)
        #expect(state.config.excludedSites.count == 200)
    }

    @Test func firstValidAddPromptsBeforeWorkingReadAndSecondAddDoesNotPrompt() {
        let promptCalled = OSAllocatedUnfairLock(initialState: 0)
        let isWorking = OSAllocatedUnfairLock(initialState: false)
        let probe = AccessibilityProbe(
            readWorks: { isWorking.withLock { $0 } },
            prompt: { promptCalled.withLock { $0 += 1 } }
        )
        let state = AppState.forSnapshot(config: AppConfig())
        state.accessibilityProbe = probe

        // First valid add before any working read -> prompts once
        let err1 = state.addExcludedSite("bank.com")
        #expect(err1 == nil)
        #expect(promptCalled.withLock { $0 } == 1)

        // Simulate read now working
        isWorking.withLock { $0 = true }

        // Second valid add -> does not prompt again
        let err2 = state.addExcludedSite("other.com")
        #expect(err2 == nil)
        #expect(promptCalled.withLock { $0 } == 1)
    }

    @Test func forSnapshotWithSitesInitializesRuleAndUpdatesOnReconfig() {
        let config = AppConfig(
            excludedSites: ["bank.com"],
            excludePrivateBrowsing: false,
            excludePrivateBrowsingAccessibility: false
        )
        let state = AppState.forSnapshot(config: config)

        #expect(state.captureManager.siteRuleActive == true)
        #expect(state.captureManager.siteSampler != nil)
        #expect(state.siteAccessibilityCaution == true)
        #expect(state.privateWindowAccessibilityMonitor.isEnabled == false)

        // Calling updateConfig with a new site list reconfigures
        var newConfig = state.config
        newConfig.excludedSites = ["newsite.com", "other.com"]
        state.updateConfig(newConfig)

        #expect(state.captureManager.siteRuleActive == true)
        let activitySettings = DesktopActivitySettings(state.config)
        #expect(activitySettings.excludedSites == ["newsite.com", "other.com"])

        // Calling updateConfig with empty site list deactivates rule
        var emptyConfig = state.config
        emptyConfig.excludedSites = []
        state.updateConfig(emptyConfig)
        #expect(state.captureManager.siteRuleActive == false)
    }
}
