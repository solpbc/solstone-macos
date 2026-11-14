// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

/// The website sampler reads only while screen capture or desktop activity needs it, and a
/// capture that starts after it stopped waits for a fresh reading before any stream starts.
@Suite("Website sampler demand", .serialized)
@MainActor
struct SiteSamplerDemandTests {
    private final class ManagerBox: @unchecked Sendable {
        weak var manager: CaptureManager?
        var pollsAtStart: [SitePollSnapshot]?
        var startedAt: TimeInterval = 0
    }

    /// No browser windows on screen, so a reading never waits on a page.
    private static let quietScreen = SiteSamplerHooks(
        safariPIDs: { [] }, pipPIDs: { [] }, chromePIDs: { [] }, edgePIDs: { [] }, bravePIDs: { [] },
        copyOnScreen: { [] }
    )

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class Values<T>: @unchecked Sendable {
        var all: [T] = []
    }

    /// A screen read that doesn't come back until released, so the sampler never reads.
    private static func stuckScreen(_ released: Flag) -> SiteSamplerHooks {
        var hooks = quietScreen
        hooks.copyOnScreen = {
            while !released.isSet { usleep(1_000) }
            return []
        }
        return hooks
    }

    private func now() -> TimeInterval { HostClock.seconds(ticks: mach_absolute_time()) }

    private func until(_ what: String, seconds: Double = 5, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func makeManager(root: URL, box: ManagerBox, hooks: SiteSamplerHooks = quietScreen) -> CaptureManager {
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                if box.pollsAtStart == nil, let manager = box.manager {
                    box.pollsAtStart = manager.siteFrameGate.polls
                    box.startedAt = HostClock.seconds(ticks: mach_absolute_time())
                }
                return FakeCaptureSegment(outputDirectory: directory)
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )
        box.manager = manager
        manager.accessibilityProbe = AccessibilityProbe(readWorks: { true }, prompt: {})
        manager.siteSamplerHooks = hooks
        manager.siteSamplerStopGrace = .milliseconds(20)
        return manager
    }

    private func startScreen(_ manager: CaptureManager) async throws {
        let result = try await manager.lifecycleStartCapture(
            reason: .user, sources: .screen, disabledMicUIDs: [], enabledMicUIDs: [], shouldVetoCommit: { false }
        )
        #expect(result == .committed)
    }

    @Test func samplerRunsOnlyWhileCaptureOrActivityNeedsIt() async throws {
        let root = try makeTempDirectory("site-demand-runs")
        defer { try? FileManager.default.removeItem(at: root) }
        let box = ManagerBox()
        let manager = makeManager(root: root, box: box)
        manager.updateSiteRule(["bank.com"])
        try await manager.waitForSiteListDrain()
        let sampler = try #require(manager.siteSampler)
        // Websites listed, but nothing is capturing or collecting: no poll, walk or probe loop.
        #expect(!(await sampler.isPollingForTesting))

        manager.setActivityNeedsSiteReads(true)
        try await until("activity to start the sampler") { await sampler.isPollingForTesting }
        manager.setActivityNeedsSiteReads(false)
        try await until("the sampler to stop with nothing needing it") { !(await sampler.isPollingForTesting) }
        #expect(manager.siteFrameGate.polls.isEmpty)

        try await startScreen(manager)
        #expect(await sampler.isPollingForTesting)
        // Locking pauses capture, and with activity paused too the sampler stops.
        _ = await manager.lifecyclePauseCapture(reason: .lock, stopAudio: true)
        try await until("the sampler to stop on lock") { !(await sampler.isPollingForTesting) }
        #expect(manager.siteFrameGate.polls.isEmpty)
    }

    @Test func captureAfterTheSamplerStoppedStartsOnlyOnceAFreshReadingIsIn() async throws {
        let root = try makeTempDirectory("site-demand-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let box = ManagerBox()
        let manager = makeManager(root: root, box: box)
        manager.updateSiteRule(["bank.com"])
        manager.setActivityNeedsSiteReads(true)
        try await until("a reading") { !manager.siteFrameGate.polls.isEmpty }
        manager.setActivityNeedsSiteReads(false)
        let sampler = try #require(manager.siteSampler)
        try await until("the sampler to stop") { !(await sampler.isPollingForTesting) }
        let stoppedAt = now()
        #expect(manager.siteFrameGate.polls.isEmpty)

        try await startScreen(manager)

        // When the first stream started, a reading of this run had already ended.
        let polls = try #require(box.pollsAtStart)
        let first = try #require(polls.last)
        #expect(polls.allSatisfy { $0.start >= stoppedAt })
        #expect(first.end <= box.startedAt)

        // So the first frame has a reading before it, and is held until one starts 0.5 s after it.
        let c = box.startedAt
        let ticks = mach_absolute_time()
        _ = manager.siteFrameGate.enqueue(displayID: 9, frame: SiteHeldFrame(id: 1, displayTicks: ticks, c: c, originTicks: ticks))
        let early = manager.siteFrameGate.evaluate(displayID: 9, axAvailable: true, now: c)
        #expect(!early.contains { if case .release = $0 { return true } else { return false } })
        try await until("a reading after the frame") { manager.siteFrameGate.polls.contains { $0.start >= c + SiteFrameGate.m } }
        let later = manager.siteFrameGate.evaluate(displayID: 9, axAvailable: true, now: c + 1)
        #expect(later.contains { if case .release(let id, _) = $0 { return id == 1 } else { return false } })
    }

    @Test func aSamplerThatNeverReadsLeavesTheFirstFrameHeld() async throws {
        let root = try makeTempDirectory("site-demand-fail-closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let released = Flag()
        defer { released.set() }
        let box = ManagerBox()
        let manager = makeManager(root: root, box: box, hooks: Self.stuckScreen(released))
        manager.siteReadingWait = .milliseconds(200)
        manager.updateSiteRule(["bank.com"])

        try await startScreen(manager)

        // The start waited its bound, then went on with no reading: nothing can vouch for a frame.
        #expect(box.pollsAtStart?.isEmpty == true)
        let c = box.startedAt
        let ticks = mach_absolute_time()
        _ = manager.siteFrameGate.enqueue(displayID: 9, frame: SiteHeldFrame(id: 1, displayTicks: ticks, c: c, originTicks: ticks))
        let held = manager.siteFrameGate.evaluate(displayID: 9, axAvailable: true, now: c + 1)
        #expect(held.isEmpty)
        let dropped = manager.siteFrameGate.evaluate(displayID: 9, axAvailable: true, now: c + SiteFrameGate.holdLimitSites + 0.1)
        #expect(dropped == [.drop(id: 1, reason: .hold)])
    }

    @Test func activityWaitsForTheBrowserReadsOfTheFirstReading() async throws {
        let root = try makeTempDirectory("site-demand-activity")
        defer { try? FileManager.default.removeItem(at: root) }
        let released = Flag()
        defer { released.set() }
        let box = ManagerBox()
        let manager = makeManager(root: root, box: box, hooks: Self.stuckScreen(released))
        manager.updateSiteRule(["bank.com"])
        manager.setActivityNeedsSiteReads(true)

        let done = Flag()
        let waiter = Task { @MainActor in
            await manager.awaitSiteReading(browserReads: true)
            done.set()
        }
        for _ in 0..<5 { await Task.yield() }
        let start = now()
        let pending = ChromiumPollRead(verdict: .cantTell, cause: nil, host: nil, readStart: start,
                                       listGeneration: manager.siteListGeneration, browser: .chrome, isPending: true)
        manager.receiveSitePoll(SitePollSnapshot(start: start, end: start + 0.001,
            windows: [SitePollWindow(windowID: 7, title: "a page", pid: 70, chromium: pending)]))
        for _ in 0..<5 { await Task.yield() }
        // The reading is in, but the browser read it started is not: an address can't stand on it yet.
        #expect(!done.isSet)
        let read = ChromiumPollRead(verdict: .ordinary, cause: nil, host: "example.com", readStart: start,
                                    listGeneration: manager.siteListGeneration, browser: .chrome, isPending: false)
        manager.receiveChromiumReadComplete(browser: .chrome, results: [7: (read: read, cgTitle: "a page", axTitle: "a page")],
                                            startSec: start, generation: manager.siteListGeneration)
        await waiter.value
        #expect(done.isSet)
        #expect(manager.chromiumActivitySnapshot.latestCompleteRead[7]?.host == "example.com")
    }

    @Test func activityTakesItsBrowserSnapshotOnlyAfterTheReading() async throws {
        let root = try makeTempDirectory("site-demand-activity-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = DesktopActivityApp(pid: 42, name: "Fixture", bundleID: "example.fixture")
        let (reading, arrive) = AsyncStream<Void>.makeStream()
        let waiting = Flag()
        nonisolated(unsafe) var generation: UInt64 = 1
        nonisolated(unsafe) var seen: UInt64 = 0
        nonisolated(unsafe) var eligible = true
        let collecting = Values<Bool>()
        let source = DesktopActivitySource(
            storage: StorageManager(baseDirectory: root.appendingPathComponent("captures")),
            eligibility: { eligible }, locked: { !eligible }, foreground: { app },
            chromiumSnapshot: { ChromiumActivitySnapshot(currentGeneration: generation) },
            reader: { _, _, _, snapshot in
                seen = snapshot.currentGeneration
                return DesktopActivityObservation(rows: [DesktopActivityRow(kind: "foreground", method: "nsworkspace", app: "Fixture")])
            },
            siteReading: { waiting.set(); for await _ in reading { break } },
            onCollectingChanged: { collecting.all.append($0) }
        )
        defer { source.stop() }
        var config = AppConfig(); config.isActivityEnabled = true
        source.start(config: config)
        #expect(collecting.all == [true])
        let task = source.sample()
        try await until("the sample to wait for a reading") { waiting.isSet }
        // The reading arrives after the sample began: the read stands on it, not on what came before.
        generation = 2
        arrive.yield(())
        await task?.value
        #expect(seen == 2)

        // Lock: activity stops collecting, so it stops needing readings; unlock brings it back.
        eligible = false
        source.invalidate(); source.sample()
        eligible = true
        source.invalidate(); source.sample()
        #expect(collecting.all == [true, false, true])
    }
}
