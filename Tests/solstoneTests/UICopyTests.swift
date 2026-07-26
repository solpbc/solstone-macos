import Testing
@testable import solstone

@Suite("UICopy")
struct UICopyTests {
    @Test func journalWindowStrings() {
        let values = [
            UICopy.JOURNAL_WINDOW_TITLE,
            UICopy.JOURNAL_WINDOW_HELD,
            UICopy.JOURNAL_WINDOW_LOADING,
            UICopy.JOURNAL_WINDOW_ERROR,
            UICopy.JOURNAL_WINDOW_RETRY
        ]

        #expect(UICopy.JOURNAL_WINDOW_TITLE == "your journal")
        #expect(UICopy.JOURNAL_WINDOW_HELD == "your journal isn\u{0027}t connected yet")
        #expect(UICopy.JOURNAL_WINDOW_LOADING == "opening your journal\u{2026}")
        #expect(UICopy.JOURNAL_WINDOW_ERROR == "your journal couldn\u{0027}t load")
        #expect(UICopy.JOURNAL_WINDOW_RETRY == "try again")
        for value in values {
            for banned in ["capture", "watch", "record", "monitor", "track", "collect"] {
                #expect(!value.localizedCaseInsensitiveContains(banned))
            }
        }
    }

    @Test func journalModeThisMacLabelString() {
        #expect(UICopy.JOURNAL_MODE_THIS_MAC_LABEL == "this Mac")
    }

    @Test func journalModeAnotherMachineLabelString() {
        #expect(UICopy.JOURNAL_MODE_ANOTHER_MACHINE_LABEL == "another device")
    }

    @Test func pairingRecoveryStrings() {
        #expect(UICopy.PAIRING_NOTENTITLED_RECOVERY == "your journal is paired, but it isn\u{0027}t on the paid plan, so it can\u{0027}t sync over the internet. on the same wi-fi as your journal, or over your own vpn, it connects directly without the plan.")
        #expect(UICopy.PAIRING_DISCONNECT_CONFIRM == "disconnect this Mac from your journal? your journal keeps everything. you can pair again anytime.")
    }

    @Test func journalMarkStrings() {
        #expect(UICopy.JOURNAL_MARK_CONFIRM_QUESTION == "does this match your journal?")
        #expect(UICopy.JOURNAL_MARK_CONFIRM_SUBTEXT == "your journal shows this same mark in its network app. it should match, exactly.")
        #expect(UICopy.JOURNAL_MARK_CONFIRM_BUTTON == "yes, this is my journal")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_BUTTON == "that doesn\u{0027}t match")
        #expect(UICopy.JOURNAL_MARK_CONNECTING == "connecting\u{2026}")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_TITLE == "not connected")
        #expect(UICopy.JOURNAL_MARK_MISMATCH_BODY == "you said this mark doesn\u{0027}t match the one your journal shows, so we didn\u{0027}t connect this Mac. you may have pasted the wrong link, or something isn\u{0027}t right. try again, or reach us and we\u{0027}ll help.")
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

    @Test func settingsSetupCopyStrings() {
        #expect(UICopy.SETTINGS_SETUP_GROUP_TITLE == "check my setup")
        #expect(UICopy.SETTINGS_SETUP_VERDICT_READY == "your setup is ready")
        #expect(UICopy.settingsSetupVerdictNeedsAttention(1) == "1 thing needs attention")
        #expect(UICopy.settingsSetupVerdictNeedsAttention(2) == "2 things need attention")
        #expect(UICopy.SETTINGS_SETUP_VERDICT_UNAVAILABLE == "some setup checks are unavailable")
        #expect(UICopy.SETTINGS_SETUP_SOL_APP_LABEL == "sol app")
        #expect(UICopy.SETTINGS_SETUP_SOL_APP_READY == "in Applications")
        #expect(UICopy.SETTINGS_SETUP_SOL_APP_NEEDS_ATTENTION == "needs to be moved")
        #expect(UICopy.SETTINGS_SETUP_SOL_APP_ACTION == "open Applications →")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_APP_LABEL == "journal app")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_APP_READY == "installed")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_APP_NEEDS_ATTENTION == "not installed")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_APP_ACTION == "open journal settings →")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_LINK_LABEL == "your journal")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_LINK_READY == "linked")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_LINK_NEEDS_ATTENTION == "not linked")
        #expect(UICopy.SETTINGS_SETUP_JOURNAL_LINK_ACTION == "connect your journal →")
        #expect(UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_LABEL == "command line tools")
        #expect(UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_READY == "installed in ~/.local/bin")
        #expect(UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_NEEDS_ATTENTION == "not installed yet")
        #expect(UICopy.SETTINGS_SETUP_COMMAND_LINE_TOOLS_ACTION == "open journal settings →")
        #expect(UICopy.SETTINGS_SETUP_SCREEN_RECORDING_LABEL == "screen recording")
        #expect(UICopy.SETTINGS_SETUP_SCREEN_RECORDING_ACTION == "grant access →")
        #expect(UICopy.SETTINGS_SETUP_MICROPHONE_LABEL == "microphone")
        #expect(UICopy.SETTINGS_SETUP_MICROPHONE_ACTION == "grant access →")
        #expect(UICopy.SETTINGS_SETUP_LAST_SYNC_LABEL == "last sync")
        #expect(UICopy.SETTINGS_SETUP_LAST_SYNC_NEVER == "no sync yet")
        #expect(UICopy.SETTINGS_SETUP_LAST_SYNC_NOT_LINKED == "your journal isn't linked")
    }

    @Test func settingsSetupSharedAndPermissionPaneCopyStrings() {
        #expect(UICopy.SETTINGS_SETUP_SHARED_NOT_REQUIRED == "not needed on this Mac")
        #expect(UICopy.SETTINGS_SETUP_SHARED_COULD_NOT_CHECK == "couldn't check")
        #expect(UICopy.SETTINGS_SETUP_SHARED_GRANTED == "granted")
        #expect(UICopy.SETTINGS_SETUP_SHARED_NOT_GRANTED == "not granted")
        #expect(UICopy.SETTINGS_SETUP_SHARED_CHECKING == "checking")
        #expect(UICopy.SETTINGS_PERMISSIONS_SCREEN_RECORDING_RESET_HINT == "if sol is already in Applications but doesn't appear in Screen & System Audio Recording, remove any old sol entry and try enabling screen recording again.")
        #expect(UICopy.SETTINGS_PERMISSIONS_MIC_DENIED == "microphone access is off. allow sol in Privacy & Security → Microphone.")
        #expect(UICopy.SETTINGS_PERMISSIONS_MIC_RESTRICTED == "microphone access is restricted by this Mac.")
        #expect(UICopy.SETTINGS_PERMISSIONS_OPEN_SYSTEM_SETTINGS == "open system settings →")
    }

}
