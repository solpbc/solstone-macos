// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import journal

@Suite("JournalFirstRunCopy")
struct JournalFirstRunCopyTests {
    @Test func constantsMatchPinnedCopy() {
        #expect(JournalFirstRunCopy.nameLocationTitle == "let's create your journal on this mac")
        #expect(JournalFirstRunCopy.adoptLandingLine == "nothing moved. your journal was always here. you know it by its mark.")
        #expect(JournalFirstRunCopy.locationField == "location")
        #expect(JournalFirstRunCopy.chooseLocation == "choose")
        #expect(JournalFirstRunCopy.continueButton == "continue")
        #expect(JournalFirstRunCopy.setupTitle == "setting up your journal")
        #expect(JournalFirstRunCopy.setupSubtitle == "this can take a minute.")
        #expect(JournalFirstRunCopy.finishInBrowserTitle == "finish in your browser")
        #expect(JournalFirstRunCopy.finishInBrowserLine == "the last few steps for your journal are open in your browser. this window moves on by itself when you're done.")
        #expect(JournalFirstRunCopy.reopenInBrowserButton == "open it again")
        #expect(JournalFirstRunCopy.adoptTitle == "journal found")
        #expect(JournalFirstRunCopy.adoptOpening == "opening this journal")
        #expect(JournalFirstRunCopy.adoptFailed == "couldn't open this journal")
        #expect(JournalFirstRunCopy.tryAgain == "try again")
    }

    @Test func firstRunCopyIsNonEmpty() {
        for copy in JournalFirstRunCopy.all {
            #expect(!copy.isEmpty)
        }
    }
}
