// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
import Testing
@testable import journal

@MainActor
@Suite("JournalAppConfig")
struct JournalAppConfigTests {
    private static let cachedMarkKey = "journalIconCachedMarkJSON"

    @Test func launchAtLoginDefaultsOnAndRegisters() {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let loginItems = FakeLoginItemManager()
        let config = JournalAppConfig(defaults: fixture.defaults, loginItemManager: loginItems)

        config.applyLaunchAtLoginPreference()

        #expect(config.launchAtLoginEnabled)
        #expect(loginItems.registerCalls == 1)
        #expect(loginItems.unregisterCalls == 0)
    }

    @Test func disablingLaunchAtLoginDeregistersAndPersists() {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let loginItems = FakeLoginItemManager()
        let config = JournalAppConfig(defaults: fixture.defaults, loginItemManager: loginItems)

        config.setLaunchAtLoginEnabled(false)
        let reloaded = JournalAppConfig(defaults: fixture.defaults, loginItemManager: FakeLoginItemManager())

        #expect(!config.launchAtLoginEnabled)
        #expect(!reloaded.launchAtLoginEnabled)
        #expect(loginItems.registerCalls == 0)
        #expect(loginItems.unregisterCalls == 1)
    }

    @Test func ineligibleCurrentBundleDoesNotRegisterLoginItem() {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let loginItems = FakeLoginItemManager()
        let config = JournalAppConfig(
            defaults: fixture.defaults,
            loginItemManager: loginItems,
            loginItemEligibility: { false }
        )

        config.applyLaunchAtLoginPreference()

        #expect(config.launchAtLoginEnabled)
        #expect(loginItems.registerCalls == 0)
        #expect(loginItems.unregisterCalls == 0)

        config.setLaunchAtLoginEnabled(false)
        #expect(loginItems.unregisterCalls == 1)
    }

    @Test func cachedIconMarkJSONRoundTripsValidatedMark() throws {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let config = JournalAppConfig(defaults: fixture.defaults, loginItemManager: FakeLoginItemManager())

        config.setCachedIconMark(.uiTestSample)

        #expect(config.cachedIconMark() == .uiTestSample)
    }

    @Test func cachedIconMarkFailsClosedForGarbageOrInvalidJSON() throws {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let config = JournalAppConfig(defaults: fixture.defaults, loginItemManager: FakeLoginItemManager())

        fixture.defaults.set(Data([0x00, 0x01]), forKey: Self.cachedMarkKey)
        #expect(config.cachedIconMark() == nil)

        let invalid = JournalMark(
            icon1: JournalMark.uiTestSample.icon1,
            icon2: JournalMark.uiTestSample.icon2,
            words: ["only-one-word"]
        )
        fixture.defaults.set(try JSONEncoder().encode(invalid), forKey: Self.cachedMarkKey)
        #expect(config.cachedIconMark() == nil)
    }

    @Test func appliedAtLeastOncePersistsIndependentlyOfCachedMark() {
        let fixture = makeDefaults()
        defer { fixture.clear() }
        let config = JournalAppConfig(defaults: fixture.defaults, loginItemManager: FakeLoginItemManager())

        config.iconMarkAppliedAtLeastOnce = true
        let reloaded = JournalAppConfig(defaults: fixture.defaults, loginItemManager: FakeLoginItemManager())

        #expect(reloaded.iconMarkAppliedAtLeastOnce)
        #expect(reloaded.cachedIconMark() == nil)
    }

    private func makeDefaults() -> DefaultsFixture {
        let suiteName = "app.solstone.journal.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsFixture(suiteName: suiteName, defaults: defaults)
    }
}

private struct DefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    func clear() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class FakeLoginItemManager: LoginItemManaging {
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        registerCalls += 1
    }

    func unregister() throws {
        unregisterCalls += 1
    }
}
