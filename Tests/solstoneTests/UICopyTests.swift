import Testing
@testable import solstone

@Suite("UICopy")
struct UICopyTests {
    @Test func journalModeThisMacLabelString() {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_LABEL == "this Mac")
    }

    @Test func journalModeAnotherMachineLabelString() {
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL == "another machine")
    }

    @Test func journalModeThisMacTradeoffString() {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_TRADEOFF == "solstone runs the full system on this Mac and hosts your journal here. recommended if you\u{0027}re just getting started.")
    }

    @Test func journalModeAnotherMachineTradeoffString() {
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_TRADEOFF == "this Mac becomes an observer feeding a journal that lives on another machine \u{2014} your other Mac, your home server, or a journal you\u{0027}ve been invited to.")
    }

    @Test func settingsPrereqPermissionsString() {
        #expect(UICopy.SETTINGS_PREREQ_PERMISSIONS == "you\u{0027}ll also need to grant permissions \u{2192}")
    }

    @Test func settingsNextConnectJournalString() {
        #expect(UICopy.SETTINGS_NEXT_CONNECT_JOURNAL == "next: connect your journal \u{2192}")
    }

    @Test func settingsNextCheckStatusString() {
        #expect(UICopy.SETTINGS_NEXT_CHECK_STATUS == "next: check status \u{2192}")
    }

    @Test func settingsTabDoneA11yString() {
        #expect(UICopy.SETTINGS_TAB_DONE_A11Y == "configured")
    }

    @Test func settingsTabAttentionA11yString() {
        #expect(UICopy.SETTINGS_TAB_ATTENTION_A11Y == "needs attention")
    }

    @Test func settingsTabUpdatesDoneA11yString() {
        #expect(UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y == "up to date")
    }

    @Test func settingsAttentionPermissionsString() {
        #expect(UICopy.SETTINGS_ATTENTION_PERMISSIONS == "permissions needed")
    }

    @Test func settingsAttentionJournalString() {
        #expect(UICopy.SETTINGS_ATTENTION_JOURNAL == "journal setup needed")
    }

    @Test func settingsAttentionUpdateAvailableString() {
        #expect(UICopy.SETTINGS_ATTENTION_UPDATE_AVAILABLE == "update available")
    }

    @Test func settingsAttentionUpdateCheckFailedString() {
        #expect(UICopy.SETTINGS_ATTENTION_UPDATE_CHECK_FAILED == "update check failed")
    }

    @Test func settingsRestartRequiredBannerString() {
        #expect(UICopy.SETTINGS_RESTART_REQUIRED_BANNER == "restart needed for this to take effect \u{2014} restart now \u{2192}")
    }
}
