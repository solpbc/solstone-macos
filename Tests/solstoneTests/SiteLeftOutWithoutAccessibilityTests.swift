// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

/// When the website rule can't read Safari's addresses, Safari alone sits out of capture. These
/// pin the guarantee: no frame is released unless the stream that captured it had confirmed a
/// filter keeping every on-screen Safari window out.
@Suite("Website rule without Accessibility")
@MainActor
struct SiteLeftOutWithoutAccessibilityTests {
    private let display: CGDirectDisplayID = 1
    private let safari: pid_t = 500
    private let pip: pid_t = 600

    private func polls(_ gate: SiteFrameGate, _ windows: [SitePollWindow]) {
        for i in 0..<8 {
            let start = 9.5 + Double(i) * 0.25
            gate.addPoll(SitePollSnapshot(start: start, end: start + 0.05, windows: windows))
        }
    }

    private func frame(keptOut: Set<pid_t> = [], c: TimeInterval = 10.0) -> SiteHeldFrame {
        SiteHeldFrame(id: 1, displayTicks: 1, c: c, originTicks: 0, keptOutPIDs: keptOut)
    }

    private func isReleased(_ actions: [SiteFrameAction]) -> Bool {
        actions.contains { if case .release = $0 { return true } else { return false } }
    }

    private func isDropped(_ actions: [SiteFrameAction]) -> Bool {
        actions.contains { if case .drop = $0 { return true } else { return false } }
    }

    private func covered(_ key: SiteDecisionKey, now: TimeInterval = 10.0) -> SiteDecision {
        var decisions = SiteDecision()
        decisions.evaluate(key: key, initialAXTitle: key.title, finalAXTitle: key.title,
                           walk: WebAreaWalkResult(urls: ["https://bank.com"], completeness: .complete),
                           sites: ["bank.com"], now: now, isSweep: false)
        return decisions
    }

    // MARK: gate

    @Test func vouchedSafariReleasesWithAccessibilityOffAndOn() {
        for ax in [false, true] {
            let gate = SiteFrameGate()
            polls(gate, [SitePollWindow(windowID: 1, title: "Page", pid: safari)])
            gate.updateDecisions(SiteDecision(), axAvailable: ax)
            _ = gate.enqueue(displayID: display, frame: frame(keptOut: [safari]))
            #expect(isReleased(gate.evaluate(displayID: display, now: 11.0)), "ax=\(ax)")
        }
    }

    @Test func unvouchedSafariHoldsWithoutAccessibility() {
        let gate = SiteFrameGate()
        polls(gate, [SitePollWindow(windowID: 1, title: "Page", pid: safari)])
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        _ = gate.enqueue(displayID: display, frame: frame())
        let held = gate.evaluate(displayID: display, now: 10.8)
        #expect(!isReleased(held) && !isDropped(held))
        #expect(isDropped(gate.evaluate(displayID: display, now: 12.1)))
    }

    @Test func aSafariRelaunchIsNotVouchedByTheOldPid() {
        let gate = SiteFrameGate()
        polls(gate, [SitePollWindow(windowID: 1, title: "Page", pid: safari + 1)])
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        _ = gate.enqueue(displayID: display, frame: frame(keptOut: [safari]))
        #expect(!isReleased(gate.evaluate(displayID: display, now: 10.8)))
    }

    @Test func aVouchedWindowDoesNotExcuseACoveredOne() {
        let gate = SiteFrameGate()
        let page = SitePollWindow(windowID: 1, title: "Bank", pid: safari)
        let agent = SitePollWindow(windowID: 2, title: "Picture in Picture", pid: pip)
        polls(gate, [page, agent])
        gate.updateDecisions(covered(SiteDecisionKey(windowID: 1, title: "Bank")), axAvailable: true)
        _ = gate.enqueue(displayID: display, frame: frame(keptOut: [pip]))
        #expect(isDropped(gate.evaluate(displayID: display, now: 11.0)))
    }

    @Test func pictureInPictureHoldsUntilVouchedWithAccessibilityOn() {
        let gate = SiteFrameGate()
        polls(gate, [SitePollWindow(windowID: 2, title: "Picture in Picture", pid: pip)])
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        _ = gate.enqueue(displayID: display, frame: frame())
        #expect(!isReleased(gate.evaluate(displayID: display, now: 10.8)))

        let later = SiteFrameGate()
        polls(later, [SitePollWindow(windowID: 2, title: "Picture in Picture", pid: pip)])
        later.updateDecisions(SiteDecision(), axAvailable: true)
        _ = later.enqueue(displayID: display, frame: frame(keptOut: [pip]))
        #expect(isReleased(later.evaluate(displayID: display, now: 10.8)))
    }

    // MARK: the held row

    @Test func heldSurvivesAQuietScreenOnACoveredPageAndNotOnAnOrdinaryOne() {
        let gate = SiteFrameGate()
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        let page = SitePollWindow(windowID: 1, title: "Bank", pid: safari)
        polls(gate, [page])
        gate.updateDecisions(covered(key), axAvailable: true)
        _ = gate.enqueue(displayID: display, frame: frame())
        #expect(isDropped(gate.evaluate(displayID: display, now: 10.9)))
        #expect(!gate.isHoldingNow(now: 11.5))
        #expect(gate.isHoldingNow(now: 13.5))

        // The owner moves to an ordinary page and nothing on screen changes after that.
        var ordinary = SiteDecision()
        ordinary.evaluate(key: key, initialAXTitle: "Bank", finalAXTitle: "Bank",
                          walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
                          sites: ["bank.com"], now: 13.5, isSweep: false)
        gate.updateDecisions(ordinary, axAvailable: true)
        #expect(!gate.isHoldingNow(now: 13.6))
    }

    @Test func aVouchedSafariIsNotHeld() {
        let gate = SiteFrameGate()
        polls(gate, [SitePollWindow(windowID: 1, title: "Page", pid: safari)])
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        _ = gate.enqueue(displayID: display, frame: frame())
        #expect(isDropped(gate.evaluate(displayID: display, now: 12.1)))
        #expect(gate.isHoldingNow(now: 13.5))

        // The stream takes the filter and the screen stays quiet: no new frame says so.
        gate.updateLiveKeptOut(displayID: display, pids: [safari])
        #expect(!gate.isHoldingNow(now: 13.6))
    }

    @Test func aSegmentBoundaryDoesNotInterruptAHold() {
        let gate = SiteFrameGate()
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        polls(gate, [SitePollWindow(windowID: 1, title: "Bank", pid: safari)])
        gate.updateDecisions(covered(key), axAvailable: true)
        _ = gate.enqueue(displayID: display, frame: frame())
        #expect(isDropped(gate.evaluate(displayID: display, now: 10.9)))
        _ = gate.drain(displayID: display, now: 13.0)
        #expect(gate.isHoldingNow(now: 13.5))
    }

    @Test func aFrameWithNoTimeDoesNotStartAHold() {
        let gate = SiteFrameGate()
        polls(gate, [SitePollWindow(windowID: 1, title: "Page", pid: safari)])
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        _ = gate.enqueue(displayID: display, frame: SiteHeldFrame(id: 1, displayTicks: nil, c: nil, originTicks: 0))
        #expect(isDropped(gate.evaluate(displayID: display, now: 13.0)))
        #expect(!gate.isHoldingNow(now: 20.0))
    }

    // MARK: only a live stream vouches

    private func capturer(_ stream: FakeCaptureStream, filter: SCContentFilter, root: URL) throws -> ScreenshotCapturer {
        try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("1.mp4"),
            width: 16, height: 16, frameRate: 1, duration: nil,
            contentFilter: filter,
            verbose: false,
            streamFactory: { _, _, _ in stream },
            siteRuleLock: OSAllocatedUnfairLock(initialState: false),
            appendsClosedLock: OSAllocatedUnfairLock(initialState: false)
        )
    }

    private func tagged(_ pids: Set<pid_t>) -> SCContentFilter {
        let filter = SCContentFilter()
        filter.keptOutPIDs = pids
        return filter
    }

    private var now: TimeInterval { HostClock.seconds(ticks: mach_absolute_time()) }

    @Test func aNewStreamVouchesFromItsFirstFrameIncludingDuringStart() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let gate = OneShotContinuationGate()
        let stream = FakeCaptureStream(startGates: [gate])
        let capturer = try capturer(stream, filter: tagged([safari]), root: root)
        let start = Task { try await capturer.start() }
        await stream.startCount.waitUntilCount(1)
        #expect(capturer.keptOutPIDs(at: now) == [safari])
        gate.release()
        try await start.value
        #expect(capturer.keptOutPIDs(at: now) == [safari])
        await capturer.stop()
        #expect(capturer.keptOutPIDs(at: now).isEmpty)
    }

    @Test func aFailedStartLeavesNoVouch() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        struct Boom: Error {}
        let stream = FakeCaptureStream(startError: Boom())
        let capturer = try capturer(stream, filter: tagged([safari]), root: root)
        await #expect(throws: (any Error).self) { try await capturer.start() }
        #expect(capturer.keptOutPIDs(at: now).isEmpty)
    }

    @Test func anUpdateVouchesOnlyAfterItReturnsAndSettles() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let gate = OneShotContinuationGate()
        let stream = FakeCaptureStream(updateGates: [gate])
        let capturer = try capturer(stream, filter: SCContentFilter(), root: root)
        try await capturer.start()
        let update = Task { try await capturer.updateContentFilter(tagged([safari])) }
        await stream.updateCount.waitUntilCount(1)
        #expect(capturer.keptOutPIDs(at: now + 60).isEmpty)
        gate.release()
        try await update.value
        #expect(capturer.keptOutPIDs(at: now).isEmpty)
        #expect(capturer.keptOutPIDs(at: now + ScreenshotCapturer.filterSettle + 0.1) == [safari])
        await capturer.stop()
    }

    @Test func narrowingRemovesTheVouchBeforeTheStreamHearsOfIt() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let gate = OneShotContinuationGate()
        let stream = FakeCaptureStream(updateGates: [gate])
        let capturer = try capturer(stream, filter: tagged([safari, pip]), root: root)
        try await capturer.start()
        let update = Task { try await capturer.updateContentFilter(tagged([pip])) }
        await stream.updateCount.waitUntilCount(1)
        #expect(capturer.keptOutPIDs(at: now + 60) == [pip])
        gate.release()
        try await update.value
        #expect(capturer.keptOutPIDs(at: now + 60) == [pip])
        await capturer.stop()
    }

    @Test func aPidKeptOutUnderBothFiltersKeepsItsVouch() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let stream = FakeCaptureStream()
        let capturer = try capturer(stream, filter: tagged([safari]), root: root)
        try await capturer.start()
        try await capturer.updateContentFilter(tagged([safari, pip]))
        #expect(capturer.keptOutPIDs(at: now) == [safari])
        await capturer.stop()
    }

    @Test func aFailedUpdateAddsNothingAndRethrows() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        struct Boom: Error {}
        let stream = FakeCaptureStream(updateError: Boom())
        let capturer = try capturer(stream, filter: SCContentFilter(), root: root)
        try await capturer.start()
        await #expect(throws: (any Error).self) { try await capturer.updateContentFilter(tagged([safari])) }
        #expect(capturer.keptOutPIDs(at: now + 60).isEmpty)
        await capturer.stop()
    }

    private final class StreamQueue: @unchecked Sendable {
        var streams: [FakeCaptureStream]
        var filters: [SCContentFilter] = []
        init(_ streams: [FakeCaptureStream]) { self.streams = streams }
    }

    private func restartingCapturer(_ queue: StreamQueue, filter: SCContentFilter, root: URL) throws -> ScreenshotCapturer {
        try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("1.mp4"),
            width: 16, height: 16, frameRate: 1, duration: nil,
            contentFilter: filter,
            verbose: false,
            streamFactory: { filter, _, _ in queue.filters.append(filter); return queue.streams.removeFirst() },
            siteRuleLock: OSAllocatedUnfairLock(initialState: false),
            appendsClosedLock: OSAllocatedUnfairLock(initialState: false)
        )
    }

    @Test func anUpdateDuringARestartThrowsAndTheNewStreamVouchesForItsOwnFilter() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let queue = StreamQueue([FakeCaptureStream(), FakeCaptureStream()])
        let original = SCContentFilter()
        let capturer = try restartingCapturer(queue, filter: original, root: root)
        try await capturer.start()

        let parked = OneShotContinuationGate()
        let reached = LockedCounter()
        capturer._restartParkHookForTesting = { reached.increment(); await parked.wait() }
        let restart = Task { @MainActor in await capturer._restartStreamForTesting() }
        await reached.waitUntilCount(1)

        await #expect(throws: CaptureFilterUpdateError.self) { try await capturer.updateContentFilter(self.tagged([self.safari])) }

        parked.release()
        await restart.value
        #expect(queue.filters.last === original)
        #expect(capturer.keptOutPIDs(at: now + 60).isEmpty)

        try await capturer.updateContentFilter(tagged([safari]))
        #expect(capturer.keptOutPIDs(at: now + ScreenshotCapturer.filterSettle + 0.1) == [safari])
        await capturer.stop()
    }

    @Test func anUpdateThatLandsOnTheDyingStreamVouchesForNothing() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let stopGate = OneShotContinuationGate()
        let updateGate = OneShotContinuationGate()
        let dying = FakeCaptureStream(stopGates: [stopGate], updateGates: [updateGate])
        let next = FakeCaptureStream()
        let queue = StreamQueue([dying, next])
        let original = SCContentFilter()
        let capturer = try restartingCapturer(queue, filter: original, root: root)
        try await capturer.start()
        capturer._restartParkHookForTesting = {}

        let restart = Task { @MainActor in await capturer._restartStreamForTesting() }
        await dying.stopCount.waitUntilCount(1)
        let update = Task { @MainActor in try await capturer.updateContentFilter(self.tagged([self.safari])) }
        await dying.updateCount.waitUntilCount(1)

        stopGate.release()
        await restart.value
        #expect(queue.filters.last === original)

        updateGate.release()
        await #expect(throws: CaptureFilterUpdateError.self) { try await update.value }
        #expect(capturer.keptOutPIDs(at: now + 60).isEmpty)

        // The next restart still builds from the filter the running stream holds.
        await capturer.stop()
    }

    @Test func aFrameFromATaggedStreamReachesTheJournalWithoutAccessibility() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let lock = OSAllocatedUnfairLock(initialState: true)
        let capturer = try ScreenshotCapturer(
            displayID: display,
            videoURL: root.appendingPathComponent("1.mp4"),
            width: 16, height: 16, frameRate: 1, duration: nil,
            contentFilter: tagged([safari]),
            verbose: false,
            streamFactory: { _, _, _ in FakeCaptureStream() },
            siteRuleLock: lock,
            appendsClosedLock: OSAllocatedUnfairLock(initialState: false)
        )
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        capturer.siteFrameGate = gate
        try await capturer.start()

        let c = now
        let window = SitePollWindow(windowID: 1, title: "Page", pid: safari)
        for i in -2..<4 {
            let start = c + Double(i) * 0.25
            gate.addPoll(SitePollSnapshot(start: start, end: start + 0.02, windows: [window]))
        }
        let ticks = mach_absolute_time()
        capturer.handleFrameFromOutput(generation: capturer._streamGenerationForTesting, pixelBuffer: makeTestPixelBuffer(width: 16, height: 16), isIdle: false, epoch: 0, displayTimeTicks: ticks)
        capturer.reevaluateHeldFrames()
        #expect(capturer._submittedVideoFrameCountForTesting == 1)
        await capturer.stop()
    }

    @Test func aFrameFromAnUntaggedStreamStaysOutWithoutAccessibility() async throws {
        let root = try makeTempDirectory("site-vouch"); defer { try? FileManager.default.removeItem(at: root) }
        let lock = OSAllocatedUnfairLock(initialState: true)
        let capturer = try ScreenshotCapturer(
            displayID: display,
            videoURL: root.appendingPathComponent("1.mp4"),
            width: 16, height: 16, frameRate: 1, duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: { _, _, _ in FakeCaptureStream() },
            siteRuleLock: lock,
            appendsClosedLock: OSAllocatedUnfairLock(initialState: false)
        )
        let gate = SiteFrameGate()
        gate.updateDecisions(SiteDecision(), axAvailable: false)
        capturer.siteFrameGate = gate
        try await capturer.start()

        let c = now
        let window = SitePollWindow(windowID: 1, title: "Page", pid: safari)
        for i in -2..<4 {
            let start = c + Double(i) * 0.25
            gate.addPoll(SitePollSnapshot(start: start, end: start + 0.02, windows: [window]))
        }
        capturer.handleFrameFromOutput(generation: capturer._streamGenerationForTesting, pixelBuffer: makeTestPixelBuffer(width: 16, height: 16), isIdle: false, epoch: 0, displayTimeTicks: mach_absolute_time())
        capturer.reevaluateHeldFrames()
        #expect(capturer._submittedVideoFrameCountForTesting == 0)
        await capturer.stop()
    }

    @Test func theSamplerPollsPictureInPictureWithItsPidAndNeverWalksIt() async {
        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [500] }
        hooks.pipPIDs = { [600] }
        hooks.copyOnScreen = {
            [
                SiteVisibleWindow(windowID: 1, pid: 500, layer: 0, title: "Page"),
                SiteVisibleWindow(windowID: 2, pid: 600, layer: 19, title: "Picture in Picture"),
                SiteVisibleWindow(windowID: 3, pid: 700, layer: 0, title: "Other"),
            ]
        }
        let walked = OSAllocatedUnfairLock<[CGWindowID]>(initialState: [])
        hooks.observe = { wid, _, title in
            walked.withLock { $0.append(wid) }
            return (title, WebAreaWalkResult(urls: [], completeness: .complete), title, false)
        }
        let polled = OSAllocatedUnfairLock<[SitePollWindow]>(initialState: [])
        let sampler = SiteSampler(
            probe: AccessibilityProbe(readWorks: { true }, prompt: {}),
            hooks: hooks,
            onPoll: { poll in polled.withLock { $0 = poll.windows } },
            onDecisionUpdate: { _, _, _ in }
        )
        await sampler.setSitesForTesting(["bank.com"])
        await sampler.performPollForTesting()
        await sampler.performWalkPassForTesting()
        let windows = polled.withLock { $0 }
        #expect(windows.map(\.windowID) == [1, 2])
        #expect(windows.map(\.pid) == [500, 600])
        #expect(walked.withLock { $0 } == [1])
    }

    // MARK: the segment

    @Test func oneFailingCapturerLetsTheOthersUpdateThenThrows() async {
        struct Boom: Error {}
        let good = FakeScreenshotCapturer()
        let bad = FakeScreenshotCapturer()
        bad.updateFilterError = Boom()
        let filters: [CGDirectDisplayID: SCContentFilter] = [1: SCContentFilter(), 2: SCContentFilter()]
        await #expect(throws: (any Error).self) {
            try await SegmentWriter.applyContentFilters(filters, to: [1: bad, 2: good])
        }
        #expect(good.updatedFilters.count == 1)
        #expect(bad.updatedFilters.count == 1)
    }

    @Test func aSegmentStillStartingHasTakenNothing() async {
        await #expect(throws: CaptureFilterUpdateError.self) {
            try await SegmentWriter.applyContentFilters([1: SCContentFilter()], to: [:])
        }
    }

    @Test func aCapturerWithNoFilterKeepsItsOwn() async throws {
        let kept = FakeScreenshotCapturer()
        try await SegmentWriter.applyContentFilters([:], to: [1: kept])
        #expect(kept.updatedFilters.isEmpty)
    }

    // MARK: the manager

    private func manager() -> WindowExclusionManager {
        WindowExclusionManager(excludedAppNames: [], excludePrivateBrowsing: false, excludedTitlePatterns: [])
    }

    @Test func aFlipBackToTheCommittedPlanStillReapplies() async {
        struct Boom: Error {}
        let manager = manager()
        var out = ExclusionPlan(); out.hiddenPIDs = [safari]; out.wholeAppPIDs = [safari]
        await manager.reconcile(plan: out) { true }
        #expect(manager.currentPlan == out)

        // A filter letting Safari back in reached a stream and didn't commit.
        var applies = 0
        await manager.reconcile(plan: .empty) { applies += 1; throw Boom() }
        await manager.reconcile(plan: out) { applies += 1; return true }
        #expect(applies == 2)

        // Committed, so an equal plan is skipped again.
        await manager.reconcile(plan: out) { applies += 1; return true }
        #expect(applies == 2)
    }

    @Test func anIncompleteApplyIsRetriedOnAnEqualPlan() async {
        let manager = manager()
        var out = ExclusionPlan(); out.hiddenPIDs = [safari]
        await manager.reconcile(plan: out) { true }
        var applies = 0
        await manager.reconcile(plan: .empty) { applies += 1; return false }
        await manager.reconcile(plan: out) { applies += 1; return true }
        #expect(applies == 2)
    }

    @Test func theRuleKeepsPictureInPictureOutAndSafariOnlyWhileUnreadable() {
        let manager = manager()
        #expect(!manager.hasExclusions)
        manager.setSiteRule(active: true, keptOutBrowsers: [])
        #expect(manager.excludedAppNames.contains("com.apple.pipagent"))
        #expect(!manager.excludedAppNames.contains("com.apple.safari"))
        manager.setSiteRule(active: true, keptOutBrowsers: [.safari])
        #expect(manager.excludedAppNames.contains("com.apple.safari"))
        #expect(manager.excludedAppNames.contains("safari"))
        manager.setSiteRule(active: false, keptOutBrowsers: [.safari])
        #expect(!manager.hasExclusions)
    }

    @Test func thePlannerKeepsBothOutWholeAndTheTagClaimsOnlyWhatWasListed() {
        var planner = ExclusionPlanner()
        let manager = manager()
        manager.setSiteRule(active: true, keptOutBrowsers: [.safari])
        let settings = manager.plannedSettings
        let apps = [
            ExclusionApp(pid: safari, name: "Safari", bundleIdentifier: "com.apple.Safari"),
            ExclusionApp(pid: pip, name: "Picture in Picture", bundleIdentifier: "com.apple.PIPAgent"),
            ExclusionApp(pid: 700, name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
        ]
        let windows = [
            ExclusionWindow(id: 1, pid: safari, ownerName: "Safari", title: "Page", layer: 0),
            ExclusionWindow(id: 2, pid: pip, ownerName: "Picture in Picture", title: "Picture in Picture", layer: 19),
        ]
        let plan = planner.plan(windows: windows, apps: apps, settings: settings, accessibilityTitles: [:], now: Date())
        #expect(plan.hiddenPIDs == [safari, pip])
        #expect(plan.wholeAppPIDs == [safari, pip])
        #expect(plan.exceptedWindowIDs.isEmpty)
        #expect(plan.keptOutWhole(listedPIDs: [safari]) == [safari])

        // Its window closed: the agent stays running, unlisted, and the plan can still be said in full.
        let closed = planner.plan(windows: [windows[0]], apps: apps, settings: settings, accessibilityTitles: [:], now: Date())
        #expect(closed.hiddenPIDs == [safari])
        #expect(closed.isFullyResolved(listedPIDs: [safari], listedWindowIDs: []))
    }

    @Test func aProtectedVideoNoteLeavesSafariOutWhileKeptOut() {
        let manager = manager()
        struct NoAccessibility: AccessibilityTitleReading { func titles(pid: pid_t) -> [CGWindowID: String] { [:] } }
        func included() -> Bool {
            var cache: [ProtectedVideoCacheKey: TitleVerdict] = [:]
            return protectedVideoObservationIncluded(
                match: ProtectedVideoMatch(windowID: 1, pid: 42, ownerName: "Safari", title: "Fixture", service: "Fixture"),
                excludedAppNames: manager.excludedAppNames, excludedTitlePatterns: [], excludePrivateBrowsing: false,
                excludePrivateBrowsingAccessibility: false, accessibilityReader: NoAccessibility(), verdictCache: &cache)
        }
        #expect(included())
        manager.setSiteRule(active: true, keptOutBrowsers: [.safari])
        #expect(!included())
    }

    // MARK: capture manager and menu

    @Test func oneFailedProbeHoldsSafariAndAccessibilityConfirmedOffTurnsTheRuleOff() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        #expect(capture.siteRuleActive)

        // One failed probe may be a blip: Safari sits out, as before.
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(capture.safariKeptOut)
        #expect(!capture.siteRuleSuspended)

        // Confirmed off: the list does nothing, and nothing is kept out in its place.
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(capture.siteRuleSuspended)
        #expect(!capture.siteRuleActive)
        #expect(!capture.safariKeptOut)
        capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        #expect(!capture.safariKeptOut)

        // A working probe turns it back on.
        capture.receiveSiteDecision(SiteDecision(), axAvailable: true, generation: capture.siteListGeneration)
        #expect(!capture.siteRuleSuspended)
        #expect(capture.siteRuleActive)
        #expect(!capture.safariKeptOut)
    }

    @Test func aSuspendedRuleClearsWithTheList() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        for _ in 0..<CaptureManager.siteAXFailuresToSuspend {
            capture.receiveSiteDecision(SiteDecision(), axAvailable: false, generation: capture.siteListGeneration)
        }
        #expect(capture.siteRuleSuspended)
        capture.updateSiteRule([])
        #expect(!capture.siteRuleSuspended)
        #expect(!capture.siteRuleActive)
        #expect(!capture.safariKeptOut)
    }

    // MARK: Safari sits out with Accessibility working

    private func onePoll(_ gate: SiteFrameGate, at time: TimeInterval, _ windows: [SitePollWindow]) {
        gate.addPoll(SitePollSnapshot(start: time, end: time + 0.05, windows: windows))
    }

    private func decided(_ verdict: SiteVerdict, _ key: SiteDecisionKey, at time: TimeInterval) -> SiteDecision {
        var decisions = SiteDecision()
        decisions.evaluate(
            key: key, initialAXTitle: key.title, finalAXTitle: key.title,
            walk: WebAreaWalkResult(urls: [verdict == .covered ? "https://bank.com/" : "https://example.com/"], completeness: .complete),
            sites: ["bank.com"], now: time, isSweep: false
        )
        return decisions
    }

    @Test func aLeftOutPageTakesSafariOutAtOnceAndAnOrdinaryReadBringsItBack() {
        let gate = SiteFrameGate()
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        let window = SitePollWindow(windowID: 1, title: "Bank", pid: safari)
        onePoll(gate, at: 10.0, [window])
        gate.updateDecisions(decided(.covered, key, at: 10.0), axAvailable: true)
        #expect(gate.safariShouldSitOut(isOutNow: false))

        gate.updateDecisions(decided(.ordinary, key, at: 11.0), axAvailable: true)
        onePoll(gate, at: 11.0, [window])
        #expect(!gate.safariShouldSitOut(isOutNow: true))
    }

    @Test func anUnreadWindowWaitsForTheLimitThenStaysOutUntilItReads() {
        let gate = SiteFrameGate()
        let window = SitePollWindow(windowID: 1, title: "Unread", pid: safari)
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        onePoll(gate, at: 10.0, [window])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
        onePoll(gate, at: 10.0 + SiteFrameGate.unreadLimit - 0.5, [window])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
        onePoll(gate, at: 10.0 + SiteFrameGate.unreadLimit, [window])
        #expect(gate.safariShouldSitOut(isOutNow: false))

        let later = 10.0 + SiteFrameGate.unreadLimit + 1
        onePoll(gate, at: later, [window])
        #expect(gate.safariShouldSitOut(isOutNow: true))
        gate.updateDecisions(decided(.ordinary, SiteDecisionKey(windowID: 1, title: "Unread"), at: later), axAvailable: true)
        onePoll(gate, at: later + 0.25, [window])
        #expect(!gate.safariShouldSitOut(isOutNow: true))
    }

    @Test func aTabSwitchThatReadsInTimeLeavesSafariIn() {
        let gate = SiteFrameGate()
        let first = SiteDecisionKey(windowID: 1, title: "One")
        let second = SiteDecisionKey(windowID: 1, title: "Two")
        gate.updateDecisions(decided(.ordinary, first, at: 10.0), axAvailable: true)
        onePoll(gate, at: 10.0, [SitePollWindow(windowID: 1, title: "One", pid: safari)])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
        onePoll(gate, at: 10.5, [SitePollWindow(windowID: 1, title: "Two", pid: safari)])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
        gate.updateDecisions(decided(.ordinary, second, at: 11.0), axAvailable: true)
        onePoll(gate, at: 11.25, [SitePollWindow(windowID: 1, title: "Two", pid: safari)])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
        // The clock restarted with the ordinary read, so a later unread stretch gets its full limit.
        onePoll(gate, at: 20.0, [SitePollWindow(windowID: 1, title: "Three", pid: safari)])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
    }

    @Test func pictureInPictureAloneDoesNotTakeSafariOut() {
        let gate = SiteFrameGate()
        let window = SitePollWindow(windowID: 2, title: "Picture in Picture", pid: pip, hasPage: false)
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        onePoll(gate, at: 10.0, [window])
        onePoll(gate, at: 10.0 + SiteFrameGate.unreadLimit + 1, [window])
        #expect(!gate.safariShouldSitOut(isOutNow: false))
    }

    @Test func noWindowsOnScreenBringsSafariBack() {
        let gate = SiteFrameGate()
        #expect(!gate.safariShouldSitOut(isOutNow: true))
        gate.updateDecisions(SiteDecision(), axAvailable: true)
        onePoll(gate, at: 10.0, [])
        #expect(!gate.safariShouldSitOut(isOutNow: true))
    }

    @Test func aVouchedFrameIsReleasedBesideALeftOutPageAndAnUnvouchedOneIsNot() {
        let gate = SiteFrameGate()
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        polls(gate, [SitePollWindow(windowID: 1, title: "Bank", pid: safari)])
        let decisions = decided(.covered, key, at: 9.9)
        _ = gate.enqueue(displayID: display, frame: frame(keptOut: [safari]))
        #expect(isReleased(gate.evaluate(displayID: display, decisions: decisions, axAvailable: true, now: 11.0)))
        _ = gate.enqueue(displayID: display, frame: frame())
        #expect(isDropped(gate.evaluate(displayID: display, decisions: decisions, axAvailable: true, now: 11.0)))
    }

    @Test func aTitleLastReadOnALeftOutPageTakesASecondOrdinaryRead() {
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        var decisions = SiteDecision()
        func read(_ url: String, at now: TimeInterval) -> SiteVerdict {
            decisions.evaluate(key: key, initialAXTitle: "Bank", finalAXTitle: "Bank",
                               walk: WebAreaWalkResult(urls: [url], completeness: .complete), sites: ["bank.com"], now: now, isSweep: true)
        }
        #expect(read("https://bank.com/", at: 10.0) == .covered)
        #expect(read("https://example.com/", at: 13.0) == .pending)
        #expect(decisions.verdict(for: key, at: 13.1) == .covered)
        #expect(read("https://example.com/", at: 13.5) == .pending)
        #expect(read("https://example.com/", at: 14.0) == .ordinary)
        // Back on the left-out page, the next change waits for its own second read.
        #expect(read("https://bank.com/", at: 15.0) == .covered)
        #expect(read("https://example.com/", at: 16.0) == .pending)
    }

    @Test func failuresEndWhenNoSafariWindowIsLeft() {
        var decisions = failing(10)
        #expect(decisions.hasSafariCaution)
        decisions.forgetCautions(notIn: [SiteDecisionKey(windowID: 1, title: "Page")])
        #expect(decisions.hasSafariCaution)
        decisions.forgetCautions(notIn: [])
        #expect(!decisions.hasSafariCaution)
    }

    @Test func aMismatchStreakEndsWithItsWindowAndTitle() {
        let key = SiteDecisionKey(windowID: 1, title: "Page")
        var decisions = SiteDecision()
        for i in 0..<5 {
            decisions.evaluate(key: key, initialAXTitle: "Other", finalAXTitle: "Other",
                               walk: WebAreaWalkResult(urls: [], completeness: .complete), sites: ["bank.com"], now: Double(i), isSweep: false)
        }
        #expect(decisions.hasSafariCaution)
        decisions.forgetCautions(notIn: [key])
        #expect(decisions.hasSafariCaution)
        decisions.forgetCautions(notIn: [SiteDecisionKey(windowID: 1, title: "Next page")])
        #expect(!decisions.hasSafariCaution)
    }

    @Test func captureKeepsSafariOutForALeftOutPageWithAccessibilityWorking() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        let key = SiteDecisionKey(windowID: 1, title: "Bank")
        let window = SitePollWindow(windowID: 1, title: "Bank", pid: safari)
        capture.receiveSitePoll(SitePollSnapshot(start: 10.0, end: 10.05, windows: [window]))
        capture.receiveSiteDecision(decided(.covered, key, at: 10.0), axAvailable: true, generation: capture.siteListGeneration)
        #expect(capture.safariKeptOut)

        capture.receiveSiteDecision(decided(.ordinary, key, at: 10.05), axAvailable: true, generation: capture.siteListGeneration)
        #expect(!capture.safariKeptOut)
    }

    private func failing(_ count: Int) -> SiteDecision {
        var decisions = SiteDecision()
        for i in 0..<count {
            decisions.evaluate(key: SiteDecisionKey(windowID: 1, title: "Page"), initialAXTitle: "Page", finalAXTitle: "Page",
                               walk: WebAreaWalkResult(urls: [], completeness: .axError), sites: ["bank.com"], now: 10.0 + Double(i), isSweep: false)
        }
        return decisions
    }

    @Test func aReadCautionNeitherTakesSafariOutNorShowsWithoutAccessibility() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        var caution: Bool?
        capture.onSiteSafariCaution = { caution = $0 }
        capture.updateSiteRule(["bank.com"])
        let decisions = failing(12)
        #expect(decisions.hasSafariCaution)

        capture.receiveSiteDecision(decisions, axAvailable: true, generation: capture.siteListGeneration)
        #expect(!capture.safariKeptOut)
        #expect(caution == true)

        capture.receiveSiteDecision(decisions, axAvailable: false, generation: capture.siteListGeneration)
        #expect(capture.safariKeptOut)
        #expect(caution == false)
    }

    @Test func theHeldRowClearsWhenTheListEmpties() {
        let state = AppState.forSnapshot(config: AppConfig())
        let capture = state.captureManager
        capture.updateSiteRule(["bank.com"])
        var held: [Bool] = []
        capture.onSiteScreenHeld = { held.append($0) }
        let page = SitePollWindow(windowID: 1, title: "Page", pid: safari)
        polls(capture.siteFrameGate, [page])
        _ = capture.siteFrameGate.enqueue(displayID: display, frame: frame())
        _ = capture.siteFrameGate.evaluate(displayID: display, now: 12.1)
        capture.receiveSitePoll(SitePollSnapshot(start: 13.4, end: 13.5, windows: [page]))
        #expect(capture.siteScreenHeld)
        capture.updateSiteRule([])
        #expect(!capture.siteScreenHeld)
        #expect(held == [true, false])
    }

    @Test func notesShowOnlyWhileTheScreenIsGoingIn() {
        func notes(recording: Bool = true, paused: Bool = false, screen: Bool = true) -> [SiteIntakeNote] {
            classifySiteIntakeNotes(isRecording: recording, isPaused: paused, screenActive: screen, safariKeptOut: true, screenHeld: true)
        }
        #expect(notes() == [.safariKeptOut, .screenHeld])
        #expect(notes(recording: false).isEmpty)
        #expect(notes(paused: true).isEmpty)
        #expect(notes(screen: false).isEmpty)
    }

    @Test func notesReachTheStatusLabelNotTheSourcesLine() {
        let presentation = MenubarPresentation(observation: .observing, attention: nil)
        let plain = statusAccessibilityLabel(presentation: presentation, errorMessage: nil, sourceStatus: "on")
        let noted = statusAccessibilityLabel(presentation: presentation, errorMessage: nil, sourceStatus: "on", siteNotes: [.safariKeptOut])
        #expect(noted != plain)
        #expect(noted.hasPrefix(plain))
    }
}
