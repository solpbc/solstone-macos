import Foundation
import Testing
import SolstoneCore

@Suite("AppConfigMigration", .serialized)
@MainActor
struct AppConfigMigrationTests {
    @Test func serviceModeBundledRoundTripsThroughDefaults() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: .bundled)
        try config.save()

        #expect(AppConfig.load().serviceMode == .bundled)
    }

    @Test func serviceModeExternalRoundTripsThroughDefaults() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: .external)
        try config.save()

        #expect(AppConfig.load().serviceMode == .external)
    }

    @Test func loadLeavesServiceModeNilForExactBundledURL() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: nil)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serviceMode == nil)
        #expect(UserDefaults.standard.string(forKey: "serviceMode") == nil)
    }

    @Test func loadLeavesServiceModeNilForExternalURL() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: "https://example.com", serverKey: "key", serviceMode: nil)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serviceMode == nil)
        #expect(UserDefaults.standard.string(forKey: "serviceMode") == nil)
    }

    @Test func notificationPreferenceReseedFiresOnceForExistingConfig() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.solInitiatedChatNotificationsEnabled = false
        try config.save()
        UserDefaults.standard.set(true, forKey: "didMigrateFromJSON")

        let reseeded = AppConfig.loadOrCreateDefault(legacyConfigPaths: [])
        #expect(reseeded.solInitiatedChatNotificationsEnabled)
        #expect(UserDefaults.standard.bool(forKey: "solInitiatedChatNotificationsEnabled"))
        #expect(UserDefaults.standard.bool(forKey: "didReseedNotificationPreference"))

        var optedOut = reseeded
        optedOut.solInitiatedChatNotificationsEnabled = false
        try optedOut.save()

        let loadedAfterMarker = AppConfig.loadOrCreateDefault(legacyConfigPaths: [])
        #expect(!loadedAfterMarker.solInitiatedChatNotificationsEnabled)
    }

    @Test func notificationPreferenceReseedAppliesToFreshConfig() {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        let loaded = AppConfig.loadOrCreateDefault(legacyConfigPaths: [])

        #expect(loaded.solInitiatedChatNotificationsEnabled)
        #expect(UserDefaults.standard.bool(forKey: "solInitiatedChatNotificationsEnabled"))
        #expect(UserDefaults.standard.bool(forKey: "didReseedNotificationPreference"))
    }

    @Test func notificationPreferenceReseedAppliesToMigratedJSONConfig() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let configURL = temp.appendingPathComponent("config.json")
        try Data("""
        {
          "serverURL": "https://example.com",
          "serverKey": "key",
          "excludePrivateBrowsing": false,
          "cacheRetentionDays": 14
        }
        """.utf8).write(to: configURL)

        let migrated = AppConfig.loadOrCreateDefault(legacyConfigPaths: [configURL])

        #expect(migrated.serverURL == "https://example.com")
        #expect(migrated.serverKey == "key")
        #expect(migrated.cacheRetentionDays == 14)
        #expect(migrated.solInitiatedChatNotificationsEnabled)
        #expect(UserDefaults.standard.bool(forKey: "solInitiatedChatNotificationsEnabled"))
        #expect(UserDefaults.standard.bool(forKey: "didMigrateFromJSON"))
        #expect(UserDefaults.standard.bool(forKey: "didReseedNotificationPreference"))
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: configURL.appendingPathExtension("migrated").path))
    }

    private func clearServiceDefaults() {
        for key in ["serverURL", "serverKey", "serviceMode"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func clearConfigDefaults() {
        for key in AppConfig.knownKeys + [
            "didMigrateFromJSON",
            "didReseedNotificationPreference",
            "localRetentionMB"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-app-config-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
