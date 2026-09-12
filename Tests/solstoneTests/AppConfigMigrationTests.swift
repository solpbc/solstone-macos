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

    @Test func observerNameRoundTripsThroughDefaultsAndLoadsNilWhenMissing() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig(observerName: "observer-name")
        try config.save()
        #expect(AppConfig.load().observerName == "observer-name")

        config.observerName = nil
        try config.save()
        #expect(AppConfig.load().observerName == nil)
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

    @Test func loadOrCreateDefaultMigratesJSONConfig() throws {
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
        #expect(UserDefaults.standard.bool(forKey: "didMigrateFromJSON"))
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
        #expect(FileManager.default.fileExists(atPath: configURL.appendingPathExtension("migrated").path))
    }

    @Test func optInMicrophoneReseedDoesNotRunWhenFlagIsSet() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        UserDefaults.standard.set(true, forKey: "didReseedOptInMicrophones")
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])

        #expect(config.microphonePriority[0].isDisabled == false)
    }

    @Test func optInMicrophoneReseedDemotesOnlyConnectedEnabledOptInEntries() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false),
            MicrophoneEntry(uid: "usb", name: "USB", isDisabled: false),
            MicrophoneEntry(uid: "disabled-continuity", name: "Disabled Continuity", isDisabled: true)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity", "disabled-continuity"])

        #expect(config.microphonePriority[0].isDisabled)
        #expect(config.microphonePriority[1].isDisabled == false)
        #expect(config.microphonePriority[2].isDisabled)
        #expect(UserDefaults.standard.bool(forKey: "didReseedOptInMicrophones"))
    }

    @Test func optInMicrophoneReseedIsNoopOnSecondRun() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }
        var config = AppConfig(microphonePriority: [
            MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        ])

        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])
        #expect(config.microphonePriority[0].isDisabled)

        config.microphonePriority[0] = MicrophoneEntry(uid: "continuity", name: "Continuity", isDisabled: false)
        config.reseedOptInOnlyMicrophonesIfNeeded(connectedOptInOnlyUIDs: ["continuity"])

        #expect(config.microphonePriority[0].isDisabled == false)
    }

    // MARK: - Capture sources

    // 2.0.6 read an absent key as `false`, so every install that upgraded into it stopped
    // capturing. An absent key means "never chosen", which is on.
    @Test func absentCaptureSourceKeysLoadAsEnabled() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        let loaded = AppConfig.load()
        #expect(loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
        #expect(loaded.selectedSources == [.screen, .microphone])
    }

    @Test func explicitlyDisabledCaptureSourcesSurviveLoad() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        try config.save()

        let loaded = AppConfig.load()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
    }

    // A 2.0.6 install that saved its config persisted both sources as off, so reading an
    // absent key as on cannot reach it. The one-shot repair does, exactly once.
    @Test func reseedTurnsBothSourcesBackOnExactlyOnce() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        config.isMicrophoneCaptureEnabled = false
        try config.save()

        var repaired = AppConfig.load()
        repaired.reseedCaptureSourcesOnIfNeeded()
        #expect(repaired.isScreenCaptureEnabled)
        #expect(repaired.isMicrophoneCaptureEnabled)
        #expect(AppConfig.load().selectedSources == [.screen, .microphone])

        // A later deliberate both-off choice is the owner's, and the repair never fires again.
        var ownerChoice = AppConfig.load()
        ownerChoice.isScreenCaptureEnabled = false
        ownerChoice.isMicrophoneCaptureEnabled = false
        try ownerChoice.save()
        ownerChoice.reseedCaptureSourcesOnIfNeeded()
        #expect(!ownerChoice.isScreenCaptureEnabled)
        #expect(!ownerChoice.isMicrophoneCaptureEnabled)
    }

    @Test func reseedLeavesASingleDisabledSourceAlone() throws {
        clearConfigDefaults()
        defer { clearConfigDefaults() }

        var config = AppConfig()
        config.isScreenCaptureEnabled = false
        try config.save()

        var loaded = AppConfig.load()
        loaded.reseedCaptureSourcesOnIfNeeded()
        #expect(!loaded.isScreenCaptureEnabled)
        #expect(loaded.isMicrophoneCaptureEnabled)
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
            "solInitiatedChatNotificationsEnabled",
            "didReseedOptInMicrophones",
            "didReseedCaptureSourcesOn",
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
