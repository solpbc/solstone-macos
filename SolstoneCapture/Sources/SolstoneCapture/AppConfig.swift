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
/// Stored at ~/Library/Application Support/Solstone/config.json
public struct AppConfig: Codable, Sendable {
    /// Ordered list of microphones (first = highest priority)
    public var microphonePriority: [MicrophoneEntry]

    /// Apps to exclude from screen capture (windows will be masked)
    public var excludedApps: [AppEntry]

    /// Exclude private/incognito browser windows (Safari, Chrome, Firefox)
    public var excludePrivateBrowsing: Bool

    // MARK: - Server Upload Configuration

    /// Remote server URL (e.g., "https://solstone.example.com")
    public var serverURL: String?

    /// API key for remote server authentication - stored securely in Keychain
    /// Note: This is a computed property backed by KeychainManager
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

    /// Default exclusions written on first run
    public static let defaultExclusions: [AppEntry] = [
        AppEntry(bundleID: "com.1password.1password", name: "1Password"),
        AppEntry(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppEntry(bundleID: "com.agilebits.onepassword-osx", name: "1Password (legacy)")
    ]

    public init(
        microphonePriority: [MicrophoneEntry] = [],
        excludedApps: [AppEntry] = [],
        excludePrivateBrowsing: Bool = true,
        serverURL: String? = nil,
        localRetentionMB: Int = 200,
        syncPaused: Bool = false
    ) {
        self.microphonePriority = microphonePriority
        self.excludedApps = excludedApps
        self.excludePrivateBrowsing = excludePrivateBrowsing
        self.serverURL = serverURL
        self.localRetentionMB = localRetentionMB
        self.syncPaused = syncPaused
    }

    /// Custom decoder for backward compatibility and Keychain migration
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphonePriority = try container.decodeIfPresent([MicrophoneEntry].self, forKey: .microphonePriority) ?? []
        excludedApps = try container.decodeIfPresent([AppEntry].self, forKey: .excludedApps) ?? []
        excludePrivateBrowsing = try container.decodeIfPresent(Bool.self, forKey: .excludePrivateBrowsing) ?? true
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        localRetentionMB = try container.decodeIfPresent(Int.self, forKey: .localRetentionMB) ?? 200
        syncPaused = try container.decodeIfPresent(Bool.self, forKey: .syncPaused) ?? false

        // Migrate legacy serverKey from JSON to Keychain
        if let legacyKey = try container.decodeIfPresent(String.self, forKey: .serverKey),
           !legacyKey.isEmpty,
           KeychainManager.loadServerKey() == nil {
            KeychainManager.saveServerKey(legacyKey)
            Log.info("Migrated server key from config file to Keychain")
        }
    }

    /// Custom encoder to exclude serverKey (stored in Keychain, not JSON)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(microphonePriority, forKey: .microphonePriority)
        try container.encode(excludedApps, forKey: .excludedApps)
        try container.encode(excludePrivateBrowsing, forKey: .excludePrivateBrowsing)
        try container.encodeIfPresent(serverURL, forKey: .serverURL)
        // Note: serverKey deliberately not encoded - stored in Keychain
        try container.encode(localRetentionMB, forKey: .localRetentionMB)
        try container.encode(syncPaused, forKey: .syncPaused)
    }

    private enum CodingKeys: String, CodingKey {
        case microphonePriority
        case excludedApps
        case excludePrivateBrowsing
        case serverURL
        case serverKey  // Only used for decoding legacy configs
        case localRetentionMB
        case syncPaused
    }

    // MARK: - File Paths

    /// Base directory for Solstone app data
    private static var baseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Solstone")
    }

    /// Config file path
    public static var configPath: URL {
        baseDirectory.appendingPathComponent("config.json")
    }

    /// Legacy sck-cli config path for migration
    private static var legacyConfigPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sck-cli.json")
    }

    // MARK: - Load/Save

    /// Loads config from disk
    /// Returns default config if file doesn't exist or is invalid
    public static func load() -> AppConfig {
        // Try to load from our config path
        if FileManager.default.fileExists(atPath: configPath.path) {
            do {
                let data = try Data(contentsOf: configPath)
                let config = try JSONDecoder().decode(AppConfig.self, from: data)
                return config
            } catch {
                Log.warn("Failed to load config: \(error.localizedDescription)")
            }
        }

        return AppConfig()
    }

    /// Loads config or creates with defaults if missing
    /// Also migrates from sck-cli config if present
    public static func loadOrCreateDefault() -> AppConfig {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        // Check for migration from sck-cli config
        if !FileManager.default.fileExists(atPath: configPath.path) {
            if let migrated = migrateFromLegacy() {
                return migrated
            }
        }

        // Load existing or create default
        if FileManager.default.fileExists(atPath: configPath.path) {
            return load()
        }

        // Create default config
        var config = AppConfig()
        config.excludedApps = defaultExclusions

        do {
            try config.save()
            Log.info("Created default config at \(configPath.path)")
        } catch {
            Log.warn("Failed to save default config: \(error.localizedDescription)")
        }

        return config
    }

    /// Saves config to disk
    public func save() throws {
        // Ensure directory exists
        try FileManager.default.createDirectory(at: Self.baseDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.configPath, options: .atomic)
    }

    /// Migrates from legacy sck-cli config if present
    private static func migrateFromLegacy() -> AppConfig? {
        guard FileManager.default.fileExists(atPath: legacyConfigPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: legacyConfigPath)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            try config.save()
            Log.info("Migrated config from \(legacyConfigPath.path)")
            return config
        } catch {
            Log.warn("Failed to migrate legacy config: \(error.localizedDescription)")
            return nil
        }
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
