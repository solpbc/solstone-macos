// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os
import Testing
@testable import solstone

@Suite("FirefoxSiteRule")
struct FirefoxSiteRuleTests {
    // MARK: - Fixtures

    static let window = CGRect(x: 0, y: 25, width: 1440, height: 965)
    static let content = CGRect(x: 40, y: 125, width: 1400, height: 865)
    static let sidebar = CGRect(x: 40, y: 188, width: 339, height: 802)

    static func tab(_ url: String?, frame: CGRect = content, panel: Int = 0) -> FirefoxWebArea {
        FirefoxWebArea(url: url, frame: frame, tabPanel: panel)
    }

    static func other(_ url: String?, frame: CGRect = sidebar) -> FirefoxWebArea {
        FirefoxWebArea(url: url, frame: frame, tabPanel: nil)
    }

    static func read(
        _ areas: [FirefoxWebArea],
        cg: String = "News",
        opening: String? = "News",
        closing: String? = "News",
        outcome: FirefoxWalkResult.Outcome = .complete,
        frame: CGRect? = window
    ) -> FirefoxSiteRead.PageRead {
        FirefoxSiteRead.PageRead(cgTitle: cg, openingTitle: opening, closingTitle: closing,
                                 walk: FirefoxWalkResult(areas: areas, outcome: outcome), windowFrame: frame)
    }

    static func verdict(
        _ read: FirefoxSiteRead.PageRead,
        sites: [String] = ["bank.example"],
        prevCG: String? = nil,
        prevAX: String? = nil,
        prevURL: String? = nil
    ) -> ChromiumPageEvaluation {
        var r6: ChromiumRule6Record?
        return FirefoxSiteRead.evaluatePageWindow(read, previousCGTitle: prevCG, previousAXTitle: prevAX,
                                                 previousOrdinaryURL: prevURL, rule6Record: &r6, sites: sites, now: 10).evaluation
    }

    static func value(_ url: String, tab: Bool = true, sites: [String] = ["bank.example"]) -> FirefoxSiteRead.Value {
        FirefoxSiteRead.value(of: url, inTabArea: tab, sites: sites)
    }

    // MARK: - Values

    @Test func readerViewOfACoveredPageIsCovered() {
        #expect(Self.value("about:reader?url=https%3A%2F%2Fbank.example%2Fx") == .covered(host: "bank.example"))
        #expect(SiteRule.normalizeReadHost("about:reader?url=https%3A%2F%2Fbank.example%2Fx") == "bank.example")
        #expect(Self.value("about:reader?url=http%3A%2F%2Fwiki.localhost%3A8771%2Fstatic%2Farticle.html") == .ordinary(host: "wiki.localhost"))
    }

    @Test func readerViewWithoutAPageIsCantTell() {
        #expect(Self.value("about:reader") == .cantTell)
        #expect(Self.value("about:reader?foo=bar") == .cantTell)
        #expect(Self.value("about:reader?url=") == .cantTell)
        #expect(SiteRule.normalizeReadHost("about:reader") == nil)
    }

    @Test func readerViewUnwrapsOnce() {
        let nested = "about:reader?url=" + "about:reader?url=https://bank.example/".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(Self.value(nested) == .cantTell)
        #expect(SiteRule.normalizeReadHost(nested) == nil)
    }

    @Test func aboutBlankWithAFragmentIsCantTell() {
        #expect(Self.value("about:blank#x") == .cantTell)
        #expect(Self.value("about:blank") == .cantTell)
        #expect(Self.value("about:srcdoc") == .cantTell)
    }

    @Test func firefoxOwnPagesAndNonWebsitesAreOrdinary() {
        #expect(Self.value("about:preferences") == .ordinary(host: nil))
        #expect(Self.value("about:preferences#privacy") == .ordinary(host: nil))
        #expect(Self.value("about:newtab") == .ordinary(host: nil))
        #expect(Self.value("about:support?x=1") == .ordinary(host: nil))
        #expect(Self.value("moz-extension://4b1c/page.html") == .ordinary(host: nil))
        #expect(Self.value("file:///Users/sol/page.html") == .ordinary(host: nil))
        #expect(Self.value("data:text/html,<h1>hi</h1>") == .ordinary(host: nil))
    }

    @Test func internalPagesOffTheAllowlistAreCantTell() {
        #expect(Self.value("about:devtools-toolbox") == .cantTell)
        #expect(Self.value("about:certerror?e=nssBadCert") == .cantTell)
        #expect(Self.value("about:somethingnew") == .cantTell)
        #expect(Self.value("chrome://browser/content/places/bookmarksSidebar.xhtml", tab: true) == .cantTell)
        #expect(Self.value("chrome://browser/content/genai/chat.html", tab: false) == .cantTell)
        #expect(Self.value("resource://pdf.js/web/viewer.html", tab: true) == .cantTell)
        #expect(Self.value("resource://pdf.js/web/viewer.html", tab: false) == .cantTell)
        #expect(Self.value("ftp://bank.example/") == .cantTell)
        #expect(Self.value("not a url") == .cantTell)
    }

    @Test func sidebarDocumentsAreOrdinaryOnlyOutsideATabPanel() {
        for doc in [
            "chrome://browser/content/places/bookmarksSidebar.xhtml",
            "chrome://browser/content/places/historySidebar.xhtml",
            "chrome://browser/content/syncedtabs/sidebar.xhtml",
            "chrome://browser/content/webext-panels.xhtml",
            "chrome://browser/content/webext-panels.xhtml?panel=1",
        ] {
            #expect(Self.value(doc, tab: false) == .ordinary(host: nil))
            #expect(Self.value(doc, tab: true) == .cantTell)
        }
    }

    @Test func anErrorPageIsJudgedByTheHostItTried() {
        #expect(Self.value("http://nx.invalid/") == .ordinary(host: "nx.invalid"))
        #expect(Self.value("http://nx.invalid/", sites: ["nx.invalid"]) == .covered(host: "nx.invalid"))
    }

    @Test func anEmptyAddressIsCantTell() {
        #expect(Self.value("") == .cantTell)
        #expect(Self.verdict(Self.read([Self.tab("")])).verdict == .cantTell)
    }

    @Test func wrappedAddressesUseTheirInnerHost() {
        #expect(Self.value("view-source:https://bank.example/a") == .covered(host: "bank.example"))
        #expect(Self.value("blob:https://bank.example/1234") == .covered(host: "bank.example"))
        #expect(Self.value("https://login.bank.example:8443/x") == .covered(host: "login.bank.example"))
        #expect(Self.value("https://") == .cantTell)
    }

    // MARK: - The page

    @Test func oneShownTabAreaDecides() {
        #expect(Self.verdict(Self.read([Self.tab("https://news.example/")])) == ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: "news.example"))
        #expect(Self.verdict(Self.read([Self.tab("https://bank.example/")])).verdict == .covered)
    }

    @Test func aBookmarksSidebarReadsByTheTabArea() {
        let areas = [Self.other("chrome://browser/content/places/bookmarksSidebar.xhtml"), Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(areas)).verdict == .ordinary)
        let covered = [Self.other("chrome://browser/content/places/bookmarksSidebar.xhtml"), Self.tab("https://bank.example/")]
        #expect(Self.verdict(Self.read(covered)).verdict == .covered)
    }

    @Test func aSidebarNamingACoveredHostIsCovered() {
        let areas = [Self.other("https://bank.example/panel"), Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(areas)).verdict == .covered)
    }

    @Test func aSidebarNamingAnOrdinaryWebsiteReadsByTheTabArea() {
        let areas = [Self.other("https://chat.example/"), Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(areas)) == ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: "news.example"))
    }

    @Test func aSidebarThatCantBeToldMakesTheReadCantTell() {
        for doc in ["about:blank", "chrome://browser/content/genai/chat.html"] {
            let areas = [Self.other(doc), Self.tab("https://news.example/")]
            #expect(Self.verdict(Self.read(areas)).verdict == .cantTell)
        }
    }

    @Test func anExtensionSidebarReadsByTheTabArea() {
        let areas = [Self.other("moz-extension://4b1c/sidebar.html"), Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(areas)).verdict == .ordinary)
        let host = [Self.other("chrome://browser/content/webext-panels.xhtml"), Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(host)).verdict == .ordinary)
    }

    @Test func dockedDevtoolsReadsByItsPage() {
        let page = CGRect(x: 40, y: 125, width: 1400, height: 600)
        let tools = CGRect(x: 40, y: 730, width: 1400, height: 260)
        let ordinary = [Self.tab("https://news.example/", frame: page), Self.tab("about:devtools-toolbox", frame: tools)]
        #expect(Self.verdict(Self.read(ordinary)).verdict == .ordinary)
        let covered = [Self.tab("https://bank.example/", frame: page), Self.tab("about:devtools-toolbox", frame: tools)]
        #expect(Self.verdict(Self.read(covered)).verdict == .covered)
    }

    @Test func undockedDevtoolsAloneIsCantTell() {
        #expect(Self.verdict(Self.read([Self.tab("about:devtools-toolbox")])).verdict == .cantTell)
    }

    @Test func devtoolsInAnotherTabPanelIsJudgedByItsOwnValue() {
        let areas = [Self.tab("https://news.example/", frame: CGRect(x: 40, y: 125, width: 700, height: 865), panel: 0),
                     Self.tab("about:devtools-toolbox", frame: CGRect(x: 740, y: 125, width: 700, height: 865), panel: 1)]
        #expect(Self.verdict(Self.read(areas)).verdict == .cantTell)
    }

    @Test func twoShownPagesAreCantTell() {
        let areas = [Self.tab("https://news.example/", frame: CGRect(x: 40, y: 125, width: 700, height: 865), panel: 0),
                     Self.tab("https://shop.example/", frame: CGRect(x: 740, y: 125, width: 700, height: 865), panel: 1)]
        #expect(Self.verdict(Self.read(areas)) == ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil))
    }

    @Test func aWindowWithNoTabAreaIsCantTell() {
        #expect(Self.verdict(Self.read([])) == ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: nil))
        #expect(Self.verdict(Self.read([Self.other("chrome://browser/content/places/places.xhtml")], cg: "Library", opening: "Library", closing: "Library")).verdict == .cantTell)
    }

    @Test func zeroFrameAndOutOfWindowAreasArentShown() {
        let zero = Self.tab("https://shop.example/", frame: .zero, panel: 0)
        let outside = Self.tab("https://shop.example/", frame: CGRect(x: 2000, y: 125, width: 100, height: 100), panel: 0)
        let shown = Self.tab("https://news.example/")
        #expect(Self.verdict(Self.read([zero, shown])).verdict == .ordinary)
        #expect(Self.verdict(Self.read([outside, shown])).verdict == .ordinary)
        #expect(Self.verdict(Self.read([zero])).verdict == .cantTell)
        #expect(Self.verdict(Self.read([outside])).verdict == .cantTell)
        let withinAPoint = Self.tab("https://news.example/", frame: CGRect(x: -0.5, y: 25, width: 1440.5, height: 965))
        #expect(Self.verdict(Self.read([withinAPoint])).verdict == .ordinary)
    }

    // MARK: - Covered wins

    @Test func coveredWinsFromAnAreaThatIsntShown() {
        let hidden = Self.tab("https://bank.example/", frame: .zero, panel: 0)
        #expect(Self.verdict(Self.read([hidden, Self.tab("https://news.example/")])).verdict == .covered)
        let outside = Self.other("https://bank.example/", frame: CGRect(x: 3000, y: 0, width: 10, height: 10))
        #expect(Self.verdict(Self.read([outside, Self.tab("https://news.example/")])).verdict == .covered)
    }

    @Test func coveredWinsOverEveryImperfection() {
        let bank = [Self.tab("https://bank.example/")]
        #expect(Self.verdict(Self.read(bank, opening: "A", closing: "B")).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, opening: nil)).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, cg: "Other")).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, outcome: .overBudget)).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, outcome: .failed)).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, frame: nil)).verdict == .covered)
        #expect(Self.verdict(Self.read(bank, cg: "News"), prevCG: "Old", prevAX: "News").verdict == .covered)
    }

    // MARK: - Failures and the title check

    @Test func eachFailureIsCantTellNeverOrdinary() {
        let page = [Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(page, opening: nil)) == ChromiumPageEvaluation(verdict: .cantTell, cause: .unread, host: "news.example"))
        #expect(Self.verdict(Self.read(page, closing: nil)).cause == .unread)
        #expect(Self.verdict(Self.read(page, frame: nil)).verdict == .cantTell)
        #expect(Self.verdict(Self.read(page, outcome: .failed)).cause == .unread)
        #expect(Self.verdict(Self.read(page, outcome: .timedOut)).cause == .unread)
        #expect(Self.verdict(Self.read(page, outcome: .overBudget)) == ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: "news.example"))
        #expect(Self.verdict(Self.read([Self.tab(nil)])).verdict == .cantTell)
        #expect(Self.verdict(Self.read([FirefoxWebArea(url: "https://news.example/", frame: nil, tabPanel: 0)])).verdict == .cantTell)
    }

    @Test func titlesThatDifferAreCantTell() {
        let page = [Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(page, opening: "News", closing: "Other")).verdict == .cantTell)
        #expect(Self.verdict(Self.read(page, cg: "News", opening: "Shop", closing: "Shop")).verdict == .cantTell)
    }

    @Test func aTornPairIsCantTell() {
        // The window server's title moved on while the AX title didn't.
        let page = [Self.tab("https://news.example/")]
        #expect(Self.verdict(Self.read(page, cg: "News", opening: "News", closing: "News"), prevCG: "Old", prevAX: "News").verdict == .cantTell)
        #expect(Self.verdict(Self.read(page), prevCG: "News", prevAX: "News").verdict == .ordinary)
    }

    @Test func aPrivateWindowTitleMatchesItself() {
        let title = "News \u{2014} Private Browsing"
        #expect(Self.verdict(Self.read([Self.tab("https://news.example/")], cg: title, opening: title, closing: title)).verdict == .ordinary)
    }

    // MARK: - A title changing on the same page

    @Test func aTickingTitleOnOneAddressStaysOrdinary() {
        let page = [Self.tab("https://news.example/live")]
        let r = Self.read(page, cg: "(3) News", opening: "(4) News", closing: "(4) News")
        #expect(Self.verdict(r, prevCG: "(3) News", prevAX: "(3) News", prevURL: "https://news.example/live").verdict == .ordinary)
    }

    @Test func theWindowServerCatchingUpOnTheSameAddressIsNotATornPair() {
        let page = [Self.tab("https://news.example/live")]
        let r = Self.read(page, cg: "(4) News", opening: "(4) News", closing: "(4) News")
        #expect(Self.verdict(r, prevCG: "(3) News", prevAX: "(4) News", prevURL: "https://news.example/live").verdict == .ordinary)
    }

    @Test func aTitleMismatchWithoutAnOrdinaryReadOfTheSameAddressStaysCantTell() {
        let page = [Self.tab("https://news.example/live")]
        let r = Self.read(page, cg: "(3) News", opening: "(4) News", closing: "(4) News")
        #expect(Self.verdict(r, prevCG: "(3) News", prevAX: "(3) News", prevURL: nil).verdict == .cantTell)
    }

    @Test func aNavigationWithATitleDisagreementIsCantTell() {
        let page = [Self.tab("https://shop.example/")]
        let r = Self.read(page, cg: "News", opening: "Shop", closing: "Shop")
        #expect(Self.verdict(r, prevCG: "News", prevAX: "News", prevURL: "https://news.example/").verdict == .cantTell)
    }

    @Test func aTitleChangeOnTheSameLeftOutAddressIsCovered() {
        let page = [Self.tab("https://bank.example/")]
        let r = Self.read(page, cg: "(3) Bank", opening: "(4) Bank", closing: "(4) Bank")
        #expect(Self.verdict(r, prevCG: "(3) Bank", prevAX: "(3) Bank", prevURL: "https://bank.example/").verdict == .covered)
    }

    @Test func aTitleChangeOnTheSameAddressBesideASecondTabPanelStaysCantTell() {
        let areas = [Self.tab("https://news.example/live", frame: CGRect(x: 40, y: 125, width: 700, height: 865), panel: 0),
                     Self.tab("https://shop.example/", frame: CGRect(x: 740, y: 125, width: 700, height: 865), panel: 1)]
        let r = Self.read(areas, cg: "(3) News", opening: "(4) News", closing: "(4) News")
        #expect(Self.verdict(r, prevCG: "(3) News", prevAX: "(3) News", prevURL: "https://news.example/live").verdict == .cantTell)
    }

    // MARK: - Rule 6

    @Test func leavingACoveredPageWaitsFiveSeconds() {
        var r6: ChromiumRule6Record?
        func step(_ url: String, _ now: TimeInterval) -> ChromiumVerdict {
            FirefoxSiteRead.evaluatePageWindow(Self.read([Self.tab(url)]), previousCGTitle: nil, previousAXTitle: nil,
                                               previousOrdinaryURL: nil, rule6Record: &r6, sites: ["bank.example"], now: now).evaluation.verdict
        }
        #expect(step("https://bank.example/", 10) == .covered)
        #expect(step("https://news.example/", 10.25) == .cantTell)
        #expect(step("https://news.example/", 14.5) == .cantTell)
        #expect(step("https://news.example/", 15.3) == .ordinary)
        #expect(r6 == nil)
        // A can't-tell read inside the wait restarts it.
        #expect(step("https://bank.example/", 20) == .covered)
        #expect(step("https://news.example/", 21) == .cantTell)
        #expect(FirefoxSiteRead.evaluatePageWindow(Self.read([Self.tab("https://news.example/")], opening: nil), previousCGTitle: nil, previousAXTitle: nil,
                                                   previousOrdinaryURL: nil, rule6Record: &r6, sites: ["bank.example"], now: 23).evaluation.verdict == .cantTell)
        #expect(step("https://news.example/", 26) == .cantTell)
        #expect(step("https://news.example/", 31.1) == .ordinary)
    }

    @Test func storedStateHoldsTheHostOnly() {
        let r = Self.read([Self.tab("https://news.example/path?q=secret#frag")])
        let e = Self.verdict(r)
        #expect(e.host == "news.example")
        #expect(FirefoxSiteRead.collectedHosts(r.walk) == ["news.example"])
        #expect(FirefoxSiteRead.collectedHosts(Self.read([Self.tab("file:///Users/sol/secret.html"), Self.other("data:text/html,x")]).walk).isEmpty)
    }

    // MARK: - The walk

    @Test func theWalkReachesTheTabAreaPastAHundredTabsWithoutEnteringThem() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/", tabs: 100)
        tree.setEngine(true, pid: -700)
        let reader = tree.makeReader()
        let walk = reader.walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .complete)
        #expect(walk.visited <= 40)
        #expect(walk.areas == [FirefoxWebArea(url: "https://news.example/", frame: FakeFirefoxTree.contentFrame, tabPanel: 0)])
        // Nothing inside the tab strip, the address field or the web area was read.
        let log = tree.locked { $0.attributeLog }
        let tabStripChildren = tree.node(ids.tabStrip)!.children
        #expect(!log.contains { $0.id.map(tabStripChildren.contains) == true })
        #expect(!log.contains { $0.id == ids.page && $0.attribute == kAXChildrenAttribute as String })
        #expect(!log.contains { $0.attribute == kAXValueAttribute as String })
    }

    @Test func overBudgetTimedOutAndFailedWalksAreEachCantTell() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/")
        tree.setEngine(true, pid: -700)
        let reader = tree.makeReader()
        let window = tree.element(ids.window)

        let over = reader.walkWindow(window, maxElements: 4, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(over.outcome == .overBudget)

        let clock = OSAllocatedUnfairLock(initialState: 1.0)
        tree.onRead = { clock.withLock { $0 += 0.004 } }
        let timed = reader.walkWindow(window, maxElements: 200, timeoutSeconds: 0.025, nowTicks: { FirefoxTestClock.ticks(seconds: clock.withLock { $0 }) })
        #expect(timed.outcome == .timedOut)
        tree.onRead = nil

        tree.update(ids.container) { $0.childrenError = .cannotComplete }
        let failed = reader.walkWindow(window, maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(failed.outcome == .failed)

        for outcome in [over, timed, failed] {
            let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: outcome, windowFrame: Self.window)
            #expect(Self.verdict(r).verdict == .cantTell)
        }
    }

    @Test func aFailedRoleStillLetsTheWalkFindACoveredAreaElsewhere() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "Bank", pageURL: "https://bank.example/",
                                        sidebarURL: "chrome://browser/content/places/bookmarksSidebar.xhtml")
        tree.setEngine(true, pid: -700)
        tree.update(ids.tabStrip) { $0.roleError = .cannotComplete }
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .failed)
        let r = FirefoxSiteRead.PageRead(cgTitle: "Bank", openingTitle: "Bank", closingTitle: "Bank", walk: walk, windowFrame: Self.window)
        #expect(Self.verdict(r).verdict == .covered)
    }

    @Test func theWalkFindsSidebarAndDevtoolsWhereTheySit() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/",
                                        sidebarURL: "chrome://browser/content/places/bookmarksSidebar.xhtml", devtoolsURL: "about:devtools-toolbox")
        tree.setEngine(true, pid: -700)
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .complete)
        #expect(walk.areas.count == 3)
        #expect(walk.areas.first { $0.url?.hasPrefix("chrome:") == true }?.tabPanel == nil)
        #expect(walk.areas.filter { $0.tabPanel == 0 }.count == 2)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .ordinary)
    }

    @Test func splitViewIsCantTellWhicheverPageItExposes() {
        // 162 exposes one pane's page; the other pane, here left out, isn't in the tree.
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "Bank", pageURL: "https://news.example/", splitView: true)
        tree.setEngine(true, pid: -700)
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .complete)
        #expect(walk.unexpectedTabPanel)
        let r = FirefoxSiteRead.PageRead(cgTitle: "Bank", openingTitle: "Bank", closingTitle: "Bank", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .cantTell)
        #expect(FirefoxSiteRead.evaluateActivity(r, previousCGTitle: nil, previousAXTitle: nil, sites: ["bank.example"]).pageURL == nil)
        // An exposed left-out page is still covered.
        tree.update(ids.page) { $0.url = "https://bank.example/" }
        let covered = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        let rc = FirefoxSiteRead.PageRead(cgTitle: "Bank", openingTitle: "Bank", closingTitle: "Bank", walk: covered, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(rc).verdict == .covered)
    }

    @Test func splitViewWithTheExposedPaneFocusedIsCantTell() {
        // Focusing the exposed pane drops the panel's extra groups and button (m5); the panel no
        // longer filling its group is then the only sign of the split, and the other pane's page,
        // here left out, still isn't in the tree.
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/", splitView: true)
        tree.update(ids.tabPanel) { $0.children = [ids.pageScroll] }
        tree.setEngine(true, pid: -700)
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .complete)
        #expect(walk.unexpectedTabPanel)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .cantTell)
        #expect(FirefoxSiteRead.evaluateActivity(r, previousCGTitle: nil, previousAXTitle: nil, sites: ["bank.example"]).pageURL == nil)
    }

    @Test func aTabPanelWhoseFrameCantBeReadIsAFailedRead() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/")
        tree.update(ids.tabPanel) { $0.frameError = .cannotComplete }
        tree.setEngine(true, pid: -700)
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .failed)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .cantTell)
    }

    @Test func aTabPanelFillsItsGroupWithinAPoint() {
        let group = CGRect(x: 60, y: 194, width: 1800, height: 796)
        #expect(FirefoxSiteRead.tabPanelFills(group, group))
        #expect(FirefoxSiteRead.tabPanelFills(CGRect(x: 60.5, y: 194, width: 1799, height: 796.5), group))
        // Measured split panes: the left of two, and one widened to all but its insets.
        #expect(!FirefoxSiteRead.tabPanelFills(CGRect(x: 63, y: 197, width: 894, height: 790), group))
        #expect(!FirefoxSiteRead.tabPanelFills(CGRect(x: 63, y: 197, width: 1794, height: 790), group))
    }

    @Test func theFindBarAndDockedDevtoolsLeaveAPageOrdinary() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/",
                                        devtoolsURL: "about:devtools-toolbox", findBar: true)
        tree.setEngine(true, pid: -700)
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .complete)
        #expect(!walk.unexpectedTabPanel)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .ordinary)
        // The find bar's field is never read.
        #expect(!tree.locked { $0.attributeLog }.contains { $0.attribute == kAXValueAttribute as String })
    }

    @Test func anyOtherTabPanelChildIsCantTell() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/")
        tree.setEngine(true, pid: -700)
        let extra = tree.add(.init(role: "AXGroup", subrole: "AXUnknown"))
        tree.update(ids.tabPanel) { $0.children.append(extra) }
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.unexpectedTabPanel)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .cantTell)
    }

    @Test func beforeTheTriggerAWindowHoldsNoWebArea() {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: "News", pageURL: "https://news.example/")
        let walk = tree.makeReader().walkWindow(tree.element(ids.window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.areas.isEmpty)
        let r = FirefoxSiteRead.PageRead(cgTitle: "News", openingTitle: "News", closingTitle: "News", walk: walk, windowFrame: FakeFirefoxTree.windowFrame)
        #expect(Self.verdict(r).verdict == .cantTell)
    }

    // MARK: - Eligibility

    final class ProbeCalls: @unchecked Sendable {
        let lock = NSLock()
        var plistReads = 0
    }

    static func probe(
        version: String? = "162.0",
        bundleID: String = "org.mozilla.firefox",
        start: FirefoxTimestamp? = FirefoxTimestamp(seconds: 1_000, nanoseconds: 500_000),
        plistChanged: FirefoxTimestamp = FirefoxTimestamp(seconds: 900, nanoseconds: 0),
        executableChanged: FirefoxTimestamp? = FirefoxTimestamp(seconds: 900, nanoseconds: 0),
        startTimes: OSAllocatedUnfairLock<FirefoxTimestamp?>? = nil,
        calls: ProbeCalls = ProbeCalls(),
        executable: String? = "/Applications/Firefox.app/Contents/MacOS/firefox",
        plistReadable: OSAllocatedUnfairLock<Bool>? = nil
    ) -> FirefoxProcessProbe {
        let bundle = URL(fileURLWithPath: "/Applications/Firefox.app")
        return FirefoxProcessProbe(
            startTime: { _ in startTimes?.withLock { $0 } ?? start },
            bundleURL: { _ in bundle },
            readPropertyList: { url in
                calls.lock.withLock { calls.plistReads += 1 }
                guard url.path == "/Applications/Firefox.app/Contents/Info.plist", plistReadable?.withLock({ $0 }) ?? true else { return nil }
                var plist: [String: any Sendable] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "firefox"]
                if let version { plist["CFBundleShortVersionString"] = version }
                return plist
            },
            statusChangeTime: { url in
                switch url.path {
                case "/Applications/Firefox.app/Contents/Info.plist": return plistChanged
                case "/Applications/Firefox.app/Contents/MacOS/firefox": return executableChanged
                default: return nil
                }
            },
            executablePath: { _ in executable }
        )
    }

    @Test func onlyVersion162AndLaterIsEligible() {
        let cases: [(String?, Bool)] = [
            ("161.0", false), ("161.0.1", false), ("162.0", true), ("162.0b2", true), ("163.0a1", true),
            ("", false), ("beta", false), (nil, false), ("16.2", false), ("99999999999999999999.0", false),
        ]
        for (version, expected) in cases {
            #expect(FirefoxEligibility.versionIsEligible(version) == expected)
            #expect(FirefoxEligibility(probe: Self.probe(version: version)).isEligible(pid: 700) == expected)
        }
    }

    @Test func aBundleChangedAfterTheProcessStartedIsIneligible() {
        let start = FirefoxTimestamp(seconds: 1_000, nanoseconds: 500_000)
        let later = FirefoxTimestamp(seconds: 1_000, nanoseconds: 500_001)
        #expect(!FirefoxEligibility(probe: Self.probe(start: start, plistChanged: later)).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe(start: start, executableChanged: later)).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe(start: start, executableChanged: nil)).isEligible(pid: 700))
        #expect(FirefoxEligibility(probe: Self.probe(start: start, plistChanged: start, executableChanged: start)).isEligible(pid: 700))
    }

    @Test func anUnreadableStartTimeIsIneligible() {
        #expect(!FirefoxEligibility(probe: Self.probe(start: nil)).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe()).isEligible(pid: 0))
    }

    @Test func anUnchangedBundleWithNoLaunchServicesLaunchIsEligible() {
        // The gate never asks LaunchServices for a launch date; the kernel's start time is enough.
        #expect(FirefoxEligibility(probe: Self.probe()).isEligible(pid: 700))
    }

    @Test func anotherBundleIdentifierIsIneligible() {
        #expect(!FirefoxEligibility(probe: Self.probe(bundleID: "org.mozilla.firefoxdeveloperedition")).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe(bundleID: "org.mozilla.nightly")).isEligible(pid: 700))
    }

    @Test func aProcessIsJudgedOncePerStartTime() {
        let calls = ProbeCalls()
        let starts = OSAllocatedUnfairLock<FirefoxTimestamp?>(initialState: FirefoxTimestamp(seconds: 1_000, nanoseconds: 0))
        let gate = FirefoxEligibility(probe: Self.probe(startTimes: starts, calls: calls))
        #expect(gate.isEligible(pid: 700))
        #expect(gate.isEligible(pid: 700))
        #expect(calls.lock.withLock { calls.plistReads } == 1)
        // The same pid, a new process started after the bundle changed: judged again, and out.
        starts.withLock { $0 = FirefoxTimestamp(seconds: 800, nanoseconds: 0) }
        #expect(!gate.isEligible(pid: 700))
        #expect(calls.lock.withLock { calls.plistReads } == 2)
    }

    @Test func theProcessMustRunItsBundlesOwnExecutable() {
        // A whole bundle renamed into place under a running Firefox: the process runs another file.
        #expect(!FirefoxEligibility(probe: Self.probe(executable: "/Applications/Firefox-old.app/Contents/MacOS/firefox")).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe(executable: "/Applications/Firefox.app/Contents/MacOS/plugin-container")).isEligible(pid: 700))
        #expect(!FirefoxEligibility(probe: Self.probe(executable: nil)).isEligible(pid: 700))
        #expect(FirefoxEligibility(probe: Self.probe(executable: "/Applications/Firefox.app/Contents/MacOS/./firefox")).isEligible(pid: 700))
    }

    @Test func aReadFailureIsNotRememberedAVerdictIs() {
        let calls = ProbeCalls()
        let readable = OSAllocatedUnfairLock(initialState: false)
        let gate = FirefoxEligibility(probe: Self.probe(calls: calls, plistReadable: readable))
        #expect(!gate.isEligible(pid: 700))
        #expect(!gate.isEligible(pid: 700))
        #expect(calls.lock.withLock { calls.plistReads } == 2)
        readable.withLock { $0 = true }
        #expect(gate.isEligible(pid: 700))
        #expect(gate.isEligible(pid: 700))
        #expect(calls.lock.withLock { calls.plistReads } == 3)

        // An ineligible version is a verdict, kept for the process's life.
        let oldCalls = ProbeCalls()
        let old = FirefoxEligibility(probe: Self.probe(version: "161.0", calls: oldCalls))
        #expect(!old.isEligible(pid: 700))
        #expect(!old.isEligible(pid: 700))
        #expect(oldCalls.lock.withLock { oldCalls.plistReads } == 1)
    }

    @Test func theCacheKeepsVerdictsForProcessesStillRunning() {
        let calls = ProbeCalls()
        let ended = OSAllocatedUnfairLock(initialState: Set<pid_t>())
        let base = Self.probe(calls: calls)
        var probe = base
        probe.startTime = { pid in ended.withLock { $0.contains(pid) } ? nil : base.startTime(pid) }
        let gate = FirefoxEligibility(probe: probe)
        for pid in pid_t(1)...pid_t(80) { #expect(gate.isEligible(pid: pid)) }
        #expect(calls.lock.withLock { calls.plistReads } == 80)
        // Every one is still running, so asking again reads nothing.
        for pid in pid_t(1)...pid_t(80) { #expect(gate.isEligible(pid: pid)) }
        #expect(calls.lock.withLock { calls.plistReads } == 80)
        // Ended processes are dropped; the rest stay.
        ended.withLock { $0 = Set(pid_t(1)...pid_t(40)) }
        #expect(gate.isEligible(pid: 81))
        for pid in pid_t(41)...pid_t(80) { #expect(gate.isEligible(pid: pid)) }
        #expect(calls.lock.withLock { calls.plistReads } == 81)
    }

    @Test func aTickingTitleCantHoldRule6sWaitOpenForever() {
        var r6: ChromiumRule6Record?
        var prevURL: String?
        var prev: (cg: String, ax: String)?
        func step(_ url: String, cg: String, ax: String, _ now: TimeInterval) -> ChromiumVerdict {
            let r = Self.read([Self.tab(url)], cg: cg, opening: ax, closing: ax)
            let (e, ordinary) = FirefoxSiteRead.evaluatePageWindow(r, previousCGTitle: prev?.cg, previousAXTitle: prev?.ax,
                                                                   previousOrdinaryURL: prevURL, rule6Record: &r6, sites: ["bank.example"], now: now)
            prevURL = ordinary
            prev = (cg, ax)
            return e.verdict
        }
        #expect(step("https://bank.example/", cg: "Bank", ax: "Bank", 10) == .covered)
        #expect(step("https://news.example/live", cg: "(1) News", ax: "(1) News", 10.25) == .cantTell)
        // From here the AX title leads the window server's on every read, on the same page.
        var t = 10.5
        var n = 1
        var verdict = ChromiumVerdict.cantTell
        while t < 16.0 {
            verdict = step("https://news.example/live", cg: "(\(n)) News", ax: "(\(n + 1)) News", t)
            n += 1
            t += 0.25
        }
        #expect(verdict == .ordinary)
        #expect(r6 == nil)
        // A navigation inside the wait still restarts it.
        #expect(step("https://bank.example/", cg: "Bank", ax: "Bank", 20) == .covered)
        #expect(step("https://news.example/a", cg: "News", ax: "News", 20.25) == .cantTell)
        #expect(step("https://shop.example/", cg: "News", ax: "Shop", 20.5) == .cantTell)
        #expect(r6?.firstOrdinaryAt == nil)
    }

    @Test func theExclusionPlannerNeverReadsAFirefoxAccessibilityTitle() {
        let planner = ExclusionPlanner()
        let settings = ExclusionSettings(excludedAppNames: [], excludePrivateBrowsing: true, accessibilityTitlesWorking: true, titlePatterns: [])
        let apps = [ExclusionApp(pid: 700, name: "Firefox", bundleIdentifier: "org.mozilla.firefox")]
        let windows = [ExclusionWindow(id: 10, pid: 700, ownerName: "Firefox", title: "News", layer: 0)]
        #expect(planner.windowsNeedingAccessibilityTitles(windows: windows, apps: apps, settings: settings).isEmpty)
    }

    @Test func aKeptOutFirefoxPutsEveryFirefoxPidInWholeAppPIDs() async {
        await MainActor.run {
            var planner = ExclusionPlanner()
            let manager = WindowExclusionManager(excludedAppNames: [], excludePrivateBrowsing: false, excludedTitlePatterns: [])
            manager.setSiteRule(active: true, keptOutBrowsers: [.firefox])
            #expect(manager.excludedAppNames.contains("org.mozilla.firefox"))
            let apps = [ExclusionApp(pid: 700, name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
                        ExclusionApp(pid: 701, name: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
                        ExclusionApp(pid: 702, name: "Firefox Developer Edition", bundleIdentifier: "org.mozilla.firefoxdeveloperedition")]
            let windows = [ExclusionWindow(id: 1, pid: 700, ownerName: "Firefox", title: "A", layer: 0),
                           ExclusionWindow(id: 2, pid: 701, ownerName: "Firefox", title: "B", layer: 0)]
            let plan = planner.plan(windows: windows, apps: apps, settings: manager.plannedSettings, accessibilityTitles: [:], now: Date())
            #expect(plan.wholeAppPIDs.isSuperset(of: [700, 701]))
            #expect(!plan.wholeAppPIDs.contains(702))
            manager.setSiteRule(active: true, keptOutBrowsers: [])
            #expect(!manager.excludedAppNames.contains("org.mozilla.firefox"))
        }
    }
}
