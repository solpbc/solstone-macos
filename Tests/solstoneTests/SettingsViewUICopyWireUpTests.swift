import Foundation
import Testing
@testable import solstone

@Suite("SettingsView UI copy wire-up")
struct SettingsViewUICopyWireUpTests {
    @Test func journalModePickerUsesUICopyLabelSymbols() throws {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_LABEL == "this Mac")
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL == "another machine")

        let source = try String(contentsOfFile: "Sources/solstone/SettingsView.swift", encoding: .utf8)
        #expect(source.contains("Text(UICopy.JOURNAL_MODE_THIS_MAC_LABEL).tag(ServiceMode.bundled)"))
        #expect(source.contains("Text(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL).tag(ServiceMode.external)"))
    }
}
