// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCaptureCore

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

    private enum Keys {
        static let microphonePriority = "microphonePriority"
        static let excludedApps = "excludedApps"
        static let excludedTitlePatterns = "excludedTitlePatterns"
        static let excludePrivateBrowsing = "excludePrivateBrowsing"
        static let serverURL = "serverURL"
        static let localRetentionMB = "localRetentionMB"
        static let syncPaused = "syncPaused"
        static let debugSegments = "debugSegments"
        static let debugKeepRejectedAudio = "debugKeepRejectedAudio"
        static let microphoneGain = "microphoneGain"
        static let silenceMusic = "silenceMusic"
        static let didMigrateFromJSON = "didMigrateFromJSON"
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

    /// Remote server URL (e.g., "https://solstone.example.com")
    public var serverURL: String?

    /// API key for remote server authentication - stored securely in Keychain
    public var serverKey: String? {
        get { KeychainManager.loadServerKey() }
        set {
            if let key = newValue {
                KeychainManager.saveServerKey(key)
            } else {
                KeychainManager.deleteServerKey()
            }
        }
    }

    /// Maximum local storage to retain after upload (in MB). Default: 200
    /// Only segments that have been successfully uploaded will be deleted.
    public var localRetentionMB: Int

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
        localRetentionMB: Int = 200,
        syncPaused: Bool = false,
        debugSegments: Bool = false,
        debugKeepRejectedAudio: Bool = false,
        microphoneGain: Float = 2.0,
        silenceMusic: Bool = true
    ) {
        self.microphonePriority = microphonePriority
        self.excludedApps = excludedApps
        self.excludedTitlePatterns = excludedTitlePatterns
        self.excludePrivateBrowsing = excludePrivateBrowsing
        self.serverURL = serverURL
        self.localRetentionMB = localRetentionMB
        self.syncPaused = syncPaused
        self.debugSegments = debugSegments
        self.debugKeepRejectedAudio = debugKeepRejectedAudio
        self.microphoneGain = microphoneGain
        self.silenceMusic = silenceMusic
    }

    // MARK: - Load/Save

    /// Loads config from UserDefaults
    public static func load() -> AppConfig {
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

        return AppConfig(
            microphonePriority: microphonePriority,
            excludedApps: excludedApps,
            excludedTitlePatterns: defaults.stringArray(forKey: Keys.excludedTitlePatterns) ?? [],
            excludePrivateBrowsing: defaults.object(forKey: Keys.excludePrivateBrowsing) as? Bool ?? true,
            serverURL: defaults.string(forKey: Keys.serverURL),
            localRetentionMB: defaults.object(forKey: Keys.localRetentionMB) as? Int ?? 200,
            syncPaused: defaults.bool(forKey: Keys.syncPaused),
            debugSegments: defaults.bool(forKey: Keys.debugSegments),
            debugKeepRejectedAudio: defaults.bool(forKey: Keys.debugKeepRejectedAudio),
            microphoneGain: defaults.object(forKey: Keys.microphoneGain) as? Float ?? 2.0,
            silenceMusic: defaults.object(forKey: Keys.silenceMusic) as? Bool ?? true
        )
    }

    /// Loads config or creates with defaults if missing
    /// Also migrates from config.json if present
    public static func loadOrCreateDefault() -> AppConfig {
        let defaults = UserDefaults.standard

        // Check for migration from JSON config
        if !defaults.bool(forKey: Keys.didMigrateFromJSON) {
            if let migrated = migrateFromJSON() {
                return migrated
            }
            // Mark migration as complete even if no file existed
            defaults.set(true, forKey: Keys.didMigrateFromJSON)
        }

        // Check if we have any config stored
        if defaults.object(forKey: Keys.excludePrivateBrowsing) != nil {
            return load()
        }

        // Create default config
        var config = AppConfig()
        config.excludedApps = defaultExclusions
        try? config.save()
        Log.info("Created default config in UserDefaults")

        return config
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
        defaults.set(localRetentionMB, forKey: Keys.localRetentionMB)
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

    /// Migrates from legacy JSON config if present
    private static func migrateFromJSON() -> AppConfig? {
        let defaults = UserDefaults.standard

        // Try main config path first, then legacy sck-cli path
        let pathsToTry = [legacyConfigPath, legacySckCliPath]

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
                    localRetentionMB: legacyConfig.localRetentionMB ?? 200,
                    syncPaused: legacyConfig.syncPaused ?? false,
                    debugSegments: legacyConfig.debugSegments ?? false,
                    debugKeepRejectedAudio: legacyConfig.debugKeepRejectedAudio ?? false,
                    microphoneGain: legacyConfig.microphoneGain ?? 2.0,
                    silenceMusic: legacyConfig.silenceMusic ?? true
                )

                // Migrate serverKey from JSON to Keychain if present
                if let key = legacyConfig.serverKey, !key.isEmpty, KeychainManager.loadServerKey() == nil {
                    KeychainManager.saveServerKey(key)
                    Log.info("Migrated server key from JSON to Keychain")
                }

                try config.save()
                defaults.set(true, forKey: Keys.didMigrateFromJSON)
                Log.info("Migrated config from \(path.path) to UserDefaults")

                // Optionally rename old file to indicate migration
                let backupPath = path.appendingPathExtension("migrated")
                try? FileManager.default.moveItem(at: path, to: backupPath)

                return config
            } catch {
                Log.warn("Failed to migrate config from \(path.path): \(error.localizedDescription)")
            }
        }

        return nil
    }

    // MARK: - Microphone Methods

    /// Returns UIDs of disabled microphones
    public var disabledMicrophoneUIDs: Set<String> {
        Set(microphonePriority.filter { $0.isDisabled }.map { $0.uid })
    }

    /// Toggles the disabled state of a microphone
    public mutating func toggleMicrophoneDisabled(uid: String) {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else { return }
        let entry = microphonePriority[index]
        microphonePriority[index] = MicrophoneEntry(uid: entry.uid, name: entry.name, isDisabled: !entry.isDisabled)
    }

    /// Reorders microphones in the priority list
    public mutating func reorderMicrophones(fromOffsets: IndexSet, toOffset: Int) {
        microphonePriority.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Selects the highest priority microphone that is currently available
    public func selectBestMicrophone(from available: [AudioInputDevice]) -> AudioInputDevice? {
        let availableUIDs = Set(available.map { $0.uid })

        for entry in microphonePriority {
            if availableUIDs.contains(entry.uid) {
                return available.first(where: { $0.uid == entry.uid })
            }
        }

        return nil
    }

    /// Adds a microphone to the priority list
    public mutating func addMicrophone(_ device: AudioInputDevice) -> Bool {
        guard !microphonePriority.contains(where: { $0.uid == device.uid }) else {
            return false
        }
        microphonePriority.append(MicrophoneEntry(uid: device.uid, name: device.name))
        return true
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
    var syncPaused: Bool?
    var debugSegments: Bool?
    var debugKeepRejectedAudio: Bool?
    var microphoneGain: Float?
    var silenceMusic: Bool?
}
