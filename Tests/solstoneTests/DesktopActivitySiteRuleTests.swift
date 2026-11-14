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

    @Test func frontmostChromeEdgeBraveDoNotCallSeam() {
        let seamCalled = OSAllocatedUnfairLock(initialState: false)
        let reader = DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { _, _, _, _ in
                seamCalled.withLock { $0 = true }
                return WebAreaWalkResult(urls: ["https://bank.com"], completeness: .complete)
            }
        )

        let chrome = DesktopActivityApp(pid: 1236, name: "Google Chrome", bundleID: "com.google.Chrome")
        let edge = DesktopActivityApp(pid: 1237, name: "Microsoft Edge", bundleID: "com.microsoft.edgemac")
        let brave = DesktopActivityApp(pid: 1238, name: "Brave", bundleID: "com.brave.Browser")

        let obs1 = reader.read(app: chrome, settings: makeSettings())
        let obs2 = reader.read(app: edge, settings: makeSettings())
        let obs3 = reader.read(app: brave, settings: makeSettings())

        #expect(seamCalled.withLock { $0 } == false)
        #expect(!obs1.rows.isEmpty)
        #expect(!obs2.rows.isEmpty)
        #expect(!obs3.rows.isEmpty)
    }

    @Test func emptyListActivityEvaluation() {
        // Empty list allows https ordinary
        let httpsEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "News",
            axTitle: "News - Google Chrome",
            doc: "https://news.ycombinator.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: []
        )
        #expect(httpsEval.verdict == .ordinary)
        #expect(httpsEval.host == "news.ycombinator.com")

        // file: and data: schemes are ordinary but have nil host (excluded from activity URL recording)
        let fileEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "File",
            axTitle: "File - Google Chrome",
            doc: "file:///Users/sol/doc.pdf",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: []
        )
        #expect(fileEval.verdict == .ordinary)
        #expect(fileEval.host == nil)

        let dataEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "Data",
            axTitle: "Data - Google Chrome",
            doc: "data:text/html,<h1>Hi</h1>",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: []
        )
        #expect(dataEval.verdict == .ordinary)
        #expect(dataEval.host == nil)

        // about:blank is cantTell
        let blankEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "Blank",
            axTitle: "Blank - Google Chrome",
            doc: "about:blank",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: []
        )
        #expect(blankEval.verdict == .cantTell)
    }

    @Test func nonEmptyListActivityEvaluation() {
        // Covered site returns covered
        let coveredEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "Bank Login",
            axTitle: "Bank Login - Google Chrome",
            doc: "https://login.bank.com/account",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: ["bank.com"]
        )
        #expect(coveredEval.verdict == .covered)
        #expect(coveredEval.host == "login.bank.com")

        // Ordinary site returns ordinary
        let ordinaryEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "Example",
            axTitle: "Example - Google Chrome",
            doc: "https://example.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: ["bank.com"]
        )
        #expect(ordinaryEval.verdict == .ordinary)
        #expect(ordinaryEval.host == "example.com")

        // Torn pair returns cantTell
        let tornEval = ChromiumSiteRead.evaluateActivity(
            browser: .chrome,
            cgTitle: "Page B",
            axTitle: "Page A - Google Chrome",
            doc: "https://example.com/page",
            docReadFailed: false,
            previousCGTitle: "Page A",
            previousAXTitle: "Page A - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            sites: ["bank.com"]
        )
        #expect(tornEval.verdict == .cantTell)
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

    // MARK: - Items 11 & 12 Chromium Activity Seams Tests

    private static func makeTicks(fromSeconds sec: TimeInterval) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanos = sec * 1_000_000_000.0
        return UInt64((nanos * Double(info.denom)) / Double(info.numer))
    }

    private struct SendableAX: @unchecked Sendable {
        let element: AXUIElement?
    }

    private func makeChromiumSeams(
        cgTitle: String? = "Page",
        axTitle: String? = "Page - Google Chrome",
        doc: String? = "https://example.com",
        docFailed: Bool = false,
        focusedWindow: AXUIElement? = AXUIElementCreateApplication(100),
        axWindowID: CGWindowID? = 10,
        nowSeconds: TimeInterval = 100.0,
        customAXTitle: (@Sendable (AXUIElement) -> String?)? = nil
    ) -> DesktopActivityReadSeams {
        let wrapped = SendableAX(element: focusedWindow)
        return DesktopActivityReadSeams(
            chromiumReader: LiveChromiumWindowReader(),
            preflightScreenCapture: { true },
            frontWindow: { _ in
                DesktopActivityFrontWindow(windowID: 10, title: cgTitle)
            },
            focusedRead: { _ in
                (element: wrapped.element, error: .success)
            },
            role: { _ in kAXWindowRole },
            axWindowID: { _ in axWindowID },
            axTitle: customAXTitle ?? { _ in axTitle },
            cgTitle: { _, _ in cgTitle },
            readDocument: { _ in (doc: doc, failed: docFailed) },
            settle: {},
            nowTicks: { Self.makeTicks(fromSeconds: nowSeconds) }
        )
    }

    @Test func item11CoveredByReaderOrSamplerYieldsNoRows() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // Reader's own read is covered
        let seamsCovered = makeChromiumSeams(doc: "https://bank.com/dashboard")
        let readerCovered = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seamsCovered)
        let obs1 = readerCovered.read(app: app, settings: settings)
        #expect(obs1.rows.isEmpty)

        // Sampler's latest snapshot is covered
        let seamsOrdinary = makeChromiumSeams(doc: "https://example.com")
        let readerOrdinary = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seamsOrdinary)
        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .covered,
            host: "bank.com",
            start: 100.0,
            listGeneration: 1
        )
        let obs2 = readerOrdinary.read(app: app, settings: settings, snapshot: snap)
        #expect(obs2.rows.isEmpty)
    }

    @Test func item11CantTellYieldsNoTitleAndNoURL() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(doc: nil, docFailed: true)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item11NoFocusedAXWindowYieldsNoTitle() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(focusedWindow: nil)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item11TwinEmptyListNoFocusedWindowKeepsTitle() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: [])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // Accessibility titles on and an empty list: a window that can't be read keeps its title.
        let seams = makeChromiumSeams(focusedWindow: nil)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row?.title == "Page")
        #expect(row?.url == nil)
    }

    @Test func item11SamplerOrdinaryHostMismatchWithReaderYieldsNoTitleAndNoURL() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(doc: "https://example.com")
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "other.com",
            start: 100.0,
            listGeneration: 1
        )
        snap.currentGeneration = 1
        let obs = reader.read(app: app, settings: settings, snapshot: snap)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item11ReaderCantTellWhileSamplerOrdinaryYieldsNoTitleAndNoURL() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(doc: nil, docFailed: true)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 100.0,
            listGeneration: 1
        )
        snap.currentGeneration = 1
        let obs = reader.read(app: app, settings: settings, snapshot: snap)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item11SamplerOldOrOlderGenerationYieldsNoTitleAndNoURL() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(doc: "https://example.com", nowSeconds: 100.0)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)

        // 1.1s old (> 1.0s)
        var snapOld = ChromiumActivitySnapshot()
        snapOld.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 98.8,
            listGeneration: 1
        )
        snapOld.currentGeneration = 1
        let obsOld = reader.read(app: app, settings: settings, snapshot: snapOld)
        let rowOld = obsOld.rows.first { $0.kind == "foreground" }
        #expect(rowOld != nil)
        #expect(rowOld?.title == nil)
        #expect(rowOld?.url == nil)

        // Older list generation
        var snapGen = ChromiumActivitySnapshot()
        snapGen.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 100.0,
            listGeneration: 1
        )
        snapGen.currentGeneration = 2
        let obsGen = reader.read(app: app, settings: settings, snapshot: snapGen)
        let rowGen = obsGen.rows.first { $0.kind == "foreground" }
        #expect(rowGen != nil)
        #expect(rowGen?.title == nil)
        #expect(rowGen?.url == nil)
    }

    @Test func item11EmptyListRecordsHttpsAXDocumentAndNothingForFileOrData() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: [])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // https: records URL
        let seamsHttps = makeChromiumSeams(doc: "https://example.com/info")
        let readerHttps = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seamsHttps)
        let obsHttps = readerHttps.read(app: app, settings: settings)
        let rowHttps = obsHttps.rows.first { $0.kind == "foreground" }
        #expect(rowHttps?.url == "https://example.com/info")

        // file: records nothing
        let seamsFile = makeChromiumSeams(doc: "file:///Users/owner/secret.pdf")
        let readerFile = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seamsFile)
        let obsFile = readerFile.read(app: app, settings: settings)
        let rowFile = obsFile.rows.first { $0.kind == "foreground" }
        #expect(rowFile?.url == nil)

        // data: records nothing
        let seamsData = makeChromiumSeams(doc: "data:text/html,<h1>Secret</h1>")
        let readerData = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seamsData)
        let obsData = readerData.read(app: app, settings: settings)
        let rowData = obsData.rows.first { $0.kind == "foreground" }
        #expect(rowData?.url == nil)
    }

    @Test func item11EmptyListAccessibilityOffKeepsTitle() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: [])
        settings.titles = true
        settings.urls = false
        settings.accessibility = false

        // With accessibility off and empty excludedSites, needsAX is false.
        // Even if focusedWindow is nil, CG title is kept.
        let seams = makeChromiumSeams(cgTitle: "My Document", focusedWindow: nil)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row?.title == "My Document")
    }

    @Test func item11FilePageKeepsTitle() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = false
        settings.accessibility = true

        let seams = makeChromiumSeams(cgTitle: "Local File", axTitle: "Local File - Google Chrome", doc: "file:///Users/owner/file.html", nowSeconds: 100.0)
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)

        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: nil,
            start: 100.0,
            listGeneration: 1
        )
        snap.currentGeneration = 1

        let obs = reader.read(app: app, settings: settings, snapshot: snap)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row?.title == "Local File")
    }

    @Test func item11EmptyListHttpsAddressIsRecorded() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: [])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        let seams = makeChromiumSeams(cgTitle: "Secure", axTitle: "Secure - Google Chrome", doc: "https://example.com/account")
        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row?.url == "https://example.com/account")
    }

    @Test func item12TornTitleInsideOneReadIsCantTell() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // Double read does open title, doc, close title.
        // If open and close titles differ within one read, verdict is can't tell -> no title, no URL.
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let seams = makeChromiumSeams(
            cgTitle: "Page",
            doc: "https://example.com",
            customAXTitle: { _ in
                let count = callCount.withLock {
                    $0 += 1
                    return $0
                }
                return count % 2 == 1 ? "Opening Title - Google Chrome" : "Closing Title - Google Chrome"
            }
        )

        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 100.0,
            listGeneration: 1
        )
        snap.currentGeneration = 1

        let obs = reader.read(app: app, settings: settings, snapshot: snap)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item12NilTitleIsCantTell() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: ["bank.com"])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // With a left-out list, a nil AX title must not coerce to "": the read can't vouch for the page.
        let seams = makeChromiumSeams(
            cgTitle: "Page",
            axTitle: nil,
            doc: "https://example.com"
        )

        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        var snap = ChromiumActivitySnapshot()
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 100.0,
            listGeneration: 1
        )
        snap.currentGeneration = 1
        let obs = reader.read(app: app, settings: settings, snapshot: snap)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func item12TwinEmptyListNilTitleKeepsTitleAndDropsAddress() {
        let app = DesktopActivityApp(pid: 100, name: "Google Chrome", bundleID: "com.google.Chrome")
        var settings = makeSettings(excludedSites: [])
        settings.titles = true
        settings.urls = true
        settings.accessibility = true

        // With an empty list nothing gates titles. An address read that can't be vouched for is dropped.
        let seams = makeChromiumSeams(
            cgTitle: "Page",
            axTitle: nil,
            doc: "https://example.com"
        )

        let reader = DesktopActivityReader(permit: DesktopActivityReadPermit(), seams: seams)
        let obs = reader.read(app: app, settings: settings)
        let row = obs.rows.first { $0.kind == "foreground" }
        #expect(row?.title == "Page")
        #expect(row?.url == nil)
    }
}
