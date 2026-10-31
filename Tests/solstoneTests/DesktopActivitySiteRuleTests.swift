// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ApplicationServices
import Foundation
import os
import Testing
@testable import solstone

@Suite("DesktopActivitySiteRule")
struct DesktopActivitySiteRuleTests {
    private func makeSettings(excludedSites: [String] = ["bank.com"]) -> DesktopActivitySettings {
        var config = AppConfig()
        config.excludedSites = excludedSites
        var settings = DesktopActivitySettings(config)
        settings.accessibility = false
        settings.privateAccessibility = false
        return settings
    }

    @Test func frontmostSafariCoveredURLCallsSeamAndReturnsEmptyRows() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, mode, _ in
                #expect(mode == .everyTopLevel)
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: ["https://login.bank.com/account"], completeness: .complete)
            }
        )

        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == true)
        #expect(observation.rows.isEmpty)
    }

    @Test func frontmostFirefoxDoesNotCallSeamAndKeepsRows() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _ in
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: ["https://bank.com/dashboard"], completeness: .complete)
            }
        )

        let firefox = DesktopActivityApp(pid: 1235, name: "Firefox", bundleID: "org.mozilla.firefox")
        let observation = reader.read(app: firefox, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == false)
        #expect(!observation.rows.isEmpty)
    }

    @Test func frontmostChromeDoesNotCallSeamAndKeepsRows() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _ in
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: ["https://bank.com"], completeness: .complete)
            }
        )

        let chrome = DesktopActivityApp(pid: 1236, name: "Google Chrome", bundleID: "com.google.Chrome")
        let observation = reader.read(app: chrome, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == false)
        #expect(!observation.rows.isEmpty)
    }

    @Test func uncoveredSafariReturnsRowWithNilURL() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, mode, _ in
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: ["https://example.com/news"], completeness: .complete)
            }
        )

        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == true)
        #expect(!observation.rows.isEmpty)
        let foregroundRow = observation.rows.first { $0.kind == "foreground" }
        #expect(foregroundRow != nil)
        #expect(foregroundRow?.url == nil)
    }

    @Test func missingURLReturnsRowNotEmpty() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, mode, _ in
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: [nil], completeness: .complete)
            }
        )

        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == true)
        #expect(!observation.rows.isEmpty)
        let foregroundRow = observation.rows.first { $0.kind == "foreground" }
        #expect(foregroundRow != nil)
    }

    @Test func emptyListWalkContinuesPastFailedNode() {
        let nodes = [
            WebAreaWalker.TestNode(roleFailed: false, role: "AXGroup", childrenFailed: false, children: [1, 2], url: nil),
            WebAreaWalker.TestNode(roleFailed: true, role: nil, childrenFailed: false, children: [], url: nil),
            WebAreaWalker.TestNode(roleFailed: false, role: "AXWebArea", childrenFailed: false, children: [], url: "https://example.com/page")
        ]

        let firstDoc = WebAreaWalker.walk(nodes: nodes, mode: .firstDocument)
        #expect(firstDoc.completeness == .complete)
        #expect(firstDoc.urls == ["https://example.com/page"])

        let everyTop = WebAreaWalker.walk(nodes: nodes, mode: .everyTopLevel)
        #expect(everyTop.completeness == .axError)

        var decision = SiteDecision()
        let verdict = decision.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "Title"),
            initialAXTitle: "Title",
            finalAXTitle: "Title",
            walk: everyTop,
            sites: ["bank.com"],
            now: 1.0,
            isSweep: false
        )
        #expect(verdict == .pending)
    }
}
