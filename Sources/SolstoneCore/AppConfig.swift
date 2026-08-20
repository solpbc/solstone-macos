// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public enum ServiceMode: String, Codable, Equatable, Sendable, CaseIterable {
    case bundled
    case external

    public static let bundledServiceURL = "http://localhost:5015"
}

/// Microphone entry for priority list
public struct MicrophoneEntry: Codable, Equatable, Sendable {
    public let uid: String
    public let name: String
    public var isDisabled: Bool

    public init(uid: String, name: String, isDisabled: Bool = false) {
        self.uid = uid
        self.name = name
        self.isDisabled = isDisabled
    }

    // Custom decoder for backward compatibility (existing configs without isDisabled)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case uid, name, isDisabled
    }
}

/// App entry for exclusion list
public struct AppEntry: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Configuration for SolstoneCapture
/// Stored in UserDefaults
public struct AppConfig: Sendable {
    // MARK: - UserDefaults Keys

    public enum Defaults {
        public static let cacheRetentionDays = 7
    }

    public static let knownKeys: [String] = [
        "microphonePriority", "excludedApps", "excludedTitlePatterns",
        "excludePrivateBrowsing", "serverURL", "serverKey",
        "cacheRetentionDays", "syncPaused", "debugSegments",
        "debugKeepRejectedAudio", "microphoneGain", "silenceMusic",
        "serviceMode", "journalPath",
        "observerName"
    ]

    private enum Keys {
        static let microphonePriority = "microphonePriority"
        static let excludedApps = "excludedApps"
        static let excludedTitlePatterns = "excludedTitlePatterns"
        static let excludePrivateBrowsing = "excludePrivateBrowsing"
        static let serverURL = "serverURL"
        static let cacheRetentionDays = "cacheRetentionDays"
        static let syncPaused = "syncPaused"
        static let debugSegments = "debugSegments"
        static let serverKey = "serverKey"
        static let debugKeepRejectedAudio = "debugKeepRejectedAudio"
        static let microphoneGain = "microphoneGain"
        static let silenceMusic = "silenceMusic"
        static let serviceMode = "serviceMode"
        static let journalPath = "journalPath"
        static let observerName = "observerName"
        static let didMigrateFromJSON = "didMigrateFromJSON"
        static let didReseedOptInMicrophones = "didReseedOptInMicrophones"
    }

    private enum LegacyKeys {
        static let localRetentionMB = "localRetentionMB"
    }

    // MARK: - Properties

    /// Ordered list of microphones (first = highest priority)
    public var microphonePriority: [MicrophoneEntry]

    /// Apps to exclude from screen capture (windows will be masked)
    public var excludedApps: [AppEntry]

    /// Title patterns - exclude any window whose title contains these patterns
    /// Example: "reddit" will exclude any window with "reddit" in the title
    public var excludedTitlePatterns: [String]

    /// Exclude private/incognito browser windows (Safari, Chrome, Firefox)
    public var excludePrivateBrowsing: Bool

    // MARK: - Server Upload Configuration

    /// Observer server URL (e.g., "https://solstone.example.com")
    public var serverURL: String?

    /// API key for observer server authentication
    public var serverKey: String?

    /// Days to keep synced segments locally. 7 = keep 7 days. 0 = delete after confirmed sync. -1 = keep forever.
    public var cacheRetentionDays: Int

    /// When true, syncing is paused (uploads skipped, but segments still recorded locally)
    public var syncPaused: Bool

    /// When true, use 1-minute segments instead of 5-minute (for testing)
    public var debugSegments: Bool

    /// When true, move rejected audio tracks to rejected/ folder instead of deleting
    public var debugKeepRejectedAudio: Bool

    /// Microphone gain multiplier (1.0 to 8.0). Default: 2.0
    public var microphoneGain: Float

    /// When true, silence music-only portions of system audio during remix. Default: true
    public var silenceMusic: Bool

    /// Configured service mode. Nil means no mode has been explicitly selected yet.
    public var serviceMode: ServiceMode?

    /// Local journal data directory for bundled mode.
    public var journalPath: String?

    /// Journal-assigned observer name returned during registration.
    public var observerName: String?

    /// Default exclusions written on first run
    public static let defaultExclusions: [AppEntry] = [
        AppEntry(bundleID: "com.1password.1password", name: "1Password"),
        AppEntry(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppEntry(bundleID: "com.agilebits.onepassword-osx", name: "1Password (legacy)")
    ]

    public init(
        microphonePriority: [MicrophoneEntry] = [],
        excludedApps: [AppEntry] = [],
        excludedTitlePatterns: [String] = [],
        excludePrivateBrowsing: Bool = true,
        serverURL: String? = nil,
        serverKey: String? = nil,
        cacheRetentionDays: Int = Defaults.cacheRetentionDays,
        syncPaused: Bool = false,
        debugSegments: Bool = false,
        debugKeepRejectedAudio: Bool = false,
        microphoneGain: Float = 2.0,
        silenceMusic: Bool = true,
        serviceMode: ServiceMode? = nil,
        journalPath: String? = nil,
        observerName: String? = nil
    ) {
        self.microphonePriority = microphonePriority
        self.excludedApps = excludedApps
        self.excludedTitlePatterns = excludedTitlePatterns
        self.excludePrivateBrowsing = excludePrivateBrowsing
        self.serverURL = serverURL
        self.serverKey = serverKey
        self.cacheRetentionDays = cacheRetentionDays
        self.syncPaused = syncPaused
        self.debugSegments = debugSegments
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.microphoneGain = microphoneGain
        self.silenceMusic = silenceMusic
        self.serviceMode = serviceMode
        self.journalPath = journalPath
        self.observerName = observerName
    }

    // MARK: - Load/Save

    /// Loads config from UserDefaults
    public static func load() -> AppConfig {
        CFPreferencesAppSynchronize(SolstoneIdentity.bundleIdentifier as CFString)
        let defaults = UserDefaults.standard

        // Load microphonePriority from JSON data
        var microphonePriority: [MicrophoneEntry] = []
        if let data = defaults.data(forKey: Keys.microphonePriority) {
            microphonePriority = (try? JSONDecoder().decode([MicrophoneEntry].self, from: data)) ?? []
        }

        // Load excludedApps from JSON data
        var excludedApps: [AppEntry] = []
        if let data = defaults.data(forKey: Keys.excludedApps) {
            excludedApps = (try? JSONDecoder().decode([AppEntry].self, from: data)) ?? []
        }

        var cacheRetentionDays: Int
        if let existing = defaults.object(forKey: Keys.cacheRetentionDays) as? Int {
            cacheRetentionDays = existing
        } else if let oldMB = defaults.object(forKey: LegacyKeys.localRetentionMB) as? Int {
            cacheRetentionDays = (oldMB == 2048) ? 7 : -1
            defaults.set(cacheRetentionDays, forKey: Keys.cacheRetentionDays)
            defaults.removeObject(forKey: LegacyKeys.localRetentionMB)
            Logger.general.info("Migrated legacy cache retention setting to \(cacheRetentionDays, privacy: .public) days")
        } else {
            cacheRetentionDays = Defaults.cacheRetentionDays
        }

        let serverURL = defaults.string(forKey: Keys.serverURL)
        let serviceMode: ServiceMode?
        if let raw = defaults.string(forKey: Keys.serviceMode), let parsed = ServiceMode(rawValue: raw) {
            serviceMode = parsed
        } else {
            serviceMode = nil
        }

        let config = AppConfig(
            microphonePriority: microphonePriority,
            excludedApps: excludedApps,
            excludedTitlePatterns: defaults.stringArray(forKey: Keys.excludedTitlePatterns) ?? [],
            excludePrivateBrowsing: defaults.object(forKey: Keys.excludePrivateBrowsing) as? Bool ?? true,
            serverURL: serverURL,
            serverKey: defaults.string(forKey: Keys.serverKey),
            cacheRetentionDays: cacheRetentionDays,
            syncPaused: defaults.bool(forKey: Keys.syncPaused),
            debugSegments: defaults.bool(forKey: Keys.debugSegments),
            debugKeepRejectedAudio: defaults.bool(forKey: Keys.debugKeepRejectedAudio),
            microphoneGain: defaults.object(forKey: Keys.microphoneGain) as? Float ?? 2.0,
            silenceMusic: defaults.object(forKey: Keys.silenceMusic) as? Bool ?? true,
            serviceMode: serviceMode,
            journalPath: defaults.string(forKey: Keys.journalPath),
            observerName: defaults.string(forKey: Keys.observerName)
        )
        return config
    }

    /// Loads config or creates with defaults if missing
    /// Also migrates from config.json if present
    public static func loadOrCreateDefault(legacyConfigPaths: [URL]? = nil) -> AppConfig {
        let defaults = UserDefaults.standard
        let legacyConfigPaths = legacyConfigPaths ?? productionLegacyConfigPaths
        var config: AppConfig?

        // Check for migration from JSON config
        if !defaults.bool(forKey: Keys.didMigrateFromJSON) {
            if let migrated = migrateFromJSON(legacyConfigPaths: legacyConfigPaths) {
                config = migrated
            } else {
                // Mark migration as complete even if no file existed
                defaults.set(true, forKey: Keys.didMigrateFromJSON)
            }
        }

        if let config {
            return config
        }

        // Check if we have any config stored
        if defaults.object(forKey: Keys.excludePrivateBrowsing) != nil {
            return load()
        }

        // Create default config
        var defaultConfig = AppConfig()
        defaultConfig.excludedApps = defaultExclusions
        try? defaultConfig.save()
        Logger.general.info("Created default config in UserDefaults")
        return defaultConfig
    }

    /// Saves config to UserDefaults
    public func save() throws {
        let defaults = UserDefaults.standard

        // Save complex types as JSON data
        if let data = try? JSONEncoder().encode(microphonePriority) {
            defaults.set(data, forKey: Keys.microphonePriority)
        }
        if let data = try? JSONEncoder().encode(excludedApps) {
            defaults.set(data, forKey: Keys.excludedApps)
        }

        defaults.set(excludedTitlePatterns, forKey: Keys.excludedTitlePatterns)
        defaults.set(excludePrivateBrowsing, forKey: Keys.excludePrivateBrowsing)
        defaults.set(serverURL, forKey: Keys.serverURL)
        defaults.set(serverKey, forKey: Keys.serverKey)
        if let serviceMode {
            defaults.set(serviceMode.rawValue, forKey: Keys.serviceMode)
        } else {
            defaults.removeObject(forKey: Keys.serviceMode)
        }
        if let journalPath {
            defaults.set(journalPath, forKey: Keys.journalPath)
        } else {
            defaults.removeObject(forKey: Keys.journalPath)
        }
        if let observerName {
            defaults.set(observerName, forKey: Keys.observerName)
        } else {
            defaults.removeObject(forKey: Keys.observerName)
        }
        defaults.set(cacheRetentionDays, forKey: Keys.cacheRetentionDays)
        defaults.set(syncPaused, forKey: Keys.syncPaused)
        defaults.set(debugSegments, forKey: Keys.debugSegments)
        defaults.set(debugKeepRejectedAudio, forKey: Keys.debugKeepRejectedAudio)
        defaults.set(microphoneGain, forKey: Keys.microphoneGain)
        defaults.set(silenceMusic, forKey: Keys.silenceMusic)
    }

    // MARK: - Migration from JSON

    /// Legacy JSON config path
    private static var legacyConfigPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solstone/config.json")
    }

    /// Legacy sck-cli config path
    private static var legacySckCliPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sck-cli.json")
    }

    private static var productionLegacyConfigPaths: [URL] {
        [legacyConfigPath, legacySckCliPath]
    }

    /// Migrates from legacy JSON config if present
    private static func migrateFromJSON(legacyConfigPaths pathsToTry: [URL]) -> AppConfig? {
        let defaults = UserDefaults.standard

        for path in pathsToTry {
            guard FileManager.default.fileExists(atPath: path.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: path)
                let legacyConfig = try JSONDecoder().decode(LegacyJSONConfig.self, from: data)

                let config = AppConfig(
                    microphonePriority: legacyConfig.microphonePriority ?? [],
                    excludedApps: legacyConfig.excludedApps ?? [],
                    excludedTitlePatterns: legacyConfig.excludedTitlePatterns ?? [],
                    excludePrivateBrowsing: legacyConfig.excludePrivateBrowsing ?? true,
                    serverURL: legacyConfig.serverURL,
                    serverKey: legacyConfig.serverKey,
                    cacheRetentionDays: legacyConfig.resolvedCacheRetentionDays(defaultDays: Defaults.cacheRetentionDays),
                    syncPaused: legacyConfig.syncPaused ?? false,
                    debugSegments: legacyConfig.debugSegments ?? false,
                    debugKeepRejectedAudio: legacyConfig.debugKeepRejectedAudio ?? false,
                    microphoneGain: legacyConfig.microphoneGain ?? 2.0,
                    silenceMusic: legacyConfig.silenceMusic ?? true
                )

                try config.save()
                defaults.set(true, forKey: Keys.didMigrateFromJSON)
                Logger.general.info("Migrated config from \(path.path, privacy: .public) to UserDefaults")

                // Optionally rename old file to indicate migration
                let backupPath = path.appendingPathExtension("migrated")
                try? FileManager.default.moveItem(at: path, to: backupPath)

                return config
            } catch {
                Logger.general.warning("Failed to migrate config from \(path.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return nil
    }

    // MARK: - Microphone Methods

    /// Returns UIDs of disabled microphones
    public var disabledMicrophoneUIDs: Set<String> {
        Set(microphonePriority.filter { $0.isDisabled }.map { $0.uid })
    }

    /// Returns UIDs of enabled microphones
    public var enabledMicrophoneUIDs: Set<String> {
        Set(microphonePriority.filter { !$0.isDisabled }.map { $0.uid })
    }

    /// One-shot migration that disables connected opt-in-only microphones previously saved as enabled.
    public mutating func reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: Set<String>) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Keys.didReseedOptInMicrophones) else {
            return
        }

        var reseeded = self
        reseeded.microphonePriority = reseeded.microphonePriority.map { entry in
            guard connectedOptInOnlyUIDs.contains(entry.uid), !entry.isDisabled else {
                return entry
            }
            return MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: true)
        }

        do {
            try reseeded.save()
            self = reseeded
            defaults.set(true, forKey: Keys.didReseedOptInMicrophones)
        } catch {
            Logger.general.warning("Failed to re-seed opt-in microphone defaults: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggles the disabled state of a microphone
    public mutating func toggleMicrophoneDisabled(uid: String) {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = microphonePriority[index]
        microphonePriority[index] = MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: !entry.isDisabled)
    }

    /// Reorders microphones in the priority list
    public mutating func reorderMicrophones(fromOffsets: IndexSet, toOffset: Int) {
        let movingEntries = fromOffsets.map { microphonePriority[$0] }
        let adjustedDestination = toOffset - fromOffsets.filter { $0 < toOffset }.count

        for index in fromOffsets.sorted(by: >) {
            microphonePriority.remove(at: index)
        }

        microphonePriority.insert(contentsOf: movingEntries, at: adjustedDestination)
    }

    /// Removes a microphone from the priority list
    public mutating func removeMicrophone(uid: String) -> Bool {
        let countBefore = microphonePriority.count
        microphonePriority.removeAll(where: { $0.uid == uid })
        return microphonePriority.count < countBefore
    }

    // MARK: - App Exclusion Methods

    /// Returns the names of excluded apps (for WindowMaskDetector)
    public var excludedAppNames: [String] {
        excludedApps.map { $0.name }
    }

    /// Checks if an app is excluded
    public func isAppExcluded(bundleID: String) -> Bool {
        excludedApps.contains(where: { $0.bundleID == bundleID })
    }

    /// Adds an app to the exclusion list
    public mutating func excludeApp(bundleID: String, name: String) -> Bool {
        guard !excludedApps.contains(where: { $0.bundleID == bundleID }) else {
            return false
        }
        excludedApps.append(AppEntry(bundleID: bundleID, name: name))
        return true
    }

    /// Removes an app from the exclusion list
    public mutating func includeApp(bundleID: String) -> Bool {
        let countBefore = excludedApps.count
        excludedApps.removeAll(where: { $0.bundleID == bundleID })
        return excludedApps.count < countBefore
    }

    // MARK: - Server Upload Methods

    /// Check if server upload is configured
    public var isUploadConfigured: Bool {
        guard let url = serverURL, !url.isEmpty,
              let key = serverKey, !key.isEmpty else {
            return false
        }
        return true
    }
}

// MARK: - Legacy JSON Config for Migration

private struct LegacyJSONConfig: Codable {
    var microphonePriority: [MicrophoneEntry]?
    var excludedApps: [AppEntry]?
    var excludedTitlePatterns: [String]?
    var excludePrivateBrowsing: Bool?
    var serverURL: String?
    var serverKey: String?
    var localRetentionMB: Int?
    var cacheRetentionDays: Int?
    var syncPaused: Bool?
    var debugSegments: Bool?
    var debugKeepRejectedAudio: Bool?
    var microphoneGain: Float?
    var silenceMusic: Bool?

    func resolvedCacheRetentionDays(defaultDays: Int) -> Int {
        if let cacheRetentionDays {
            return cacheRetentionDays
        }
        guard let localRetentionMB else {
            return defaultDays
        }
        return localRetentionMB == 2048 ? 7 : -1
    }
}
