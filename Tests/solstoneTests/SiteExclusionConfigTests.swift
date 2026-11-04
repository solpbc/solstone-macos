// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import Testing
import UpdateKit
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

    @Test func invalidAddressDoesNotPromptAndReturnsError() async {
        let promptCalled = OSAllocatedUnfairLock(initialState: 0)
        let probe = AccessibilityProbe(
            readWorks: { false },
            prompt: { promptCalled.withLock { $0 += 1 } }
        )
        let state = AppState.forSnapshot(config: AppConfig())
        state.accessibilityProbe = probe

        let error = await state.addExcludedSite("bank .com")
        #expect(error == UICopy.Websites.ERROR_INVALID_ADDRESS)
        #expect(promptCalled.withLock { $0 } == 0)
    }

    @Test func addEnforcesTwoHundredCap() async {
        var config = AppConfig()
        config.excludedSites = (1...200).map { "site\($0).com" }
        let state = AppState.forSnapshot(config: config)

        let error = await state.addExcludedSite("overflow.com")
        #expect(error == UICopy.Websites.ERROR_LIMIT_REACHED)
        #expect(state.config.excludedSites.count == 200)
    }

    @Test func addingASiteNeverAsksAndTheOwnersButtonDoes() async {
        let promptCalled = OSAllocatedUnfairLock(initialState: 0)
        let probe = AccessibilityProbe(
            readWorks: { false },
            prompt: { promptCalled.withLock { $0 += 1 } }
        )
        let state = AppState.forSnapshot(config: AppConfig())
        state.accessibilityProbe = probe

        #expect(await state.addExcludedSite("bank.com") == nil)
        #expect(state.config.excludedSites == ["bank.com"])
        #expect(promptCalled.withLock { $0 } == 0)

        state.askForWebsiteAccessibility()
        #expect(promptCalled.withLock { $0 } == 1)
    }

    @Test func forSnapshotWithSitesInitializesRuleAndUpdatesOnReconfig() {
        let config = AppConfig(
            excludedSites: ["bank.com"],
            excludePrivateBrowsing: false,
            excludePrivateBrowsingAccessibility: false
        )
        let state = AppState.forSnapshot(config: config, snapshotAccessibilityCaution: true)

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

    @Test func sitesListedWithoutAccessibilityToggleShowsSiteCautionWithoutPrivateWindowAttention() async throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        var config = AppConfig(
            excludedSites: ["bank.com"],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: false
        )
        let loginService = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(config: AppConfig(), loginService: loginService)

        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(
            readWorks: { await reader.read() },
            scheduler: polling.scheduler
        )
        state.privateWindowAccessibilityMonitor = monitor
        state.updateConfig(config)

        #expect(polling.passes.count == 1)
        await polling.passes[0]()

        #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention != .privateWindows)
        #expect(state.siteAccessibilityCaution == true)
        #expect(state.privateWindowAccessibilityEnabled == false)

        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: defaults
        ) { _, _ in nil }
        let settingsView = SettingsView(appState: state, updateController: updateController, openURL: { _ in true })
        #expect(settingsView.privateWindowAccessibilityState == .off)
    }

    @Test func enablingAccessibilityBindingRequestsAccessibilityEvenWithSitesListed() async throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }

        var config = AppConfig(
            excludedSites: ["bank.com"],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: false
        )
        let loginService = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(config: AppConfig(), loginService: loginService)

        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(
            readWorks: { await reader.read() },
            scheduler: polling.scheduler
        )
        state.privateWindowAccessibilityMonitor = monitor
        state.updateConfig(config)

        var askCount = 0
        state.requestPrivateWindowAccessibility = { askCount += 1 }

        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: Logger.setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: defaults
        ) { _, _ in nil }
        let settingsView = SettingsView(appState: state, updateController: updateController, openURL: { _ in true })

        settingsView.excludePrivateBrowsingAccessibilityBinding.wrappedValue = true
        #expect(askCount == 1)
    }

    @Test func togglingAccessibilityOffWithSitesPreservesSiteSamplingWithoutPrivateWindowAttention() async throws {
        let config = AppConfig(
            excludedSites: ["bank.com"],
            excludePrivateBrowsing: true,
            excludePrivateBrowsingAccessibility: true
        )
        let loginService = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(config: AppConfig(), loginService: loginService)

        let polling = ManualAccessibilityPolling()
        let reader = AccessibilitySampleReader(false)
        let monitor = PrivateWindowAccessibilityMonitor(
            readWorks: { await reader.read() },
            scheduler: polling.scheduler
        )
        state.privateWindowAccessibilityMonitor = monitor
        state.updateConfig(config)

        #expect(polling.passes.count == 1)
        await polling.passes[0]()

        #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention == .privateWindows)

        var updatedConfig = state.config
        updatedConfig.excludePrivateBrowsingAccessibility = false
        state.updateConfig(updatedConfig)

        #expect(polling.cancelled.isEmpty)
        await polling.passes[0]()

        #expect(state.siteAccessibilityCaution == true)
        #expect(state.menubarPresentation(durableUpdateStatus: .idle).attention != .privateWindows)
        #expect(state.privateWindowAccessibilityEnabled == false)

        try await state.captureManager.waitForSiteListDrain()
        let isPolling = await state.captureManager.siteSampler?.isPollingForTesting
        #expect(isPolling == true)
    }

    @Test func privateWindowAccessibilityEnabledTruthTable() {
        let loginService = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(config: AppConfig(), loginService: loginService)

        let polling = ManualAccessibilityPolling()
        let monitor = PrivateWindowAccessibilityMonitor(
            readWorks: { false },
            scheduler: polling.scheduler
        )
        state.privateWindowAccessibilityMonitor = monitor

        let bools = [false, true]
        let siteOptions: [[String]] = [[], ["bank.com"]]

        for excludePrivate in bools {
            for accessibility in bools {
                for sites in siteOptions {
                    var config = state.config
                    config.excludePrivateBrowsing = excludePrivate
                    config.excludePrivateBrowsingAccessibility = accessibility
                    config.excludedSites = sites
                    state.updateConfig(config)

                    let expectedConjunction = excludePrivate && accessibility
                    #expect(state.privateWindowAccessibilityEnabled == expectedConjunction,
                            "Mismatch for excludePrivate: \(excludePrivate), accessibility: \(accessibility), sites: \(sites)")
                    #expect(state.privateWindowAccessibilityMonitor.isEnabled == expectedConjunction)
                    #expect(state.privateWindowAccessibilityMonitor.sitesEnabled == !sites.isEmpty)
                }
            }
        }
    }

    @Test func siteSafariCautionObservationFiresWhenGateCautionFlips() {
        var config = AppConfig()
        config.excludedSites = ["bank.com"]
        let loginService = FakeLoginItemService(watchdogStatus: .notRegistered, mainAppStatus: .notFound)
        let state = AppState.forLoginItemTest(config: config, loginService: loginService)

        let trackingFired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.siteSafariCaution
        } onChange: {
            trackingFired.withLock { $0 = true }
        }

        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 10, title: "T")
        let axErrorWalk = WebAreaWalkResult(urls: ["https://example.com"], completeness: .axError)
        for i in 1...10 {
            decision.evaluate(
                key: key,
                initialAXTitle: "T",
                finalAXTitle: "T",
                walk: axErrorWalk,
                sites: ["bank.com"],
                now: Double(i),
                isSweep: false
            )
        }
        #expect(decision.hasSafariCaution == true)

        state.captureManager.receiveSiteDecision(decision, axAvailable: true, generation: state.captureManager.siteListGeneration)

        #expect(trackingFired.withLock { $0 } == true)
        #expect(state.siteSafariCaution == true)
    }
}
