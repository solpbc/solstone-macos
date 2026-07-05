import Testing
@testable import solstone

@Suite("UICopy")
struct UICopyTests {
    @Test func journalModeThisMacLabelString() {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_LABEL == "this Mac")
    }

    @Test func journalModeAnotherMachineLabelString() {
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL == "another device")
    }

    @Test func journalModeThisMacTradeoffString() {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_TRADEOFF == "everything runs on this Mac and your journal lives here. recommended if you're just getting started.")
    }

    @Test func journalModeAnotherMachineTradeoffString() {
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_TRADEOFF == "this Mac syncs to a journal that lives on another device — your other Mac, your home server, or a journal you've been invited to.")
        #expect(UICopy.PAIRING_NOTENTITLED_RECOVERY == "your journal is paired, but it isn\u{0027}t on the paid plan \u{2014} so it can\u{0027}t sync over the internet. on the same wi-fi as your journal, or over your own vpn, it connects directly without the plan.")
        #expect(UICopy.PAIRING_DISCONNECT_CONFIRM == "disconnect this Mac from your journal? your journal keeps everything \u{2014} you can pair again anytime.")
    }

    @Test func journalMarkStrings() {
        #expect(UICopy.JOURNAL_MARK_CONFIRM_QUESTION == "does this match your journal?")
        #expect(UICopy.JOURNAL_MARK_CONFIRM_SUBTEXT == "your journal shows this same mark in its network app. it should match \u{2014} exactly.")
        #expect(UICopy.JOURNAL_MARK_CONFIRM_BUTTON == "yes \u{2014} this is my journal")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_BUTTON == "that doesn\u{0027}t match")
        #expect(UICopy.JOURNAL_MARK_CONNECTING == "connecting\u{2026}")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_TITLE == "not connected")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_BODY == "you said this mark doesn\u{0027}t match the one your journal shows \u{2014} so we didn\u{0027}t connect this Mac. you may have pasted the wrong link, or something isn\u{0027}t right. try again, or reach us and we\u{0027}ll help.")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_FRESH_LINK == "get a fresh link")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_SUPPORT == "email support@solstone.app")
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
        #expect(UICopy.SETTINGS_TAB_UPDATES_DONE_A11Y == "sol is up to date")
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

    @Test func journalRuntimeMenuStateStrings() {
        #expect(UICopy.JOURNAL_SETUP_NEEDED_OPEN_SETTINGS == "journal setup needed \u{2014} open settings")
        #expect(UICopy.JOURNAL_NEEDS_ATTENTION_OPEN_SETTINGS == "journal needs attention \u{2014} open settings")
        #expect(UICopy.JOURNAL_RESTARTING == "journal restarting\u{2026}")
    }

    @Test func journalRuntimeStatusPaneStrings() {
        #expect(UICopy.JOURNAL_STATUS_RUNNING == "running")
        #expect(UICopy.JOURNAL_STATUS_RESTARTING == "restarting\u{2026}")
        #expect(UICopy.JOURNAL_STATUS_SETUP_NEEDED == "setup needed")
        #expect(UICopy.JOURNAL_STATUS_NEEDS_ATTENTION == "needs attention")
        #expect(UICopy.JOURNAL_STATUS_STOPPED == "stopped")
    }

    @Test func journalWaitingMenuStrings() {
        #expect(UICopy.JOURNAL_WAITING_FOR_READINESS_MENU == "on, waiting for journal")
        #expect(UICopy.JOURNAL_WAITING_FOR_READINESS_MENU_BUTTON == "on, waiting for journal →")
    }

    @Test func journalRestartAndSetupStrings() {
        #expect(UICopy.RESTART_JOURNAL == "restart journal")
        #expect(UICopy.STOP_JOURNAL == "stop journal")
        #expect(UICopy.START_JOURNAL == "start journal")
    }

    @Test func installerInlineFailureGenericString() {
        #expect(UICopy.INSTALLER_INLINE_FAILURE_GENERIC == "setup hit a snag \u{2014} retry below, or open details to share with support.")
    }

    @Test func installerReadinessTimeoutString() {
        #expect(UICopy.INSTALLER_READINESS_TIMEOUT == "the journal didn't become ready in time")
    }

}
