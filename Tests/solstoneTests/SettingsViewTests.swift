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

    @Test func journalPaneKeepsCacheControlsInExternalModeBranch() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let serviceSection = try extract(
            from: source,
            start: "private var serviceSection: some View",
            end: "    @ViewBuilder\n    private var bundledJournalStatusSection"
        )
        let bundledBranch = try extract(
            from: serviceSection,
            start: "case .bundled:",
            end: "case .external:"
        )
        let externalBranch = try extract(
            from: serviceSection,
            start: "case .external:",
            end: "        }\n    }"
        )

        #expect(bundledBranch.contains("bundledJournalStatusSection"))
        #expect(!bundledBranch.contains("externalJournalSyncSection"))
        #expect(!bundledBranch.contains("externalJournalStorageSection"))
        #expect(externalBranch.contains("externalJournalSyncSection"))
        #expect(externalBranch.contains("externalJournalStorageSection"))
    }

    @Test func statusPaneHidesStorageControlsInBundledMode() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")
        let statusTab = try extract(
            from: source,
            start: "private var statusTab: some View",
            end: "    #if DEBUG"
        )
        let beforeExternalStorageGate = try extract(
            from: statusTab,
            start: "GroupBox(\"journal\")",
            end: "if appState.config.serviceMode == .external"
        )
        let externalStorageGate = try extract(
            from: statusTab,
            start: "if appState.config.serviceMode == .external",
            end: "Text(statusFooterText)"
        )

        #expect(statusTab.contains("if appState.config.serviceMode == .bundled"))
        #expect(!beforeExternalStorageGate.contains("AXID.Settings.Status.storageSettings"))
        #expect(externalStorageGate.contains("AXID.Settings.Status.storageSettings"))
    }

    private func extract(from source: String, start: String, end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source[startRange.upperBound...].range(of: end))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}
