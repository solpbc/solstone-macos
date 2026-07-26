// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import journal

@Suite("JournalFirstRunCopy")
struct JournalFirstRunCopyTests {
    @Test func constantsMatchPinnedCopy() {
        #expect(JournalFirstRunCopy.nameLocationTitle == "let's create your journal on this mac")
        #expect(JournalFirstRunCopy.markRevealSubtitle == "this is your journal's mark. your journal is always private, only yours.")
        #expect(JournalFirstRunCopy.lockButton == "lock it in")
        #expect(JournalFirstRunCopy.tryAnotherButton == "try another")
        #expect(JournalFirstRunCopy.tryAnotherLoading == "trying…")
        #expect(JournalFirstRunCopy.markRevealExplainer == "lock it in and this mark is your journal's, for good. it can't be changed later. try as many as you like first.")
        #expect(JournalFirstRunCopy.adoptLandingLine == "nothing moved. your journal was always here. now it has a name.")
        #expect(JournalFirstRunCopy.markTitle == "your journal mark")
        #expect(JournalFirstRunCopy.nameField == "name")
        #expect(JournalFirstRunCopy.locationField == "location")
        #expect(JournalFirstRunCopy.chooseLocation == "choose")
        #expect(JournalFirstRunCopy.continueButton == "continue")
        #expect(JournalFirstRunCopy.setupTitle == "setting up your journal")
        #expect(JournalFirstRunCopy.setupSubtitle == "this can take a minute.")
        #expect(JournalFirstRunCopy.finishingTitle == "finishing")
        #expect(JournalFirstRunCopy.finishingLoading == "finishing…")
        #expect(JournalFirstRunCopy.finishedWithNotes == "finished with notes")
        #expect(JournalFirstRunCopy.nameCanBeSavedLater == "name can be saved later.")
        #expect(JournalFirstRunCopy.adoptTitle == "journal found")
        #expect(JournalFirstRunCopy.adoptOpening == "opening this journal")
        #expect(JournalFirstRunCopy.adoptFailed == "couldn't open this journal")
        #expect(JournalFirstRunCopy.tryAgain == "try again")
    }

    @Test func firstRunCopyAvoidsForbiddenTokensAndStartsLowercase() {
        let forbidden = [
            "observer", "observers", "client", "clients", "watch", "capture",
            "record", "monitor", "track", "collect", "install", "service", "host", "wizard",
        ]

        for copy in JournalFirstRunCopy.all {
            if let first = copy.unicodeScalars.first {
                #expect(CharacterSet.lowercaseLetters.contains(first))
            } else {
                Issue.record("expected non-empty copy")
            }
            let words = Set(copy.lowercased().split { !$0.isLetter }.map(String.init))
            for token in forbidden {
                #expect(!words.contains(token))
            }
        }
    }
}
