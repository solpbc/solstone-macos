import Foundation
import Testing
import SolstoneCore

@Suite("AppConfigMigration", .serialized)
@MainActor
struct AppConfigMigrationTests {
    @Test func inferServiceModeExactBundledURL() {
        #expect(AppConfig.inferServiceMode(from: "http://localhost:5015") == .bundled)
    }

    @Test func inferServiceModeRejectsNonExactURLs() {
        #expect(AppConfig.inferServiceMode(from: "http://localhost:5015/") == nil)
        #expect(AppConfig.inferServiceMode(from: "https://localhost:5015") == nil)
        #expect(AppConfig.inferServiceMode(from: "http://127.0.0.1:5015") == nil)
        #expect(AppConfig.inferServiceMode(from: "") == nil)
        #expect(AppConfig.inferServiceMode(from: nil) == nil)
    }

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

    @Test func loadBackfillsBundledServiceModeFromExactURL() throws {
        clearServiceDefaults()
        defer { clearServiceDefaults() }

        let config = AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "key", serviceMode: nil)
        try config.save()
        UserDefaults.standard.removeObject(forKey: "serviceMode")

        let loaded = AppConfig.load()
        #expect(loaded.serviceMode == .bundled)
        #expect(UserDefaults.standard.string(forKey: "serviceMode") == "bundled")
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

    private func clearServiceDefaults() {
        for key in ["serverURL", "serverKey", "serviceMode"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
