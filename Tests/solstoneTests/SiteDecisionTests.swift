// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("SiteDecision")
struct SiteDecisionTests {
    @Test func cacheCapacityAndEviction() {
        var decision = SiteDecision()
        let sites = ["bank.com"]

        for i in 0..<128 {
            let key = SiteDecisionKey(windowID: CGWindowID(i), title: "Window \(i)")
            let walk = WebAreaWalkResult(urls: ["https://example\(i).com"], completeness: .complete)
            decision.evaluate(
                key: key,
                initialAXTitle: "Window \(i)",
                finalAXTitle: "Window \(i)",
                walk: walk,
                sites: sites,
                now: TimeInterval(i),
                isSweep: false
            )
        }
        #expect(decision.entries.count == 128)

        // Adding 129th entry should evict windowID 0 (oldest decision time 0)
        let key128 = SiteDecisionKey(windowID: 128, title: "Window 128")
        let walk128 = WebAreaWalkResult(urls: ["https://example128.com"], completeness: .complete)
        decision.evaluate(
            key: key128,
            initialAXTitle: "Window 128",
            finalAXTitle: "Window 128",
            walk: walk128,
            sites: sites,
            now: 200.0,
            isSweep: false
        )
        #expect(decision.entries.count == 128)
        #expect(decision.entries[SiteDecisionKey(windowID: 0, title: "Window 0")] == nil)
        #expect(decision.entries[key128] != nil)
    }

    @Test func freshnessWindow() {
        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Tab")
        let walk = WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete)
        decision.evaluate(
            key: key,
            initialAXTitle: "Tab",
            finalAXTitle: "Tab",
            walk: walk,
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )

        // Valid within [0, 5.0]
        #expect(decision.verdict(for: key, at: 10.0) == .ordinary)
        #expect(decision.verdict(for: key, at: 14.0) == .ordinary)
        #expect(decision.verdict(for: key, at: 15.0) == .ordinary)
        // Stale after 5.0s
        #expect(decision.verdict(for: key, at: 15.1) == .pending)
        #expect(decision.verdict(for: key, at: 20.0) == .pending)
        // Future time is pending
        #expect(decision.verdict(for: key, at: 9.0) == .pending)
    }

    @Test func titleMatchingWithSafariTail() {
        #expect(SiteDecision.titleMatches(axTitle: "Tab Title", cgTitle: "Tab Title"))
        #expect(SiteDecision.titleMatches(axTitle: "Tab Title, Private Browsing", cgTitle: "Tab Title"))
        #expect(!SiteDecision.titleMatches(axTitle: "Tab Title — Private Browsing", cgTitle: "Tab Title"))
        #expect(!SiteDecision.titleMatches(axTitle: "Different Title", cgTitle: "Tab Title"))
        #expect(!SiteDecision.titleMatches(axTitle: nil, cgTitle: "Tab Title"))
    }

    @Test func evaluateCoveredAndSplitView() {
        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Split View")
        let walk = WebAreaWalkResult(
            urls: ["https://example.com", "https://login.bank.com/dashboard"],
            completeness: .complete
        )
        let verdict = decision.evaluate(
            key: key,
            initialAXTitle: "Split View",
            finalAXTitle: "Split View",
            walk: walk,
            sites: ["bank.com"],
            now: 1.0,
            isSweep: false
        )
        #expect(verdict == .covered)
        #expect(decision.verdict(for: key, at: 1.0) == .covered)
    }

    @Test func titleMismatchCautionStreak() {
        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Target Title")
        let walk = WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete)

        #expect(!decision.hasSafariCaution)
        for i in 1...4 {
            let verdict = decision.evaluate(
                key: key,
                initialAXTitle: "Mismatched",
                finalAXTitle: "Mismatched",
                walk: walk,
                sites: ["bank.com"],
                now: TimeInterval(i),
                isSweep: false
            )
            #expect(verdict == .pending)
            #expect(!decision.hasSafariCaution)
        }

        // 5th mismatch triggers caution
        _ = decision.evaluate(
            key: key,
            initialAXTitle: "Mismatched",
            finalAXTitle: "Mismatched",
            walk: walk,
            sites: ["bank.com"],
            now: 5.0,
            isSweep: false
        )
        #expect(decision.hasSafariCaution)

        // Matching title resets streak
        _ = decision.evaluate(
            key: key,
            initialAXTitle: "Target Title",
            finalAXTitle: "Target Title",
            walk: walk,
            sites: ["bank.com"],
            now: 6.0,
            isSweep: false
        )
        #expect(!decision.hasSafariCaution)
    }

    @Test func unreadableCautionStreak() {
        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Title")
        let incompleteWalk = WebAreaWalkResult(urls: [nil], completeness: .timedOut)

        #expect(!decision.hasSafariCaution)
        for i in 1...9 {
            let verdict = decision.evaluate(
                key: key,
                initialAXTitle: "Title",
                finalAXTitle: "Title",
                walk: incompleteWalk,
                sites: ["bank.com"],
                now: TimeInterval(i),
                isSweep: false
            )
            #expect(verdict == .pending)
            #expect(!decision.hasSafariCaution)
        }

        // 10th failure triggers caution
        _ = decision.evaluate(
            key: key,
            initialAXTitle: "Title",
            finalAXTitle: "Title",
            walk: incompleteWalk,
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        #expect(decision.hasSafariCaution)

        // Success resets failure streak
        let goodWalk = WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete)
        _ = decision.evaluate(
            key: key,
            initialAXTitle: "Title",
            finalAXTitle: "Title",
            walk: goodWalk,
            sites: ["bank.com"],
            now: 11.0,
            isSweep: false
        )
        #expect(!decision.hasSafariCaution)
    }

    @Test func emptyWalkPairingRequiresOneSecondGap() {
        var decision = SiteDecision()
        let key = SiteDecisionKey(windowID: 1, title: "Empty Window")
        let emptyWalk = WebAreaWalkResult(urls: [], completeness: .complete)

        // First empty walk -> pending
        let v1 = decision.evaluate(
            key: key,
            initialAXTitle: "Empty Window",
            finalAXTitle: "Empty Window",
            walk: emptyWalk,
            sites: ["bank.com"],
            now: 10.0,
            isSweep: false
        )
        #expect(v1 == .pending)

        // Second empty walk too fast (< 1.0s) -> pending
        let v2 = decision.evaluate(
            key: key,
            initialAXTitle: "Empty Window",
            finalAXTitle: "Empty Window",
            walk: emptyWalk,
            sites: ["bank.com"],
            now: 10.8,
            isSweep: false
        )
        #expect(v2 == .pending)

        // Third empty walk >= 1.0s after initial (10.0) -> ordinary
        let v3 = decision.evaluate(
            key: key,
            initialAXTitle: "Empty Window",
            finalAXTitle: "Empty Window",
            walk: emptyWalk,
            sites: ["bank.com"],
            now: 11.0,
            isSweep: false
        )
        #expect(v3 == .ordinary)
    }
}
