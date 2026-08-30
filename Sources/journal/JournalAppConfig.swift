// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalMarkKit
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
        static let journalIconMarkAppliedAtLeastOnce = "journalIconMarkAppliedAtLeastOnce"
        static let journalIconCachedMarkJSON = "journalIconCachedMarkJSON"
    }

    private let defaults: UserDefaults
    private let loginItemManager: any LoginItemManaging
    private let loginItemEligibility: () -> Bool

    init(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard,
        loginItemManager: any LoginItemManaging = LiveJournalLoginItemManager(),
        loginItemEligibility: @escaping () -> Bool = {
            let fileManager = FileManager.default
            return WatchdogAppLocationEligibility.isEligible(
                enclosingAppURL: Bundle.main.bundleURL,
                cachesURL: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                temporaryDirectoryURL: fileManager.temporaryDirectory
            )
        }
    ) {
        self.defaults = defaults
        self.loginItemManager = loginItemManager
        self.loginItemEligibility = loginItemEligibility
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

    var iconMarkAppliedAtLeastOnce: Bool {
        get {
            defaults.bool(forKey: Keys.journalIconMarkAppliedAtLeastOnce)
        }
        set {
            defaults.set(newValue, forKey: Keys.journalIconMarkAppliedAtLeastOnce)
        }
    }

    func cachedIconMark() -> JournalMark? {
        guard let data = defaults.data(forKey: Keys.journalIconCachedMarkJSON),
              let decoded = try? JSONDecoder().decode(JournalMark.self, from: data) else {
            return nil
        }
        return JournalMark.validate(decoded)
    }

    func setCachedIconMark(_ mark: JournalMark) {
        guard let validated = JournalMark.validate(mark),
              let data = try? JSONEncoder().encode(validated) else {
            return
        }
        defaults.set(data, forKey: Keys.journalIconCachedMarkJSON)
    }

    func applyLaunchAtLoginPreference() {
        do {
            if launchAtLoginEnabled {
                // A quarantined app can execute from AppTranslocation while its
                // bundled login item resolves the original download. Registering
                // there would let the watchdog relaunch a different identity
                // after an ordinary quit, so transient locations never enroll.
                guard loginItemEligibility() else { return }
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
        } catch {
            Logger.journalApp.error("journal login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
