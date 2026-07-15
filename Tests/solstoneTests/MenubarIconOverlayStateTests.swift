// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("Menubar Icon Overlay State")
struct MenubarIconOverlayStateTests {
    @Test func overlayStatePrecedenceTableIsExhaustive() {
        let bools = [false, true]
        var checked = 0

        for rowState in MenubarStatusRowState.allCases {
            for solChatStale in bools {
                for solChatPending in bools {
                    let actual = menubarIconOverlayState(
                        rowState: rowState,
                        solChatStale: solChatStale,
                        solChatPending: solChatPending
                    )
                    let expected: MenubarIconOverlayState

                    if rowState == .localOnly {
                        // this documents totality over production-unreachable `.localOnly` + sol-chat combinations, NOT a live precedence decision.
                        expected = .journalSetup
                    } else if solChatStale {
                        expected = .chatStale
                    } else if solChatPending {
                        expected = .chatPending
                    } else {
                        expected = .none
                    }

                    #expect(actual == expected)
                    checked += 1
                }
            }
        }

        #expect(checked == MenubarStatusRowState.allCases.count * bools.count * bools.count)
    }

    @Test func axTokensMatchContractVocabulary() {
        let cases: [(MenubarIconOverlayState, String)] = [
            (.none, "none"),
            (.journalSetup, "journal_setup"),
            (.chatStale, "chat_stale"),
            (.chatPending, "chat_pending"),
        ]

        #expect(cases.count == MenubarIconOverlayState.allCases.count)
        for (state, token) in cases {
            #expect(state.axToken == token)
        }
    }
}
