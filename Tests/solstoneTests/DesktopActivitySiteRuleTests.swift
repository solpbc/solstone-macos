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
        let recordedTimeout = OSAllocatedUnfairLock<Float?>(initialState: nil)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, mode, _, timeout in
                #expect(mode == .everyTopLevel)
                seamCalled.withLock { $0 = true }
                recordedTimeout.withLock { $0 = timeout }
                return WebAreaWalkResult(urls: ["https://login.bank.com/account"], completeness: .complete)
            }
        )

        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == true)
        #expect(recordedTimeout.withLock { $0 } == 0.05)
        #expect(observation.rows.isEmpty)
    }

    @Test func frontmostFirefoxDoesNotCallSeamAndKeepsRows() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _, _ in
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
            walkSeam: { _, _, _, _ in
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
            walkSeam: { _, mode, _, _ in
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
            walkSeam: { _, mode, _, _ in
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

    @Test func firstDocumentWalksChildrenOfFailedRoleAndReturnsComplete() {
        let nodes = [
            WebAreaWalker.TestNode(roleFailed: true, role: nil, childrenFailed: false, children: [1], url: nil),
            WebAreaWalker.TestNode(roleFailed: false, role: "AXWebArea", childrenFailed: false, children: [], url: "https://child.com/doc")
        ]
        let result = WebAreaWalker.walk(nodes: nodes, mode: .firstDocument)
        #expect(result.completeness == .complete)
        #expect(result.urls == ["https://child.com/doc"])
    }

    @Test func everyTopLevelFailedRoleWithCoveredChildYieldsEmptyRowsAndAXError() {
        let nodes = [
            WebAreaWalker.TestNode(roleFailed: true, role: nil, childrenFailed: false, children: [1], url: nil),
            WebAreaWalker.TestNode(roleFailed: false, role: "AXWebArea", childrenFailed: false, children: [], url: "https://login.bank.com/account")
        ]
        let walkResult = WebAreaWalker.walk(nodes: nodes, mode: .everyTopLevel)
        #expect(walkResult.completeness != .complete)
        #expect(walkResult.completeness == .axError)

        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _, _ in
                walkResult
            }
        )
        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())
        #expect(observation.rows.isEmpty)
    }

    @Test func everyTopLevelFailedRoleWithUncoveredChildYieldsPendingDecisionAndKeepsRows() {
        let nodes = [
            WebAreaWalker.TestNode(roleFailed: true, role: nil, childrenFailed: false, children: [1], url: nil),
            WebAreaWalker.TestNode(roleFailed: false, role: "AXWebArea", childrenFailed: false, children: [], url: "https://uncovered.com/page")
        ]
        let walkResult = WebAreaWalker.walk(nodes: nodes, mode: .everyTopLevel)
        #expect(walkResult.completeness != .complete)
        #expect(walkResult.completeness == .axError)

        var decision = SiteDecision()
        let verdict = decision.evaluate(
            key: SiteDecisionKey(windowID: 1, title: "Title"),
            initialAXTitle: "Title",
            finalAXTitle: "Title",
            walk: walkResult,
            sites: ["bank.com"],
            now: 1.0,
            isSweep: false
        )
        #expect(verdict == .pending)

        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _, _ in
                walkResult
            }
        )
        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let observation = reader.read(app: safari, settings: makeSettings())
        #expect(!observation.rows.isEmpty)
    }

    @Test func aTitleGoesWithAnAddressOnlyWhenTwoReadsAgree() {
        typealias R = DesktopActivityReader
        typealias P = DesktopActivityPairRead
        func pair(_ cg: String?, _ ax: String?, _ urls: [String?], complete: Bool = true) -> P {
            P(cgTitle: cg, axTitle: ax, urls: urls, complete: complete)
        }
        let shared = "https://shared.example/"
        let steady = pair("Shared", "Shared", [shared])
        #expect(R.titleGoesWithAddress(steady, steady, titlesMustMatch: true))
        // A tab switch: Accessibility and the address have moved, the window list hasn't.
        let trailing = pair("Other tab", "Shared", [shared])
        #expect(!R.titleGoesWithAddress(trailing, trailing, titlesMustMatch: true))
        #expect(!R.titleGoesWithAddress(trailing, steady, titlesMustMatch: true))
        // A page change: the address has moved, both titles haven't, until the second read.
        let committed = pair("Left out", "Left out", [shared])
        #expect(!R.titleGoesWithAddress(committed, steady, titlesMustMatch: true))
        // The next page beside the one it replaces.
        let replacing = pair("Left out", "Left out", [shared, "https://left.example/"])
        #expect(!R.titleGoesWithAddress(replacing, replacing, titlesMustMatch: true))
        // A read that came back short vouches for nothing, either time.
        let short = pair("Shared", "Shared", [shared], complete: false)
        #expect(!R.titleGoesWithAddress(steady, short, titlesMustMatch: true))
        #expect(!R.titleGoesWithAddress(short, short, titlesMustMatch: true))
        let noAXTitle = pair("A", nil, ["https://a.example/"])
        #expect(!R.titleGoesWithAddress(noAXTitle, noAXTitle, titlesMustMatch: true))
        // Chromium adds its own name to one of the two titles.
        let chromium = pair("Page", "Page - Google Chrome", ["https://a.example/"])
        #expect(R.titleGoesWithAddress(chromium, chromium, titlesMustMatch: false))
        #expect(!R.titleGoesWithAddress(chromium, pair("Next", "Page - Google Chrome", ["https://a.example/"]), titlesMustMatch: false))
        // No screen recording: Accessibility's title stands alone.
        let axOnly = pair(nil, "Shared", [shared])
        #expect(R.titleGoesWithAddress(axOnly, axOnly, titlesMustMatch: true))
    }

    @Test func addressesAreUnavailableOnlyWhereABrowserIsInFront() {
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), walkSeam: { _, _, _, _ in
            WebAreaWalkResult(urls: [], completeness: .complete)
        })
        var settings = makeSettings()
        settings.urls = true
        let finder = DesktopActivityApp(pid: 1234, name: "Finder", bundleID: "com.apple.finder")
        #expect(!reader.read(app: finder, settings: settings).urlUnavailable)
        let firefox = DesktopActivityApp(pid: 1234, name: "Firefox", bundleID: "org.mozilla.firefox")
        #expect(reader.read(app: firefox, settings: settings).urlUnavailable)
    }

    @Test func shortSafariReadKeepsTitleAndAddressOutOfThatSample() {
        typealias R = DesktopActivityReader
        #expect(R.siteReadIsShort(WebAreaWalkResult(urls: ["https://example.com"], completeness: .timedOut)))
        #expect(R.siteReadIsShort(WebAreaWalkResult(urls: [], completeness: .axError)))
        #expect(R.siteReadIsShort(WebAreaWalkResult(urls: [nil], completeness: .complete)))
        #expect(R.siteReadIsShort(WebAreaWalkResult(urls: ["https://a.com"], completeness: .childListCut)))
        #expect(!R.siteReadIsShort(WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete)))
        #expect(!R.siteReadIsShort(WebAreaWalkResult(urls: [], completeness: .complete)))
    }

    @Test func deniedAccessibilityKeepsSafariTitleOutWhateverTheWalkSays() {
        typealias R = DesktopActivityReader
        #expect(R.siteUndecided(WebAreaWalkResult(urls: [], completeness: .axError), accessibilityDenied: true))
        #expect(R.siteUndecided(WebAreaWalkResult(urls: [], completeness: .complete), accessibilityDenied: true))
        #expect(R.siteUndecided(WebAreaWalkResult(urls: ["https://a.com"], completeness: .complete), accessibilityDenied: true))
        #expect(!R.siteUndecided(WebAreaWalkResult(urls: ["https://a.com"], completeness: .complete), accessibilityDenied: false))
    }

    @Test func shortSafariReadStillWritesTheForegroundRowWithoutAnAddress() {
        var settings = makeSettings()
        settings.urls = true
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), walkSeam: { _, _, _, _ in
            WebAreaWalkResult(urls: ["https://example.com/news"], completeness: .timedOut)
        })
        let safari = DesktopActivityApp(pid: 1234, name: "Safari", bundleID: "com.apple.Safari")
        let row = reader.read(app: safari, settings: settings).rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }
}
