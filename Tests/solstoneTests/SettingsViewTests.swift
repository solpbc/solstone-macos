import Testing
@testable import solstone

@Suite("SettingsView")
struct SettingsViewTests {
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
}
