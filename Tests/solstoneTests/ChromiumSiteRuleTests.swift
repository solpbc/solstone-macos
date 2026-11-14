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
        let rule6 = ChromiumRule6Record(waitStart: 100.0, host: "bank.com")

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
            rule6Record: rule6,
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
            rule6Record: rule6,
            sites: ["bank.com"],
            now: 104.5
        )
        #expect(eval4_5s.verdict == .cantTell)
        #expect(eval4_5s.cause == .unclear)

        // Clears at 5.5 s
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
            rule6Record: rule6,
            sites: ["bank.com"],
            now: 105.5
        )
        #expect(eval5_5s.verdict == .ordinary)
        #expect(eval5_5s.host == "example.com")
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

        // 3. Ordinary at 5 s clears (at 109.7 >= 104.6 + 5.0)
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
            now: 109.7
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

    @Test func listGenerationAndHostOnlyStorage() {
        // Pass result stores host only: no url, path, query
        let pass = ChromiumPassResult(
            axTitle: "Inbox - Google Chrome",
            docHash: 12345,
            host: "mail.google.com",
            time: 100.0,
            selectedTabCount: 1,
            totalTabCount: 5
        )
        #expect(pass.host == "mail.google.com")

        // Rule 6 record stores host only: no url, path, query, file path, or data body
        let r6 = ChromiumRule6Record(waitStart: 100.0, host: "bank.com")
        #expect(r6.host == "bank.com")

        // Activity with generation change: snap.listGeneration < currentGeneration
        var snapshot = ChromiumActivitySnapshot()
        snapshot.currentGeneration = 2
        let snap = ChromiumActivityWindowSnapshot(
            verdict: .ordinary,
            host: "example.com",
            start: 100.0,
            listGeneration: 1 // older generation
        )
        snapshot.latestCompleteRead[10] = snap
        snapshot.latestAXTitle[10] = "Secret Page - Google Chrome"
        snapshot.latestCGTitle[10] = "Secret Page"

        #expect(snap.listGeneration == 1)
        #expect(snapshot.currentGeneration == 2)
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

        init(
            windowIDs: [CGWindowID],
            onPassStart: @escaping @Sendable (CGWindowID) -> Void,
            onTitleRead: @escaping @Sendable (CGWindowID) -> Void
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
            Array(elements.values)
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
            return titles.withLock { $0[wid] }
        }
        func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) {
            guard let wid = windowID(for: window) else { return (nil, true) }
            return (docs.withLock { $0[wid] }, false)
        }
        func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval) -> ChromiumTabStripOutcome {
            guard let wid = windowID(for: window) else { return .failed }
            onPassStart(wid)
            return .counts(selected: 1, total: 1)
        }
        func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
            ([], .complete)
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
        recorder.recordRead(attribute: "AXDocument", role: "AXWindow")
        recorder.recordRead(attribute: "AXTitle", role: "AXWindow")
        recorder.recordRead(attribute: "AXValue", role: "AXTabButton")
        recorder.recordRead(attribute: "AXValue", role: "AXStaticText")

        #expect(recorder.recordedReads.contains(AllowedAXRead(attribute: "AXDocument", role: "AXWindow")))
        #expect(recorder.recordedReads.contains(AllowedAXRead(attribute: "AXTitle", role: "AXWindow")))
        #expect(recorder.recordedReads.allSatisfy { read in
            if read.attribute == "AXValue" {
                return read.role == "AXTabButton" || read.role == "AXStaticText"
            }
            return true
        })
        #expect(recorder.actionCount == 0)
        #expect(recorder.setCount == 0)
    }
}
