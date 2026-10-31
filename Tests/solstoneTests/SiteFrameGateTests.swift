// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import Testing
@testable import solstone

@Suite("SiteFrameGate")
@MainActor
struct SiteFrameGateTests {
    private let displayID: CGDirectDisplayID = 1

    private func makeTicks(fromSeconds sec: TimeInterval) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanos = sec * 1_000_000_000.0
        return UInt64((nanos * Double(info.denom)) / Double(info.numer))
    }

    @Test func ordinaryBracketsReleasePreservesCaptureOrder() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        // Polls: 9.8 - 9.9, 10.1 - 10.2, 10.5 - 10.6, 10.8 - 10.9, 11.1 - 11.2, 11.4 - 11.5, 11.6 - 11.7
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 10.8, end: 10.9, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 11.1, end: 11.2, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 11.4, end: 11.5, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 11.6, end: 11.7, windows: [SitePollWindow(windowID: 1, title: "Page")]))

        var decisions = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Page")
        decisions.evaluate(
            key: key,
            initialAXTitle: "Page",
            finalAXTitle: "Page",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame1 = SiteHeldFrame(id: 101, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        let frame2 = SiteHeldFrame(id: 102, displayTicks: makeTicks(fromSeconds: 111.0), c: 11.0, originTicks: originTicks)

        _ = gate.enqueue(displayID: displayID, frame: frame1)
        _ = gate.enqueue(displayID: displayID, frame: frame2)
        #expect(gate.heldCount == 2)

        let actions = gate.evaluate(displayID: displayID, now: 12.0)
        #expect(actions.count == 2)
        if case .release(let id1, let pts1) = actions[0], case .release(let id2, let pts2) = actions[1] {
            #expect(id1 == 101)
            #expect(id2 == 102)
            #expect(pts2 > pts1)
        } else {
            Issue.record("Expected both frames to be released in order")
        }
        #expect(gate.heldCount == 0)
    }

    @Test func pollGapDropsGapReason() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        // Gap between 9.9 and 10.5 is 0.6 s > 0.3 s max gap
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Page")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Page")]))

        var decisions = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Page")
        decisions.evaluate(
            key: key,
            initialAXTitle: "Page",
            finalAXTitle: "Page",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .gap)])
        #expect(gate.heldCount == 0)
    }

    @Test func coveredInIntermediateOrLaterPollDropsCov() {
        let originTicks = makeTicks(fromSeconds: 100.0)

        // Case A: Covered in intermediate poll
        do {
            let gate = SiteFrameGate()
            gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))
            gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 2, title: "Covered")]))
            gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))

            var decisions = SiteDecision()
            decisions.evaluate(
                key: SiteDecisionKey(windowID: 1, title: "Ordinary"),
                initialAXTitle: "Ordinary",
                finalAXTitle: "Ordinary",
                walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
                sites: ["bank.com"],
                now: 10.0,
                isSweep: false
            )
            decisions.evaluate(
                key: SiteDecisionKey(windowID: 2, title: "Covered"),
                initialAXTitle: "Covered",
                finalAXTitle: "Covered",
                walk: WebAreaWalkResult(urls: ["https://login.bank.com"], completeness: .complete),
                sites: ["bank.com"],
                now: 10.0,
                isSweep: false
            )
            gate.updateDecisions(decisions, axAvailable: true)

            let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
            _ = gate.enqueue(displayID: displayID, frame: frame)
            let actions = gate.evaluate(displayID: displayID, now: 11.0)
            #expect(actions == [.drop(id: 1, reason: .cov)])
        }

        // Case B: Covered only in later poll
        do {
            let gate = SiteFrameGate()
            gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))
            gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "Ordinary")]))
            gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 2, title: "Covered")]))

            var decisions = SiteDecision()
            decisions.evaluate(
                key: SiteDecisionKey(windowID: 1, title: "Ordinary"),
                initialAXTitle: "Ordinary",
                finalAXTitle: "Ordinary",
                walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
                sites: ["bank.com"],
                now: 10.0,
                isSweep: false
            )
            decisions.evaluate(
                key: SiteDecisionKey(windowID: 2, title: "Covered"),
                initialAXTitle: "Covered",
                finalAXTitle: "Covered",
                walk: WebAreaWalkResult(urls: ["https://login.bank.com"], completeness: .complete),
                sites: ["bank.com"],
                now: 10.0,
                isSweep: false
            )
            gate.updateDecisions(decisions, axAvailable: true)

            let frame = SiteHeldFrame(id: 2, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
            _ = gate.enqueue(displayID: displayID, frame: frame)
            let actions = gate.evaluate(displayID: displayID, now: 11.0)
            #expect(actions == [.drop(id: 2, reason: .cov)])
        }
    }

    @Test func pendingWithinHoldWaitsThenDropsAfterTwoSeconds() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Pending")]))

        // No decision -> pending
        gate.updateDecisions(SiteDecision(), axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Inside hold (now - c = 1.0 < 2.0) -> no action, still held
        let actionsEarly = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actionsEarly.isEmpty)
        #expect(gate.heldCount == 1)

        // At hold limit (now - c = 2.0 >= 2.0) -> drop .hold
        let actionsLate = gate.evaluate(displayID: displayID, now: 12.0)
        #expect(actionsLate == [.drop(id: 1, reason: .hold)])
        #expect(gate.heldCount == 0)
    }

    @Test func pendingWindowDisappearingBetweenPollsDropsHold() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        // Earlier poll had window 1 (pending), later poll only has window 2 (ordinary)
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 2, title: "Ordinary")]))

        var decisions = SiteDecision()
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 2, title: "Ordinary"),
            initialAXTitle: "Ordinary",
            finalAXTitle: "Ordinary",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Even though now - c < 2.0, disappeared pending window drops .hold immediately
        let actions = gate.evaluate(displayID: displayID, now: 10.7)
        #expect(actions == [.drop(id: 1, reason: .hold)])
        #expect(gate.heldCount == 0)
    }

    @Test func fifthFrameDropsOldestAsStallCapacityNeverExceedsFour() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        for i in 1...4 {
            let actions = gate.enqueue(
                displayID: displayID,
                frame: SiteHeldFrame(id: UInt64(i), displayTicks: makeTicks(fromSeconds: 100.0 + Double(i)), c: 10.0 + Double(i), originTicks: originTicks)
            )
            #expect(actions.isEmpty)
            #expect(gate.heldCount == i)
        }

        // 5th frame drops frame 1 with .stall
        let actions5 = gate.enqueue(
            displayID: displayID,
            frame: SiteHeldFrame(id: 5, displayTicks: makeTicks(fromSeconds: 105.0), c: 15.0, originTicks: originTicks)
        )
        #expect(actions5 == [.drop(id: 1, reason: .stall)])
        #expect(gate.heldCount == 4)
    }

    @Test func nilDisplayTimeDropsTime() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        let frame = SiteHeldFrame(id: 99, displayTicks: nil, c: nil, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 10.0)
        #expect(actions == [.drop(id: 99, reason: .time)])
        #expect(gate.heldCount == 0)
    }

    @Test func accessibilityUnavailableWithEmptyWindowListReleases() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        // AX unavailable with no Safari windows -> release
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: []))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: []))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: []))
        gate.updateDecisions(SiteDecision(), axAvailable: false)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions.count == 1)
        if case .release(let id, _) = actions[0] {
            #expect(id == 1)
        } else {
            Issue.record("Expected release when AX unavailable and window list is empty")
        }

        // AX unavailable with a Safari window -> nothing released (held, then drops .hold)
        gate.addPoll(SitePollSnapshot(start: 11.8, end: 11.9, windows: [SitePollWindow(windowID: 1, title: "Safari Window")]))
        gate.addPoll(SitePollSnapshot(start: 12.1, end: 12.2, windows: [SitePollWindow(windowID: 1, title: "Safari Window")]))
        gate.addPoll(SitePollSnapshot(start: 12.5, end: 12.6, windows: []))

        let frame2 = SiteHeldFrame(id: 2, displayTicks: makeTicks(fromSeconds: 120.0), c: 12.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame2)

        let actionsEarly = gate.evaluate(displayID: displayID, now: 12.7)
        #expect(actionsEarly.isEmpty)

        let actionsLate = gate.evaluate(displayID: displayID, now: 14.1)
        #expect(actionsLate == [.drop(id: 2, reason: .hold)])
    }

    @Test func drainDropsHeldFramesAsEnd() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        let frame = SiteHeldFrame(id: 42, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)
        #expect(gate.heldCount == 1)

        let actions = gate.drain(displayID: displayID, now: 10.5)
        #expect(actions == [.drop(id: 42, reason: .end)])
        #expect(gate.heldCount == 0)
    }

    @Test func deactivateAllDropsHeldFramesWithoutReleasing() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        _ = gate.enqueue(displayID: 1, frame: SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks))
        _ = gate.enqueue(displayID: 2, frame: SiteHeldFrame(id: 2, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks))
        #expect(gate.heldCount == 2)

        let actions = gate.deactivateAll()
        #expect(actions.count == 2)
        #expect(actions.contains(.drop(id: 1, reason: .end)))
        #expect(actions.contains(.drop(id: 2, reason: .end)))
        #expect(gate.heldCount == 0)
    }

    @Test func ptsStrictlyIncreasingAcrossDeactivateAndCloseToDateElapsed() {
        let gate = SiteFrameGate()
        let originDate = Date()
        let originTicks = mach_absolute_time()

        let tickOffset1 = makeTicks(fromSeconds: 1.0)
        let pts1 = gate.makeClampedPTS(displayID: displayID, displayTicks: originTicks + tickOffset1, originTicks: originTicks)
        #expect(pts1.timescale == 600)

        _ = gate.deactivate(displayID: displayID)

        let tickOffset2 = makeTicks(fromSeconds: 2.0)
        let pts2 = gate.makeClampedPTS(displayID: displayID, displayTicks: originTicks + tickOffset2, originTicks: originTicks)
        #expect(pts2.timescale == 600)
        #expect(pts2 > pts1)

        // Compare pts seconds against HostClock conversion of ticks and Date elapsed
        let elapsedReal = HostClock.seconds(ticks: tickOffset2)
        #expect(abs(pts2.seconds - elapsedReal) < 0.050)
        let dateElapsed = Date().timeIntervalSince(originDate)
        #expect(dateElapsed >= 0)
    }

    @Test func churnReleasesUncoveredFramesWithoutDrops() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)
        var decisions = SiteDecision()

        // 5 seconds of polls spaced 0.25 s
        // Title changes every 1 s: "T0" for [0, 1), "T1" for [1, 2), "T2" for [2, 3), etc.
        for tick in 0..<20 {
            let t = Double(tick) * 0.25
            let titleIdx = Int(t)
            let title = "T\(titleIdx)"
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.05, windows: [SitePollWindow(windowID: 1, title: title)]))
        }

        // Decisions arrive: for each title Tk, ordinary decision recorded at k + 1.0
        for k in 0..<5 {
            decisions.evaluate(
                key: SiteDecisionKey(windowID: 1, title: "T\(k)"),
                initialAXTitle: "T\(k)",
                finalAXTitle: "T\(k)",
                walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
                sites: ["bank.com"],
                now: Double(k) + 1.0,
                isSweep: false
            )
        }
        gate.updateDecisions(decisions, axAvailable: true)

        // Enqueue 4 frames at c = 0.2, 1.2, 2.2, 3.2
        for i in 0..<4 {
            let c = Double(i) + 0.2
            _ = gate.enqueue(
                displayID: displayID,
                frame: SiteHeldFrame(id: UInt64(i + 1), displayTicks: makeTicks(fromSeconds: 100.0 + c), c: c, originTicks: originTicks)
            )
        }

        let actions = gate.evaluate(displayID: displayID, now: 5.0)
        #expect(actions.count == 4)
        for action in actions {
            guard case .release = action else {
                Issue.record("Expected release under churn, got \(action)")
                return
            }
        }
        #expect(gate.heldCount == 0)
        #expect(gate.holdDropCount == 0)
        #expect(gate.covCount == 0)
        #expect(gate.gapCount == 0)
    }

    @Test func storedDecisionForOldTitleReleasesFrameAfterNewTitleRecorded() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)

        // Frame at c = 10.0 saw "TitleOld"
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "TitleOld")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "TitleOld")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "TitleOld")]))

        var decisions = SiteDecision()
        // Record TitleOld at 10.0
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "TitleOld"),
            initialAXTitle: "TitleOld",
            finalAXTitle: "TitleOld",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )

        // At 11.0, record TitleNew
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "TitleNew"),
            initialAXTitle: "TitleNew",
            finalAXTitle: "TitleNew",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 11.0,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.5)
        #expect(actions.count == 1)
        if case .release(let id, _) = actions[0] {
            #expect(id == 1)
        } else {
            Issue.record("Expected frame to release for TitleOld")
        }
    }

    @Test func bracketPollsWithIntermediateCoveredTitleOnSameWindowDropsFrame() {
        let gate = SiteFrameGate()
        let originTicks = makeTicks(fromSeconds: 100.0)
        var decisions = SiteDecision()

        // Bracket polls for window 1: title A, then C, then B
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 10.0, windows: [SitePollWindow(windowID: 1, title: "TitleA")]))
        gate.addPoll(SitePollSnapshot(start: 10.2, end: 10.3, windows: [SitePollWindow(windowID: 1, title: "TitleC")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "TitleB")]))

        // A and B are ordinary, C is covered
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "TitleA"),
            initialAXTitle: "TitleA",
            finalAXTitle: "TitleA",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "TitleC"),
            initialAXTitle: "TitleC",
            finalAXTitle: "TitleC",
            walk: WebAreaWalkResult(urls: ["https://bank.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.3,
            isSweep: false
        )
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "TitleB"),
            initialAXTitle: "TitleB",
            finalAXTitle: "TitleB",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.6,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .cov)])
    }
}
