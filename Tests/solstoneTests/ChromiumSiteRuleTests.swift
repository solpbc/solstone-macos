// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ApplicationServices
import CoreGraphics
import Foundation
import os
import Testing
@testable import solstone

@Suite("ChromiumSiteRule")
struct ChromiumSiteRuleTests {
    private static func makeTicks(fromSeconds sec: TimeInterval) -> UInt64 {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanos = sec * 1_000_000_000.0
        return UInt64((nanos * Double(info.denom)) / Double(info.numer))
    }

    private struct SendableAX: @unchecked Sendable {
        let element: AXUIElement
    }
    // MARK: - Title Checks

    @Test func titleCheckPlainTab() {
        let chrome = ChromiumSiteRead.checkTitles(
            cgTitle: "My Page",
            axTitle: "My Page - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(chrome == .plain)

        let edge = ChromiumSiteRead.checkTitles(
            cgTitle: "My Page",
            axTitle: "My Page - Microsoft Edge",
            browser: .edge,
            tabButtonCount: 1
        )
        #expect(edge == .plain)

        let brave = ChromiumSiteRead.checkTitles(
            cgTitle: "My Page",
            axTitle: "My Page - Brave",
            browser: .brave,
            tabButtonCount: 1
        )
        #expect(brave == .plain)
    }

    @Test func titleCheckPlainVariants() {
        // brand only
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome", browser: .chrome, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Microsoft Edge", browser: .edge, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Brave", browser: .brave, tabButtonCount: 1) == .plain)

        // brand plus (…) with nothing after closing paren
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome (Incognito)", browser: .chrome, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Microsoft Edge (InPrivate)", browser: .edge, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Brave (Private)", browser: .brave, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome (Guest)", browser: .chrome, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome (1)", browser: .chrome, tabButtonCount: 1) == .plain)

        // brand plus " - " plus profile name containing no " - "
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome - Person 1", browser: .chrome, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Microsoft Edge - Profile 2", browser: .edge, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Brave - Person 1", browser: .brave, tabButtonCount: 1) == .plain)
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Google Chrome - Your Chrome", browser: .chrome, tabButtonCount: 1) == .plain)
    }

    @Test func titleCheckInsertedVariants() {
        // High memory usage
        let highMem = ChromiumSiteRead.checkTitles(
            cgTitle: "HTML Standard",
            axTitle: "HTML Standard - High memory usage - 902 MB - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(highMem == .inserted)

        // Network error (measured form is inserted)
        let netErr = ChromiumSiteRead.checkTitles(
            cgTitle: "nx.example.test",
            axTitle: "nx.example.test - Network error - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(netErr == .inserted)

        // Video playing in PiP
        let pip = ChromiumSiteRead.checkTitles(
            cgTitle: "Watch",
            axTitle: "Watch - Video playing in picture-in-picture mode - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(pip == .inserted)

        // Split views
        let leftView = ChromiumSiteRead.checkTitles(
            cgTitle: "Page",
            axTitle: "Page - Left view - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(leftView == .inserted)

        let rightView = ChromiumSiteRead.checkTitles(
            cgTitle: "Page",
            axTitle: "Page - Right view - Microsoft Edge",
            browser: .edge,
            tabButtonCount: 1
        )
        #expect(rightView == .inserted)

        // Known hole: Acme - Sign in when cg is Acme
        let acme = ChromiumSiteRead.checkTitles(
            cgTitle: "Acme",
            axTitle: "Acme - Sign in - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(acme == .inserted)

        // Non-English inserted phrase
        let nonEnglish = ChromiumSiteRead.checkTitles(
            cgTitle: "Page",
            axTitle: "Page - Vue fractionnée - Google Chrome",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(nonEnglish == .inserted)
    }

    @Test func titleCheckNegatives() {
        // Empty cgTitle
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "", axTitle: " - Google Chrome", browser: .chrome, tabButtonCount: 1) == .failed)

        // cgTitle starts with " - "
        #expect(ChromiumSiteRead.checkTitles(cgTitle: " - Something", axTitle: " - Something - Google Chrome", browser: .chrome, tabButtonCount: 1) == .failed)

        // Next page AX
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Old Page", axTitle: "New Page - Google Chrome", browser: .chrome, tabButtonCount: 1) == .failed)

        // Missing brand
        #expect(ChromiumSiteRead.checkTitles(cgTitle: "Inbox", axTitle: "Inbox - Safari", browser: .chrome, tabButtonCount: 1) == .failed)
    }

    @Test func titleCheckAppWindowZeroTabs() {
        let app = ChromiumSiteRead.checkTitles(
            cgTitle: "Slack",
            axTitle: "Slack",
            browser: .chrome,
            tabButtonCount: 0
        )
        #expect(app == .appWindow)

        let notAppWithTabs = ChromiumSiteRead.checkTitles(
            cgTitle: "Slack",
            axTitle: "Slack",
            browser: .chrome,
            tabButtonCount: 1
        )
        #expect(notAppWithTabs == .failed)

        let notAppNilTabs = ChromiumSiteRead.checkTitles(
            cgTitle: "Slack",
            axTitle: "Slack",
            browser: .chrome,
            tabButtonCount: nil
        )
        #expect(notAppNilTabs == .failed)
    }

    // MARK: - Page Evaluation & Pure Rules

    @Test func tornPairYieldsCantTellUnclear() {
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page B",
            initialAXTitle: "Page A - Google Chrome",
            finalAXTitle: "Page A - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Page A",
            previousAXTitle: "Page A - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
        #expect(eval.cause == .unclear)
    }

    @Test func loginWithAcmeForumTornPairForm() {
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Login",
            initialAXTitle: "Login - Acme Forum - Google Chrome",
            finalAXTitle: "Login - Acme Forum - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Login - Acme Forum",
            previousAXTitle: "Login - Acme Forum - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        // Previous CG was Login - Acme Forum, current CG is Login, but AX stayed Login - Acme Forum - Google Chrome
        #expect(eval.verdict == .cantTell)
        #expect(eval.cause == .unclear)
    }

    @Test func splitViewMultipleSelectedTabsYieldsCantTellUnclear() {
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Tab 1",
            initialAXTitle: "Tab 1 - Google Chrome",
            finalAXTitle: "Tab 1 - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 2, total: 5),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
        #expect(eval.cause == .unclear)
    }

    @Test func rule1EmptyDocument() {
        // App window empty doc, empty titles, zero tabs -> ordinary
        let appEmpty = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "",
            initialAXTitle: "",
            finalAXTitle: "",
            doc: "",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 0, total: 0),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(appEmpty.verdict == .ordinary)

        // Non-empty title with empty doc -> cantTell unclear
        let nonAppEmpty = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "New Tab",
            initialAXTitle: "New Tab - Google Chrome",
            finalAXTitle: "New Tab - Google Chrome",
            doc: "",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(nonAppEmpty.verdict == .cantTell)
        #expect(nonAppEmpty.cause == .unclear)
    }

    @Test func rule3URLSchemeClassification() {
        func evalDoc(_ doc: String) -> ChromiumPageEvaluation {
            ChromiumSiteRead.evaluatePageWindow(
                windowID: 10,
                browser: .chrome,
                cgTitle: "Page",
                initialAXTitle: "Page - Google Chrome",
                finalAXTitle: "Page - Google Chrome",
                doc: doc,
                docReadFailed: false,
                previousCGTitle: nil,
                previousAXTitle: nil,
                tabStripOutcome: .counts(selected: 1, total: 1),
                rule6Record: nil,
                sites: ["bank.com"],
                now: 100.0
            )
        }

        #expect(evalDoc("about:blank").verdict == .cantTell)
        #expect(evalDoc("about:blank#hash").verdict == .cantTell)
        #expect(evalDoc("about:srcdoc").verdict == .cantTell)

        #expect(evalDoc("file:///Users/sol/doc.pdf").verdict == .ordinary)
        #expect(evalDoc("data:text/html,hello").verdict == .ordinary)
        #expect(evalDoc("chrome://settings").verdict == .ordinary)
        #expect(evalDoc("chrome-extension://abcdef/popup.html").verdict == .ordinary)

        #expect(evalDoc("chrome-error://chromewebdata/").verdict == .cantTell)
        #expect(evalDoc("chrome-untrusted://print/").verdict == .cantTell)
        #expect(evalDoc("ftp://ftp.example.com").verdict == .cantTell)

        // Filesystem unwrap
        let fsOrdinary = evalDoc("filesystem:https://example.com/temporary/test.txt")
        #expect(fsOrdinary.verdict == .ordinary)
        #expect(fsOrdinary.host == "example.com")

        let fsCovered = evalDoc("filesystem:https://bank.com/temporary/test.txt")
        #expect(fsCovered.verdict == .covered)
        #expect(fsCovered.host == "bank.com")
    }

    @Test func coveredWinsOverTornPairOrFailedPass() {
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Login",
            initialAXTitle: "Old Page - Google Chrome",
            finalAXTitle: "Different Page - Google Chrome",
            doc: "https://login.bank.com/account",
            docReadFailed: false,
            previousCGTitle: "Previous",
            previousAXTitle: "Old Page - Google Chrome",
            tabStripOutcome: .failed,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .covered)
        #expect(eval.host == "login.bank.com")
    }

    @Test func rule6MemoryAcrossLeave() {
        var rule6: ChromiumRule6Record? = ChromiumRule6Record(waitStart: 100.0, host: "bank.com")

        // Ordinary page at 102.0 (2 s in): still cantTell unclear
        let eval2s = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Search",
            initialAXTitle: "Search - Google Chrome",
            finalAXTitle: "Search - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 102.0
        )
        #expect(eval2s.verdict == .cantTell)
        #expect(eval2s.cause == .unclear)

        // Holds at 4.5 s across CG title change
        let eval4_5s = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Search Results",
            initialAXTitle: "Search Results - Google Chrome",
            finalAXTitle: "Search Results - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Search",
            previousAXTitle: "Search - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 104.5
        )
        #expect(eval4_5s.verdict == .cantTell)
        #expect(eval4_5s.cause == .unclear)

        // Clears at 5 s after first ordinary read (first ordinary read at 102.0, clears at 107.1)
        let eval5_5s = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Search Results",
            initialAXTitle: "Search Results - Google Chrome",
            finalAXTitle: "Search Results - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 107.1
        )
        #expect(eval5_5s.verdict == .ordinary)
        #expect(eval5_5s.host == "example.com")
        #expect(rule6 == nil)
    }

    // MARK: - Side Window (Layer 3) Evaluation

    @Test func sideWindowVideoPiPEmptyDoc() {
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["youtube.com"],
            walkOutcome: .complete,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .ordinary)
        #expect(eval.host == "youtube.com")
    }

    @Test func sideWindowDocumentPiPCovered() {
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["https://bank.com:8443/pip"],
            walkOutcome: .complete,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .covered)
        #expect(eval.host == "bank.com")
    }

    @Test func sideWindowOverBudgetYieldsCantTellUnclear() {
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["example.com"],
            walkOutcome: .overBudget,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
        #expect(eval.cause == .unclear)
    }

    @Test func sideWindowFailedYieldsCantTellUnread() {
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: [],
            walkOutcome: .failed,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
        #expect(eval.cause == .unread)
    }

    // MARK: - Gate Late Read & Deadline Miss

    @Test @MainActor func gateLateOrdinaryIgnoredLateCoveredApplied() {
        let gate = SiteFrameGate()
        gate.updateSiteList(["bank.com"], generation: 1)

        // Poll from 10.0 to 10.1 with pending window 10
        let pending = ChromiumPollRead(
            verdict: .cantTell,
            cause: .unread,
            host: nil,
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: true
        )
        let poll = SitePollSnapshot(
            start: 10.0,
            end: 10.1,
            windows: [SitePollWindow(windowID: 10, title: "Page", pid: 100, chromium: pending)]
        )
        gate.addPoll(poll)

        // 1. Late ordinary read arriving after deadline (now = 10.6 >= 10.0 + 0.5)
        let lateOrdinary = ChromiumPollRead(
            verdict: .ordinary,
            cause: nil,
            host: "example.com",
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        gate.patchChromiumPoll(start: 10.0, windowID: 10, read: lateOrdinary, at: 10.6)

        // Poll window should still be pending / unpatched because late ordinary is ignored
        #expect(gate.polls.first?.windows.first?.chromium?.isPending == true)

        // 2. Late covered read arriving after deadline (now = 10.7 >= 10.0 + 0.5)
        let lateCovered = ChromiumPollRead(
            verdict: .covered,
            cause: nil,
            host: "bank.com",
            readStart: 10.0,
            listGeneration: 1,
            browser: .chrome,
            isPending: false
        )
        gate.patchChromiumPoll(start: 10.0, windowID: 10, read: lateCovered, at: 10.7)

        // Late covered read is applied!
        #expect(gate.polls.first?.windows.first?.chromium?.verdict == .covered)
        #expect(gate.polls.first?.windows.first?.chromium?.isPending == false)
    }

    // MARK: - App Window Evaluation

    @Test func appWindowTabCountAndFailedPass() {
        // App window (Slack) with 0 tabs -> ordinary
        let app0 = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Slack",
            initialAXTitle: "Slack",
            finalAXTitle: "Slack",
            doc: "https://slack.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 0, total: 0),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(app0.verdict == .ordinary)

        // App window with 1 tab -> failed title check -> cantTell (.unclear)
        let app1 = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Slack",
            initialAXTitle: "Slack",
            finalAXTitle: "Slack",
            doc: "https://slack.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(app1.verdict == .cantTell)
        #expect(app1.cause == .unclear)

        // App window with failed pass -> failed title check -> cantTell (.unclear)
        let appFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Slack",
            initialAXTitle: "Slack",
            finalAXTitle: "Slack",
            doc: "https://slack.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .failed,
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(appFailed.verdict == .cantTell)
        #expect(appFailed.cause == .unclear)
    }

    // MARK: - Heavy Tab and Split View

    @Test func heavyTabAndSplitViewEvaluation() {
        // Heavy tab: plain title form with 1 selected tab
        let heavyOrd = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Inbox",
            initialAXTitle: "Inbox - Google Chrome (1)",
            finalAXTitle: "Inbox - Google Chrome (1)",
            doc: "https://example.com/inbox",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(heavyOrd.verdict == .ordinary)

        let heavyCov = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Inbox",
            initialAXTitle: "Inbox - Google Chrome (1)",
            finalAXTitle: "Inbox - Google Chrome (1)",
            doc: "https://bank.com/inbox",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(heavyCov.verdict == .covered)

        // Inserted phrase (measured PiP) with 1 selected tab
        let pipOrd = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Watch",
            initialAXTitle: "Watch - Video playing in picture-in-picture mode - Google Chrome",
            finalAXTitle: "Watch - Video playing in picture-in-picture mode - Google Chrome",
            doc: "https://example.com/watch",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(pipOrd.verdict == .ordinary)

        let pipCov = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Watch",
            initialAXTitle: "Watch - Video playing in picture-in-picture mode - Google Chrome",
            finalAXTitle: "Watch - Video playing in picture-in-picture mode - Google Chrome",
            doc: "https://bank.com/watch",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(pipCov.verdict == .covered)

        // Split view (2 selected tabs) with ordinary host -> cantTell (.unclear)
        let splitOrd = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Left view - Google Chrome",
            finalAXTitle: "Page - Left view - Google Chrome",
            doc: "https://example.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 2, total: 2),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(splitOrd.verdict == .cantTell)
        #expect(splitOrd.cause == .unclear)

        // Split view (2 selected tabs) with covered host -> covered! Covered wins!
        let splitCov = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Left view - Google Chrome",
            finalAXTitle: "Page - Left view - Google Chrome",
            doc: "https://bank.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 2, total: 2),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(splitCov.verdict == .covered)

        // Non-English inserted phrase with 2 selected tabs: cantTell on ordinary, covered on covered
        let nonEngOrd = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Vue fractionnée - Google Chrome",
            finalAXTitle: "Page - Vue fractionnée - Google Chrome",
            doc: "https://example.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 2, total: 2),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(nonEngOrd.verdict == .cantTell)
        #expect(nonEngOrd.cause == .unclear)

        let nonEngCov = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Vue fractionnée - Google Chrome",
            finalAXTitle: "Page - Vue fractionnée - Google Chrome",
            doc: "https://bank.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 2, total: 2),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(nonEngCov.verdict == .covered)
    }

    // MARK: - Empty Document Detailed Variants

    @Test func emptyDocumentDetailedVariants() {
        // 1. Both titles empty and zero tabs -> ordinary
        let appZero = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "",
            initialAXTitle: "",
            finalAXTitle: "",
            doc: "",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 0, total: 0),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(appZero.verdict == .ordinary)

        // 2. Tail-less non-empty title with zero tabs stays can't tell through 3 s
        for t in [100.0, 101.5, 103.0] {
            let tailless = ChromiumSiteRead.evaluatePageWindow(
                windowID: 10,
                browser: .chrome,
                cgTitle: "SomeApp",
                initialAXTitle: "SomeApp",
                finalAXTitle: "SomeApp",
                doc: "",
                docReadFailed: false,
                previousCGTitle: nil,
                previousAXTitle: nil,
                tabStripOutcome: .counts(selected: 0, total: 0),
                rule6Record: nil,
                sites: ["bank.com"],
                now: t
            )
            #expect(tailless.verdict == .cantTell)
            #expect(tailless.cause == .unclear)
        }

        // 3. Page-form title with one selected tab stays can't tell through 3 s
        for t in [100.0, 101.5, 103.0] {
            let pageFormEmptyDoc = ChromiumSiteRead.evaluatePageWindow(
                windowID: 10,
                browser: .chrome,
                cgTitle: "My Page",
                initialAXTitle: "My Page - Google Chrome",
                finalAXTitle: "My Page - Google Chrome",
                doc: "",
                docReadFailed: false,
                previousCGTitle: nil,
                previousAXTitle: nil,
                tabStripOutcome: .counts(selected: 1, total: 1),
                rule6Record: nil,
                sites: ["bank.com"],
                now: t
            )
            #expect(pageFormEmptyDoc.verdict == .cantTell)
            #expect(pageFormEmptyDoc.cause == .unclear)
        }
    }

    // MARK: - URL Classes Detailed Variants

    @Test func urlClassesDetailedVariants() {
        // filesystem: covered
        let fsCovered = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "File",
            initialAXTitle: "File - Google Chrome",
            finalAXTitle: "File - Google Chrome",
            doc: "filesystem:https://bank.com/temporary/test.txt",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(fsCovered.verdict == .covered)
        #expect(fsCovered.host == "bank.com")

        // filesystem:ftp: can't tell
        let fsFtp = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "File",
            initialAXTitle: "File - Google Chrome",
            finalAXTitle: "File - Google Chrome",
            doc: "filesystem:ftp://ftp.example.com/temporary/test.txt",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(fsFtp.verdict == .cantTell)
        #expect(fsFtp.cause == .unclear)

        // about:blank#x can't tell
        let blankHash = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Blank",
            initialAXTitle: "Blank - Google Chrome",
            finalAXTitle: "Blank - Google Chrome",
            doc: "about:blank#hash",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(blankHash.verdict == .cantTell)
        #expect(blankHash.cause == .unclear)

        // about:srcdoc can't tell
        let srcdoc = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Srcdoc",
            initialAXTitle: "Srcdoc - Google Chrome",
            finalAXTitle: "Srcdoc - Google Chrome",
            doc: "about:srcdoc",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(srcdoc.verdict == .cantTell)
        #expect(srcdoc.cause == .unclear)
    }

    // MARK: - Attribute Failing in Turn

    @Test func attributeFailingInTurnNeverOrdinary() {
        // Initial title nil (failed) -> cantTell (.unread), never ordinary
        let titleFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: nil,
            finalAXTitle: "Page - Google Chrome",
            doc: "https://example.com/page",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(titleFailed.verdict == .cantTell)
        #expect(titleFailed.cause == .unread)

        // Document read failed -> cantTell (.unread), never ordinary
        let docFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: nil,
            docReadFailed: true,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(docFailed.verdict == .cantTell)
        #expect(docFailed.cause == .unread)
    }

    // MARK: - Rule 6 Detailed Cases

    @Test func rule6AcrossCGTitleChangeMissAndClearing() {
        var rule6: ChromiumRule6Record? = ChromiumRule6Record(waitStart: 100.0, host: "bank.com")

        // 1. Holds at 4.5 s across CG title change
        let eval4_5 = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Next Page",
            initialAXTitle: "Next Page - Google Chrome",
            finalAXTitle: "Next Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Old Page",
            previousAXTitle: "Old Page - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 104.5
        )
        #expect(eval4_5.verdict == .cantTell)
        #expect(eval4_5.cause == .unclear)
        #expect(rule6?.waitStart == 100.0)

        // 2. A miss restarts waitStart
        let evalMiss = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Next Page",
            initialAXTitle: "Next Page - Google Chrome",
            finalAXTitle: "Next Page - Google Chrome",
            doc: nil,
            docReadFailed: true,
            previousCGTitle: "Next Page",
            previousAXTitle: "Next Page - Google Chrome",
            tabStripOutcome: .failed,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 104.6
        )
        #expect(evalMiss.verdict == .cantTell)
        #expect(rule6?.waitStart == 104.6)

        // At 107.0 (2.4 s after restart), still holds
        let eval2_4s = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Next Page",
            initialAXTitle: "Next Page - Google Chrome",
            finalAXTitle: "Next Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Next Page",
            previousAXTitle: "Next Page - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 107.0
        )
        #expect(eval2_4s.verdict == .cantTell)
        #expect(eval2_4s.cause == .unclear)

        // 3. Ordinary at 5 s clears (first ordinary was at 107.0, so at 112.1 >= 107.0 + 5.0)
        let eval5s = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Next Page",
            initialAXTitle: "Next Page - Google Chrome",
            finalAXTitle: "Next Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: "Next Page",
            previousAXTitle: "Next Page - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 112.1
        )
        #expect(eval5s.verdict == .ordinary)
        #expect(rule6 == nil)
    }

    // MARK: - Covered Wins Over All Imperfections

    @Test func coveredWinsOverAllImperfections() {
        let coveredDoc = "https://login.bank.com/account"
        let sites = ["bank.com"]

        // 1. Torn titles
        let torn = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page B",
            initialAXTitle: "Page A - Google Chrome",
            finalAXTitle: "Page A - Google Chrome",
            doc: coveredDoc,
            docReadFailed: false,
            previousCGTitle: "Page A",
            previousAXTitle: "Page A - Google Chrome",
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(torn.verdict == .covered)
        #expect(torn.host == "login.bank.com")

        // 2. First title failed (nil)
        let firstTitleFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page A",
            initialAXTitle: nil,
            finalAXTitle: "Page A - Google Chrome",
            doc: coveredDoc,
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(firstTitleFailed.verdict == .covered)
        #expect(firstTitleFailed.host == "login.bank.com")

        // 3. Title check failed (e.g. next page ax)
        let titleCheckFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Old Page",
            initialAXTitle: "New Page - Google Chrome",
            finalAXTitle: "New Page - Google Chrome",
            doc: coveredDoc,
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .counts(selected: 1, total: 1),
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(titleCheckFailed.verdict == .covered)
        #expect(titleCheckFailed.host == "login.bank.com")

        // 4. Pass did not run
        let passNotRun = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: coveredDoc,
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .notRun,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(passNotRun.verdict == .covered)
        #expect(passNotRun.host == "login.bank.com")

        // 5. Pass failed
        let passFailed = ChromiumSiteRead.evaluatePageWindow(
            windowID: 10,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: coveredDoc,
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: .failed,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(passFailed.verdict == .covered)
        #expect(passFailed.host == "login.bank.com")
    }

    // MARK: - List Generation & Host-Only Storage

    @Test func listGenerationAndHostOnlyStorage() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let roundComplete = OneShotContinuationGate()
        let roundResults = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        struct MockHostReader: ChromiumWindowReading, @unchecked Sendable {
            func copyWindows(for pid: pid_t) -> [AXUIElement]? { [AXUIElementCreateApplication(10)] }
            func focusedWindow(for pid: pid_t) -> AXUIElement? { nil }
            func windowID(for window: AXUIElement) -> CGWindowID? { 10 }
            func readTitle(for window: AXUIElement) -> String? { "Page - Google Chrome" }
            func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) {
                ("https://bank.com/secret/account?token=private#hash", false)
            }
            func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome {
                .counts(selected: 1, total: 1)
            }
            func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
                ([], .complete)
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = { [SiteVisibleWindow(windowID: 10, pid: 100, layer: 0, title: "Page")] }
        hooks.chromiumReader = MockHostReader()

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                roundResults.withLock { $0 = results }
                roundComplete.release()
            }
        )

        await sampler.applySites(["bank.com"], generation: 2)
        await sampler.performPollForTesting()
        await roundComplete.wait()

        let res = roundResults.withLock { $0[10] }!
        #expect(res.read.verdict == .covered)
        #expect(res.read.host == "bank.com")
        #expect(res.read.host?.contains("secret") == false)
        #expect(res.read.host?.contains("account") == false)
        #expect(res.read.host?.contains("token") == false)
        #expect(res.read.host?.contains("hash") == false)
        #expect(res.read.listGeneration == 2)
    }

    // MARK: - Side Window Shapes

    @Test func sideWindowShapesComprehensive() {
        let sites = ["bank.com"]

        // 1. No host in static texts -> cantTell (.unclear), no caution
        let noHost = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["Hello World", "Welcome"],
            walkOutcome: .complete,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(noHost.verdict == .cantTell)
        #expect(noHost.cause == .unclear)

        // 2. Two different hosts -> cantTell (.unclear), no caution
        let twoHosts = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["example.com", "other.org"],
            walkOutcome: .complete,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(twoHosts.verdict == .cantTell)
        #expect(twoHosts.cause == .unclear)

        // 3. Over budget -> cantTell (.unclear), no caution
        let overBudget = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["example.com"],
            walkOutcome: .overBudget,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(overBudget.verdict == .cantTell)
        #expect(overBudget.cause == .unclear)

        // 4. Failed read -> cantTell (.unread)
        let failed = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: [],
            walkOutcome: .failed,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(failed.verdict == .cantTell)
        #expect(failed.cause == .unread)

        // 5. Covered origin in side window -> covered
        let covered = ChromiumSiteRead.evaluateSideWindow(
            windowID: 20,
            staticTexts: ["https://bank.com:8443/pip"],
            walkOutcome: .complete,
            rule6Record: nil,
            sites: sites,
            now: 100.0
        )
        #expect(covered.verdict == .covered)
        #expect(covered.host == "bank.com")
    }

    // MARK: - Tab Strip Scheduling On Injected Clock

    final class MockChromiumReader: ChromiumWindowReading, @unchecked Sendable {
        let elements: [CGWindowID: AXUIElement]
        let widByElement: [AXUIElement: CGWindowID]
        let titles = OSAllocatedUnfairLock(initialState: [CGWindowID: String]())
        let docs = OSAllocatedUnfairLock(initialState: [CGWindowID: String]())
        let passDurations = OSAllocatedUnfairLock(initialState: [CGWindowID: TimeInterval]())
        let onPassStart: @Sendable (CGWindowID) -> Void
        let onTitleRead: @Sendable (CGWindowID) -> Void
        var customWalkSideWindow: (@Sendable (AXUIElement, CGWindowID, Int, TimeInterval, @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome))? = nil
        var customWalkTabStrip: (@Sendable (AXUIElement, CGWindowID, Int, TimeInterval, @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome)? = nil
        var customReadTitle: (@Sendable (AXUIElement, CGWindowID) -> String?)? = nil
        var customReadDocument: (@Sendable (AXUIElement, CGWindowID) -> (doc: String?, failed: Bool))? = nil
        var customCopyWindows: (@Sendable (pid_t) -> [AXUIElement]?)? = nil

        init(
            windowIDs: [CGWindowID] = [],
            onPassStart: @escaping @Sendable (CGWindowID) -> Void = { _ in },
            onTitleRead: @escaping @Sendable (CGWindowID) -> Void = { _ in }
        ) {
            var elems: [CGWindowID: AXUIElement] = [:]
            var reverse: [AXUIElement: CGWindowID] = [:]
            for wid in windowIDs {
                let elem = AXUIElementCreateApplication(pid_t(wid + 1000))
                elems[wid] = elem
                reverse[elem] = wid
            }
            self.elements = elems
            self.widByElement = reverse
            self.onPassStart = onPassStart
            self.onTitleRead = onTitleRead
        }

        func copyWindows(for pid: pid_t) -> [AXUIElement]? {
            if let custom = customCopyWindows {
                return custom(pid)
            }
            return Array(elements.values)
        }
        func focusedWindow(for pid: pid_t) -> AXUIElement? {
            elements.values.first
        }
        func windowID(for window: AXUIElement) -> CGWindowID? {
            widByElement[window]
        }
        func readTitle(for window: AXUIElement) -> String? {
            guard let wid = windowID(for: window) else { return nil }
            onTitleRead(wid)
            if let custom = customReadTitle {
                return custom(window, wid)
            }
            return titles.withLock { $0[wid] }
        }
        func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) {
            guard let wid = windowID(for: window) else { return (nil, true) }
            if let custom = customReadDocument {
                return custom(window, wid)
            }
            return (docs.withLock { $0[wid] }, false)
        }
        func walkTabStrip(
            for window: AXUIElement,
            maxNodes: Int = 3000,
            timeoutSeconds: TimeInterval = 0.05,
            nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
        ) -> ChromiumTabStripOutcome {
            guard let wid = windowID(for: window) else { return .failed }
            onPassStart(wid)
            if let custom = customWalkTabStrip {
                return custom(window, wid, maxNodes, timeoutSeconds, nowTicks)
            }
            return .counts(selected: 1, total: 1)
        }
        func walkSideWindow(
            for window: AXUIElement,
            maxNodes: Int = 300,
            timeoutSeconds: TimeInterval = 0.15,
            nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
        ) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
            guard let wid = windowID(for: window) else { return ([], .failed) }
            if let custom = customWalkSideWindow {
                return custom(window, wid, maxNodes, timeoutSeconds, nowTicks)
            }
            return ([], .complete)
        }
    }

    @Test func tabStripSchedulingOnInjectedClock() async throws {
        let windowIDs: [CGWindowID] = Array(1...8)
        let currentTime = OSAllocatedUnfairLock(initialState: 0.005)
        let firstTitleReadTime = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let passesStarted = OSAllocatedUnfairLock(initialState: [CGWindowID]())
        let round1Complete = OneShotContinuationGate()
        let round2Complete = OneShotContinuationGate()
        let round3Complete = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let passDuration = OSAllocatedUnfairLock(initialState: 0.020001)

        let reader = MockChromiumReader(
            windowIDs: windowIDs,
            onPassStart: { wid in
                passesStarted.withLock { $0.append(wid) }
                let dt = passDuration.withLock { $0 }
                currentTime.withLock { $0 += dt }
            },
            onTitleRead: { _ in
                firstTitleReadTime.withLock {
                    if $0 == nil {
                        $0 = currentTime.withLock { $0 }
                    }
                }
            }
        )

        for wid in windowIDs {
            reader.titles.withLock { $0[wid] = "Page \(wid) - Google Chrome" }
            reader.docs.withLock { $0[wid] = "https://example.com/page\(wid)" }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            windowIDs.map {
                SiteVisibleWindow(windowID: $0, pid: 100, layer: 0, title: "Page \($0)")
            }
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { browser, results, startSec, gen in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Complete.release()
                } else if mode == 2 {
                    round2Complete.release()
                } else {
                    round3Complete.release()
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        // 1. Budget test: 8 windows, 20 ms per fake pass.
        // First 5 passes run (0, 20, 40, 60, 80 ms), reaching 100 ms elapsed.
        // No pass starts at or after 100 ms (windows 6, 7, 8 are notRun).
        await sampler.performPollForTesting()
        await round1Complete.wait()

        #expect(firstTitleReadTime.withLock { $0 }! <= 0.010) // first title reads within 10 ms of round start
        let startedR1 = passesStarted.withLock { $0 }
        #expect(startedR1.count == 5)
        #expect(startedR1 == [1, 2, 3, 4, 5])

        // 2. Next round: use 10 ms per fake pass so that remaining windows (6, 7, 8) also complete passes.
        roundMode.withLock { $0 = 2 }
        passDuration.withLock { $0 = 0.010 }
        passesStarted.withLock { $0.removeAll() }
        await sampler.performPollForTesting()
        await round2Complete.wait()

        // 3. Priority test (1 changed + 7 refresh-due):
        // Advance time past 1.0 s refresh threshold.
        // Windows 1...7 are refresh-due. Window 8 has changed title.
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 += 1.5 }
        reader.titles.withLock { $0[8] = "Changed Title - Google Chrome" }
        passesStarted.withLock { $0.removeAll() }

        await sampler.performPollForTesting()
        await round3Complete.wait()

        let startedR3 = passesStarted.withLock { $0 }
        #expect(!startedR3.isEmpty)
        #expect(startedR3.first == 8) // 1 changed window is scheduled first ahead of 7 refresh-due windows!
    }

    // MARK: - AXReadRecorder Allowed Reads

    @Test func axReadRecorderTracksExpectedReads() {
        let recorder = AXReadRecorder()
        let reader = LiveChromiumWindowReader(recorder: recorder)

        let winElem = SendableAX(element: AXUIElementCreateApplication(100))
        let tabElem = SendableAX(element: AXUIElementCreateApplication(101))
        let textElem = SendableAX(element: AXUIElementCreateApplication(102))

        reader.copyAttribute = { element, attr in
            if CFEqual(element, winElem.element) {
                if attr as String == (kAXRoleAttribute as String) {
                    return (.success, kAXWindowRole as CFTypeRef)
                }
                if attr as String == (kAXTitleAttribute as String) {
                    return (.success, "My Title" as CFTypeRef)
                }
                if attr as String == "AXDocument" {
                    return (.success, "https://example.com" as CFTypeRef)
                }
                if attr as String == (kAXChildrenAttribute as String) {
                    return (.success, [tabElem.element, textElem.element] as CFTypeRef)
                }
            } else if CFEqual(element, tabElem.element) {
                if attr as String == (kAXRoleAttribute as String) {
                    return (.success, "AXTabButton" as CFTypeRef)
                }
                if attr as String == (kAXValueAttribute as String) {
                    return (.success, 1 as CFTypeRef)
                }
                if attr as String == (kAXChildrenAttribute as String) {
                    return (.success, [] as CFTypeRef)
                }
            } else if CFEqual(element, textElem.element) {
                if attr as String == (kAXRoleAttribute as String) {
                    return (.success, "AXStaticText" as CFTypeRef)
                }
                if attr as String == (kAXValueAttribute as String) {
                    return (.success, "example.com" as CFTypeRef)
                }
                if attr as String == (kAXChildrenAttribute as String) {
                    return (.success, [] as CFTypeRef)
                }
            }
            return (.noValue, nil)
        }

        _ = reader.readTitle(for: winElem.element)
        _ = reader.readDocument(for: winElem.element)
        _ = reader.walkTabStrip(for: winElem.element, maxNodes: 10, timeoutSeconds: 0.05, nowTicks: { mach_absolute_time() })
        _ = reader.walkSideWindow(for: winElem.element, maxNodes: 10, timeoutSeconds: 0.05, nowTicks: { mach_absolute_time() })

        let reads = recorder.recordedReads
        #expect(!reads.isEmpty)
        #expect(reads.contains(AllowedAXRead(attribute: "AXTitle", role: "AXWindow")))
        #expect(reads.contains(AllowedAXRead(attribute: "AXDocument", role: "AXWindow")))
        #expect(reads.contains(AllowedAXRead(attribute: "AXValue", role: "AXTabButton")))
        #expect(reads.contains(AllowedAXRead(attribute: "AXValue", role: "AXStaticText")))
        #expect(reads.allSatisfy { read in
            if read.attribute == "AXValue" {
                return read.role == "AXTabButton" || read.role == "AXStaticText"
            }
            return true
        })
        #expect(recorder.actionCount == 0)
        #expect(recorder.setCount == 0)
    }

    // MARK: - Item 1 Tests

    @Test func item1TwoPiPSideWindowsStampSecondReadStart() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let roundComplete = OneShotContinuationGate()
        let roundResults = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let roundStart = OSAllocatedUnfairLock<Double>(initialState: 0.0)

        let reader = MockChromiumReader(windowIDs: [1, 2])
        reader.customWalkSideWindow = { _, wid, _, _, _ in
            if wid == 1 {
                currentTime.withLock { $0 += 0.15 }
            }
            return (["example.com"], .complete)
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 1, pid: 100, layer: 3, title: "PiP 1"),
                SiteVisibleWindow(windowID: 2, pid: 100, layer: 3, title: "PiP 2")
            ]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, startSec, _ in
                roundResults.withLock { $0 = results }
                roundStart.withLock { $0 = startSec }
                roundComplete.release()
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await roundComplete.wait()

        let start = roundStart.withLock { $0 }
        let res = roundResults.withLock { $0 }
        let r2 = try! #require(res[2]?.read)
        #expect(r2.readStart >= start + 0.15)
    }

    @Test func item1OpeningTitlesPrecedeSideWalksOnCopyLog() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let roundComplete = OneShotContinuationGate()
        let callLog = OSAllocatedUnfairLock<[String]>(initialState: [])

        let reader = MockChromiumReader(windowIDs: [1, 2])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" } // covered, so no pass due
        reader.customReadTitle = { _, wid in
            callLog.withLock { $0.append("title\(wid)") }
            return "Page \(wid) - Google Chrome"
        }
        reader.customWalkSideWindow = { _, wid, _, _, _ in
            callLog.withLock { $0.append("sideWalk\(wid)") }
            currentTime.withLock { $0 += 0.15 }
            return (["example.com"], .complete)
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1"),
                SiteVisibleWindow(windowID: 2, pid: 100, layer: 3, title: "PiP 2")
            ]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                roundComplete.release()
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await roundComplete.wait()

        let log = callLog.withLock { $0 }
        #expect(log == ["title1", "title1", "sideWalk2"])
    }

    @Test func item1SideReadStartStableAcrossPassAndNoPass() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Complete = OneShotContinuationGate()
        let round2Complete = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round1Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let start1 = OSAllocatedUnfairLock<Double>(initialState: 0.0)
        let start2 = OSAllocatedUnfairLock<Double>(initialState: 0.0)

        let reader = MockChromiumReader(windowIDs: [1, 2])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customWalkTabStrip = { _, wid, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                currentTime.withLock { $0 += 0.080 } // 80 ms pass in round 1
            }
            return .counts(selected: 1, total: 1)
        }
        reader.customWalkSideWindow = { _, wid, _, _, _ in
            ([], .complete)
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1"),
                SiteVisibleWindow(windowID: 2, pid: 100, layer: 3, title: "PiP 2")
            ]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, startSec, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Results.withLock { $0 = results }
                    start1.withLock { $0 = startSec }
                    round1Complete.release()
                } else {
                    round2Results.withLock { $0 = results }
                    start2.withLock { $0 = startSec }
                    round2Complete.release()
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Complete.wait()

        // Round 2: no pass due (carried pass matches)
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 0.5 }
        await sampler.performPollForTesting()
        await round2Complete.wait()

        let r1 = round1Results.withLock { $0[2]!.read }
        let s1 = start1.withLock { $0 }
        let r2 = round2Results.withLock { $0[2]!.read }
        let s2 = start2.withLock { $0 }

        let offset1 = r1.readStart - s1
        let offset2 = r2.readStart - s2
        #expect(abs(offset1 - offset2) < 0.010)
    }

    // MARK: - Item 2 Tests

    @Test func item2NilClosingTitleIsUnread() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let roundComplete = OneShotContinuationGate()
        let roundResults = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        let titleCallCount = OSAllocatedUnfairLock(initialState: 0)
        reader.customReadTitle = { _, wid in
            let count = titleCallCount.withLock {
                $0 += 1
                return $0
            }
            if count == 1 {
                return "Page 1 - Google Chrome"
            }
            return nil // closing title is nil
        }
        reader.customWalkTabStrip = { _, _, _, _, _ in
            .counts(selected: 1, total: 1)
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                roundResults.withLock { $0 = results }
                roundComplete.release()
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await roundComplete.wait()

        let res = roundResults.withLock { $0[1] }!
        #expect(res.read.verdict == .cantTell)
        #expect(res.read.cause == .unread)
    }

    // MARK: - Item 3 Tests

    @Test func item3RoleFailureHidesOneOfTwoSelectedTabs() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let tab1 = SendableAX(element: AXUIElementCreateApplication(101))
        let tab2 = SendableAX(element: AXUIElementCreateApplication(102))

        let liveReader = LiveChromiumWindowReader()
        let failRole = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [tab1.element, tab2.element] as CFTypeRef) }
            } else if CFEqual(element, tab1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, tab2.element) {
                if attr as String == (kAXRoleAttribute as String) {
                    if failRole.withLock({ $0 }) {
                        return (.failure, nil)
                    } else {
                        return (.success, "AXTabButton" as CFTypeRef)
                    }
                }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        // Fixture check: tree has two selected tabs when role succeeds
        failRole.withLock { $0 = false }
        let baseline = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(baseline == .counts(selected: 2, total: 2))

        // When role fails on tab2: walk fails, not counts(selected: 1)
        failRole.withLock { $0 = true }
        let failedOutcome = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(failedOutcome == .failed)
        #expect(failedOutcome != .counts(selected: 1, total: 1))

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 1,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: failedOutcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func item3TabValueFailureHidesOneOfTwoSelectedTabs() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let tab1 = SendableAX(element: AXUIElementCreateApplication(101))
        let tab2 = SendableAX(element: AXUIElementCreateApplication(102))

        let liveReader = LiveChromiumWindowReader()
        let failValue = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [tab1.element, tab2.element] as CFTypeRef) }
            } else if CFEqual(element, tab1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, tab2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) {
                    if failValue.withLock({ $0 }) {
                        return (.cannotComplete, nil)
                    } else {
                        return (.success, 1 as CFTypeRef)
                    }
                }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        failValue.withLock { $0 = false }
        let baseline = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(baseline == .counts(selected: 2, total: 2))

        failValue.withLock { $0 = true }
        let failedOutcome = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(failedOutcome == .failed)
        #expect(failedOutcome != .counts(selected: 1, total: 1))

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 1,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: failedOutcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func item3ChildrenCannotCompleteHidesOneOfTwoSelectedTabs() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let tab1 = SendableAX(element: AXUIElementCreateApplication(101))
        let container = SendableAX(element: AXUIElementCreateApplication(102))
        let tab2 = SendableAX(element: AXUIElementCreateApplication(103))

        let liveReader = LiveChromiumWindowReader()
        let failChildren = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [tab1.element, container.element] as CFTypeRef) }
            } else if CFEqual(element, tab1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, container.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXGroup" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) {
                    if failChildren.withLock({ $0 }) {
                        return (.cannotComplete, nil)
                    } else {
                        return (.success, [tab2.element] as CFTypeRef)
                    }
                }
            } else if CFEqual(element, tab2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        failChildren.withLock { $0 = false }
        let baseline = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(baseline == .counts(selected: 2, total: 2))

        failChildren.withLock { $0 = true }
        let failedOutcome = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(failedOutcome == .failed)
        #expect(failedOutcome != .counts(selected: 1, total: 1))

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluatePageWindow(
            windowID: 1,
            browser: .chrome,
            cgTitle: "Page",
            initialAXTitle: "Page - Google Chrome",
            finalAXTitle: "Page - Google Chrome",
            doc: "https://example.com",
            docReadFailed: false,
            previousCGTitle: nil,
            previousAXTitle: nil,
            tabStripOutcome: failedOutcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func item3TwinChildrenNoValueOrUnsupportedCompletes() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let tab1 = SendableAX(element: AXUIElementCreateApplication(101))
        let tab2 = SendableAX(element: AXUIElementCreateApplication(102))
        let leaf1 = SendableAX(element: AXUIElementCreateApplication(103))
        let leaf2 = SendableAX(element: AXUIElementCreateApplication(104))

        let liveReader = LiveChromiumWindowReader()
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [tab1.element, tab2.element, leaf1.element, leaf2.element] as CFTypeRef) }
            } else if CFEqual(element, tab1.element) || CFEqual(element, tab2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, 1 as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, leaf1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXGroup" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.noValue, nil) }
            } else if CFEqual(element, leaf2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXGroup" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.attributeUnsupported, nil) }
            }
            return (.noValue, nil)
        }

        let outcome = liveReader.walkTabStrip(for: win.element, maxNodes: 10, timeoutSeconds: 0.05)
        #expect(outcome == .counts(selected: 2, total: 2))
    }

    @Test func item3SideRoleFailure() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let text1 = SendableAX(element: AXUIElementCreateApplication(101))
        let text2 = SendableAX(element: AXUIElementCreateApplication(102))

        let liveReader = LiveChromiumWindowReader()
        let failRole = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [text1.element, text2.element] as CFTypeRef) }
            } else if CFEqual(element, text1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXStaticText" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, "example.com" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, text2.element) {
                if attr as String == (kAXRoleAttribute as String) {
                    if failRole.withLock({ $0 }) {
                        return (.failure, nil)
                    } else {
                        return (.success, "AXStaticText" as CFTypeRef)
                    }
                }
                if attr as String == (kAXValueAttribute as String) { return (.success, "bank.com" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        failRole.withLock { $0 = false }
        let baseline = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(baseline.outcome == .complete)
        #expect(baseline.staticTexts.count == 2)

        failRole.withLock { $0 = true }
        let failed = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(failed.outcome == .failed)

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: failed.staticTexts,
            walkOutcome: failed.outcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func item3SideValueFailure() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let text1 = SendableAX(element: AXUIElementCreateApplication(101))
        let text2 = SendableAX(element: AXUIElementCreateApplication(102))

        let liveReader = LiveChromiumWindowReader()
        let failValue = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [text1.element, text2.element] as CFTypeRef) }
            } else if CFEqual(element, text1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXStaticText" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, "example.com" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, text2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXStaticText" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) {
                    if failValue.withLock({ $0 }) {
                        return (.cannotComplete, nil)
                    } else {
                        return (.success, "bank.com" as CFTypeRef)
                    }
                }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        failValue.withLock { $0 = false }
        let baseline = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(baseline.outcome == .complete)
        #expect(baseline.staticTexts.count == 2)

        failValue.withLock { $0 = true }
        let failed = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(failed.outcome == .failed)

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: failed.staticTexts,
            walkOutcome: failed.outcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func item3SideChildrenFailure() {
        let win = SendableAX(element: AXUIElementCreateApplication(100))
        let text1 = SendableAX(element: AXUIElementCreateApplication(101))
        let container = SendableAX(element: AXUIElementCreateApplication(102))
        let text2 = SendableAX(element: AXUIElementCreateApplication(103))

        let liveReader = LiveChromiumWindowReader()
        let failChildren = OSAllocatedUnfairLock(initialState: true)
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, win.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [text1.element, container.element] as CFTypeRef) }
            } else if CFEqual(element, text1.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXStaticText" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, "example.com" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            } else if CFEqual(element, container.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXGroup" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) {
                    if failChildren.withLock({ $0 }) {
                        return (.cannotComplete, nil)
                    } else {
                        return (.success, [text2.element] as CFTypeRef)
                    }
                }
            } else if CFEqual(element, text2.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXStaticText" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) { return (.success, "bank.com" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        failChildren.withLock { $0 = false }
        let baseline = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(baseline.outcome == .complete)
        #expect(baseline.staticTexts.count == 2)

        failChildren.withLock { $0 = true }
        let failed = liveReader.walkSideWindow(for: win.element, maxNodes: 10, timeoutSeconds: 0.15)
        #expect(failed.outcome == .failed)

        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: failed.staticTexts,
            walkOutcome: failed.outcome,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    // MARK: - Item 4 Tests

    @Test func item4InFlightMissIsNotMovedEarlier() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2InFlight = OneShotContinuationGate()
        let round2Proceed = DispatchSemaphore(value: 0)
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let round4Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let inFlightPaused = OSAllocatedUnfairLock(initialState: false)
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let round4Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }
        reader.customReadTitle = { _, wid in
            let shouldPause = inFlightPaused.withLock { p -> Bool in
                if !p && roundMode.withLock({ $0 == 2 }) {
                    p = true
                    return true
                }
                return false
            }
            if shouldPause {
                round2InFlight.release()
                round2Proceed.wait()
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                } else if mode == 4 {
                    round4Results.withLock { $0 = results }
                    round4Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: in flight
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        await sampler.performPollForTesting()
        await round2InFlight.wait()

        // Missed poll at 11.5 while round 2 is in flight -> updates waitStart to 11.5
        currentTime.withLock { $0 = 11.5 }
        await sampler.performPollForTesting()

        // Complete round 2 at 11.8
        currentTime.withLock { $0 = 11.8 }
        round2Proceed.signal()
        await round2Gate.wait()

        // Round 3 at 16.2: ordinary read ("https://example.com").
        // 16.2 is 5.2s after 11.0, but only 4.7s after 11.5. Must stay can't tell!
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 16.2 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[1]!.read }
        #expect(r3.verdict == .cantTell)

        // Round 4 at 21.3: >= 11.5 + 5.0 and >= 16.2 + 5.0 -> becomes ordinary
        roundMode.withLock { $0 = 4 }
        currentTime.withLock { $0 = 21.3 }
        await sampler.performPollForTesting()
        await round4Gate.wait()

        let r4 = round4Results.withLock { $0[1]!.read }
        #expect(r4.verdict == .ordinary)
    }

    @Test func item4ChromeRoundDoesNotTouchEdge() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1, 2])
        reader.titles.withLock {
            $0[1] = "Chrome Window - Google Chrome"
            $0[2] = "Edge Window - Microsoft Edge"
        }
        reader.docs.withLock {
            $0[1] = "https://example.com"
            $0[2] = "https://bank.com" // Edge window covered initially
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = {
            let mode = roundMode.withLock { $0 }
            return (mode == 2) ? [100] : []
        }
        hooks.edgePIDs = {
            let mode = roundMode.withLock { $0 }
            return (mode != 2) ? [200] : []
        }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            let mode = roundMode.withLock { $0 }
            if mode == 2 {
                return [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Chrome Window")]
            } else {
                return [SiteVisibleWindow(windowID: 2, pid: 200, layer: 0, title: "Edge Window")]
            }
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { browser, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                }
            }
        )

        // Round 1 at 10.0: Edge window reads covered -> wait starts for Edge window 2
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: Chrome round only, reads ordinary
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 12.0: Edge round, reads ordinary ("https://example.com").
        // Since wait for Edge was not cleared by Chrome, Edge stays can't tell!
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 12.0 }
        reader.docs.withLock { $0[2] = "https://example.com" }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[2]!.read }
        #expect(r3.verdict == .cantTell)
    }

    @Test func item4LateCoveredStartsLaterWait() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let round4Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let round4Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }
        reader.customReadTitle = { _, wid in
            let mode = roundMode.withLock { $0 }
            if mode == 2 {
                // Round 2 finishes late at 12.0 (> 11.0 + 0.5s deadline)
                currentTime.withLock { $0 = 12.0 }
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                } else if mode == 4 {
                    round4Results.withLock { $0 = results }
                    round4Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: late covered read finishes at 12.0 -> starts wait later at 12.0
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 15.5: ordinary read ("https://example.com").
        // 15.5 is 5.5s after 10.0, but only 3.5s after 12.0. Must stay can't tell!
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 15.5 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[1]!.read }
        #expect(r3.verdict == .cantTell)

        // Round 4 at 20.6: >= 12.0 + 5.0 and >= 15.5 + 5.0 -> becomes ordinary
        roundMode.withLock { $0 = 4 }
        currentTime.withLock { $0 = 20.6 }
        await sampler.performPollForTesting()
        await round4Gate.wait()

        let r4 = round4Results.withLock { $0[1]!.read }
        #expect(r4.verdict == .ordinary)
    }

    @Test func item4OrdinaryResumesFiveSecondsAfterMiss() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3InFlight = OneShotContinuationGate()
        let round3Proceed = DispatchSemaphore(value: 0)
        let round3Gate = OneShotContinuationGate()
        let round4Gate = OneShotContinuationGate()
        let round5Gate = OneShotContinuationGate()
        let round6Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let inFlightPaused = OSAllocatedUnfairLock(initialState: false)
        let round5Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let round6Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }
        reader.customReadTitle = { _, wid in
            let shouldPause = inFlightPaused.withLock { p -> Bool in
                if !p && roundMode.withLock({ $0 == 3 }) {
                    p = true
                    return true
                }
                return false
            }
            if shouldPause {
                round3InFlight.release()
                round3Proceed.wait()
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Gate.release()
                } else if mode == 4 {
                    round4Gate.release()
                } else if mode == 5 {
                    round5Results.withLock { $0 = results }
                    round5Gate.release()
                } else if mode == 6 {
                    round6Results.withLock { $0 = results }
                    round6Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 13.0: 3s later, ordinary read -> firstOrdinaryAt = 13.0
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 13.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 13.5: in flight, missed poll arrives at 14.0 -> waitStart = 14.0, firstOrdinaryAt = nil
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 13.5 }
        await sampler.performPollForTesting()
        await round3InFlight.wait()

        currentTime.withLock { $0 = 14.0 }
        await sampler.performPollForTesting() // miss at 14.0

        round3Proceed.signal()
        await round3Gate.wait()

        // Round 4 at 15.0: first ordinary read after miss -> firstOrdinaryAt = 15.0
        roundMode.withLock { $0 = 4 }
        currentTime.withLock { $0 = 15.0 }
        await sampler.performPollForTesting()
        await round4Gate.wait()

        // Round 5 at 19.5: 5.5s after miss (14.0), but only 4.5s after first ordinary (15.0). Must stay can't tell!
        roundMode.withLock { $0 = 5 }
        currentTime.withLock { $0 = 19.5 }
        await sampler.performPollForTesting()
        await round5Gate.wait()

        let r5 = round5Results.withLock { $0[1]!.read }
        #expect(r5.verdict == .cantTell)

        // Round 6 at 20.1: >= 15.0 + 5.0 -> becomes ordinary
        roundMode.withLock { $0 = 6 }
        currentTime.withLock { $0 = 20.1 }
        await sampler.performPollForTesting()
        await round6Gate.wait()

        let r6 = round6Results.withLock { $0[1]!.read }
        #expect(r6.verdict == .ordinary)
    }

    @Test func item4TwinUnrestartedWaitClearsWithinOneRound() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: first ordinary read -> firstOrdinaryAt = 11.0
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 16.1: 5.1s after first ordinary (within 5s + one 1.0s round) -> becomes ordinary
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 16.1 }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[1]!.read }
        #expect(r3.verdict == .ordinary)
    }

    @Test func item4LateOrdinaryRoundRestartsAndCountsAMiss() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let round4Gate = OneShotContinuationGate()
        let round5Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round5Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }
        reader.customReadTitle = { _, wid in
            let mode = roundMode.withLock { $0 }
            if mode == 3 {
                // Round 3 finishes late at 13.0 (> 12.0 + 0.5s deadline)
                currentTime.withLock { $0 = 13.0 }
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Gate.release()
                } else if mode == 4 {
                    round4Gate.release()
                } else if mode == 5 {
                    round5Results.withLock { $0 = results }
                    round5Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: first ordinary read -> firstOrdinaryAt = 11.0
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 12.0: late round finishes at 13.0 -> restarts wait at 13.0, firstOrdinaryAt = nil
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 12.0 }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        // Round 4 at 14.0: first ordinary read after restart -> firstOrdinaryAt = 14.0
        roundMode.withLock { $0 = 4 }
        currentTime.withLock { $0 = 14.0 }
        await sampler.performPollForTesting()
        await round4Gate.wait()

        // Round 5 at 16.5: 2.5s after 14.0. Must stay can't tell!
        roundMode.withLock { $0 = 5 }
        currentTime.withLock { $0 = 16.5 }
        await sampler.performPollForTesting()
        await round5Gate.wait()

        let r5 = round5Results.withLock { $0[1]!.read }
        #expect(r5.verdict == .cantTell)
    }

    @Test func item4TwinListAddsRememberedHostWhileRoundReadsOtherHost() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2InFlight = OneShotContinuationGate()
        let round2Proceed = DispatchSemaphore(value: 0)
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let inFlightPaused = OSAllocatedUnfairLock(initialState: false)
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" } // Host H
        reader.customReadTitle = { _, wid in
            let shouldPause = inFlightPaused.withLock { p -> Bool in
                if !p && roundMode.withLock({ $0 == 2 }) {
                    p = true
                    return true
                }
                return false
            }
            if shouldPause {
                round2InFlight.release()
                round2Proceed.wait()
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                }
            }
        )

        // Round 1 at 10.0: list is empty. Reads "bank.com" (remembered).
        await sampler.applySites([], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: in flight reading host G ("example.com").
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2InFlight.wait()

        // List adds "bank.com" (generation 2) before round 2 completes
        await sampler.applySites(["bank.com"], generation: 2)

        round2Proceed.signal()
        await round2Gate.wait()

        // Round 3 at 12.0: reads host G ("example.com").
        // Since H was remembered and became covered, window has rule-6 record. G stays can't tell!
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 12.0 }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[1]!.read }
        #expect(r3.verdict == .cantTell)
    }

    @Test func item4FailedPassOrTornCloseDropsCarriedResult() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        let titleCallCount = OSAllocatedUnfairLock(initialState: 0)
        reader.customReadTitle = { _, wid in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                let count = titleCallCount.withLock {
                    $0 += 1
                    return $0
                }
                if count == 1 {
                    return "Page A - Google Chrome"
                } else {
                    return "Page B - Google Chrome" // differing closing title in round 1
                }
            }
            return "Page A - Google Chrome"
        }
        reader.customWalkTabStrip = { _, _, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                return .counts(selected: 1, total: 1)
            } else {
                return .notRun // pass does not run in round 2
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                }
            }
        )

        // Round 1: torn close title drops carried result
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: pass does not run. Since carried result was dropped, verdict is can't tell
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let r2 = round2Results.withLock { $0[1]!.read }
        #expect(r2.verdict == .cantTell)
    }

    // MARK: - Item 5 Tests

    @Test func item5InFlightHostBecomesCovered() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1InFlight = OneShotContinuationGate()
        let round1Proceed = DispatchSemaphore(value: 0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let inFlightPaused = OSAllocatedUnfairLock(initialState: false)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" } // Host H
        reader.customReadTitle = { _, wid in
            let shouldPause = inFlightPaused.withLock { p -> Bool in
                if !p && roundMode.withLock({ $0 == 1 }) {
                    p = true
                    return true
                }
                return false
            }
            if shouldPause {
                round1InFlight.release()
                round1Proceed.wait()
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                }
            }
        )

        // Round 1 at 10.0: starts with empty list
        await sampler.applySites([], generation: 1)
        await sampler.performPollForTesting()
        await round1InFlight.wait()

        // List adds "bank.com" before round 1 completes
        await sampler.applySites(["bank.com"], generation: 2)

        round1Proceed.signal()
        await round1Gate.wait()

        // Round 2 at 11.0: reads ordinary "https://example.com".
        // Wait started because in-flight host became covered. Next ordinary reads stay can't tell!
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let r2 = round2Results.withLock { $0[1]!.read }
        #expect(r2.verdict == .cantTell)
    }

    // MARK: - Item 8 Tests

    @Test func sustainedSplitViewThroughTheSamplerRaisesNoCaution() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let cautionState = OSAllocatedUnfairLock(initialState: false)
        let verdicts = OSAllocatedUnfairLock(initialState: [ChromiumVerdict]())
        let roundGate = OSAllocatedUnfairLock<OneShotContinuationGate?>(initialState: nil)

        // Split view: an inserted title phrase and two selected tabs. Read correctly, found unclear.
        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customReadTitle = { _, _ in "Page 1 - Left view - Google Chrome" }
        reader.customWalkTabStrip = { _, _, _, _, _ in .counts(selected: 2, total: 4) }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                verdicts.withLock { v in v.append(contentsOf: results.values.map(\.read.verdict)) }
                roundGate.withLock { $0?.release() }
            },
            onChromiumCautionUpdate: { browser, caution in
                if browser == .chrome {
                    cautionState.withLock { $0 = caution }
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        for _ in 1...12 {
            let gate = OneShotContinuationGate()
            roundGate.withLock { $0 = gate }
            currentTime.withLock { $0 += 1.0 }
            await sampler.performPollForTesting()
            await gate.wait()
        }

        // Every read is can't tell, so frames drop, but none of them counts toward caution.
        #expect(verdicts.withLock { $0 }.count == 12)
        #expect(verdicts.withLock { $0 }.allSatisfy { $0 == .cantTell })
        #expect(cautionState.withLock { $0 } == false)
    }

    @Test func item8TenFailedTitlesRaiseCaution() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let cautionState = OSAllocatedUnfairLock(initialState: false)
        let roundGate = OSAllocatedUnfairLock<OneShotContinuationGate?>(initialState: nil)

        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customReadTitle = { _, _ in nil } // Title read fails (returns nil)

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                roundGate.withLock { $0?.release() }
            },
            onChromiumCautionUpdate: { browser, caution in
                if browser == .chrome {
                    cautionState.withLock { $0 = caution }
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        for i in 1...10 {
            let gate = OneShotContinuationGate()
            roundGate.withLock { $0 = gate }
            currentTime.withLock { $0 += 1.0 }
            await sampler.performPollForTesting()
            await gate.wait()

            print("iteration \(i), caution: \(cautionState.withLock { $0 })")
            if i < 10 {
                #expect(cautionState.withLock { $0 } == false)
            }
        }

        #expect(cautionState.withLock { $0 } == true)
    }

    @Test func item8TwinNineFailuresThenCompleteDoesNot() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let cautionState = OSAllocatedUnfairLock(initialState: false)
        let roundGate = OSAllocatedUnfairLock<OneShotContinuationGate?>(initialState: nil)
        let roundCount = OSAllocatedUnfairLock(initialState: 0)

        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customReadTitle = { _, _ in
            let count = roundCount.withLock { $0 }
            if count <= 9 {
                return nil
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                roundGate.withLock { $0?.release() }
            },
            onChromiumCautionUpdate: { browser, caution in
                if browser == .chrome {
                    cautionState.withLock { $0 = caution }
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        for _ in 1...10 {
            let gate = OneShotContinuationGate()
            roundGate.withLock { $0 = gate }
            roundCount.withLock { $0 += 1 }
            currentTime.withLock { $0 += 1.0 }
            await sampler.performPollForTesting()
            await gate.wait()
            #expect(cautionState.withLock { $0 } == false)
        }
    }

    @Test func item8NineFailuresThenLateRoundRaisesCaution() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let cautionState = OSAllocatedUnfairLock(initialState: false)
        let roundGate = OSAllocatedUnfairLock<OneShotContinuationGate?>(initialState: nil)
        let roundCount = OSAllocatedUnfairLock(initialState: 0)

        let reader = MockChromiumReader(windowIDs: [1])
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customReadTitle = { _, _ in
            let count = roundCount.withLock { $0 }
            if count <= 9 {
                return nil
            }
            // Round 10: complete title, but late (> 0.5s)
            currentTime.withLock { $0 += 0.6 }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                roundGate.withLock { $0?.release() }
            },
            onChromiumCautionUpdate: { browser, caution in
                if browser == .chrome {
                    cautionState.withLock { $0 = caution }
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        for i in 1...10 {
            let gate = OneShotContinuationGate()
            roundGate.withLock { $0 = gate }
            roundCount.withLock { $0 += 1 }
            currentTime.withLock { $0 += 1.0 }
            await sampler.performPollForTesting()
            await gate.wait()

            print("iteration \(i), caution: \(cautionState.withLock { $0 })")
            if i < 10 {
                #expect(cautionState.withLock { $0 } == false)
            }
        }

        #expect(cautionState.withLock { $0 } == true)
    }

    @Test func item8TimedOutSideWalkCounts() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let cautionState = OSAllocatedUnfairLock(initialState: false)
        let roundGate = OSAllocatedUnfairLock<OneShotContinuationGate?>(initialState: nil)

        let reader = MockChromiumReader(windowIDs: [1])
        reader.customWalkSideWindow = { _, _, _, _, _ in
            ([], .timedOut)
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 3, title: "PiP")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                roundGate.withLock { $0?.release() }
            },
            onChromiumCautionUpdate: { browser, caution in
                if browser == .chrome {
                    cautionState.withLock { $0 = caution }
                }
            }
        )

        await sampler.applySites(["bank.com"], generation: 1)

        for i in 1...10 {
            let gate = OneShotContinuationGate()
            roundGate.withLock { $0 = gate }
            currentTime.withLock { $0 += 1.0 }
            await sampler.performPollForTesting()
            await gate.wait()

            print("iteration \(i), caution: \(cautionState.withLock { $0 })")
            if i < 10 {
                #expect(cautionState.withLock { $0 } == false)
            }
        }

        #expect(cautionState.withLock { $0 } == true)
    }

    // MARK: - Item 9 Tests

    @Test func item9MissAfterWaitEndedDoesNotStartWait() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let round4InFlight = OneShotContinuationGate()
        let round4Proceed = DispatchSemaphore(value: 0)
        let round4Gate = OneShotContinuationGate()
        let round5Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let inFlightPaused = OSAllocatedUnfairLock(initialState: false)
        let round5Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://bank.com" }
        reader.customReadTitle = { _, wid in
            let shouldPause = inFlightPaused.withLock { p -> Bool in
                if !p && roundMode.withLock({ $0 == 4 }) {
                    p = true
                    return true
                }
                return false
            }
            if shouldPause {
                round4InFlight.release()
                round4Proceed.wait()
            }
            return "Page 1 - Google Chrome"
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Gate.release()
                } else if mode == 3 {
                    round3Gate.release()
                } else if mode == 4 {
                    round4Gate.release()
                } else if mode == 5 {
                    round5Results.withLock { $0 = results }
                    round5Gate.release()
                }
            }
        )

        // Round 1 at 10.0: covered -> wait starts at 10.0
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2 at 11.0: first ordinary read -> firstOrdinaryAt = 11.0
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 = 11.0 }
        reader.docs.withLock { $0[1] = "https://example.com" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Round 3 at 16.1: wait ends at 16.0 (11.0 + 5.0) -> ordinary read clears rule-6 record
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 = 16.1 }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        // Round 4 at 17.0: a missed poll occurs while round is in flight
        roundMode.withLock { $0 = 4 }
        currentTime.withLock { $0 = 17.0 }
        await sampler.performPollForTesting()
        await round4InFlight.wait()

        currentTime.withLock { $0 = 17.2 }
        await sampler.performPollForTesting() // Missed poll

        round4Proceed.signal()
        await round4Gate.wait()

        // Round 5 at 18.0: ordinary read. Miss did not restart wait because wait had ended!
        roundMode.withLock { $0 = 5 }
        currentTime.withLock { $0 = 18.0 }
        await sampler.performPollForTesting()
        await round5Gate.wait()

        let r5 = round5Results.withLock { $0[1]!.read }
        #expect(r5.verdict == .ordinary)
    }

    // MARK: - Item 10 Tests

    @Test func item10SevenRefreshDueTwoKeptByCarriedResult() async {
        let windowIDs: [CGWindowID] = Array(1...7)
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(
            windowIDs: windowIDs,
            onPassStart: { _ in }
        )
        for wid in windowIDs {
            reader.titles.withLock { $0[wid] = "Page \(wid) - Google Chrome" }
            reader.docs.withLock { $0[wid] = "https://example.com/page\(wid)" }
        }
        reader.customWalkTabStrip = { _, wid, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                return .counts(selected: 1, total: 1)
            } else {
                // In round 2, each pass takes 0.020001s. After 5 passes (0.100005s), budget is exhausted.
                currentTime.withLock { $0 += 0.020001 }
                return .counts(selected: 1, total: 1)
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            windowIDs.map {
                SiteVisibleWindow(windowID: $0, pid: 100, layer: 0, title: "Page \($0)")
            }
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                }
            }
        )

        // Round 1: all 7 complete passes and get carried results
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Advance 1.5s so all 7 are refresh-due (> 1.0s)
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 1.5 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        // Windows 6 and 7 did not get passes, but keep their matching carried results and read ordinary
        let res = round2Results.withLock { $0 }
        #expect(res[6]?.read.verdict == .ordinary)
        #expect(res[7]?.read.verdict == .ordinary)
    }

    @Test func item10ShortBudgetRealWalkKeepsCarriedResult() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let round3Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])
        let round3Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let winElem = SendableAX(element: AXUIElementCreateApplication(101))
        let tabElem = SendableAX(element: AXUIElementCreateApplication(102))

        let liveReader = LiveChromiumWindowReader()
        liveReader.copyAttribute = { element, attr in
            if CFEqual(element, winElem.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXWindow" as CFTypeRef) }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [tabElem.element] as CFTypeRef) }
            } else if CFEqual(element, tabElem.element) {
                if attr as String == (kAXRoleAttribute as String) { return (.success, "AXTabButton" as CFTypeRef) }
                if attr as String == (kAXValueAttribute as String) {
                    let mode = roundMode.withLock { $0 }
                    if mode == 2 {
                        // Advance clock by 0.040s so that short budget (0.035s) times out
                        currentTime.withLock { $0 += 0.040 }
                    }
                    return (.success, 1 as CFTypeRef)
                }
                if attr as String == (kAXChildrenAttribute as String) { return (.success, [] as CFTypeRef) }
            }
            return (.noValue, nil)
        }

        let reader = MockChromiumReader(windowIDs: [1, 2])
        reader.titles.withLock {
            $0[1] = "Page 1 - Google Chrome"
            $0[2] = "Page 2 - Google Chrome"
        }
        reader.docs.withLock {
            $0[1] = "https://example.com/1"
            $0[2] = "https://example.com/2"
        }
        reader.customWalkTabStrip = { _, wid, maxNodes, timeoutSec, nowTicks in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                return .counts(selected: 1, total: 1)
            } else if mode == 2 {
                if wid == 2 {
                    // Window 2 takes 0.065s, leaving 0.035s (< 0.050s) for window 1
                    currentTime.withLock { $0 += 0.065 }
                    return .counts(selected: 1, total: 1)
                } else {
                    // Window 1 runs real walk under short budget
                    return liveReader.walkTabStrip(for: winElem.element, maxNodes: maxNodes, timeoutSeconds: timeoutSec, nowTicks: nowTicks)
                }
            } else {
                return .notRun
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 2, pid: 100, layer: 0, title: "Page 2"),
                SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")
            ]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else if mode == 2 {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                } else {
                    round3Results.withLock { $0 = results }
                    round3Gate.release()
                }
            }
        )

        // Round 1: pass completes and carried result is stored
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: window 1 starts with under 50 ms budget left and times out (.budgetCut). Carried result kept -> ordinary
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 1.5 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let r2 = round2Results.withLock { $0[1]!.read }
        #expect(r2.verdict == .ordinary)

        // Round 3: pass does not run (.notRun). Carried result is still held -> ordinary
        roundMode.withLock { $0 = 3 }
        currentTime.withLock { $0 += 1.5 }
        await sampler.performPollForTesting()
        await round3Gate.wait()

        let r3 = round3Results.withLock { $0[1]!.read }
        #expect(r3.verdict == .ordinary)
    }

    @Test func item10TwinNotRunMismatchedKeyIsCantTell() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page A - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://example.com/a" }
        reader.customWalkTabStrip = { _, _, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                return .counts(selected: 1, total: 1)
            } else {
                return .notRun // pass does not run in round 2
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                }
            }
        )

        // Round 1: carried result for Page A
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: title changes to Page B, pass does not run (.notRun). Key differs -> can't tell
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 1.5 }
        reader.titles.withLock { $0[1] = "Page B - Google Chrome" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let r2 = round2Results.withLock { $0[1]!.read }
        #expect(r2.verdict == .cantTell)
    }

    @Test func item10TwinFullBudgetTimeoutIsCantTell() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let round2Results = OSAllocatedUnfairLock<[CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)]>(initialState: [:])

        let reader = MockChromiumReader(windowIDs: [1])
        reader.titles.withLock { $0[1] = "Page 1 - Google Chrome" }
        reader.docs.withLock { $0[1] = "https://example.com" }
        reader.customWalkTabStrip = { _, _, _, timeoutSec, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                return .counts(selected: 1, total: 1)
            } else {
                // Given full 50 ms (timeoutSec >= 0.050), times out -> .timedOut
                currentTime.withLock { $0 += 0.055 }
                return .timedOut
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1")]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, results, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Results.withLock { $0 = results }
                    round2Gate.release()
                }
            }
        )

        // Round 1: pass completes
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: full budget timeout -> can't tell
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 1.5 }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let r2 = round2Results.withLock { $0[1]!.read }
        #expect(r2.verdict == .cantTell)
    }

    @Test func item10FullTimeoutsDoNotBlockChangedWindow() async {
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let passesStartedRound2 = OSAllocatedUnfairLock<[CGWindowID]>(initialState: [])

        let reader = MockChromiumReader(
            windowIDs: [1, 2, 3],
            onPassStart: { wid in
                let mode = roundMode.withLock { $0 }
                if mode == 2 {
                    passesStartedRound2.withLock { $0.append(wid) }
                }
            }
        )
        for wid: CGWindowID in [1, 2, 3] {
            reader.titles.withLock { $0[wid] = "Page \(wid) - Google Chrome" }
            reader.docs.withLock { $0[wid] = "https://example.com/page\(wid)" }
        }
        reader.customWalkTabStrip = { _, wid, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                if wid == 1 || wid == 2 {
                    return .timedOut
                }
                return .counts(selected: 1, total: 1)
            } else {
                return .counts(selected: 1, total: 1)
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 1, pid: 100, layer: 0, title: "Page 1"),
                SiteVisibleWindow(windowID: 2, pid: 100, layer: 0, title: "Page 2"),
                SiteVisibleWindow(windowID: 3, pid: 100, layer: 0, title: "Page 3")
            ]
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Gate.release()
                }
            }
        )

        // Round 1: windows 1 and 2 time out on 50 ms
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: window 3 changes title
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 0.5 }
        reader.titles.withLock { $0[3] = "Changed Page 3 - Google Chrome" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let started = passesStartedRound2.withLock { $0 }
        #expect(started.contains(CGWindowID(3)))
    }

    @Test func item10ChangedWindowRunsBeforeNotRunPasses() async {
        let windowIDs: [CGWindowID] = Array(1...6)
        let currentTime = OSAllocatedUnfairLock(initialState: 10.0)
        let round1Gate = OneShotContinuationGate()
        let round2Gate = OneShotContinuationGate()
        let roundMode = OSAllocatedUnfairLock(initialState: 1)
        let passesStartedRound2 = OSAllocatedUnfairLock<[CGWindowID]>(initialState: [])

        let reader = MockChromiumReader(
            windowIDs: windowIDs,
            onPassStart: { wid in
                let mode = roundMode.withLock { $0 }
                if mode == 2 {
                    passesStartedRound2.withLock { $0.append(wid) }
                }
            }
        )
        for wid in windowIDs {
            reader.titles.withLock { $0[wid] = "Page \(wid) - Google Chrome" }
            reader.docs.withLock { $0[wid] = "https://example.com/page\(wid)" }
        }
        reader.customWalkTabStrip = { _, wid, _, _, _ in
            let mode = roundMode.withLock { $0 }
            if mode == 1 {
                // Window 1 consumes entire budget so windows 2..6 are not run
                if wid == 1 {
                    currentTime.withLock { $0 += 0.100001 }
                }
                return .counts(selected: 1, total: 1)
            } else {
                return .counts(selected: 1, total: 1)
            }
        }

        var hooks = SiteSamplerHooks()
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.safariPIDs = { [] }
        hooks.pipPIDs = { [] }
        hooks.nowTicks = { Self.makeTicks(fromSeconds: currentTime.withLock { $0 }) }
        hooks.copyOnScreen = {
            windowIDs.map {
                SiteVisibleWindow(windowID: $0, pid: 100, layer: 0, title: "Page \($0)")
            }
        }
        hooks.chromiumReader = reader

        let sampler = SiteSampler(
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { _, _, _, _ in
                let mode = roundMode.withLock { $0 }
                if mode == 1 {
                    round1Gate.release()
                } else {
                    round2Gate.release()
                }
            }
        )

        // Round 1: leaves windows 2..6 not run
        await sampler.applySites(["bank.com"], generation: 1)
        await sampler.performPollForTesting()
        await round1Gate.wait()

        // Round 2: window 6 has changed title
        roundMode.withLock { $0 = 2 }
        currentTime.withLock { $0 += 0.5 }
        reader.titles.withLock { $0[6] = "New Title 6 - Google Chrome" }
        await sampler.performPollForTesting()
        await round2Gate.wait()

        let started = passesStartedRound2.withLock { $0 }
        #expect(started.first == CGWindowID(6))
    }

    // MARK: - Item 14 Tests

    @Test func item14PunycodeSideWindowIsCovered() {
        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: ["bücher.de"],
            walkOutcome: .complete,
            rule6Record: &rule6,
            sites: ["xn--bcher-kva.de"],
            now: 100.0
        )
        #expect(eval.verdict == .covered)
        #expect(eval.host == "xn--bcher-kva.de")
    }

    @Test func item14FailedNormalizationIsCantTell() {
        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: ["http://[invalid-host", "example.com"],
            walkOutcome: .complete,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .cantTell)
    }

    @Test func sideWindowDottedTextThatIsNotAnAddressStaysOrdinary() {
        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: ["1.5x", "Loading...", "0:15", "example.com"],
            walkOutcome: .complete,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .ordinary)
        #expect(eval.host == "example.com")
    }

    @Test func sideWindowPunycodeTopLevelDomainIsAnAddress() {
        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: ["xn--e1afmkfd.xn--p1ai"],
            walkOutcome: .complete,
            rule6Record: &rule6,
            sites: ["xn--e1afmkfd.xn--p1ai"],
            now: 100.0
        )
        #expect(eval.verdict == .covered)
    }

    @Test func item14TwinBareExampleIsOrdinary() {
        var rule6: ChromiumRule6Record? = nil
        let eval = ChromiumSiteRead.evaluateSideWindow(
            windowID: 1,
            staticTexts: ["example.com"],
            walkOutcome: .complete,
            rule6Record: &rule6,
            sites: ["bank.com"],
            now: 100.0
        )
        #expect(eval.verdict == .ordinary)
        #expect(eval.host == "example.com")
    }
}
