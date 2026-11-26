// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os
import Testing
@testable import solstone

/// Firefox through the website sampler: the trigger, the round, panels, failures and the reads it
/// may make, over a fake AX tree on an injected clock.
@Suite("FirefoxSampler", .serialized)
struct FirefoxSamplerTests {
    static let pid: pid_t = -700

    static func pageWindow(_ wid: CGWindowID = 10, title: String = "News", pid: pid_t = pid, layer: Int = 0) -> SiteVisibleWindow {
        SiteVisibleWindow(windowID: wid, pid: pid, layer: layer, title: title)
    }

    static func appRoleReads(_ recorder: AXReadRecorder) -> [pid_t] {
        recorder.applicationReads.filter { $0.attribute == kAXRoleAttribute as String }.map(\.pid)
    }

    // MARK: - The trigger

    @Test func theFirstRoundWithDemandTriggersOnce() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow()])
        await h.start(sites: ["bank.example"])

        let first = await h.poll()
        #expect(Self.appRoleReads(h.recorder) == [Self.pid])
        // The engine came up within the round, so the read that followed the trigger saw the page.
        #expect(first?[10]?.verdict == .ordinary)
        // AXWindows was read before the trigger, and nothing else on the application element.
        #expect(h.recorder.applicationReads.first?.attribute == kAXWindowsAttribute as String)
        for _ in 0..<30 { await h.poll() }
        #expect(Self.appRoleReads(h.recorder) == [Self.pid])
        #expect(await h.sampler.firefoxEngineForTesting(Self.pid)?.foundTabArea == true)
    }

    @Test func noTriggerWithoutDemand() async {
        // Accessibility not working.
        let off = FirefoxSamplerHarness(axWorking: false)
        off.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        off.show([Self.pageWindow()])
        await off.start(sites: ["bank.example"], axWorking: false)
        for _ in 0..<8 { await off.poll() }
        #expect(Self.appRoleReads(off.recorder).isEmpty)

        // No website listed.
        let empty = FirefoxSamplerHarness()
        empty.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        empty.show([Self.pageWindow()])
        await empty.start(sites: [])
        for _ in 0..<8 { await empty.poll() }
        #expect(Self.appRoleReads(empty.recorder).isEmpty)
    }

    @Test func anIneligiblePidIsNeverRead() async {
        let h = FirefoxSamplerHarness(firefoxPIDs: [Self.pid], eligible: [])
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "Bank", pageURL: "https://bank.example/")
        h.show([Self.pageWindow(title: "Bank")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<8 { await h.poll(expectRound: false) }
        #expect(h.recorder.applicationReads.isEmpty)
        #expect(h.recorder.recordedReads.isEmpty)
        #expect(h.tree.locked { $0.attributeLog }.isEmpty)
        // Its windows aren't in any poll's reads, so it never sits out.
        #expect(h.polls.withLock { $0 }.allSatisfy { $0.windows.isEmpty })
    }

    @Test func anEngineThatDoesntComeUpIsRetriggeredAtMostEveryFiveSeconds() async {
        let h = FirefoxSamplerHarness()
        h.tree.engineComesUp = false
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow()])
        await h.start(sites: ["bank.example"])
        for _ in 0..<48 { await h.poll() }   // 12 s
        #expect(Self.appRoleReads(h.recorder).count == 3)
    }

    @Test func afterFiveSecondsWithNoWebAreaFailuresAccrueAndCautionRises() async {
        let h = FirefoxSamplerHarness()
        h.tree.engineComesUp = false
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow()])
        await h.start(sites: ["bank.example"])
        for _ in 0..<19 { await h.poll() }   // through 104.5
        #expect(await h.sampler.failureCountForTesting(.firefox) == 0)
        #expect(!h.firefoxCautionRaised)
        var last: [CGWindowID: ChromiumPollRead]?
        for _ in 0..<14 { last = await h.poll() }   // through 107.75
        #expect(last?[10]?.cause == .unread)
        #expect(await h.sampler.failureCountForTesting(.firefox) >= 10)
        #expect(h.firefoxCautionRaised)
    }

    @Test func aLibraryWindowBesideAPageAccruesNothing() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.tree.addLibraryWindow(pid: Self.pid, wid: 11)
        h.show([Self.pageWindow(), Self.pageWindow(11, title: "Library")])
        await h.start(sites: ["bank.example"])
        var last: [CGWindowID: ChromiumPollRead]?
        for _ in 0..<40 { last = await h.poll() }   // 10 s
        #expect(last?[10]?.verdict == .ordinary)
        #expect(last?[11]?.verdict == .cantTell)
        #expect(last?[11]?.cause == .unclear)
        #expect(await h.sampler.failureCountForTesting(.firefox) == 0)
        #expect(h.cautions.withLock { $0 }.allSatisfy { $0.0 != .firefox || !$0.1 })
    }

    // MARK: - No element kept across reads

    @Test func aSwitchedAwayTabsWebAreaIsNeverReadAgain() async {
        let h = FirefoxSamplerHarness()
        let ids = h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow()])
        await h.start(sites: ["bank.example"])
        #expect(await h.poll()?[10]?.verdict == .ordinary)
        #expect(await h.poll()?[10]?.host == "news.example")

        // A tab switch: the old tab's web area keeps answering with its own address and a full
        // frame, as measured, but it is no longer in the window's tree.
        let bank = h.tree.add(FakeFirefoxTree.Node(role: "AXWebArea", url: "https://bank.example/", frame: FakeFirefoxTree.contentFrame))
        h.tree.update(ids.pageScroll) { $0.children = [bank] }
        h.tree.locked { $0.cgTitles[10] = "Bank" }
        h.tree.update(ids.window) { $0.title = "Bank" }
        h.show([Self.pageWindow(title: "Bank")])

        let afterSwitch = await h.poll()
        #expect(afterSwitch?[10]?.verdict == .covered)
        for _ in 0..<8 {
            let r = await h.poll()
            #expect(!(r?[10]?.verdict == .ordinary && r?[10]?.host == "news.example"))
        }
    }

    // MARK: - Windows

    @Test func aPanelIsItsOwnCauseCountsNothingAndNeverTriggers() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow(), Self.pageWindow(20, title: "")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<40 {   // 10 s on screen
            let r = await h.poll()
            #expect(r?[20] == ChromiumPollRead(verdict: .cantTell, cause: .panel, host: nil, readStart: r?[20]?.readStart ?? 0, listGeneration: 1, browser: .firefox, isPending: false))
            #expect(r?[10]?.verdict == .ordinary)
        }
        #expect(await h.sampler.failureCountForTesting(.firefox) == 0)
        #expect(!h.firefoxCautionRaised)
        #expect(await h.sampler.rule6RecordForTesting(20) == nil)

        // With only a panel on screen, nothing triggers the engine.
        let alone = FirefoxSamplerHarness()
        alone.tree.listWindows([], pid: Self.pid)
        alone.show([Self.pageWindow(20, title: "")])
        await alone.start(sites: ["bank.example"])
        for _ in 0..<8 {
            #expect(await alone.poll()?[20]?.cause == .panel)
        }
        #expect(Self.appRoleReads(alone.recorder).isEmpty)
        #expect(await alone.sampler.failureCountForTesting(.firefox) == 0)
    }

    @Test func aTitledWindowAccessibilityDoesntListIsAFailedReadNeverAPanel() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow(), Self.pageWindow(21, title: "Bank")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<12 {
            let r = await h.poll()
            #expect(r?[21]?.cause == .unread)
            #expect(r?[10]?.verdict == .ordinary)
        }
        #expect(await h.sampler.failureCountForTesting(.firefox) >= 10)
        #expect(h.firefoxCautionRaised)
    }

    @Test func aFailedWindowListIsAFailedReadNeverAPanel() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.tree.axWindowsFails = [Self.pid]
        h.show([Self.pageWindow(), Self.pageWindow(20, title: "")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<12 {
            let r = await h.poll()
            #expect(r?[10]?.cause == .unread)
            #expect(r?[20]?.cause == .unread)
        }
        #expect(await h.sampler.failureCountForTesting(.firefox) >= 10)
        #expect(h.firefoxCautionRaised)
        #expect(Self.appRoleReads(h.recorder).isEmpty)
    }

    @Test func aPairingErrorIsAFailedReadNeverAPanel() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        let other = h.tree.addLibraryWindow(pid: Self.pid, wid: 11)
        h.tree.pairingFails = [other]
        h.show([Self.pageWindow(), Self.pageWindow(20, title: "")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<12 {
            let r = await h.poll()
            #expect(r?[10]?.cause == .unread)
            #expect(r?[20]?.cause == .unread)
            #expect(r?.values.contains { $0.cause == .panel } == false)
        }
        #expect(await h.sampler.failureCountForTesting(.firefox) >= 10)
    }

    @Test func pictureInPictureWithNoOriginIsCantTell() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.tree.addPiPWindow(pid: Self.pid, wid: 30)
        h.show([Self.pageWindow(), Self.pageWindow(30, title: "", layer: 3)])
        await h.start(sites: ["bank.example"])
        let r = await h.poll()
        #expect(r?[30]?.verdict == .cantTell)
        #expect(r?[10]?.verdict == .ordinary)
    }

    @Test func pictureInPictureIsCantTellWhateverTextItShowsAndIsNeverRead() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        let pip = h.tree.addPiPWindow(pid: Self.pid, wid: 30, originText: "news.example")
        h.show([Self.pageWindow(), Self.pageWindow(30, title: "", layer: 3)])
        await h.start(sites: ["bank.example"])
        h.tree.clearLog()
        let r = await h.poll()
        #expect(r?[30]?.verdict == .cantTell)
        #expect(!h.tree.locked { $0.attributeLog }.contains { $0.id == pip && $0.attribute == kAXChildrenAttribute as String })
    }

    @Test func otherLayersAreIgnoredAndFireNothing() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/")
        h.show([Self.pageWindow(40, title: "", layer: 25), Self.pageWindow(41, title: "", layer: 101)])
        await h.start(sites: ["bank.example"])
        for _ in 0..<8 { await h.poll(expectRound: false) }
        #expect(h.recorder.applicationReads.isEmpty)
        #expect(h.polls.withLock { $0 }.allSatisfy { $0.windows.isEmpty })
    }

    // MARK: - Values through the sampler

    @Test func aListChangeCoveringAReaderViewHostStartsRule6() async {
        let h = FirefoxSamplerHarness()
        h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "Article",
                                pageURL: "about:reader?url=https%3A%2F%2Fnews.example%2Farticle")
        h.show([Self.pageWindow(title: "Article")])
        await h.start(sites: ["bank.example"])
        #expect(await h.poll()?[10]?.verdict == .ordinary)
        #expect(await h.sampler.rule6RecordForTesting(10) == nil)
        await h.sampler.applySites(["news.example"], generation: 2)
        #expect(await h.sampler.rule6RecordForTesting(10)?.host == "news.example")
    }

    // MARK: - A hung Firefox

    struct HungFirefoxReader: FirefoxWindowReading, @unchecked Sendable {
        let blocker: DispatchSemaphore
        func triggerEngine(pid: pid_t) {}
        func copyWindows(for pid: pid_t) -> [AXUIElement]? {
            _ = blocker.wait(timeout: .now() + 10)
            return nil
        }
        func windowID(for window: AXUIElement) -> CGWindowID? { nil }
        func readTitle(for window: AXUIElement) -> String? { nil }
        func readFrame(for window: AXUIElement) -> CGRect? { nil }
        func walkWindow(_ window: AXUIElement, maxElements: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> FirefoxWalkResult {
            FirefoxWalkResult(areas: [], outcome: .failed)
        }
        func currentCGTitle(windowID: CGWindowID) -> String? { nil }
    }

    @Test func aHungFirefoxNeverHoldsUpAPollAChromeRoundOrASafariWalk() async {
        let blocker = DispatchSemaphore(value: 0)
        defer { blocker.signal() }
        let chrome = ChromiumSiteRuleTests.MockChromiumReader(windowIDs: [50])
        chrome.titles.withLock { $0[50] = "Shop - Google Chrome" }
        chrome.docs.withLock { $0[50] = "https://shop.example/" }

        let chromeDone = OneShotContinuationGate()
        let safariWalked = OSAllocatedUnfairLock(initialState: false)
        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [300] }
        hooks.pipPIDs = { [] }
        hooks.chromePIDs = { [100] }
        hooks.edgePIDs = { [] }
        hooks.bravePIDs = { [] }
        hooks.firefoxPIDs = { [Self.pid] }
        hooks.firefoxEligible = { _ in true }
        hooks.copyOnScreen = {
            [Self.pageWindow(10), SiteVisibleWindow(windowID: 50, pid: 100, layer: 0, title: "Shop"),
             SiteVisibleWindow(windowID: 60, pid: 300, layer: 0, title: "Docs")]
        }
        hooks.chromiumReader = chrome
        hooks.firefoxReader = HungFirefoxReader(blocker: blocker)
        hooks.observe = { _, _, title in
            safariWalked.withLock { $0 = true }
            return (title, WebAreaWalkResult(urls: ["https://docs.example/"], completeness: .complete), title, false)
        }
        let sampler = SiteSampler(
            probe: AccessibilityProbe(readWorks: { true }, prompt: {}),
            isSnapshot: true,
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in },
            onChromiumReadComplete: { browser, _, _, _ in
                if browser == .chrome { chromeDone.release() }
            }
        )
        await sampler.applySites(["bank.example"], generation: 1)

        let started = ContinuousClock.now
        await sampler.performPollForTesting()
        #expect(ContinuousClock.now - started < .seconds(2))
        await chromeDone.wait()
        await sampler.performWalkPassForTesting()
        #expect(safariWalked.withLock { $0 })
        #expect(ContinuousClock.now - started < .seconds(5))
        // The next poll finds Firefox's round still in flight: its window is missed, not waited on.
        await sampler.performPollForTesting()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await sampler.failureCountForTesting(.firefox) == 1)
    }

    // MARK: - Only the allowed reads

    static let allowedReads: Set<AllowedAXRead> = {
        var allowed: Set<AllowedAXRead> = [
            AllowedAXRead(attribute: "AXRole", role: "AXApplication"),
            AllowedAXRead(attribute: "AXWindows", role: "AXApplication"),
            AllowedAXRead(attribute: "AXTitle", role: "AXWindow"),
            AllowedAXRead(attribute: "AXPosition", role: "AXWindow"),
            AllowedAXRead(attribute: "AXSize", role: "AXWindow"),
            AllowedAXRead(attribute: "AXRole", role: nil),
            AllowedAXRead(attribute: "AXSubrole", role: "AXGroup"),
            // A tab panel's frame and its holding group's, for split view.
            AllowedAXRead(attribute: "AXPosition", role: "AXGroup"),
            AllowedAXRead(attribute: "AXSize", role: "AXGroup"),
            AllowedAXRead(attribute: "AXURL", role: "AXWebArea"),
            AllowedAXRead(attribute: "AXPosition", role: "AXWebArea"),
            AllowedAXRead(attribute: "AXSize", role: "AXWebArea"),
        ]
        return allowed
    }()

    @Test func everyFirefoxCaseReadsOnlyTheAllowedAttributes() async {
        let h = FirefoxSamplerHarness(firefoxPIDs: [Self.pid, -701], eligible: [Self.pid])
        let ids = h.tree.addBrowserWindow(pid: Self.pid, wid: 10, title: "News", pageURL: "https://news.example/",
                                          sidebarURL: "chrome://browser/content/places/bookmarksSidebar.xhtml",
                                          devtoolsURL: "about:devtools-toolbox")
        h.tree.addLibraryWindow(pid: Self.pid, wid: 11)
        h.tree.addPiPWindow(pid: Self.pid, wid: 30, originText: "bank.example")
        h.tree.addBrowserWindow(pid: -701, wid: 70, title: "Old", pageURL: "https://bank.example/")
        h.show([Self.pageWindow(), Self.pageWindow(11, title: "Library"), Self.pageWindow(20, title: ""),
                Self.pageWindow(30, title: "", layer: 3), Self.pageWindow(40, title: "", layer: 101),
                SiteVisibleWindow(windowID: 70, pid: -701, layer: 0, title: "Old")])
        await h.start(sites: ["bank.example"])
        for _ in 0..<4 { await h.poll() }
        // Reader View, a covered tab and a failing walk.
        h.tree.update(ids.page) { $0.url = "about:reader?url=https%3A%2F%2Fbank.example%2F" }
        for _ in 0..<2 { await h.poll() }
        h.tree.update(ids.tabPanel) { $0.childrenError = .cannotComplete }
        for _ in 0..<2 { await h.poll() }
        h.tree.axWindowsFails = [Self.pid]
        for _ in 0..<2 { await h.poll() }

        let reads = h.recorder.recordedReads
        let childReads = reads.filter { $0.attribute == "AXChildren" }
        let other = reads.subtracting(childReads)
        #expect(other.isSubset(of: Self.allowedReads), "unexpected reads: \(other.subtracting(Self.allowedReads))")
        // Never into a web area.
        for read in childReads {
            #expect(read.role != "AXWebArea")
        }
        // A page window's walk never enters the tab strip or the navigation toolbar.
        let container = h.tree.node(ids.container)!.children
        let toolbars = container.filter { h.tree.node($0)?.role == "AXToolbar" }
        let log = h.tree.locked { $0.attributeLog }
        for toolbar in toolbars {
            #expect(!log.contains { $0.id == toolbar && $0.attribute == "AXChildren" })
            for child in h.tree.node(toolbar)!.children {
                #expect(!log.contains { $0.id == child })
            }
        }
        #expect(!reads.contains { ["AXEnhancedUserInterface", "AXManualAccessibility", "AXFocusedUIElement"].contains($0.attribute) })
        #expect(Set(h.recorder.applicationReads.map(\.pid)) == [Self.pid])
        #expect(Self.appRoleReads(h.recorder) == [Self.pid])
        #expect(h.recorder.actionCount == 0)
        #expect(h.recorder.setCount == 0)
        // No value was read but a side window's static text.
        #expect(!log.contains { $0.attribute == kAXValueAttribute as String && $0.id != nil && h.tree.node($0.id!)?.role != "AXStaticText" })
    }
}

// MARK: - The frame gate and the capture manager

@Suite("FirefoxGate")
@MainActor
struct FirefoxGateTests {
    let displayID: CGDirectDisplayID = 1
    static let pid: pid_t = 700

    static func read(_ verdict: ChromiumVerdict, cause: ChromiumUnclearCause? = nil, host: String? = nil,
                     start: TimeInterval, browser: PrivateBrowser = .firefox) -> ChromiumPollRead {
        ChromiumPollRead(verdict: verdict, cause: cause, host: host, readStart: start, listGeneration: 1, browser: browser, isPending: false)
    }

    static func page(_ verdict: ChromiumVerdict = .ordinary, start: TimeInterval, host: String? = "news.example") -> SitePollWindow {
        SitePollWindow(windowID: 10, title: "News", pid: pid, chromium: read(verdict, host: host, start: start))
    }

    static func panel(start: TimeInterval) -> SitePollWindow {
        SitePollWindow(windowID: 20, title: "", pid: pid, chromium: read(.cantTell, cause: .panel, start: start))
    }

    func makeGate() -> SiteFrameGate {
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        gate.updateSiteList(["bank.example"], generation: 1)
        return gate
    }

    func frame(_ id: UInt64, c: TimeInterval, keptOut: Set<pid_t> = []) -> SiteHeldFrame {
        let origin = SiteFrameGateTests.makeTicks(fromSeconds: 100)
        return SiteHeldFrame(id: id, displayTicks: origin, c: c, originTicks: origin, keptOutPIDs: keptOut)
    }

    @Test func aPanelTakesFirefoxOutAtOnceAndClearsOnTheFirstAllOrdinaryPoll() {
        let gate = makeGate()
        var t = 10.0
        gate.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t), Self.panel(start: t)]))
        #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: false, now: t + 0.01))
        #expect(gate.chromiumSitOutIsPanelOnly(for: .firefox))
        for _ in 0..<40 {   // 10 s on screen
            t += 0.25
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t), Self.panel(start: t)]))
            #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: true, now: t + 0.01))
        }
        // The panel closes: the first complete poll with every window ordinary brings Firefox back,
        // with no hold-down.
        t += 0.25
        gate.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t)]))
        #expect(!gate.chromiumShouldSitOut(for: .firefox, isOutNow: true, now: t + 0.01))
        #expect(!gate.chromiumSitOutIsPanelOnly(for: .firefox))
    }

    @Test func aPanelBesideAnUnclearWindowIsNotPanelOnly() {
        let gate = makeGate()
        gate.addPoll(SitePollSnapshot(start: 10, end: 10.01, windows: [Self.page(.cantTell, start: 10), Self.panel(start: 10)]))
        #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: false, now: 10.01))
        #expect(!gate.chromiumSitOutIsPanelOnly(for: .firefox))
    }

    @Test func aPanelDropCarriesItsOwnReasonAndClosesTheIntakeRange() {
        let gate = makeGate()
        let log = IntakeIntervalLog()
        log.beginDisplay(String(displayID), at: 0)
        gate.intakeLog = log
        for t in [9.75, 10.0, 10.25, 10.5] {
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t), Self.panel(start: t)]))
        }
        _ = gate.enqueue(displayID: displayID, frame: frame(1, c: 10.0))
        #expect(gate.evaluate(displayID: displayID, now: 11) == [.drop(id: 1, reason: .panel)])
        #expect(gate.panelDropCount == 1)
        #expect(gate.holdDropCount == 0)
        #expect(gate.covCount == 0)
        #expect(gate.heldSince[displayID] == 10.0)
        #expect(log.screenRanges()[String(displayID)]?.isEmpty == false)
    }

    @Test func aFrameBeforeThePollThatFirstListsAPanelDrops() {
        let gate = makeGate()
        gate.addPoll(SitePollSnapshot(start: 9.75, end: 9.76, windows: [Self.page(start: 9.75)]))
        gate.addPoll(SitePollSnapshot(start: 10.0, end: 10.01, windows: [Self.page(start: 10.0)]))
        gate.addPoll(SitePollSnapshot(start: 10.25, end: 10.26, windows: [Self.page(start: 10.25)]))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.51, windows: [Self.page(start: 10.5), Self.panel(start: 10.5)]))
        gate.addPoll(SitePollSnapshot(start: 10.75, end: 10.76, windows: [Self.page(start: 10.75), Self.panel(start: 10.75)]))
        // c is 0.4 s before the panel's first poll, which is the bracket's late poll.
        _ = gate.enqueue(displayID: displayID, frame: frame(1, c: 10.1))
        #expect(gate.evaluate(displayID: displayID, now: 11) == [.drop(id: 1, reason: .panel)])
        // The twin without the panel releases.
        let twin = makeGate()
        for t in [9.75, 10.0, 10.25, 10.5, 10.75] {
            twin.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t)]))
        }
        _ = twin.enqueue(displayID: displayID, frame: frame(1, c: 10.1))
        if case .release = twin.evaluate(displayID: displayID, now: 11).first {} else { Issue.record("expected the twin to release") }
    }

    @Test func aFrameKeptOutOfFirefoxIsVouchedPastItsPanel() {
        let gate = makeGate()
        for t in [9.75, 10.0, 10.25, 10.5] {
            gate.addPoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [Self.page(start: t), Self.panel(start: t)]))
        }
        _ = gate.enqueue(displayID: displayID, frame: frame(1, c: 10.0, keptOut: [Self.pid]))
        if case .release = gate.evaluate(displayID: displayID, now: 11).first {} else { Issue.record("expected a release") }
    }

    @Test func eachBrowserSitsOutAndClearsOnItsOwn() {
        let gate = makeGate()
        let chromeOrdinary = SitePollWindow(windowID: 50, title: "Shop", pid: 100, chromium: Self.read(.ordinary, host: "shop.example", start: 10, browser: .chrome))
        let chromeCovered = SitePollWindow(windowID: 50, title: "Bank", pid: 100, chromium: Self.read(.covered, host: "bank.example", start: 10, browser: .chrome))
        gate.addPoll(SitePollSnapshot(start: 10, end: 10.01, windows: [Self.page(.covered, start: 10, host: "bank.example"), chromeOrdinary]))
        #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: false, now: 10.01))
        #expect(!gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 10.01))
        gate.addPoll(SitePollSnapshot(start: 10.25, end: 10.26, windows: [Self.page(.covered, start: 10.25, host: "bank.example"), chromeCovered]))
        #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: true, now: 10.26))
        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: false, now: 10.26))
        gate.addPoll(SitePollSnapshot(start: 10.5, end: 10.51, windows: [Self.page(start: 10.5), chromeCovered]))
        #expect(!gate.chromiumShouldSitOut(for: .firefox, isOutNow: true, now: 10.51))
        #expect(gate.chromiumShouldSitOut(for: .chrome, isOutNow: true, now: 10.51))
        gate.addPoll(SitePollSnapshot(start: 10.75, end: 10.76, windows: [Self.page(.covered, start: 10.75, host: "bank.example"), chromeOrdinary]))
        #expect(gate.chromiumShouldSitOut(for: .firefox, isOutNow: false, now: 10.76))
        #expect(!gate.chromiumShouldSitOut(for: .chrome, isOutNow: true, now: 10.76))
    }

    // MARK: - Every sit-out path

    func activeCapture() -> CaptureManager {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.example"])
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        return capture
    }

    func coveredPoll(_ capture: CaptureManager, at t: TimeInterval) -> SitePollSnapshot {
        SitePollSnapshot(start: t, end: t + 0.01, windows: [
            SitePollWindow(windowID: 10, title: "Bank", pid: Self.pid,
                           chromium: ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.example", readStart: t,
                                                      listGeneration: capture.siteListGeneration, browser: .firefox, isPending: false)),
        ])
    }

    func expectFirefoxOut(_ capture: CaptureManager, _ note: Comment) {
        #expect(capture.siteKeptOutBrowsers.contains(.firefox), note)
        #expect(capture.siteNamedKeptOutBrowsers.contains(.firefox), note)
        #expect(capture.exclusionNamesForTesting.contains("org.mozilla.firefox"), note)
    }

    @Test func everySitOutPathKeepsACoveredFirefoxOut() {
        let capture = activeCapture()
        let t = capture.siteNowSeconds()

        // The poll.
        capture.receiveSitePoll(coveredPoll(capture, at: t))
        expectFirefoxOut(capture, "poll")
        #expect(!capture.siteKeptOutBrowsers.contains(.chrome))

        // A late covered result for a poll already past its deadline.
        let late = AppState.forSnapshot(config: AppConfig()).captureManager
        late.updateSiteRule(["bank.example"])
        late.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: late.siteListGeneration)
        let start = late.siteNowSeconds() - 1.0
        var pending = coveredPoll(late, at: start)
        pending.windows = [SitePollWindow(windowID: 10, title: "Bank", pid: Self.pid,
                                          chromium: ChromiumPollRead(verdict: .cantTell, cause: nil, host: nil, readStart: start,
                                                                     listGeneration: late.siteListGeneration, browser: .firefox, isPending: true))]
        late.receiveSitePoll(pending)
        late.receiveChromiumReadComplete(
            browser: .firefox,
            results: [10: (read: ChromiumPollRead(verdict: .covered, cause: nil, host: "bank.example", readStart: start,
                                                  listGeneration: late.siteListGeneration, browser: .firefox, isPending: false),
                           cgTitle: "Bank", axTitle: "Bank")],
            startSec: start,
            generation: late.siteListGeneration
        )
        expectFirefoxOut(late, "late covered result")

        // A miss keeps it out.
        capture.receiveChromiumMiss(browser: .firefox, windowID: 10, cgTitle: "Bank", startSec: t + 0.25, generation: capture.siteListGeneration)
        expectFirefoxOut(capture, "miss")

        // Accessibility availability arriving again keeps it out.
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        expectFirefoxOut(capture, "availability")

        // Its caution is published, and suspension clears it with everything else.
        capture.receiveChromiumCaution(browser: .firefox, caution: true)
        #expect(capture.siteFirefoxCaution)
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(!capture.siteRuleActive)
        #expect(!capture.siteFirefoxCaution)
        #expect(capture.siteKeptOutBrowsers.isEmpty)

        // After it resumes, a covered Firefox goes out again.
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        #expect(capture.siteRuleActive)
        capture.receiveSitePoll(coveredPoll(capture, at: capture.siteNowSeconds()))
        expectFirefoxOut(capture, "resume")
    }

    @Test func thePanelHoldKeepsFirefoxOutWithoutNamingIt() {
        let capture = activeCapture()
        let t = capture.siteNowSeconds()
        let gen = capture.siteListGeneration
        func w(_ wid: CGWindowID, _ v: ChromiumVerdict, _ cause: ChromiumUnclearCause?, _ host: String?) -> SitePollWindow {
            SitePollWindow(windowID: wid, title: "", pid: Self.pid,
                           chromium: ChromiumPollRead(verdict: v, cause: cause, host: host, readStart: t, listGeneration: gen, browser: .firefox, isPending: false))
        }
        capture.receiveSitePoll(SitePollSnapshot(start: t, end: t + 0.01, windows: [w(10, .ordinary, nil, "news.example"), w(20, .cantTell, .panel, nil)]))
        #expect(capture.siteKeptOutBrowsers.contains(.firefox))
        #expect(capture.exclusionNamesForTesting.contains("org.mozilla.firefox"))
        #expect(!capture.siteNamedKeptOutBrowsers.contains(.firefox))
        #expect(!capture.siteFirefoxCaution)

        // A left-out page while the panel is open is named.
        capture.receiveSitePoll(SitePollSnapshot(start: t + 0.25, end: t + 0.26, windows: [w(10, .covered, nil, "bank.example"), w(20, .cantTell, .panel, nil)]))
        #expect(capture.siteNamedKeptOutBrowsers.contains(.firefox))
    }
}

// MARK: - Activity

@Suite("FirefoxActivity")
struct FirefoxActivityTests {
    static func settings(_ sites: [String]) -> DesktopActivitySettings {
        var config = AppConfig()
        config.excludedSites = sites
        var s = DesktopActivitySettings(config)
        s.titles = true
        s.urls = true
        s.accessibility = true
        s.excludePrivate = true
        s.privateAccessibility = false
        return s
    }

    struct Probe: @unchecked Sendable {
        let tree: FakeFirefoxTree
        let window: AXUIElement
        let rolesAsked = OSAllocatedUnfairLock(initialState: [AXUIElement]())
    }

    /// Every walk the reader asks for, of whichever element. A Firefox read never uses this walk.
    final class WalkCalls: @unchecked Sendable {
        let elements = OSAllocatedUnfairLock(initialState: [AXUIElement]())
        var count: Int { elements.withLock { $0.count } }
    }

    static func reader(_ seams: DesktopActivityReadSeams, walks: WalkCalls = WalkCalls(), failOnWalk: Bool = true) -> DesktopActivityReader {
        struct Box: @unchecked Sendable { let walks: WalkCalls }
        let box = Box(walks: walks)
        return DesktopActivityReader(
            permit: DesktopActivityReadPermit(),
            walkSeam: { element, _, _, _ in
                box.walks.elements.withLock { $0.append(element) }
                if failOnWalk { Issue.record("the activity walk was called") }
                return WebAreaWalkResult(urls: [], completeness: .complete)
            },
            seams: seams
        )
    }

    static func seams(_ tree: FakeFirefoxTree, window: Int, title: String, frontTitle: String? = nil, eligible: Bool = true,
                      focused: Bool = true, probe: Probe? = nil, recorder: AXReadRecorder? = nil) -> DesktopActivityReadSeams {
        let element = focused ? tree.element(window) : nil
        struct Box: @unchecked Sendable { let element: AXUIElement? }
        let box = Box(element: element)
        return DesktopActivityReadSeams(
            chromiumReader: LiveChromiumWindowReader(),
            preflightScreenCapture: { true },
            frontWindow: { _ in DesktopActivityFrontWindow(windowID: 10, title: frontTitle ?? title) },
            focusedRead: { _ in (element: box.element, error: .success) },
            role: { el in
                probe?.rolesAsked.withLock { $0.append(el) }
                return kAXWindowRole
            },
            axWindowID: { _ in 10 },
            axTitle: { _ in title },
            cgTitle: { _, _ in title },
            readDocument: { _ in (doc: nil, failed: true) },
            settle: {},
            nowTicks: { FirefoxTestClock.ticks(seconds: 100) },
            firefoxReader: tree.makeReader(recorder: recorder),
            firefoxEligible: { _ in eligible }
        )
    }

    static let firefox = DesktopActivityApp(pid: -700, name: "Firefox", bundleID: "org.mozilla.firefox")

    static func tree(_ url: String, title: String = "News") -> (FakeFirefoxTree, Int) {
        let tree = FakeFirefoxTree()
        let ids = tree.addBrowserWindow(pid: -700, wid: 10, title: title, pageURL: url)
        tree.setEngine(true, pid: -700)
        return (tree, ids.window)
    }

    static func snapshot(_ verdict: ChromiumVerdict, host: String?, start: TimeInterval = 99.8) -> ChromiumActivitySnapshot {
        var snap = ChromiumActivitySnapshot(currentGeneration: 1)
        snap.latestCompleteRead[10] = ChromiumActivityWindowSnapshot(verdict: verdict, host: host, start: start, listGeneration: 1)
        return snap
    }

    static func foreground(_ obs: DesktopActivityObservation) -> DesktopActivityRow? {
        obs.rows.first { $0.kind == "foreground" }
    }

    @Test func aCoveredPageByEitherReadLeavesNoRows() {
        let (tree, window) = Self.tree("https://bank.example/")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
        #expect(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.ordinary, host: "bank.example")).rows.isEmpty)

        let (tree2, window2) = Self.tree("https://news.example/")
        let reader2 = Self.reader(Self.seams(tree2, window: window2, title: "News"))
        #expect(reader2.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.covered, host: "bank.example")).rows.isEmpty)
    }

    @Test func aReaderViewOfALeftOutPageLeavesNoRows() {
        let (tree, window) = Self.tree("about:reader?url=https%3A%2F%2Fbank.example%2Fx")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
        #expect(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.ordinary, host: "bank.example")).rows.isEmpty)
    }

    @Test func noSamplerReadWithAListWithholdsTitleAndAddress() {
        let (tree, window) = Self.tree("https://news.example/a")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
        let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"])))
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func aStaleOrDisagreeingSamplerReadWithholdsTitleAndAddress() {
        for snap in [Self.snapshot(.ordinary, host: "news.example", start: 98.5),
                     Self.snapshot(.ordinary, host: "shop.example"),
                     Self.snapshot(.cantTell, host: "news.example")] {
            let (tree, window) = Self.tree("https://news.example/a")
            let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
            let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: snap))
            #expect(row?.title == nil)
            #expect(row?.url == nil)
        }
    }

    @Test func anOrdinaryPageWithAFreshSamplerReadKeepsTitleAndAddress() {
        let (tree, window) = Self.tree("https://news.example/a?q=1")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
        let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.ordinary, host: "news.example")))
        #expect(row?.title == "News")
        #expect(row?.url == "https://news.example/a")
    }

    @Test func noFocusedWindowWithAListWithholdsTheTitleAndKeepsItWithout() {
        let (tree, window) = Self.tree("https://news.example/")
        let listed = Self.reader(Self.seams(tree, window: window, title: "News", focused: false))
        #expect(Self.foreground(listed.read(app: Self.firefox, settings: Self.settings(["bank.example"])))?.title == nil)
        #expect(Self.foreground(listed.read(app: Self.firefox, settings: Self.settings([])))?.title == "News")
    }

    @Test func anEmptyListKeepsTheTitleAndRecordsOnlyAWebAddress() {
        let (tree, window) = Self.tree("https://news.example/a")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News"))
        let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings([])))
        #expect(row?.title == "News")
        #expect(row?.url == "https://news.example/a")

        let (fileTree, fileWindow) = Self.tree("file:///Users/sol/page.html")
        let fileReader = Self.reader(Self.seams(fileTree, window: fileWindow, title: "News"))
        let fileRow = Self.foreground(fileReader.read(app: Self.firefox, settings: Self.settings([])))
        #expect(fileRow?.title == "News")
        #expect(fileRow?.url == nil)
    }

    @Test func aPrivateWindowIsDecidedFirst() {
        let title = "News \u{2014} Private Browsing"
        let (tree, window) = Self.tree("https://news.example/", title: title)
        let reader = Self.reader(Self.seams(tree, window: window, title: title))
        #expect(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"])).rows.isEmpty)
        #expect(tree.locked { $0.attributeLog }.isEmpty)
    }

    @Test func anIneligibleFirefoxIsNeverReadThisWay() {
        let (tree, window) = Self.tree("https://bank.example/")
        let probe = Probe(tree: tree, window: tree.element(window))
        let app = AXUIElementCreateApplication(-700)

        // Addresses off and no list: no walk of any kind.
        var quiet = Self.settings([])
        quiet.urls = false
        let silent = Self.reader(Self.seams(tree, window: window, title: "News", eligible: false, probe: probe), failOnWalk: true)
        #expect(Self.foreground(silent.read(app: Self.firefox, settings: quiet))?.title == "News")

        // With a list, the activity walk a Firefox below 162 has always had still runs, from the
        // focused window only, never the application element. The Firefox read is never used.
        let walks = WalkCalls()
        let listed = Self.reader(Self.seams(tree, window: window, title: "News", eligible: false, probe: probe), walks: walks, failOnWalk: false)
        _ = listed.read(app: Self.firefox, settings: Self.settings(["bank.example"]))
        #expect(walks.count > 0)
        #expect(walks.elements.withLock { $0 }.allSatisfy { CFEqual($0, probe.window) && !CFEqual($0, app) })
        #expect(tree.locked { $0.attributeLog }.isEmpty)
        #expect(!probe.rolesAsked.withLock { $0 }.contains { CFEqual($0, app) })
    }

    @Test func theRowTitleIsTheOneTheReadsCleared() {
        // The window list's title moved on from the one both reads saw.
        let (tree, window) = Self.tree("https://news.example/a")
        let reader = Self.reader(Self.seams(tree, window: window, title: "News", frontTitle: "Bank"), failOnWalk: true)
        let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.ordinary, host: "news.example")))
        #expect(row != nil)
        #expect(row?.title == nil)
        #expect(row?.url == nil)
    }

    @Test func anActivityReadMakesOnlyTheAllowedReads() {
        let (tree, window) = Self.tree("https://news.example/a")
        let recorder = AXReadRecorder()
        let reader = Self.reader(Self.seams(tree, window: window, title: "News", recorder: recorder), failOnWalk: true)
        let row = Self.foreground(reader.read(app: Self.firefox, settings: Self.settings(["bank.example"]), snapshot: Self.snapshot(.ordinary, host: "news.example")))
        #expect(row?.title == "News")
        let reads = recorder.recordedReads
        #expect(!reads.isEmpty)
        let children = reads.filter { $0.attribute == "AXChildren" }
        #expect(reads.subtracting(children).isSubset(of: FirefoxSamplerTests.allowedReads))
        #expect(children.allSatisfy { $0.role != "AXWebArea" && !FirefoxSiteRead.skippedRoles.contains($0.role ?? "") })
        #expect(!reads.contains { $0.attribute == "AXValue" })
        #expect(recorder.applicationReads.isEmpty)
        #expect(recorder.actionCount == 0)
        #expect(recorder.setCount == 0)
    }

    @Test func aRevokedPermitStopsTheWalk() {
        let (tree, window) = Self.tree("https://news.example/a")
        let permit = DesktopActivityReadPermit()
        let recorder = AXReadRecorder()
        let reader = LiveFirefoxWindowReader(recorder: recorder, permit: permit)
        let live = tree.makeReader(recorder: recorder)
        reader.copyAttribute = live.copyAttribute
        permit.revoke()
        let walk = reader.walkWindow(tree.element(window), maxElements: 200, timeoutSeconds: 1, nowTicks: { mach_absolute_time() })
        #expect(walk.outcome == .failed)
        #expect(walk.areas.isEmpty)
        #expect(reader.readFrame(for: tree.element(window)) == nil)
        #expect(recorder.recordedReads.isEmpty)
    }
}

// MARK: - The wire

#if SOLSTONE_BROWSER_INTAKE_PREVIEW
@Suite("FirefoxWire")
struct FirefoxWireTests {
    @Test func aFirefoxSessionIsCheckedOnlyForAnEligibleParent() {
        var snapshot = BrowserSiteListSnapshot(sites: ["bank.example"], accessibilityWorks: true, eligibleFirefoxPIDs: [700])
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefox", parentPID: 700) == "on")
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefox", parentPID: 701) == "not_checked")
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefox", parentPID: nil) == "not_checked")
        #expect(snapshot.sitesValue(for: .firefox, bundleID: nil, parentPID: 700) == "not_checked")
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefoxdeveloperedition", parentPID: 700) == "not_checked")
        #expect(snapshot.sitesValue(for: .chrome, bundleID: "org.mozilla.firefox") == "not_checked")
        snapshot.cautionedBundleIDs = ["org.mozilla.firefox"]
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefox", parentPID: 700) == "unreadable")
        #expect(snapshot.sitesValue(for: .chrome, bundleID: "com.google.Chrome") == "on")
        snapshot.accessibilityWorks = false
        #expect(snapshot.sitesValue(for: .firefox, bundleID: "org.mozilla.firefox", parentPID: 700) == "needs_access")
    }

    @Test func aHostWithNoParentPidIsNotCheckedWhateverIsRunning() {
        let snapshot = BrowserSiteListSnapshot(sites: ["bank.example"], accessibilityWorks: true, eligibleFirefoxPIDs: [700, 701, 702])
        let context = BrowserHostConnectionContext.decode(Data(#"{"type":"local_hello","brand":"firefox","mode":"production","bundle_id":"org.mozilla.firefox"}"#.utf8))
        #expect(context?.parentPID == nil)
        #expect(snapshot.sitesValue(for: .firefox, bundleID: context?.bundleID, parentPID: context?.parentPID) == "not_checked")
    }

    @Test func theHelloCarriesTheParentPidAsAString() {
        let context = BrowserHostConnectionContext.decode(Data(#"{"type":"local_hello","brand":"firefox","mode":"production","bundle_id":"org.mozilla.firefox","parent_pid":"700"}"#.utf8))
        #expect(context?.bundleID == "org.mozilla.firefox")
        #expect(context?.parentPID == 700)
        for bad in ["", "x", "-4", "0", "1"] {
            let c = BrowserHostConnectionContext.decode(Data(#"{"type":"local_hello","brand":"firefox","mode":"production","parent_pid":"\#(bad)"}"#.utf8))
            #expect(c != nil)
            #expect(c?.parentPID == nil)
        }
    }

    @MainActor final class Calls { var count = 0 }

    @Test @MainActor func aLaunchOrQuitRepublishes() async {
        let center = NotificationCenter()
        let calls = Calls()
        let observer = RunningApplicationsObserver(center: center) { calls.count += 1 }
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for _ in 0..<100 where calls.count < 2 { await Task.yield() }
        #expect(calls.count == 2)
        observer.invalidate()
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(calls.count == 2)

        // A changed set of eligible Firefox processes is a new snapshot.
        let source = BrowserSiteListSource()
        let running: [(pid: pid_t, bundleID: String?)] = [(700, "org.mozilla.firefox"), (701, "org.mozilla.firefox"), (800, "com.google.Chrome")]
        let eligible = RunningApplicationsObserver.eligibleFirefoxPIDs(running: running, isEligible: { $0 == 700 })
        #expect(eligible == [700])
        #expect(source.update(BrowserSiteListSnapshot(sites: ["bank.example"], epoch: "e", accessibilityWorks: true, eligibleFirefoxPIDs: eligible)))
        #expect(!source.update(BrowserSiteListSnapshot(sites: ["bank.example"], epoch: "e", accessibilityWorks: true, eligibleFirefoxPIDs: eligible)))
        let quit = RunningApplicationsObserver.eligibleFirefoxPIDs(running: Array(running.dropFirst()), isEligible: { $0 == 700 })
        #expect(source.update(BrowserSiteListSnapshot(sites: ["bank.example"], epoch: "e", accessibilityWorks: true, eligibleFirefoxPIDs: quit)))
    }
}
#endif
