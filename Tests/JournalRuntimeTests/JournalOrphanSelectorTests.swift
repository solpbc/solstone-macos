// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
@testable import JournalRuntime

@Suite("JournalOrphanSelector")
struct JournalOrphanSelectorTests {
    @Test func protectsLaunchdManagedPIDAndSelectsUnownedSameRootOrphan() {
        let root = URL(fileURLWithPath: "/Users/jer/journal", isDirectory: true)
        let rows = [
            JournalProcessRow(pid: 111, ppid: 1, uid: 501, command: "journal: start"),
            JournalProcessRow(pid: 222, ppid: 1, uid: 501, command: "journal: start")
        ]

        let selection = selectJournalOrphans(
            from: rows,
            rowCount: rows.count,
            journalRoot: root,
            protectedLaunchdPIDs: [111],
            excludedPIDs: [],
            environmentReader: { pid in
                pid == 111 || pid == 222 ? ["SOLSTONE_JOURNAL": "/Users/jer/journal"] : nil
            },
            currentUID: 501
        )

        #expect(selection.selected == [222])
        #expect(selection.protected == [111])
        #expect(selection.ambiguous.isEmpty)
    }

    @Test func unreadableOrMissingEnvironmentIsAmbiguousNeverSelected() {
        let root = URL(fileURLWithPath: "/Users/jer/journal", isDirectory: true)
        let rows = [
            JournalProcessRow(pid: 111, ppid: 1, uid: 501, command: "journal: start"),
            JournalProcessRow(pid: 222, ppid: 1, uid: 501, command: "journal: start"),
            JournalProcessRow(pid: 333, ppid: 1, uid: 501, command: "/bin/sleep 30")
        ]

        let selection = selectJournalOrphans(
            from: rows,
            rowCount: rows.count,
            journalRoot: root,
            protectedLaunchdPIDs: [],
            excludedPIDs: [],
            environmentReader: { pid in
                switch pid {
                case 111:
                    return nil
                case 222:
                    return [:]
                default:
                    return ["SOLSTONE_JOURNAL": "/Users/jer/journal"]
                }
            },
            currentUID: 501
        )

        #expect(selection.selected.isEmpty)
        #expect(selection.protected.isEmpty)
        #expect(selection.ambiguous == [111, 222])
    }

    @Test func differentRootAndCurrentChildAreProtected() {
        let root = URL(fileURLWithPath: "/Users/jer/journal", isDirectory: true)
        let rows = [
            JournalProcessRow(pid: 111, ppid: 1, uid: 501, command: "journal: start"),
            JournalProcessRow(pid: 222, ppid: 1, uid: 501, command: "journal: start")
        ]

        let selection = selectJournalOrphans(
            from: rows,
            rowCount: rows.count,
            journalRoot: root,
            protectedLaunchdPIDs: [],
            excludedPIDs: [222],
            environmentReader: { pid in
                pid == 111 ? ["SOLSTONE_JOURNAL": "/Users/jer/other-journal"] : ["SOLSTONE_JOURNAL": "/Users/jer/journal"]
            },
            currentUID: 501
        )

        #expect(selection.selected.isEmpty)
        #expect(selection.protected == [111, 222])
        #expect(selection.ambiguous.isEmpty)
    }
}
