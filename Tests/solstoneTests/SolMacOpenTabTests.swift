import Testing
@testable import sol_mac

@Suite("SolMacOpenTab")
struct SolMacOpenTabTests {
    @Test func whitelistMatchesSpec() {
        #expect(openTabWhitelist == [
            "general",
            "permissions",
            "journal",
            "service",
            "microphones",
            "privacy",
            "help",
            "status",
            "updates"
        ])
    }

    @Test func unknownTabWarnsButDoesNotReject() {
        #expect(openTabWarning(for: "mystery") == "warning: unknown tab 'mystery'; window will open without changing pane")
        #expect(openTabWarning(for: "general") == nil)
    }

    @Test func journalTabIsAccepted() {
        #expect(openTabWarning(for: "journal") == nil)
    }
}
