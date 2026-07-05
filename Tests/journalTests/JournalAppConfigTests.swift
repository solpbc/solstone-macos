// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@MainActor
@Suite("JournalAppConfig")
struct JournalAppConfigTests {
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
