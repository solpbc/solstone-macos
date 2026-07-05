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
}
