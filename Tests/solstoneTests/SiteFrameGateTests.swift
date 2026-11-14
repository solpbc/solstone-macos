// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ApplicationServices
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import os
import Testing
@testable import solstone

@Suite("SiteFrameGate")
@MainActor
struct SiteFrameGateTests {
    private let displayID: CGDirectDisplayID = 1

    nonisolated static func makeTicks(fromSeconds sec: TimeInterval) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanos = sec * 1_000_000_000.0
        return UInt64((nanos * Double(info.denom)) / Double(info.numer))
    }

    @Test func ordinaryBracketsReleasePreservesCaptureOrder() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

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

        let frame1 = SiteHeldFrame(id: 101, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        let frame2 = SiteHeldFrame(id: 102, displayTicks: Self.makeTicks(fromSeconds: 111.0), c: 11.0, originTicks: originTicks)

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
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

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

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .gap)])
        #expect(gate.heldCount == 0)
    }

    @Test func coveredInIntermediateOrLaterPollDropsCov() {
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

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

            let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
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

            let frame = SiteHeldFrame(id: 2, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
            _ = gate.enqueue(displayID: displayID, frame: frame)
            let actions = gate.evaluate(displayID: displayID, now: 11.0)
            #expect(actions == [.drop(id: 2, reason: .cov)])
        }
    }

    @Test func pendingWithinHoldWaitsThenDropsAfterTwoSeconds() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: 1, title: "Pending")]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: 1, title: "Pending")]))

        // No decision -> pending
        gate.updateDecisions(SiteDecision(), axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
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
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

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

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Even though now - c < 2.0, disappeared pending window drops .hold immediately
        let actions = gate.evaluate(displayID: displayID, now: 10.7)
        #expect(actions == [.drop(id: 1, reason: .hold)])
        #expect(gate.heldCount == 0)
    }

    @Test func fifthFrameDropsOldestAsStallCapacityNeverExceedsFour() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        for i in 1...4 {
            let actions = gate.enqueue(
                displayID: displayID,
                frame: SiteHeldFrame(id: UInt64(i), displayTicks: Self.makeTicks(fromSeconds: 100.0 + Double(i)), c: 10.0 + Double(i), originTicks: originTicks)
            )
            #expect(actions.isEmpty)
            #expect(gate.heldCount == i)
        }

        // 5th frame drops frame 1 with .stall
        let actions5 = gate.enqueue(
            displayID: displayID,
            frame: SiteHeldFrame(id: 5, displayTicks: Self.makeTicks(fromSeconds: 105.0), c: 15.0, originTicks: originTicks)
        )
        #expect(actions5 == [.drop(id: 1, reason: .stall)])
        #expect(gate.heldCount == 4)
    }

    @Test func nilDisplayTimeDropsTime() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let frame = SiteHeldFrame(id: 99, displayTicks: nil, c: nil, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 10.0)
        #expect(actions == [.drop(id: 99, reason: .time)])
        #expect(gate.heldCount == 0)
    }

    @Test func accessibilityUnavailableWithEmptyWindowListReleases() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        // AX unavailable with no Safari windows -> release
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: []))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: []))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: []))
        gate.updateDecisions(SiteDecision(), axAvailable: false)

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
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

        let frame2 = SiteHeldFrame(id: 2, displayTicks: Self.makeTicks(fromSeconds: 120.0), c: 12.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame2)

        let actionsEarly = gate.evaluate(displayID: displayID, now: 12.7)
        #expect(actionsEarly.isEmpty)

        let actionsLate = gate.evaluate(displayID: displayID, now: 14.1)
        #expect(actionsLate == [.drop(id: 2, reason: .hold)])
    }

    @Test func drainDropsHeldFramesAsEnd() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let frame = SiteHeldFrame(id: 42, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)
        #expect(gate.heldCount == 1)

        let actions = gate.drain(displayID: displayID, now: 10.5)
        #expect(actions == [.drop(id: 42, reason: .end)])
        #expect(gate.heldCount == 0)
    }

    @Test func deactivateAllDropsHeldFramesWithoutReleasing() {
        let gate = SiteFrameGate()
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        _ = gate.enqueue(displayID: 1, frame: SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks))
        _ = gate.enqueue(displayID: 2, frame: SiteHeldFrame(id: 2, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks))
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

        let tickOffset1 = Self.makeTicks(fromSeconds: 1.0)
        let pts1 = gate.makeClampedPTS(displayID: displayID, displayTicks: originTicks + tickOffset1, originTicks: originTicks)
        #expect(pts1.timescale == 600)

        _ = gate.deactivate(displayID: displayID)

        let tickOffset2 = Self.makeTicks(fromSeconds: 2.0)
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
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
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
                frame: SiteHeldFrame(id: UInt64(i + 1), displayTicks: Self.makeTicks(fromSeconds: 100.0 + c), c: c, originTicks: originTicks)
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
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

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

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
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
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
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

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .cov)])
    }

    // MARK: - Chromium Gate Integration

    @Test func chromiumPollOrdinaryReleasesFrame() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let read = ChromiumPollRead(
            verdict: .ordinary,
            cause: nil,
            host: "example.com",
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        let win = SitePollWindow(windowID: 10, title: "Example", pid: 100, chromium: read)
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [win]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [win]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [win]))

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions.count == 1)
        if case .release(let id, _) = actions.first {
            #expect(id == 1)
        } else {
            Issue.record("Expected frame to release for ordinary Chromium poll")
        }
    }

    @Test func chromiumPollCoveredDropsCov() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let read = ChromiumPollRead(
            verdict: .covered,
            cause: nil,
            host: "bank.com",
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        let win = SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: read)
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [win]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [win]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [win]))

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .cov)])
    }

    @Test func chromiumPollPendingWaitsForDeadlineBeforeDrop() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let ordinaryRead = ChromiumPollRead(
            verdict: .ordinary,
            cause: nil,
            host: "example.com",
            readStart: 9.8,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        let ordinaryWin = SitePollWindow(windowID: 10, title: "Ordinary", pid: 100, chromium: ordinaryRead)

        let pendingRead = ChromiumPollRead(
            verdict: .cantTell,
            cause: .unread,
            host: nil,
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: true
        )
        let pendingWin = SitePollWindow(windowID: 10, title: "Pending", pid: 100, chromium: pendingRead)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [ordinaryWin]))
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.1, windows: [pendingWin]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [ordinaryWin]))

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // At now = 10.2 (< 10.0 + 0.5 deadline): frame is held, no actions emitted
        let earlyActions = gate.evaluate(displayID: displayID, now: 10.2)
        #expect(earlyActions.isEmpty)
        #expect(gate.heldCount == 1)

        // At now = 10.6 (>= 10.0 + 0.5 deadline): hold expired, frame is dropped
        let lateActions = gate.evaluate(displayID: displayID, now: 10.6)
        #expect(lateActions.count == 1)
        #expect(gate.heldCount == 0)
    }

    @Test func isHoldingNowUsesLatestCompletePoll() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)

        let coveredRead = ChromiumPollRead(
            verdict: .covered,
            cause: nil,
            host: "bank.com",
            readStart: 7.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        let coveredWin = SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: coveredRead)
        gate.addPoll(SitePollSnapshot(start: 6.8, end: 6.9, windows: [coveredWin]))
        gate.addPoll(SitePollSnapshot(start: 7.1, end: 7.2, windows: [coveredWin]))
        gate.addPoll(SitePollSnapshot(start: 7.5, end: 7.6, windows: [coveredWin]))

        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 107.0), c: 7.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)
        let dropActions = gate.evaluate(displayID: displayID, now: 8.0)
        #expect(dropActions == [.drop(id: 1, reason: .cov)])

        // Latest poll has pending read
        let pendingRead = ChromiumPollRead(
            verdict: .cantTell,
            cause: .unread,
            host: nil,
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: true
        )
        let pendingWin = SitePollWindow(windowID: 10, title: "Pending", pid: 100, chromium: pendingRead)
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.1, windows: [pendingWin]))

        // isHoldingNow inspects latest complete poll (at 7.5), which is covered. Since c=7.0 and now=10.2 (diff=3.2 >= 3.0), returns true.
        #expect(gate.isHoldingNow(now: 10.2) == true)
    }

    // MARK: - Chromium Sit-Out Timing Rules

    @Test func chromiumSitOutOneMissThenOrdinaryNeverSitsOut() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)

        // Poll at 0.0 with 1 unread miss
        let missRead = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: 0.0, listGeneration: 1, browser: .chrome, isPending: false)
        let missWin = SitePollWindow(windowID: 10, title: "Unread", pid: 100, chromium: missRead)
        gate.addPoll(SitePollSnapshot(start: 0.0, end: 0.1, windows: [missWin]))
        #expect(!gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 0.1))

        // Followed by 5 s of unbroken ordinary polls (every 0.5 s from 0.5 to 5.5)
        for i in 1...11 {
            let t = Double(i) * 0.5
            let ordRead = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            let ordWin = SitePollWindow(windowID: 10, title: "Ord", pid: 100, chromium: ordRead)
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.1, windows: [ordWin]))
            #expect(!gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: t + 0.1))
        }
    }

    @Test func chromiumSitOutTornEveryTwoSecondsNeverSitsOut() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)

        // For 10 seconds: poll every 0.5 s. At 0.0, 2.0, 4.0, 6.0, 8.0, 10.0 it is torn (unclear).
        // Otherwise it is ordinary.
        for tick in 0...20 {
            let t = Double(tick) * 0.5
            let isTorn = (tick % 4 == 0) // every 2.0 s
            let read: ChromiumPollRead
            if isTorn {
                read = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            } else {
                read = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            }
            let win = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: read)
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.1, windows: [win]))
            #expect(!gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: t + 0.1))
        }
    }

    @Test func chromiumSitOutEverySecondPollMissedSitsOutWithinThreeSeconds() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let initialRead = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: -0.2, listGeneration: 1, browser: .chrome, isPending: false)
        let initialWin = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: initialRead)
        gate.addPoll(SitePollSnapshot(start: -0.2, end: 0.0, windows: [initialWin]))

        // Enqueue a frame at c = 0.0
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 0.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        var satOut = false
        var isHolding = false

        for tick in 0...20 {
            let t = Double(tick) * 0.5
            let isMissed = (tick % 2 == 0)
            let read: ChromiumPollRead
            if isMissed {
                read = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            } else {
                read = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            }
            let win = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: read)
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.1, windows: [win]))

            _ = gate.evaluate(displayID: displayID, now: t + 0.1)

            let out = gate.chromiumShouldSitOut(for: .chrome, isOutNow: satOut, now: t + 0.1)
            if out {
                satOut = true
            }
            if gate.isHoldingNow(now: t + 0.1) {
                isHolding = true
            }
        }
        #expect(satOut == true)
        #expect(isHolding == true)
    }

    @Test func chromiumSitOutEverySixthPollMissedSitsOutWithinSixSeconds() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)

        var satOutTime: TimeInterval?

        for tick in 0...30 {
            let t = Double(tick) * 0.5
            let isMissed = (tick % 6 == 0)
            let read: ChromiumPollRead
            if isMissed {
                read = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            } else {
                read = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: t, listGeneration: 1, browser: .chrome, isPending: false)
            }
            let win = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: read)
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.1, windows: [win]))

            let out = gate.chromiumShouldSitOut(for: .chrome, isOutNow: satOutTime != nil, now: t + 0.1)
            if out && satOutTime == nil {
                satOutTime = t
            }
        }
        #expect(satOutTime != nil)
        #expect(satOutTime! <= 6.0)
    }

    @Test func chromeCoveredTakesOnlyChromeOutAndFrameVouchedOnlyForChromeDropsCoveredSafari() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        let chromePID: pid_t = 100
        let safariPID: pid_t = 200

        // 1. Chrome covered, Safari ordinary
        let chromeCov = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 10.0, listGeneration: 1, browser: .chrome, isPending: false)
        let chromeWin = SitePollWindow(windowID: 10, title: "Bank", pid: chromePID, chromium: chromeCov)
        let safariWin = SitePollWindow(windowID: 20, title: "Example", pid: safariPID)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [chromeWin, safariWin]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [chromeWin, safariWin]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [chromeWin, safariWin]))

        var safariDecisions = SiteDecision()
        safariDecisions.evaluate(
            key: SiteDecisionKey(windowID: 20, title: "Example"),
            initialAXTitle: "Example",
            finalAXTitle: "Example",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(safariDecisions, axAvailable: true)

        // Chrome should sit out, Safari should NOT sit out
        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 10.6) == true)
        #expect(gate.safariShouldSitOut(isOutNow: false) == false)

        // 2. Both out together, each clears alone
        var safariCoveredDecisions = SiteDecision()
        safariCoveredDecisions.evaluate(
            key: SiteDecisionKey(windowID: 20, title: "Example"),
            initialAXTitle: "Example",
            finalAXTitle: "Example",
            walk: WebAreaWalkResult(urls: ["https://bank.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(safariCoveredDecisions, axAvailable: true)

        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: true, now: 10.6) == true)
        #expect(gate.safariShouldSitOut(isOutNow: false) == true)

        // Chrome clears alone when ordinary
        let chromeOrd = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 11.0, listGeneration: 1, browser: .chrome, isPending: false)
        let chromeOrdWin = SitePollWindow(windowID: 10, title: "Example", pid: chromePID, chromium: chromeOrd)
        gate.addPoll(SitePollSnapshot(start: 11.0, end: 11.1, windows: [chromeOrdWin, safariWin]))

        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: true, now: 11.1) == false)
        #expect(gate.safariShouldSitOut(isOutNow: true) == true)

        // 3. A frame vouched only for Chrome (keptOutPIDs: [chromePID]), with a covered Safari window in its polls, is dropped!
        let frameVouchedOnlyForChrome = SiteHeldFrame(
            id: 1,
            displayTicks: originTicks,
            c: 10.0,
            originTicks: originTicks,
            keptOutPIDs: [chromePID] // vouched only for Chrome
        )
        _ = gate.enqueue(displayID: displayID, frame: frameVouchedOnlyForChrome)
        let actions = gate.evaluate(displayID: displayID, now: 12.0)
        #expect(actions == [.drop(id: 1, reason: .cov)])
    }

    @Test func mixedCaseBundleIDsWholeAppPIDs() {
        var planner = ExclusionPlanner()
        let manager = WindowExclusionManager(excludedAppNames: [], excludePrivateBrowsing: false, excludedTitlePatterns: [])
        manager.setSiteRule(active: true, keptOutBrowsers: [.chrome, .brave])

        let chromePID: pid_t = 501
        let bravePID: pid_t = 502

        let apps = [
            ExclusionApp(pid: chromePID, name: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            ExclusionApp(pid: bravePID, name: "Brave Browser", bundleIdentifier: "com.brave.Browser")
        ]
        let windows = [
            ExclusionWindow(id: 1, pid: chromePID, ownerName: "Google Chrome", title: "Chrome Window", layer: 0),
            ExclusionWindow(id: 2, pid: bravePID, ownerName: "Brave Browser", title: "Brave Window", layer: 0)
        ]

        let plan = planner.plan(windows: windows, apps: apps, settings: manager.plannedSettings, accessibilityTitles: [:], now: Date())
        #expect(plan.wholeAppPIDs.contains(chromePID))
        #expect(plan.wholeAppPIDs.contains(bravePID))
    }

    @Test func hungSeamPerformPollReturnsAndFrameReleases() async {
        let hangBlocker = DispatchSemaphore(value: 0)
        defer { hangBlocker.signal() }

        struct HungReader: ChromiumWindowReading, @unchecked Sendable {
            let hangBlocker: DispatchSemaphore
            func copyWindows(for pid: pid_t) -> [AXUIElement]? {
                _ = hangBlocker.wait(timeout: .now() + 10)
                return nil
            }
            func focusedWindow(for pid: pid_t) -> AXUIElement? { nil }
            func windowID(for window: AXUIElement) -> CGWindowID? { nil }
            func readTitle(for window: AXUIElement) -> String? {
                _ = hangBlocker.wait(timeout: .now() + 10)
                return nil
            }
            func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) { (nil, false) }
            func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome { .failed }
            func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) { ([], .failed) }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 10, pid: 100, layer: 0, title: "Chrome Page")]
        }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: 10.0) }
        hooks.chromiumReader = HungReader(hangBlocker: hangBlocker)

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in }
        )

        // The poll returns without waiting on the read queue
        await sampler.performPollForTesting()

        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        // Frame has no Chrome windows in its polls (only ordinary Safari)
        let safariWin = SitePollWindow(windowID: 20, title: "Example", pid: 200)
        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [safariWin]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [safariWin]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [safariWin]))

        var decisions = SiteDecision()
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 20, title: "Example"),
            initialAXTitle: "Example",
            finalAXTitle: "Example",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let frame = SiteHeldFrame(id: 1, displayTicks: Self.makeTicks(fromSeconds: 110.0), c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Frame with no Chrome window releases without waiting for any Chrome seam
        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions.count == 1)
        if case .release(let id, _) = actions.first {
            #expect(id == 1)
        } else {
            Issue.record("Expected frame to release")
        }
    }

    @Test func splitViewRaisesNoCautionAndSuspensionClearsEveryBrowser() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)

        // Sustained split view raises no caution
        for _ in 1...10 {
            let chk = ChromiumSiteRead.checkTitles(
                cgTitle: "Page",
                axTitle: "Page - Split view - Google Chrome",
                browser: .chrome,
                tabButtonCount: 1
            )
            #expect(chk == .inserted)
        }
        #expect(capture.siteChromeCaution == false)

        // Covered Chrome takes Chrome out
        let chromeCov = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 10.0, listGeneration: 1, browser: .chrome, isPending: false)
        let chromeWin = SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: chromeCov)
        capture.receiveSitePoll(SitePollSnapshot(start: 10.0, end: 10.1, windows: [chromeWin]))
        #expect(capture.siteKeptOutBrowsers.contains(.chrome))

        // Suspend with receiveSiteDecision(..., axAvailable: false) until siteAXFailures reaches siteAXFailuresToSuspend (2)
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(capture.siteRuleActive)
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(!capture.siteRuleActive)
        #expect(capture.siteKeptOutBrowsers.isEmpty)

        // After it resumes, a covered Chrome window takes Chrome out again
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        #expect(capture.siteRuleActive)
        capture.receiveSitePoll(SitePollSnapshot(start: 11.0, end: 11.1, windows: [chromeWin]))
        #expect(capture.siteKeptOutBrowsers.contains(.chrome))
    }

    // MARK: - Chromium Frame Edge Cases (Gap Twin, Look-Back, Lag, Sliver, etc.)

    @Test func gapTwinSpacingAndEarliestReadAfterC() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)

        // Subcase 1: ordinary polls, one window's read starts 0.5 s apart around c, no release
        let winID: CGWindowID = 10
        let pid: pid_t = 100
        let ord1 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.75, listGeneration: 1, browser: .chrome, isPending: false)
        let ord2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.25, listGeneration: 1, browser: .chrome, isPending: false)
        let ord3 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.55, listGeneration: 1, browser: .chrome, isPending: false)

        gate.addPoll(SitePollSnapshot(start: 9.7, end: 9.8, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord1)]))
        gate.addPoll(SitePollSnapshot(start: 9.95, end: 10.05, windows: [])) // no poll gap; window not read in this poll
        gate.addPoll(SitePollSnapshot(start: 10.25, end: 10.35, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord2)]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord3)]))

        let frame1 = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame1)
        let actions1 = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions1 == [.drop(id: 1, reason: .gap)])

        // Subcase 2: same when earliest read starts after c and previous poll is not ordinary
        let gate2 = SiteFrameGate()
        gate2.updateDecisions(SiteDecision(), axAvailable: true)
        gate2.updateSiteList(["bank.com"], generation: 1)

        // Previous poll ending before c has no ordinary read for this window (window not present)
        gate2.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: []))
        // Window appears in poll starting after c, readStart = 10.1 > c (10.0)
        let lateOrd = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.1, listGeneration: 1, browser: .chrome, isPending: false)
        let lateOrd2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.5, listGeneration: 1, browser: .chrome, isPending: false)
        gate2.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: lateOrd)]))
        gate2.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: lateOrd2)]))

        let frame2 = SiteHeldFrame(id: 2, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate2.enqueue(displayID: displayID, frame: frame2)
        let actions2 = gate2.evaluate(displayID: displayID, now: 11.0)
        #expect(actions2 == [.drop(id: 2, reason: .gap)])
    }

    @Test func lookBackCoveredAndCantTellDrops() {
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // Subcase 1: covered in poll ending before c, then ordinary, drops
        let gate1 = SiteFrameGate()
        gate1.updateDecisions(SiteDecision(), axAvailable: true)
        gate1.updateSiteList(["bank.com"], generation: 1)

        let covPoll = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        let ordPoll1 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.15, listGeneration: 1, browser: .chrome, isPending: false)
        let ordPoll2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.55, listGeneration: 1, browser: .chrome, isPending: false)

        gate1.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: winID, title: "Bank", pid: pid, chromium: covPoll)]))
        gate1.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPoll1)]))
        gate1.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPoll2)]))

        let frame1 = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate1.enqueue(displayID: displayID, frame: frame1)
        let actions1 = gate1.evaluate(displayID: displayID, now: 11.0)
        #expect(actions1 == [.drop(id: 1, reason: .cov)])

        // Subcase 2: can't tell in poll ending before c, then ordinary, drops once bracket is complete
        let gate2 = SiteFrameGate()
        gate2.updateDecisions(SiteDecision(), axAvailable: true)
        gate2.updateSiteList(["bank.com"], generation: 1)

        let ctPoll = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        let ordPollMid = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.35, listGeneration: 1, browser: .chrome, isPending: false)
        gate2.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ctPoll)]))
        gate2.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPoll1)]))
        gate2.addPoll(SitePollSnapshot(start: 10.35, end: 10.45, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPollMid)]))

        let frame2 = SiteHeldFrame(id: 2, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate2.enqueue(displayID: displayID, frame: frame2)

        // Before bracket is complete (no poll >= c + 0.5 yet at now = 10.3), frame held
        let incompleteActions = gate2.evaluate(displayID: displayID, now: 10.3)
        #expect(incompleteActions.isEmpty)
        #expect(gate2.heldCount == 1)

        // Once bracket complete (poll >= c + 0.5 added), drops
        gate2.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPoll2)]))
        let completeActions = gate2.evaluate(displayID: displayID, now: 10.7)
        #expect(completeActions == [.drop(id: 2, reason: .hold)])
    }

    @Test func lagOrdinaryThenCoveredDrops() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // Ordinary at c + 0.005 on old host, covered at c + 0.25, drops
        let ordOld = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        let ordAtLag = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.005, listGeneration: 1, browser: .chrome, isPending: false)
        let covAtNew = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 10.25, listGeneration: 1, browser: .chrome, isPending: false)
        let covLate = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 10.5, listGeneration: 1, browser: .chrome, isPending: false)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordOld)]))
        gate.addPoll(SitePollSnapshot(start: 10.005, end: 10.015, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordAtLag)]))
        gate.addPoll(SitePollSnapshot(start: 10.25, end: 10.26, windows: [SitePollWindow(windowID: winID, title: "Bank", pid: pid, chromium: covAtNew)]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Bank", pid: pid, chromium: covLate)]))

        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .cov)])
    }

    @Test func noCacheOrdinaryBeforeCEveryLaterPollCantTellOrMissedNeverReleases() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // Ordinary before c
        let ordBefore = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        let ctLater1 = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 10.15, listGeneration: 1, browser: .chrome, isPending: false)
        let ctLaterMid = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 10.35, listGeneration: 1, browser: .chrome, isPending: false)
        let ctLater2 = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 10.55, listGeneration: 1, browser: .chrome, isPending: false)

        gate.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordBefore)]))
        gate.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ctLater1)]))
        gate.addPoll(SitePollSnapshot(start: 10.35, end: 10.45, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ctLaterMid)]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ctLater2)]))

        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        let actions = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions == [.drop(id: 1, reason: .hold)])
    }

    @Test func earliestReadSliverReleasesWhenPreviousPollOrdinaryAndDropsWhenNot() {
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // Sliver: frame c = 9.85 is between early poll end (9.8) and first subsequent read (9.95)
        // Subcase 1: previous poll is ordinary -> releases
        let gate1 = SiteFrameGate()
        gate1.updateDecisions(SiteDecision(), axAvailable: true)
        gate1.updateSiteList(["bank.com"], generation: 1)

        let ordPrev = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.75, listGeneration: 1, browser: .chrome, isPending: false)
        let ordNext = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.95, listGeneration: 1, browser: .chrome, isPending: false)
        let ordMid = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.2, listGeneration: 1, browser: .chrome, isPending: false)
        let ordLate = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.45, listGeneration: 1, browser: .chrome, isPending: false)

        gate1.addPoll(SitePollSnapshot(start: 9.7, end: 9.8, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordPrev)]))
        gate1.addPoll(SitePollSnapshot(start: 9.9, end: 10.0, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordNext)]))
        gate1.addPoll(SitePollSnapshot(start: 10.15, end: 10.25, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordMid)]))
        gate1.addPoll(SitePollSnapshot(start: 10.4, end: 10.5, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordLate)]))

        let frame1 = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 9.85, originTicks: originTicks)
        _ = gate1.enqueue(displayID: displayID, frame: frame1)
        let actions1 = gate1.evaluate(displayID: displayID, now: 10.6)
        #expect(actions1.count == 1)
        if case .release(let id, _) = actions1.first {
            #expect(id == 1)
        } else {
            Issue.record("Expected frame to release when previous poll was ordinary")
        }

        // Subcase 2: previous poll is not ordinary (cantTell) -> drops .gap via look-back
        // No can't-tell read is inside the bracket
        let gate2 = SiteFrameGate()
        gate2.updateDecisions(SiteDecision(), axAvailable: true)
        gate2.updateSiteList(["bank.com"], generation: 1)

        let ctPrev = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 9.75, listGeneration: 1, browser: .chrome, isPending: false)
        // Poll 0 (outside bracket): ctPrev at 9.75
        gate2.addPoll(SitePollSnapshot(start: 9.7, end: 9.75, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ctPrev)]))
        // Poll 1 (earlyIdx in bracket): empty windows, end 9.80 <= c (9.85)
        gate2.addPoll(SitePollSnapshot(start: 9.78, end: 9.80, windows: []))
        // Bracket polls: all ordinary
        gate2.addPoll(SitePollSnapshot(start: 9.9, end: 10.0, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordNext)]))
        gate2.addPoll(SitePollSnapshot(start: 10.15, end: 10.25, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordMid)]))
        gate2.addPoll(SitePollSnapshot(start: 10.4, end: 10.5, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordLate)]))

        let frame2 = SiteHeldFrame(id: 2, displayTicks: originTicks, c: 9.85, originTicks: originTicks)
        _ = gate2.enqueue(displayID: displayID, frame: frame2)
        let actions2 = gate2.evaluate(displayID: displayID, now: 10.6)
        #expect(actions2 == [.drop(id: 2, reason: .gap)])
    }

    @Test func lateOrdinaryIgnoredLateCoveredAppliedAndSitsBrowserOut() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // Poll starts at 10.0, initially pending
        let pendingRead = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: 10.0, listGeneration: 1, browser: .chrome, isPending: true)
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.1, windows: [SitePollWindow(windowID: winID, title: "Pending", pid: pid, chromium: pendingRead)]))

        // At now = 10.6 (>= 10.0 + 0.5), deadline missed
        let ordinaryLate = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.0, listGeneration: 1, browser: .chrome, isPending: false)
        gate.patchChromiumPoll(start: 10.0, windowID: winID, read: ordinaryLate, at: 10.7)

        // Late ordinary ignored: browser does NOT turn ordinary (counted as unread/missed)
        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 10.7) == false)
        #expect(gate.latestCompletePoll(at: 10.7)?.windows.first?.chromium?.verdict != .ordinary)

        // Late covered applied: sits that browser out
        let coveredLate = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: 10.0, listGeneration: 1, browser: .chrome, isPending: false)
        gate.patchChromiumPoll(start: 10.0, windowID: winID, read: coveredLate, at: 10.8)
        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 10.8) == true)
    }

    @Test func finalCantTellDropAndReadSpacingDropSetHeldSinceAndCallIntakeLogHold() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let log = IntakeIntervalLog()
        log.beginDisplay(String(displayID), at: 0.0)
        log.hold(display: String(displayID), at: 9.0)
        gate.intakeLog = log
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let winID: CGWindowID = 10
        let pid: pid_t = 100

        // 1. Read-spacing drop (gap > 0.3 s between reads around c = 10.0)
        let ord1 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.75, listGeneration: 1, browser: .chrome, isPending: false)
        let ord2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.25, listGeneration: 1, browser: .chrome, isPending: false)
        let ord3 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.55, listGeneration: 1, browser: .chrome, isPending: false)

        gate.addPoll(SitePollSnapshot(start: 9.7, end: 9.8, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord1)]))
        gate.addPoll(SitePollSnapshot(start: 9.95, end: 10.05, windows: [])) // no poll gap
        gate.addPoll(SitePollSnapshot(start: 10.25, end: 10.35, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord2)]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ord3)]))

        let frame1 = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame1)
        let actions1 = gate.evaluate(displayID: displayID, now: 11.0)
        #expect(actions1 == [.drop(id: 1, reason: .gap)])
        #expect(gate.heldSince[displayID] == 10.0)
        #expect(log.screenRanges()[String(displayID)]?.isEmpty == false)

        // Reset state for final can't-tell drop
        let gate2 = SiteFrameGate()
        gate2.updateDecisions(SiteDecision(), axAvailable: true)
        gate2.updateSiteList(["bank.com"], generation: 1)
        let log2 = IntakeIntervalLog()
        log2.beginDisplay(String(displayID), at: 0.0)
        gate2.intakeLog = log2

        let ct1 = ChromiumPollRead(verdict: .cantTell, cause: .unclear, host: nil, readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        let ordLater = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.15, listGeneration: 1, browser: .chrome, isPending: false)
        let ordLaterMid = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.35, listGeneration: 1, browser: .chrome, isPending: false)
        let ordLate2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.55, listGeneration: 1, browser: .chrome, isPending: false)

        gate2.addPoll(SitePollSnapshot(start: 9.8, end: 9.9, windows: [SitePollWindow(windowID: winID, title: "Unclear", pid: pid, chromium: ct1)]))
        gate2.addPoll(SitePollSnapshot(start: 10.1, end: 10.2, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordLater)]))
        gate2.addPoll(SitePollSnapshot(start: 10.35, end: 10.45, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordLaterMid)]))
        gate2.addPoll(SitePollSnapshot(start: 10.5, end: 10.6, windows: [SitePollWindow(windowID: winID, title: "Example", pid: pid, chromium: ordLate2)]))

        let frame2 = SiteHeldFrame(id: 2, displayTicks: originTicks, c: 10.0, originTicks: originTicks)
        _ = gate2.enqueue(displayID: displayID, frame: frame2)
        let actions2 = gate2.evaluate(displayID: displayID, now: 11.0)
        #expect(actions2 == [.drop(id: 2, reason: .hold)])
        #expect(gate2.heldSince[displayID] == 10.0)
        #expect(log2.screenRanges()[String(displayID)]?.isEmpty == false)
    }

    @Test func item6ChromeAndEdgeHoldClearsWhenLastRoundFinishes() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        let log = IntakeIntervalLog()
        let base = capture.siteNowSeconds()
        log.beginDisplay(String(displayID), at: 0.0)
        log.hold(display: String(displayID), at: base - 3.5)
        capture.siteFrameGate.intakeLog = log

        // A drop has held the screen for at least 3 s
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let covRead = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: base - 3.7, listGeneration: 1, browser: .chrome, isPending: false)
        capture.receiveSitePoll(SitePollSnapshot(start: base - 3.8, end: base - 3.7, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        capture.receiveSitePoll(SitePollSnapshot(start: base - 3.4, end: base - 3.3, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        capture.receiveSitePoll(SitePollSnapshot(start: base - 2.9, end: base - 2.8, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: base - 3.5, originTicks: originTicks)
        _ = capture.siteFrameGate.enqueue(displayID: displayID, frame: frame)
        _ = capture.siteFrameGate.evaluate(displayID: displayID, now: base - 2.7)
        #expect(capture.siteFrameGate.heldSince[displayID] == base - 3.5)

        // One poll dispatches Chrome and Edge
        let chromePending = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: true)
        let edgePending = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base, listGeneration: capture.siteListGeneration, browser: .edge, isPending: true)
        let chromeWin = SitePollWindow(windowID: 10, title: "Chrome", pid: 100, chromium: chromePending)
        let edgeWin = SitePollWindow(windowID: 20, title: "Edge", pid: 200, chromium: edgePending)
        capture.receiveSitePoll(SitePollSnapshot(start: base, end: base + 0.05, windows: [chromeWin, edgeWin]))

        // Chrome completes ordinary while Edge is pending: held stays true and resume is not called
        let chromeOrd = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: base + 0.02, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: chromeOrd, cgTitle: "Chrome", axTitle: "Chrome - Google Chrome")], startSec: base, generation: capture.siteListGeneration)
        #expect(capture.siteFrameGate.heldSince[displayID] == base - 3.5)
        #expect(capture.siteFrameGate.isHoldingNow(now: capture.siteNowSeconds()) == true)

        // Edge completes ordinary: held is false and resume is called once
        let edgeOrd = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.org", readStart: base + 0.03, listGeneration: capture.siteListGeneration, browser: .edge, isPending: false)
        capture.receiveChromiumReadComplete(browser: .edge, results: [20: (read: edgeOrd, cgTitle: "Edge", axTitle: "Edge - Microsoft Edge")], startSec: base, generation: capture.siteListGeneration)
        #expect(capture.siteFrameGate.heldSince[displayID] == nil)
        #expect(capture.siteFrameGate.isHoldingNow(now: capture.siteNowSeconds()) == false)
        log.endDisplay(String(displayID), at: base + 1.0)
        #expect(log.screenRanges()[String(displayID)]?.count == 2)
    }

    @Test func item13LateOrdinaryBecomesActivityMiss() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        let base = capture.siteNowSeconds()
        let ordRead = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: base - 0.6, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: ordRead, cgTitle: "Page", axTitle: "Page - Google Chrome")], startSec: base - 0.6, generation: capture.siteListGeneration)
        let snap = capture.chromiumActivitySnapshot.latestCompleteRead[10]
        #expect(snap?.verdict == .cantTell)
        #expect(snap?.start == base - 0.6)
    }

    @Test func item13TwinLateCoveredReachesActivity() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        let base = capture.siteNowSeconds()
        let covRead = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: base - 0.6, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: covRead, cgTitle: "Bank", axTitle: "Bank - Google Chrome")], startSec: base - 0.6, generation: capture.siteListGeneration)
        let snap = capture.chromiumActivitySnapshot.latestCompleteRead[10]
        #expect(snap?.verdict == .covered)
        #expect(snap?.host == "bank.com")
        #expect(snap?.start == base - 0.6)
    }

    // MARK: - Items 1, 6, 7 Tests

    @Test func item1DelayCausesLookBackGapDrop() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 9.75)
        let currentDelay = OSAllocatedUnfairLock(initialState: 0.0)

        struct DelayedReader: ChromiumWindowReading, @unchecked Sendable {
            let currentTime: OSAllocatedUnfairLock<Double>
            let currentDelay: OSAllocatedUnfairLock<Double>
            func copyWindows(for pid: pid_t) -> [AXUIElement]? {
                let delay = currentDelay.withLock { $0 }
                currentTime.withLock { $0 += delay }
                return [AXUIElementCreateApplication(pid)]
            }
            func focusedWindow(for pid: pid_t) -> AXUIElement? { nil }
            func windowID(for window: AXUIElement) -> CGWindowID? { 10 }
            func readTitle(for window: AXUIElement) -> String? { "Page - Google Chrome" }
            func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) { ("https://example.com", false) }
            func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome { .counts(selected: 1, total: 1) }
            func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) { ([], .complete) }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.copyOnScreen = { [SiteVisibleWindow(windowID: 10, pid: 100, layer: 0, title: "Page")] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.chromiumReader = DelayedReader(currentTime: currentTime, currentDelay: currentDelay)

        let roundReadCaptured = OSAllocatedUnfairLock<ChromiumPollRead?>(initialState: nil)
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                roundReadCaptured.withLock { $0 = results[10]?.read }
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Gate.release()
                }
            }
        )

        // Round k-1: at 9.75 s (-0.25 s relative to 10.0), ordinary
        currentTime.withLock { $0 = 9.75 }
        currentDelay.withLock { $0 = 0.0 }
        await sampler.performPollForTesting()
        await round1Gate.wait()
        let readKMinus1 = roundReadCaptured.withLock { $0 }!

        // Round k: delayed 0.2 s, starts at 10.0, readStart becomes 10.2
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 10.0 }
        currentDelay.withLock { $0 = 0.20 }
        await sampler.performPollForTesting()
        await round2Gate.wait()
        let readK = roundReadCaptured.withLock { $0 }!

        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        gate.addPoll(SitePollSnapshot(start: 9.75, end: 9.85, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readKMinus1)]))
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.3, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))
        gate.addPoll(SitePollSnapshot(start: 10.4, end: 10.5, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))
        gate.addPoll(SitePollSnapshot(start: 10.55, end: 10.65, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))

        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.02, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Earliest readStart is 10.2 > c (10.02); look-back to k-1 (9.75) has gap 10.2 - 9.75 = 0.45 > 0.3 -> drops .gap
        let actions = gate.evaluate(displayID: displayID, now: 10.7)
        #expect(actions == [.drop(id: 1, reason: .gap)])
    }

    /// The early poll's read started after the frame, so the gate looks back one poll. That look-back
    /// read joins the spacing chain: 0.45 s before the next read is too far apart to vouch for the frame.
    @Test func item1LookBackReadTooFarBeforeTheNextReadDropsGap() {
        func run(lookBackStart: TimeInterval) -> [SiteFrameAction] {
            let gate = SiteFrameGate()
            gate.updateDecisions(SiteDecision(), axAvailable: true)
            gate.updateSiteList(["bank.com"], generation: 1)
            func read(_ start: TimeInterval) -> ChromiumPollRead {
                ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: start, listGeneration: 1, browser: .chrome, isPending: false)
            }
            func poll(_ start: TimeInterval, _ readStart: TimeInterval) -> SitePollSnapshot {
                SitePollSnapshot(start: start, end: start + 0.05, windows: [SitePollWindow(windowID: 10, title: "Example", pid: 100, chromium: read(readStart))])
            }
            gate.addPoll(poll(9.5, lookBackStart)) // the look-back poll
            gate.addPoll(poll(9.75, 9.95))         // early poll: ends before c, its read starts after c
            gate.addPoll(poll(10.0, 10.2))
            gate.addPoll(poll(10.2, 10.25))
            gate.addPoll(poll(10.4, 10.45))        // first poll starting at or after c + 0.5
            let originTicks = Self.makeTicks(fromSeconds: 100.0)
            _ = gate.enqueue(displayID: displayID, frame: SiteHeldFrame(id: 1, displayTicks: originTicks, c: 9.85, originTicks: originTicks))
            return gate.evaluate(displayID: displayID, now: 10.6)
        }
        #expect(run(lookBackStart: 9.5) == [.drop(id: 1, reason: .gap)])
        // Twin: 0.25 s before the next read, the look-back read vouches for the frame.
        if case .release(let id, _) = run(lookBackStart: 9.7).first {
            #expect(id == 1)
        } else {
            Issue.record("Expected the frame to release when the look-back read is within 0.3 s")
        }
    }

    @Test func item1TwinShorterDelayReleases() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 9.85)
        let currentDelay = OSAllocatedUnfairLock(initialState: 0.0)

        struct DelayedReader: ChromiumWindowReading, @unchecked Sendable {
            let currentTime: OSAllocatedUnfairLock<Double>
            let currentDelay: OSAllocatedUnfairLock<Double>
            func copyWindows(for pid: pid_t) -> [AXUIElement]? {
                let delay = currentDelay.withLock { $0 }
                currentTime.withLock { $0 += delay }
                return [AXUIElementCreateApplication(pid)]
            }
            func focusedWindow(for pid: pid_t) -> AXUIElement? { nil }
            func windowID(for window: AXUIElement) -> CGWindowID? { 10 }
            func readTitle(for window: AXUIElement) -> String? { "Page - Google Chrome" }
            func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) { ("https://example.com", false) }
            func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome { .counts(selected: 1, total: 1) }
            func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) { ([], .complete) }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.copyOnScreen = { [SiteVisibleWindow(windowID: 10, pid: 100, layer: 0, title: "Page")] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.chromiumReader = DelayedReader(currentTime: currentTime, currentDelay: currentDelay)

        let roundReadCaptured = OSAllocatedUnfairLock<ChromiumPollRead?>(initialState: nil)
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                roundReadCaptured.withLock { $0 = results[10]?.read }
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Gate.release()
                }
            }
        )

        currentTime.withLock { $0 = 9.85 }
        currentDelay.withLock { $0 = 0.0 }
        await sampler.performPollForTesting()
        await round1Gate.wait()
        let readKMinus1 = roundReadCaptured.withLock { $0 }!

        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 10.0 }
        currentDelay.withLock { $0 = 0.04 }
        await sampler.performPollForTesting()
        await round2Gate.wait()
        let readK = roundReadCaptured.withLock { $0 }!

        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 0)
        gate.addPoll(SitePollSnapshot(start: 9.85, end: 9.95, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readKMinus1)]))
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.15, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))
        gate.addPoll(SitePollSnapshot(start: 10.2, end: 10.3, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))
        gate.addPoll(SitePollSnapshot(start: 10.55, end: 10.65, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readK)]))

        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.02, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Shorter delay (0.04 s): readStart 10.04 - 9.85 = 0.19 <= 0.3 s -> releases
        let actions = gate.evaluate(displayID: displayID, now: 10.7)
        #expect(actions.count == 1)
        if case .release(let id, _) = actions.first {
            #expect(id == 1)
        } else {
            Issue.record("Expected frame to release with shorter delay")
        }
    }

    @Test func item1LookBackReadStartsAfterCDropsGap() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.01)

        struct MockReader: ChromiumWindowReading, @unchecked Sendable {
            func copyWindows(for pid: pid_t) -> [AXUIElement]? { [AXUIElementCreateApplication(pid)] }
            func focusedWindow(for pid: pid_t) -> AXUIElement? { nil }
            func windowID(for window: AXUIElement) -> CGWindowID? { 10 }
            func readTitle(for window: AXUIElement) -> String? { "Page - Google Chrome" }
            func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) { ("https://example.com", false) }
            func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome { .counts(selected: 1, total: 1) }
            func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) { ([], .complete) }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.copyOnScreen = { [SiteVisibleWindow(windowID: 10, pid: 100, layer: 0, title: "Page")] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.chromiumReader = MockReader()

        let roundReadCaptured = OSAllocatedUnfairLock<ChromiumPollRead?>(initialState: nil)
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                roundReadCaptured.withLock { $0 = results[10]?.read }
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Gate.release()
                }
            }
        )

        // Previous poll has readStart = 10.01 (> c = 10.00)
        currentTime.withLock { $0 = 10.01 }
        await sampler.performPollForTesting()
        await round1Gate.wait()
        let readPrev = roundReadCaptured.withLock { $0 }!

        // Next poll has readStart = 10.15
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 10.15 }
        await sampler.performPollForTesting()
        await round2Gate.wait()
        let readNext = roundReadCaptured.withLock { $0 }!

        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        gate.addPoll(SitePollSnapshot(start: 9.7, end: 9.8, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readPrev)]))
        gate.addPoll(SitePollSnapshot(start: 9.85, end: 9.95, windows: []))
        gate.addPoll(SitePollSnapshot(start: 10.05, end: 10.15, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readNext)]))
        gate.addPoll(SitePollSnapshot(start: 10.55, end: 10.65, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: readNext)]))

        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 10.00, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Previous read's readStart (10.01) is > c (10.00), so look-back drops .gap
        let actions = gate.evaluate(displayID: displayID, now: 10.7)
        #expect(actions == [.drop(id: 1, reason: .gap)])
    }

    @Test func item6PendingPollKeepsScreenHeldUntilOrdinaryCompletion() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        let log = IntakeIntervalLog()
        let base = capture.siteNowSeconds()
        log.beginDisplay(String(displayID), at: 0.0)
        log.hold(display: String(displayID), at: base - 3.5)
        capture.siteFrameGate.intakeLog = log

        // After a drop, screen is held
        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let covRead = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: base - 3.7, listGeneration: 1, browser: .chrome, isPending: false)
        capture.receiveSitePoll(SitePollSnapshot(start: base - 3.8, end: base - 3.7, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        capture.receiveSitePoll(SitePollSnapshot(start: base - 3.4, end: base - 3.3, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        capture.receiveSitePoll(SitePollSnapshot(start: base - 2.9, end: base - 2.8, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: covRead)]))
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: base - 3.5, originTicks: originTicks)
        _ = capture.siteFrameGate.enqueue(displayID: displayID, frame: frame)
        _ = capture.siteFrameGate.evaluate(displayID: displayID, now: base - 2.7)
        #expect(capture.siteFrameGate.heldSince[displayID] == base - 3.5)

        // receiveSitePoll with pending poll (now < poll.start + 0.5) keeps screen held
        let pendingRead = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: true)
        let win = SitePollWindow(windowID: 10, title: "Pending", pid: 100, chromium: pendingRead)
        capture.receiveSitePoll(SitePollSnapshot(start: base, end: base + 0.05, windows: [win]))
        #expect(capture.siteFrameGate.heldSince[displayID] == base - 3.5)
        #expect(capture.siteFrameGate.isHoldingNow(now: capture.siteNowSeconds()))

        // When round completes ordinary, held is clear and resume is called
        let ordRead = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: base + 0.02, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: ordRead, cgTitle: "Example", axTitle: "Example - Google Chrome")], startSec: base, generation: capture.siteListGeneration)
        #expect(capture.siteFrameGate.heldSince[displayID] == nil)
        #expect(!capture.siteFrameGate.isHoldingNow(now: capture.siteNowSeconds()))
    }

    @Test func item6TwinMissThenOrdinaryNeverSitsOut() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)

        // One missed poll
        let base = capture.siteNowSeconds()
        let missWin = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false))
        capture.receiveSitePoll(SitePollSnapshot(start: base, end: base + 0.05, windows: [missWin]))
        capture.receiveChromiumMiss(browser: .chrome, windowID: 10, cgTitle: "Page", startSec: base, generation: capture.siteListGeneration)
        #expect(!capture.siteKeptOutBrowsers.contains(.chrome))

        // Followed by 5 s of ordinary rounds delivered as pending polls followed by completions
        for _ in 0..<10 {
            let t = capture.siteNowSeconds()
            let pendingRead = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: t, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: true)
            let win = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: pendingRead)
            capture.receiveSitePoll(SitePollSnapshot(start: t, end: t + 0.05, windows: [win]))
            #expect(!capture.siteKeptOutBrowsers.contains(.chrome))

            let ordRead = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: t + 0.02, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
            capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: ordRead, cgTitle: "Page", axTitle: "Page - Google Chrome")], startSec: t, generation: capture.siteListGeneration)
            #expect(!capture.siteKeptOutBrowsers.contains(.chrome))
        }
        #expect(!capture.siteKeptOutBrowsers.contains(.chrome))
    }

    @Test func item6TwinFrameReleasingWhileNewestPollPendingResumesAtC() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)
        let log = IntakeIntervalLog()
        log.beginDisplay(String(displayID), at: 0.0)
        log.hold(display: String(displayID), at: 9.0)
        gate.intakeLog = log

        // Earlier polls: ordinary
        let ord1 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.75, listGeneration: 1, browser: .chrome, isPending: false)
        let ord2 = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 9.85, listGeneration: 1, browser: .chrome, isPending: false)
        gate.addPoll(SitePollSnapshot(start: 9.7, end: 9.8, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: ord1)]))
        gate.addPoll(SitePollSnapshot(start: 9.82, end: 9.9, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: ord2)]))
        gate.addPoll(SitePollSnapshot(start: 10.10, end: 10.15, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: ord2)]))
        gate.addPoll(SitePollSnapshot(start: 10.30, end: 10.35, windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: ord2)]))

        // Newest poll is pending
        let pending = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: 10.40, listGeneration: 1, browser: .chrome, isPending: true)
        gate.addPoll(SitePollSnapshot(start: 10.40, end: 10.45, windows: [SitePollWindow(windowID: 10, title: "Pending", pid: 100, chromium: pending)]))

        let originTicks = Self.makeTicks(fromSeconds: 100.0)
        let frame = SiteHeldFrame(id: 1, displayTicks: originTicks, c: 9.80, originTicks: originTicks)
        _ = gate.enqueue(displayID: displayID, frame: frame)

        // Frame releases and calls resume at frame's c (9.80)
        let actions = gate.evaluate(displayID: displayID, now: 10.42)
        #expect(actions.count == 1)
        if case .release = actions.first {
            log.endDisplay(String(displayID), at: 11.0)
            let ranges = log.screenRanges()[String(displayID)] ?? []
            #expect(!ranges.isEmpty)
            #expect(ranges.last?.0 == 9.80)
        } else {
            Issue.record("Expected frame to release")
        }
    }

    @Test func item6TwinEdgePendingDoesNotFreezeChromeSitOut() {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.com"], generation: 1)

        // Poll at 10.0 with ordinary Chrome and pending Edge (now = 10.2 < 10.0 + 0.5)
        let chromeOrd = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: 10.05, listGeneration: 1, browser: .chrome, isPending: false)
        let edgePending = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: 10.0, listGeneration: 1, browser: .edge, isPending: true)
        let chromeWin = SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: chromeOrd)
        let edgeWin = SitePollWindow(windowID: 20, title: "Edge", pid: 200, chromium: edgePending)

        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.1, windows: [chromeWin, edgeWin]))

        // Chrome was out; Edge's pending round does not freeze Chrome's sit-out
        let chromeOut = gate.chromiumShouldSitOut(for: .chrome, isOutNow: true, now: 10.2)
        #expect(chromeOut == false)
    }

    @Test func item7CoveredPollFollowedByMissedPollTakesBrowserOutImmediately() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)

        let base = capture.siteNowSeconds()
        let pendingK = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: true)
        capture.receiveSitePoll(SitePollSnapshot(start: base, end: base + 0.05, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: pendingK)]))

        // Poll k+1 arrives missed first at base + 0.1
        let missKPlus1 = ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: base + 0.1, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveSitePoll(SitePollSnapshot(start: base + 0.1, end: base + 0.15, windows: [SitePollWindow(windowID: 10, title: "Bank", pid: 100, chromium: missKPlus1)]))
        capture.receiveChromiumMiss(browser: .chrome, windowID: 10, cgTitle: "Bank", startSec: base + 0.1, generation: capture.siteListGeneration)

        // Poll k completes covered
        let covRead = ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.com", readStart: base + 0.02, listGeneration: capture.siteListGeneration, browser: .chrome, isPending: false)
        capture.receiveChromiumReadComplete(browser: .chrome, results: [10: (read: covRead, cgTitle: "Bank", axTitle: "Bank - Google Chrome")], startSec: base, generation: capture.siteListGeneration)

        // The browser goes out at once
        #expect(capture.siteKeptOutBrowsers.contains(.chrome))
    }
}
