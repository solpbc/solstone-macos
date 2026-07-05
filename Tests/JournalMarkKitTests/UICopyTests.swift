import JournalMarkKit
import Testing

@Suite("JournalMarkKit UICopy")
struct JournalMarkKitUICopyTests {
    @Test func markCopyStrings() {
        #expect(UICopy.JOURNAL_MARK_CONFIRMED_LINE == "this is your journal")
    }
}
