// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import ServiceManagement
import SolstoneCore

@MainActor
protocol LoginItemManaging: AnyObject {
    func register() throws
    func unregister() throws
}

@MainActor
final class LiveJournalLoginItemManager: LoginItemManaging {
    private static let watchdogPlistName = "app.solstone.journal.watchdog.plist"

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.watchdogPlistName)
    }
}

@MainActor
final class JournalAppConfig {
    static let suiteName = "app.solstone.journal"

    private enum Keys {
        static let journalRoot = "journalRoot"
        static let launchAtLoginEnabled = "launchAtLoginEnabled"
    }

    private let defaults: UserDefaults
    private let loginItemManager: any LoginItemManaging

    init(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard,
        loginItemManager: any LoginItemManaging = LiveJournalLoginItemManager()
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager
    }

    var journalRoot: URL? {
        get {
            defaults.string(forKey: Keys.journalRoot).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }
        set {
            defaults.set(newValue?.path, forKey: Keys.journalRoot)
        }
    }

    var resolvedJournalRoot: URL {
        journalRoot ?? ExpectedExitMarker
            .markerURL(for: ExpectedExitMarker.journalMarkerDiscriminator)
            .deletingLastPathComponent()
            .appendingPathComponent("journal", isDirectory: true)
    }

    var launchAtLoginEnabled: Bool {
        guard defaults.object(forKey: Keys.launchAtLoginEnabled) != nil else {
            return true
        }
        return defaults.bool(forKey: Keys.launchAtLoginEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.launchAtLoginEnabled)
        applyLaunchAtLoginPreference()
    }

    func applyLaunchAtLoginPreference() {
        do {
            if launchAtLoginEnabled {
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
        } catch {
            Logger.journalApp.error("journal login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
