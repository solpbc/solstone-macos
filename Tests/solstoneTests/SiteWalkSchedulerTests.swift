// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("SiteWalkScheduler")
struct SiteWalkSchedulerTests {
    @Test func maxBudgetIsFour() {
        var cursor = 0
        let pending = (1...10).map { SiteDecisionKey(windowID: CGWindowID($0), title: "Title \($0)") }
        let decided: [CGWindowID] = []

        let scheduled = SiteWalkScheduler.schedule(pending: pending, decided: decided, cursor: &cursor)
        #expect(scheduled.count == 4)
        #expect(scheduled == (1...4).map { .pending(pending[$0 - 1]) })
    }

    @Test func alternatesPendingAndSweep() {
        var cursor = 0
        let pending = [
            SiteDecisionKey(windowID: 100, title: "P1"),
            SiteDecisionKey(windowID: 101, title: "P2")
        ]
        let decided: [CGWindowID] = [1, 2, 3, 4]

        let scheduled = SiteWalkScheduler.schedule(pending: pending, decided: decided, cursor: &cursor)
        #expect(scheduled.count == 4)
        #expect(scheduled[0] == .pending(pending[0]))
        #expect(scheduled[1] == .sweep(1))
        #expect(scheduled[2] == .pending(pending[1]))
        #expect(scheduled[3] == .sweep(2))
        #expect(cursor == 2)
    }

    @Test func sweepsAllTenDecidedWindowsWithPersistentCursor() {
        var cursor = 0
        let decided: [CGWindowID] = Array(1...10).map { CGWindowID($0) }
        var allSwept = Set<CGWindowID>()

        // 5 ticks of pending taking 2 slots (P, S, P, S) -> 2 sweeps per tick -> 10 sweeps total
        for tick in 0..<5 {
            let pending = [
                SiteDecisionKey(windowID: CGWindowID(100 + tick * 2), title: "Pending A"),
                SiteDecisionKey(windowID: CGWindowID(101 + tick * 2), title: "Pending B")
            ]
            let scheduled = SiteWalkScheduler.schedule(pending: pending, decided: decided, cursor: &cursor)
            #expect(scheduled.count == 4)
            for item in scheduled {
                if case .sweep(let wid) = item {
                    allSwept.insert(wid)
                }
            }
        }

        #expect(allSwept.count == 10)
        #expect(allSwept == Set(decided))
    }

    @Test func fallbackToAvailableKindWhenOtherQueueEmpty() {
        var cursor = 0
        let pending = [SiteDecisionKey(windowID: 1, title: "Only One")]
        let decided: [CGWindowID] = [10, 20, 30, 40]

        // 1 pending, 4 decided -> P, S, S, S
        let scheduled = SiteWalkScheduler.schedule(pending: pending, decided: decided, cursor: &cursor)
        #expect(scheduled.count == 4)
        #expect(scheduled[0] == .pending(pending[0]))
        #expect(scheduled[1] == .sweep(10))
        #expect(scheduled[2] == .sweep(20))
        #expect(scheduled[3] == .sweep(30))
    }
}
