import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("Settings restart contract")
struct SettingsRestartContractTests {
    @Test func registryCoversEveryKnownAppConfigKey() {
        for key in AppConfig.knownKeys {
            #expect(SettingsReloadSemantics.semantic[key] != nil)
        }
    }

    @Test func connectionKeysAreLiveReloaded() {
        for key in ["serverURL", "serverKey", "serviceMode", "journalPath"] {
            #expect(SettingsReloadSemantics.semantic[key] == .live)
        }
    }

    @Test func registryPinsLiveKeys() {
        let keys = [
            "cacheRetentionDays",
            "microphoneGain",
            "silenceMusic",
            "microphonePriority",
            "excludedApps",
            "excludedTitlePatterns",
            "excludePrivateBrowsing",
            "syncPaused",
            "debugSegments",
            "debugKeepRejectedAudio",
            "loginItemEnabled",
            "observerName",
        ]
        for key in keys {
            #expect(SettingsReloadSemantics.semantic[key] == .live)
        }
    }

    @Test func registryPinsAppRestartPseudoKeys() {
        #expect(SettingsReloadSemantics.semantic["screenRecordingGranted"] == .appRestart)
        #expect(SettingsReloadSemantics.semantic["microphoneGranted"] == .live)
    }

    @Test func productionSettingsNoLongerUsesRestartRequiredHookOrBanner() throws {
        let settingsSource = try readSource("Sources/solstone/SettingsView.swift")
        let appStateSource = try readSource("Sources/solstone/AppState.swift")

        #expect(!settingsSource.contains("notifyRestartRequiredSettingSaved"))
        #expect(!settingsSource.contains("restartRequiredBanner"))
        #expect(!settingsSource.contains("requestJournalRestart"))
        #expect(!settingsSource.contains("AXID.Settings.Service.restartJournalButton"))
        #expect(!appStateSource.contains("restartRequiredBannerVisible"))
    }

    @Test func saveServiceImmediateSyncNoLongerWaitsForBundledReadinessGate() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let body = try extract(
            from: source,
            start: "private func saveService(url: String, key: String, mode: ServiceMode)",
            end: "    // MARK: - Microphone Tab"
        )

        #expect(body.contains("syncOnStartup()"))
        #expect(body.contains("appState.clearLastSuccessfulJournalContact()"))
        #expect(body.range(of: "appState.clearLastSuccessfulJournalContact()")!.lowerBound < body.range(of: "appState.updateConfig(config)")!.lowerBound)
        #expect(!body.contains("journalDependentServicesReady"))
        #expect(!body.contains("mode != .bundled"))
    }

    @Test func externalDefaultsReloadIncludesJournalModeKeys() throws {
        let source = try readSource("Sources/solstone/AppState.swift")
        let body = try extract(
            from: source,
            start: "private func handleExternalDefaultsChange()",
            end: "    private func handleDockModeDefaultsChange()"
        )

        #expect(body.contains("fresh.serverURL != config.serverURL"))
        #expect(body.contains("fresh.serverKey != config.serverKey"))
        #expect(body.contains("fresh.observerName != config.observerName"))
        #expect(body.contains("fresh.serviceMode != config.serviceMode"))
        #expect(body.contains("fresh.journalPath != config.journalPath"))
        #expect(body.contains("clearLastSuccessfulJournalContact()"))
        #expect(body.contains("updateConfig(fresh)"))
        #expect(body.range(of: "clearLastSuccessfulJournalContact()")!.lowerBound < body.range(of: "updateConfig(fresh)")!.lowerBound)
    }

    @Test func settingsRelaunchRoutesThroughAppQuitCoordinator() throws {
        let source = try readSource("Sources/solstone/SettingsView.swift")
        let body = try extract(
            from: source,
            start: "private func relaunchApp()",
            end: "    // MARK: - Observer Tab"
        )

        #expect(body.contains("appState.appQuitCoordinator.requestSettingsRestart()"))
        #expect(!body.contains("Process()"))
        #expect(!body.contains("asyncAfter"))
        #expect(!body.contains("NSApp.terminate"))
    }

    private func readSource(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func extract(from source: String, start: String, end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source[startRange.upperBound...].range(of: end))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
