import Foundation
import Testing
@testable import solstone

@Suite("SettingsView UI copy wire-up")
struct SettingsViewUICopyWireUpTests {
    @Test func journalPanelUsesApprovedLowercaseCopy() throws {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_LABEL == "this Mac")
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL == "another device")

        let source = try String(contentsOfFile: "Sources/solstone/SettingsView.swift", encoding: .utf8)
        #expect(source.contains(#"Text("your journal")"#))
        #expect(source.contains(#"Text("found your journal on this mac")"#))
        #expect(source.contains(#"Button("create your journal on this mac")"#))
        #expect(source.contains(#"Button("pair to a journal on another device")"#))
        #expect(!source.contains("journalModePicker"))
    }

    @Test func journalMarkSheetUsesUICopySymbols() throws {
        let source = try String(contentsOfFile: "Sources/solstone/SettingsView.swift", encoding: .utf8)
        let references = [
            "UICopy.JOURNAL_MARK_CONNECTING",
            "UICopy.JOURNAL_MARK_CONFIRM_QUESTION",
            "UICopy.JOURNAL_MARK_CONFIRM_SUBTEXT",
            "UICopy.JOURNAL_MARK_CONFIRM_BUTTON",
            "UICopy.JOURNAL_MARK_MISMATCH_BUTTON",
            "UICopy.JOURNAL_MARK_MISMATCH_TITLE",
            "UICopy.JOURNAL_MARK_MISMATCH_BODY",
            "UICopy.JOURNAL_MARK_MISMATCH_FRESH_LINK",
            "UICopy.JOURNAL_MARK_MISMATCH_SUPPORT"
        ]

        for reference in references {
            #expect(source.contains(reference))
        }
    }
}
