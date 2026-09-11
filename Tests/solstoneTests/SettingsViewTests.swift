import Foundation
import OSLog
import Testing
import UpdateKit
@testable import solstone

@Suite("SettingsView")
struct SettingsViewTests {
    @Test func configuredJournalPanelWiresAffordancesFromRemedy() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        #expect(wireUpContains(source, "journalPanelAffordances(for:"))
        #expect(wireUpContains(source, "affordances.showOpenJournal"))
        #expect(wireUpContains(source, "appState.requestOpenJournal(.root)"))
        #expect(wireUpContains(source, "affordances.showRelink"))
        #expect(wireUpContains(source, "affordances.showTunnelRetry"))
        #expect(wireUpContains(source, "affordances.showPairingForm"))
    }

    @Test func tabRawValuesMatchCaseNames() {
        #expect(SettingsView.Tab.permissions.rawValue == "permissions")
        #expect(SettingsView.Tab.observer.rawValue == "observer")
        #expect(SettingsView.Tab.service.rawValue == "service")
        #expect(SettingsView.Tab.microphones.rawValue == "microphones")
        #expect(SettingsView.Tab.privacy.rawValue == "privacy")
        #expect(SettingsView.Tab.status.rawValue == "status")
        #expect(SettingsView.Tab.updates.rawValue == "updates")
        #expect(SettingsView.Tab.help.rawValue == "help")
    }

    @Test @MainActor func settingsViewAcceptsInjectedOpenURL() {
        var openedURLs: [URL] = []
        let customOpenURL: @MainActor (URL) -> Bool = { url in
            openedURLs.append(url)
            return true
        }

        let state = AppState.forSnapshot()
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }
        _ = SettingsView(appState: state, updateController: updateController, openURL: customOpenURL)
        #expect(openedURLs.isEmpty)
    }

    @Test @MainActor func openerRefusalAndSuccessIsolation() {
        final class OpenResultBox: @unchecked Sendable {
            var result = false
        }

        let appState = AppState.forSnapshot()
        var openedURLs: [URL] = []
        let box = OpenResultBox()
        let updateController = UpdateController(
            feedURL: nil,
            publicKey: nil,
            log: .setup,
            errorDomain: "app.solstone.observer.updates",
            defaults: .standard
        ) { _, _ in nil }

        let settings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { url in
                openedURLs.append(url)
                return box.result
            }
        )

        // Test entitlement opener failure
        box.result = false
        let entFailResult = settings.openEntitlementURL()
        #expect(!entFailResult)
        #expect(openedURLs.last?.absoluteString == "https://link.solstone.app")

        // Test entitlement opener success
        box.result = true
        let entSuccessResult = settings.openEntitlementURL()
        #expect(entSuccessResult)

        // Test support mailto failure
        box.result = false
        let supFailResult = settings.openSupportMailto()
        #expect(!supFailResult)
        #expect(openedURLs.last?.absoluteString == "mailto:support@solstone.app")

        // Test support mailto success
        box.result = true
        let supSuccessResult = settings.openSupportMailto()
        #expect(supSuccessResult)

        // Test isolation: openEntitlementURL success does not clear supportOpenFailed
        let supportFailedSettings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { _ in true },
            initialEntitlementOpenFailed: false,
            initialSupportOpenFailed: true
        )
        #expect(supportFailedSettings.supportOpenFailed)
        #expect(!supportFailedSettings.entitlementOpenFailed)
        let entSucceeded = supportFailedSettings.openEntitlementURL()
        #expect(entSucceeded)
        #expect(supportFailedSettings.supportOpenFailed)
        #expect(!supportFailedSettings.entitlementOpenFailed)

        // Test isolation: openSupportMailto success does not clear entitlementOpenFailed
        let entFailedSettings = SettingsView(
            appState: appState,
            updateController: updateController,
            openURL: { _ in true },
            initialEntitlementOpenFailed: true,
            initialSupportOpenFailed: false
        )
        #expect(entFailedSettings.entitlementOpenFailed)
        #expect(!entFailedSettings.supportOpenFailed)
        let supSucceeded = entFailedSettings.openSupportMailto()
        #expect(supSucceeded)
        #expect(entFailedSettings.entitlementOpenFailed)
        #expect(!entFailedSettings.supportOpenFailed)
    }
}
