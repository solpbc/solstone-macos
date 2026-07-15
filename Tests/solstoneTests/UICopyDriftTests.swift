import Testing
@testable import solstone

@Suite("UICopy drift")
struct UICopyDriftTests {
    @Test func fixedJournalPanelCopyLiteralsStayExact() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")

        #expect(source.contains(#"Text("your journal")"#))
        #expect(source.contains(#"Text("found your journal on this mac")"#))
        #expect(source.contains(#"Button("create your journal on this mac")"#))
        #expect(source.contains(#"Button("pair to a journal on another device")"#))
    }

    @Test func setupStatusCopyIsReferencedThroughUICopy() throws {
        let source = try readWireUpSource("Sources/solstone/SettingsView.swift")

        #expect(source.contains("UICopy.SETTINGS_SETUP_GROUP_TITLE"))
        #expect(source.contains("UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION"))
        #expect(source.contains("UICopy.SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT"))
        #expect(source.contains("UICopy.SETTINGS_PERMISSIONS_MIC_DENIED"))
        #expect(!source.contains(#"GroupBox("check my setup")"#))
        #expect(!source.contains(#"Button("open journal settings →")"#))
    }
}
