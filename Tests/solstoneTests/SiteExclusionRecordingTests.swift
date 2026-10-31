// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("SiteExclusionRecordingTests")
struct SiteExclusionRecordingTests {

    @MainActor
    @Test func ptsBaselinePerCapturerAcrossSegmentsAndMidSegmentToggle() async throws {
        let root = try makeTempDirectory("site-pts-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = SiteFrameGate()
        let fakeFactory = FakeCaptureStreamFactory()
        let buffer = makeTestPixelBuffer()

        // Capturer A: started 100s ago, rule off, gate set
        let startA = Date().addingTimeInterval(-100.0)
        let capturerA = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("a.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: fakeFactory.factory,
            captureStartTime: startA
        )
        capturerA.siteFrameGate = gate
        capturerA.isSiteRuleActive = false
        try await capturerA.start()

        capturerA.handleFrameFromOutput(
            generation: capturerA._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1
        )

        let ptsA = try #require(capturerA._lastAppendedPTSForTesting)
        #expect(abs(ptsA.seconds - 100.0) < 5.0)

        // Capturer B: started now, same gate, rule off
        let startB = Date()
        let capturerB = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("b.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: fakeFactory.factory,
            captureStartTime: startB
        )
        capturerB.siteFrameGate = gate
        capturerB.isSiteRuleActive = false
        try await capturerB.start()

        capturerB.handleFrameFromOutput(
            generation: capturerB._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1
        )

        let ptsB1 = try #require(capturerB._lastAppendedPTSForTesting)
        // Red check: without the fix, ptsB1 is clamped to ptsA (~100s).
        // With the fix, ptsB1 is near 0 (< 0.5s) and far from ptsA.
        #expect(ptsB1.seconds < 1.0)
        #expect(abs(ptsB1.seconds - ptsA.seconds) > 50.0)

        // On B, turn the rule on. Enqueue/release a frame whose raw tick PTS delta is behind B's last write.
        capturerB.isSiteRuleActive = true
        // Set up gate decisions and bracketing polls to release a frame at c = cSec
        let originTicks = mach_absolute_time()
        let cSec = HostClock.seconds(ticks: originTicks)
        gate.addPoll(SitePollSnapshot(start: cSec - 0.1, end: cSec - 0.05, windows: [SitePollWindow(windowID: 10, title: "Ordinary")]))
        gate.addPoll(SitePollSnapshot(start: cSec + 0.15, end: cSec + 0.20, windows: [SitePollWindow(windowID: 10, title: "Ordinary")]))
        gate.addPoll(SitePollSnapshot(start: cSec + 0.40, end: cSec + 0.45, windows: [SitePollWindow(windowID: 10, title: "Ordinary")]))
        gate.addPoll(SitePollSnapshot(start: cSec + 0.65, end: cSec + 0.70, windows: [SitePollWindow(windowID: 10, title: "Ordinary")]))
        var decisions = SiteDecision()
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 10, title: "Ordinary"),
            initialAXTitle: "Ordinary",
            finalAXTitle: "Ordinary",
            walk: WebAreaWalkResult(urls: ["https://uncovered.com"], completeness: .complete),
            sites: ["bank.com"],
            now: cSec,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        // Frame with raw ticks near 0 (originTicks chosen so delta is ~0 while ptsB1 is > 0)
        capturerB.handleFrameFromOutput(
            generation: capturerB._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks
        )

        let ptsB2 = try #require(capturerB._lastAppendedPTSForTesting)
        #expect(ptsB2 > ptsB1)

        // Capturer C: fresh start, same gate, rule off
        let capturerC = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("c.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: fakeFactory.factory
        )
        capturerC.siteFrameGate = gate
        capturerC.isSiteRuleActive = false
        try await capturerC.start()

        capturerC.handleFrameFromOutput(
            generation: capturerC._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1
        )

        let ptsC = try #require(capturerC._lastAppendedPTSForTesting)
        #expect(ptsC.seconds < 1.0)
        #expect(abs(ptsC.seconds - ptsA.seconds) > 50.0)

        await capturerA.stop()
        await capturerB.stop()
        await capturerC.stop()
    }

    @MainActor
    @Test func ruleLockToggleGatingConstructedCapturersAndNilGateDrops() async throws {
        let root = try makeTempDirectory("site-b2-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let buffer = makeTestPixelBuffer()
        let gate = SiteFrameGate()

        // Case 1: Toggle rule active while capturer is starting (constructed, not yet in screenshotCapturers)
        let startGate = OneShotContinuationGate()
        let fakeStream = FakeCaptureStream(startGates: [startGate])
        var capturedCapturer: ScreenshotCapturer?

        let writer = SegmentWriter(
            outputDirectory: root,
            timePrefix: "test1",
            screenshotCapturerFactory: { info, videoURL, frameRate, duration, filter, verbose in
                let capturer = try ScreenshotCapturer(
                    displayID: info.displayID,
                    videoURL: videoURL,
                    width: 16,
                    height: 16,
                    frameRate: frameRate,
                    duration: duration,
                    contentFilter: filter ?? SCContentFilter(),
                    verbose: verbose,
                    streamFactory: { _, _, _ in fakeStream }
                )
                capturedCapturer = capturer
                return capturer
            }
        )
        writer.siteFrameGate = gate
        writer.isSiteRuleActive = false

        let display = DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        let startTask = Task {
            _ = try await writer.start(sources: .screen, displayInfos: [display], filters: [1: SCContentFilter()])
        }

        defer {
            startGate.release()
        }

        // Wait bounded time until capturer is running and parked in startCapture
        for _ in 0..<50 {
            if let c = capturedCapturer, c.isRunning {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let capturer = try #require(capturedCapturer)
        #expect(capturer.isRunning)

        // Turn rule on on segment while start() is still blocked
        writer.isSiteRuleActive = true

        // Deliver a non-idle frame to the capturer. If rule active is recognized, frame is held (count 0).
        // If missed (red run), frame is appended as inactive (count 1).
        capturer.handleFrameFromOutput(
            generation: capturer._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1
        )

        #expect(capturer._submittedVideoFrameCountForTesting == 0)

        startGate.release()
        _ = try await startTask.value
        await capturer.stop()

        // Case 2: Rule on, siteFrameGate == nil, one non-idle frame -> dropped, count stays 0
        let capturerNoGate = try ScreenshotCapturer(
            displayID: 2,
            videoURL: root.appendingPathComponent("nogate.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: { _, _, _ in FakeCaptureStream() }
        )
        capturerNoGate.siteFrameGate = nil
        capturerNoGate.isSiteRuleActive = true
        try await capturerNoGate.start()

        capturerNoGate.handleFrameFromOutput(
            generation: capturerNoGate._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1
        )

        #expect(capturerNoGate._submittedVideoFrameCountForTesting == 0)
        await capturerNoGate.stop()
    }

    @MainActor
    @Test func idleStreamFrameReevaluatedOnReceiveSitePoll() async throws {
        let root = try makeTempDirectory("site-b3-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(baseDirectory: root)
        let manager = CaptureManager(storageManager: storage)
        let buffer = makeTestPixelBuffer()

        var capturedCapturer: ScreenshotCapturer?
        let writer = SegmentWriter(
            outputDirectory: root,
            timePrefix: "b3",
            screenshotCapturerFactory: { info, videoURL, frameRate, duration, filter, verbose in
                let capturer = try ScreenshotCapturer(
                    displayID: info.displayID,
                    videoURL: videoURL,
                    width: 16,
                    height: 16,
                    frameRate: frameRate,
                    duration: duration,
                    contentFilter: filter ?? SCContentFilter(),
                    verbose: verbose,
                    streamFactory: { _, _, _ in FakeCaptureStream() }
                )
                capturedCapturer = capturer
                return capturer
            }
        )
        writer.siteFrameGate = manager.siteFrameGate
        writer.isSiteRuleActive = true
        manager.seedRecordingForTesting(currentSegment: writer)

        let display = DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        _ = try await writer.start(sources: .screen, displayInfos: [display], filters: [1: SCContentFilter()])

        let capturer = try #require(capturedCapturer)

        let originTicks = mach_absolute_time()
        let c = HostClock.seconds(ticks: originTicks)

        // Install an ordinary decision for window 42
        var decisions = SiteDecision()
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 42, title: "Ordinary Window"),
            initialAXTitle: "Ordinary Window",
            finalAXTitle: "Ordinary Window",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["blocked.com"],
            now: c,
            isSweep: false
        )
        manager.receiveSiteDecision(decisions, axAvailable: true, generation: manager.siteListGeneration)

        // Deliver one non-idle frame with displayTime whose c sits in a bracket we will complete
        capturer.handleFrameFromOutput(
            generation: capturer._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks
        )
        // Must not be appended yet (no polls)
        #expect(capturer._submittedVideoFrameCountForTesting == 0)

        // Then only idle frames. Count still 0.
        capturer.handleFrameFromOutput(
            generation: capturer._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: true,
            epoch: 1,
            displayTimeTicks: originTicks + 10_000
        )
        #expect(capturer._submittedVideoFrameCountForTesting == 0)

        // Deliver polls completing the bracket:
        // end of early poll <= c, start of late poll >= c + 0.5, consecutive gap < 300 ms.
        let window = SitePollWindow(windowID: 42, title: "Ordinary Window")
        manager.receiveSitePoll(SitePollSnapshot(start: c - 0.20, end: c - 0.05, windows: [window]))
        manager.receiveSitePoll(SitePollSnapshot(start: c + 0.15, end: c + 0.25, windows: [window]))
        manager.receiveSitePoll(SitePollSnapshot(start: c + 0.50, end: c + 0.60, windows: [window]))

        // Red: without reevaluate on receiveSitePoll, count stays 0.
        // Fix: count becomes 1.
        #expect(capturer._submittedVideoFrameCountForTesting == 1)

        await capturer.stop()
    }

    @MainActor
    @Test func capturerKeyedHeldFramesAndAppendsClosedFence() async throws {
        let root = try makeTempDirectory("site-m1-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = SiteFrameGate()
        let fakeFactory = FakeCaptureStreamFactory()

        let capturerA = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("a.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: fakeFactory.factory
        )
        capturerA.siteFrameGate = gate
        capturerA.isSiteRuleActive = true
        try await capturerA.start()

        let capturerB = try ScreenshotCapturer(
            displayID: 1,
            videoURL: root.appendingPathComponent("b.mp4"),
            width: 32,
            height: 32,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: fakeFactory.factory
        )
        capturerB.siteFrameGate = gate
        capturerB.isSiteRuleActive = true
        try await capturerB.start()

        #expect(capturerA.ownerID != capturerB.ownerID)

        let bufferA = makeTestPixelBuffer(width: 16, height: 16)
        let bufferB = makeTestPixelBuffer(width: 32, height: 32)

        let originTicks = mach_absolute_time()
        let c = HostClock.seconds(ticks: originTicks)

        // Hold one frame each. Both start nextFrameID at 0, so first held id matches (1).
        capturerA.handleFrameFromOutput(
            generation: capturerA._streamGenerationForTesting,
            pixelBuffer: bufferA,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks
        )

        capturerB.handleFrameFromOutput(
            generation: capturerB._streamGenerationForTesting,
            pixelBuffer: bufferB,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks
        )

        // Arrange polls and an ordinary decision so evaluate will release
        var decisions = SiteDecision()
        decisions.evaluate(
            key: SiteDecisionKey(windowID: 10, title: "Title"),
            initialAXTitle: "Title",
            finalAXTitle: "Title",
            walk: WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete),
            sites: ["blocked.com"],
            now: c,
            isSweep: false
        )
        gate.updateDecisions(decisions, axAvailable: true)

        let window = SitePollWindow(windowID: 10, title: "Title")
        gate.addPoll(SitePollSnapshot(start: c - 0.20, end: c - 0.05, windows: [window]))
        gate.addPoll(SitePollSnapshot(start: c + 0.15, end: c + 0.25, windows: [window]))
        gate.addPoll(SitePollSnapshot(start: c + 0.50, end: c + 0.60, windows: [window]))

        // Re-evaluate only capturer A
        capturerA.reevaluateHeldFrames()

        #expect(capturerA._submittedVideoFrameCountForTesting == 1)
        #expect(capturerA._lastAppendedBufferForTesting === bufferA)
        #expect(capturerB._submittedVideoFrameCountForTesting == 0)

        // Re-evaluate capturer B
        capturerB.reevaluateHeldFrames()
        #expect(capturerB._submittedVideoFrameCountForTesting == 1)
        #expect(capturerB._lastAppendedBufferForTesting === bufferB)

        // Enqueue another releasable frame on A
        let originTicks2 = originTicks + 10_000_000_000
        let c2 = HostClock.seconds(ticks: originTicks2)
        gate.addPoll(SitePollSnapshot(start: c2 - 0.20, end: c2 - 0.05, windows: [window]))
        gate.addPoll(SitePollSnapshot(start: c2 + 0.15, end: c2 + 0.25, windows: [window]))
        gate.addPoll(SitePollSnapshot(start: c2 + 0.50, end: c2 + 0.60, windows: [window]))

        let finishGate = OneShotContinuationGate()
        capturerA.finish { _ in
            finishGate.release()
        }
        await finishGate.wait()

        let countAfterFinish = capturerA._submittedVideoFrameCountForTesting

        // After finish has closed appends, any further evaluate must not append frames
        capturerA.handleFrameFromOutput(
            generation: capturerA._streamGenerationForTesting,
            pixelBuffer: bufferA,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks2
        )
        capturerA.reevaluateHeldFrames()

        #expect(capturerA._submittedVideoFrameCountForTesting == countAfterFinish)

        await capturerB.stop()
    }

    @Test func idleFrameSkipsDeepCopyOnActiveRule() throws {
        let ruleLock = OSAllocatedUnfairLock(initialState: true)
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        var deliveredFrames: [(CVPixelBuffer, Bool, UInt64?)] = []
        let output = VideoStreamOutput(sampleQueueRuleActive: ruleLock) { buffer, isIdle, ticks in
            deliveredFrames.append((buffer, isIdle, ticks))
        }

        let pixelBuffer = makeTestPixelBuffer(width: 16, height: 16)
        let idleSample = makeTestSampleBuffer(pixelBuffer: pixelBuffer, status: .idle, displayTime: 100)
        let nonIdleSample = makeTestSampleBuffer(pixelBuffer: pixelBuffer, status: .complete, displayTime: 200)

        #expect(output._deepCopyCountForTesting == 0)

        output.stream(stream, didOutputSampleBuffer: idleSample, of: SCStreamOutputType.screen)
        #expect(output._deepCopyCountForTesting == 0)
        #expect(deliveredFrames.count == 1)
        #expect(deliveredFrames[0].1 == true) // isIdle
        #expect(deliveredFrames[0].0 === pixelBuffer) // same source buffer

        output.stream(stream, didOutputSampleBuffer: nonIdleSample, of: SCStreamOutputType.screen)
        #expect(output._deepCopyCountForTesting == 1)
        #expect(deliveredFrames.count == 2)
        #expect(deliveredFrames[1].1 == false) // non-idle
        #expect(deliveredFrames[1].0 !== pixelBuffer) // deep-copied buffer
    }

    @Test func walkBlockingDoesNotDelayPolls() async throws {
        let sema = DispatchSemaphore(value: 0)
        let observeEntered = OneShotContinuationGate()
        let pollCount = OSAllocatedUnfairLock(initialState: 0)

        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [123] }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 1, pid: 123, layer: 0, title: "Safari")]
        }
        hooks.observe = { wid, pid, title in
            observeEntered.release()
            sema.wait()
            return ("Safari", WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete), "Safari", false)
        }

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in
                pollCount.withLock { $0 += 1 }
            },
            onDecisionUpdate: { _, _, _ in }
        )

        defer {
            sema.signal()
            Task { await sampler.stop() }
        }

        await sampler.updateSites(["blocked.com"])

        // Wait bounded time for observe to enter and block
        await observeEntered.wait()

        // While walk is blocking, wait about 1 second and assert at least 3 polls were delivered
        let startPolls = pollCount.withLock { $0 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let pollsWhileBlocked = pollCount.withLock { $0 } - startPolls
        #expect(pollsWhileBlocked >= 3)
    }

    @MainActor
    @Test func stableWindowSweptEveryFourSecondsWithoutPendingOrDrop() async throws {
        let timeLock = OSAllocatedUnfairLock(initialState: 100.0)

        var hooks = SiteSamplerHooks()
        hooks.nowTicks = {
            let sec = timeLock.withLock { $0 }
            var info = mach_timebase_info()
            mach_timebase_info(&info)
            let ticks = UInt64((sec * 1_000_000_000.0 * Double(info.denom)) / Double(info.numer))
            return ticks
        }
        hooks.safariPIDs = { [123] }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 10, pid: 123, layer: 0, title: "Main")]
        }

        let observeCountsPerTick = OSAllocatedUnfairLock(initialState: [Int]())
        let tickObserveCount = OSAllocatedUnfairLock(initialState: 0)

        hooks.observe = { wid, pid, title in
            tickObserveCount.withLock { $0 += 1 }
            return ("Main", WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete), "Main", false)
        }

        let gate = SiteFrameGate()
        let sampler = SiteSampler(
            probe: AccessibilityProbe(readWorks: { true }),
            hooks: hooks,
            onPoll: { poll in
                gate.addPoll(poll)
            },
            onDecisionUpdate: { dec, ax, _ in
                gate.updateDecisions(dec, axAvailable: ax)
            }
        )

        await sampler.setSitesForTesting(["blocked.com"])

        var anyPendingAfterFirstDecision = false
        var firstDecisionMade = false

        // Run 30 seconds of virtual time
        for sec in 0..<30 {
            tickObserveCount.withLock { $0 = 0 }
            for pollIdx in 0..<4 {
                let t = 100.0 + Double(sec) + Double(pollIdx) * 0.25
                timeLock.withLock { $0 = t }
                await sampler.performPollForTesting()
            }
            timeLock.withLock { $0 = 100.0 + Double(sec) + 1.0 }
            await sampler.performWalkPassForTesting()
            let c = tickObserveCount.withLock { $0 }
            observeCountsPerTick.withLock { $0.append(c) }

            let dec = await sampler.decisionsForTesting
            let key = SiteDecisionKey(windowID: 10, title: "Main")
            let v = dec.verdict(for: key, at: 100.0 + Double(sec) + 1.0)
            if v != .pending {
                firstDecisionMade = true
            } else if firstDecisionMade {
                anyPendingAfterFirstDecision = true
            }
        }

        #expect(!anyPendingAfterFirstDecision)
        let maxObservesInOneTick = observeCountsPerTick.withLock { $0.max() ?? 0 }
        #expect(maxObservesInOneTick <= 1)

        let totalObserves = observeCountsPerTick.withLock { $0.reduce(0, +) }
        #expect(totalObserves <= 12)
        #expect(totalObserves >= 6)

        // Verify gate hold drop count stays 0 for a frame bracketed by polls
        let frameTime = 128.0
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let fTicks = UInt64((frameTime * 1_000_000_000.0 * Double(info.denom)) / Double(info.numer))
        let frame = SiteHeldFrame(id: 1, displayTicks: fTicks, c: frameTime, originTicks: 0)
        _ = gate.enqueue(displayID: 1, frame: frame)
        let actions = gate.evaluate(displayID: 1, now: 129.0)
        #expect(gate.holdDropCount == 0)
        #expect(actions.contains(where: {
            if case .release(let id, _) = $0 { return id == 1 }
            return false
        }))
    }

    @MainActor
    @Test func pollStampsBracketTheWindowListCall() async throws {
        let recordedMidTick = OSAllocatedUnfairLock(initialState: UInt64(0))
        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = {
            usleep(40_000) // 40 ms pid lookup
            return [123]
        }
        hooks.copyOnScreen = {
            recordedMidTick.withLock { $0 = mach_absolute_time() }
            return [SiteVisibleWindow(windowID: 1, pid: 123, layer: 0, title: "Safari")]
        }

        let latestSnapshotLock = OSAllocatedUnfairLock<SitePollSnapshot?>(initialState: nil)
        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { snapshot in
                latestSnapshotLock.withLock { $0 = snapshot }
            },
            onDecisionUpdate: { _, _, _ in }
        )

        await sampler.performPollForTesting()

        let snapshot = try #require(latestSnapshotLock.withLock { $0 })
        let midTick = recordedMidTick.withLock { $0 }
        let midSec = HostClock.seconds(ticks: midTick)

        #expect(abs(snapshot.start - midSec) < 0.010)
        #expect(abs(snapshot.end - midSec) < 0.010)
    }

    @MainActor
    @Test func stalePendingTitlesPrunedAndClosedWindowNeverCountsAXFailure() async throws {
        let observedTitles = OSAllocatedUnfairLock(initialState: [String]())
        let windowList = OSAllocatedUnfairLock(initialState: [SiteVisibleWindow]())

        let observeHandler = OSAllocatedUnfairLock<@Sendable (CGWindowID, pid_t, String) -> (String?, WebAreaWalkResult, String?, Bool)>(
            initialState: { wid, pid, title in
                observedTitles.withLock { $0.append(title) }
                return (title, WebAreaWalkResult(urls: ["https://example.com"], completeness: .complete), title, false)
            }
        )

        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [123] }
        hooks.copyOnScreen = {
            windowList.withLock { $0 }
        }
        hooks.observe = { wid, pid, title in
            observeHandler.withLock { $0 }(wid, pid, title)
        }

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in }
        )

        await sampler.setSitesForTesting(["blocked.com"])

        // One window, five successive titles
        for i in 1...5 {
            windowList.withLock {
                $0 = [SiteVisibleWindow(windowID: 10, pid: 123, layer: 0, title: "Title\(i)")]
            }
            await sampler.performPollForTesting()
        }

        // Perform one walk pass
        await sampler.performWalkPassForTesting()

        let observed = observedTitles.withLock { $0 }
        #expect(observed == ["Title5"])

        let dec = await sampler.decisionsForTesting
        #expect(dec.consecutiveFailures == 0)
        for streak in dec.titleMismatchStreaks.values {
            #expect(streak == 0)
        }

        // Poll with window gone
        windowList.withLock { $0 = [] }
        await sampler.performPollForTesting()
        await sampler.performWalkPassForTesting()

        let dec2 = await sampler.decisionsForTesting
        #expect(dec2.consecutiveFailures == 0)

        // Poll with window whose pid is 0
        windowList.withLock {
            $0 = [SiteVisibleWindow(windowID: 10, pid: 0, layer: 0, title: "Title5")]
        }
        await sampler.performPollForTesting()
        await sampler.performWalkPassForTesting()

        let dec3 = await sampler.decisionsForTesting
        #expect(dec3.consecutiveFailures == 0)

        // Real PID, but observe returns windowMissing: true (window closed mid-walk)
        let missingHookCalled = OSAllocatedUnfairLock(initialState: false)
        observeHandler.withLock {
            $0 = { wid, pid, title in
                missingHookCalled.withLock { $0 = true }
                return (nil, WebAreaWalkResult(urls: [], completeness: .axError), nil, true)
            }
        }
        windowList.withLock {
            $0 = [SiteVisibleWindow(windowID: 10, pid: 123, layer: 0, title: "Title6")]
        }
        await sampler.performPollForTesting()
        await sampler.performWalkPassForTesting()
        #expect(missingHookCalled.withLock { $0 } == true)
        let dec4 = await sampler.decisionsForTesting
        #expect(dec4.consecutiveFailures == 0)
    }

    @MainActor
    @Test func synchronousListGenerationInvalidatesGateDecisionsAndDiscardsStaleWalks() async throws {
        let root = try makeTempDirectory("h3-gen-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(baseDirectory: root)
        let manager = CaptureManager(storageManager: storage)

        // Initial rule with one site
        manager.updateSiteRule(["site1.com"])
        let gen1 = manager.siteListGeneration
        #expect(gen1 == 1)

        // Install a valid decision under gen1
        var dec1 = SiteDecision()
        let nowSec = HostClock.seconds(ticks: mach_absolute_time())
        dec1.evaluate(
            key: SiteDecisionKey(windowID: 10, title: "Covered"),
            initialAXTitle: "Covered",
            finalAXTitle: "Covered",
            walk: WebAreaWalkResult(urls: ["https://site1.com"], completeness: .complete),
            sites: ["site1.com"],
            now: nowSec,
            isSweep: false
        )
        manager.receiveSiteDecision(dec1, axAvailable: true, generation: gen1)
        #expect(manager.siteFrameGate.currentDecisions.verdict(for: SiteDecisionKey(windowID: 10, title: "Covered"), at: nowSec) == .covered)

        // Update site rule to ["site2.com"]
        manager.updateSiteRule(["site2.com"])
        let gen2 = manager.siteListGeneration
        #expect(gen2 == 2)

        // Synchronous check: gate decisions must immediately be cleared (SiteDecision())
        #expect(manager.siteFrameGate.currentDecisions.verdict(for: SiteDecisionKey(windowID: 10, title: "Covered"), at: nowSec) == .pending)

        // An in-flight decision callback arriving from gen1 must be discarded
        manager.receiveSiteDecision(dec1, axAvailable: true, generation: gen1)
        #expect(manager.siteFrameGate.currentDecisions.verdict(for: SiteDecisionKey(windowID: 10, title: "Covered"), at: nowSec) == .pending)

        // Drain to ensure gen2 is applied
        try await manager.waitForSiteListDrain()
    }

    @MainActor
    @Test func pollsRunIfAndOnlyIfAppliedListIsNonEmpty() async throws {
        let root = try makeTempDirectory("h3-polls-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(baseDirectory: root)
        let manager = CaptureManager(storageManager: storage)

        manager.updateSiteRule(["a.com"])
        manager.updateSiteRule([])
        manager.updateSiteRule(["b.com"])
        try await manager.waitForSiteListDrain()

        let sampler = try #require(manager.siteSampler)
        let polling1 = await sampler.isPollingForTesting
        #expect(polling1)
        let applied = await sampler.appliedSitesForTesting
        #expect(applied == [["a.com"], [], ["b.com"]])

        manager.updateSiteRule([])
        try await manager.waitForSiteListDrain()
        let polling2 = await sampler.isPollingForTesting
        #expect(!polling2)
        #expect(manager.siteSampler != nil)
    }

    @MainActor
    @Test func frameAfterListEditWaitsForFreshDecisionUnderNewList() async throws {
        let root = try makeTempDirectory("h3-frame-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = StorageManager(baseDirectory: root)
        let manager = CaptureManager(storageManager: storage)
        let buffer = makeTestPixelBuffer()

        var capturedCapturer: ScreenshotCapturer?
        let writer = SegmentWriter(
            outputDirectory: root,
            timePrefix: "h3-frame",
            screenshotCapturerFactory: { info, videoURL, frameRate, duration, filter, verbose in
                let capturer = try ScreenshotCapturer(
                    displayID: info.displayID,
                    videoURL: videoURL,
                    width: 16,
                    height: 16,
                    frameRate: frameRate,
                    duration: duration,
                    contentFilter: filter ?? SCContentFilter(),
                    verbose: verbose,
                    streamFactory: { _, _, _ in FakeCaptureStream() }
                )
                capturedCapturer = capturer
                return capturer
            }
        )
        writer.siteFrameGate = manager.siteFrameGate
        manager.seedRecordingForTesting(currentSegment: writer)

        let display = DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        _ = try await writer.start(sources: .screen, displayInfos: [display], filters: [1: SCContentFilter()])
        let capturer = try #require(capturedCapturer)

        let originTicks = mach_absolute_time()
        let c = HostClock.seconds(ticks: originTicks)

        // Install polls for one window and an ordinary decision
        manager.receiveSitePoll(SitePollSnapshot(start: c - 0.1, end: c - 0.05, windows: [SitePollWindow(windowID: 10, title: "Window")]))
        manager.receiveSitePoll(SitePollSnapshot(start: c + 0.15, end: c + 0.20, windows: [SitePollWindow(windowID: 10, title: "Window")]))
        manager.receiveSitePoll(SitePollSnapshot(start: c + 0.40, end: c + 0.45, windows: [SitePollWindow(windowID: 10, title: "Window")]))
        manager.receiveSitePoll(SitePollSnapshot(start: c + 0.65, end: c + 0.70, windows: [SitePollWindow(windowID: 10, title: "Window")]))

        var initialDec = SiteDecision()
        initialDec.evaluate(
            key: SiteDecisionKey(windowID: 10, title: "Window"),
            initialAXTitle: "Window",
            finalAXTitle: "Window",
            walk: WebAreaWalkResult(urls: ["https://other.com"], completeness: .complete),
            sites: ["a.com"],
            now: c,
            isSweep: false
        )
        manager.receiveSiteDecision(initialDec, axAvailable: true, generation: manager.siteListGeneration)

        // Sequence with no await before the frame check:
        manager.updateSiteRule(["a.com"])
        manager.updateSiteRule([])
        manager.updateSiteRule(["b.com"])

        // Deliver one frame through handleFrameFromOutput. Submitted count is 0.
        capturer.handleFrameFromOutput(
            generation: capturer._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 1,
            displayTimeTicks: originTicks
        )

        #expect(capturer._submittedVideoFrameCountForTesting == 0)

        // Deliver fresh decision under b.com (covered)
        var coveredDec = SiteDecision()
        coveredDec.evaluate(
            key: SiteDecisionKey(windowID: 10, title: "Window"),
            initialAXTitle: "Window",
            finalAXTitle: "Window",
            walk: WebAreaWalkResult(urls: ["https://b.com"], completeness: .complete),
            sites: ["b.com"],
            now: c + 0.1,
            isSweep: false
        )
        manager.receiveSiteDecision(coveredDec, axAvailable: true, generation: manager.siteListGeneration)

        // Submitted count stays 0 (covered frame is dropped, not appended)
        #expect(capturer._submittedVideoFrameCountForTesting == 0)

        await capturer.stop()
    }

    @MainActor
    @Test func samplerTitleMismatchBeforeCoveredURLStaysPending() async throws {
        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [123] }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 42, pid: 123, layer: 0, title: "T")]
        }
        hooks.observe = { wid, pid, title in
            ("T", WebAreaWalkResult(urls: ["https://bank.com/account"], completeness: .complete), "T2", false)
        }

        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, _ in }
        )

        await sampler.setSitesForTesting(["bank.com"])
        await sampler.performPollForTesting()
        await sampler.performWalkPassForTesting()

        let dec = await sampler.decisionsForTesting
        let key = SiteDecisionKey(windowID: 42, title: "T")
        let nowSec = HostClock.seconds(ticks: mach_absolute_time())
        #expect(dec.verdict(for: key, at: nowSec) == .pending)
    }

    @MainActor
    @Test func staleWalkFromOlderListIsDiscarded() async throws {
        let observeEntered = OneShotContinuationGate()
        let sema = DispatchSemaphore(value: 0)
        defer { sema.signal() }

        var hooks = SiteSamplerHooks()
        hooks.safariPIDs = { [123] }
        hooks.copyOnScreen = {
            [SiteVisibleWindow(windowID: 42, pid: 123, layer: 0, title: "T")]
        }
        hooks.observe = { wid, pid, title in
            observeEntered.release()
            sema.wait()
            return ("T", WebAreaWalkResult(urls: ["https://a.com/page"], completeness: .complete), "T", false)
        }

        let reportedGens = OSAllocatedUnfairLock(initialState: [UInt64]())
        let sampler = SiteSampler(
            hooks: hooks,
            onPoll: { _ in },
            onDecisionUpdate: { _, _, gen in
                reportedGens.withLock { $0.append(gen) }
            }
        )

        await sampler.applySites(["a.com"], generation: 1)
        await sampler.stop()

        await sampler.performPollForTesting()

        let walkTask = Task {
            await sampler.performWalkPassForTesting()
        }

        await observeEntered.wait()

        await sampler.applySites(["b.com"], generation: 2)
        await sampler.stop()

        sema.signal()
        await walkTask.value

        let dec = await sampler.decisionsForTesting
        #expect(dec.entries.isEmpty)
        #expect(dec.consecutiveFailures == 0)

        let gens = reportedGens.withLock { $0 }
        if let idx2 = gens.firstIndex(of: 2) {
            #expect(!gens[idx2...].contains(1))
        } else {
            #expect(!gens.contains(1))
        }
    }

    @MainActor
    @Test func siteAccessibilityCautionFollowsPublishedMonitorAndSnapshotFixtures() {
        let config = AppConfig(excludedSites: ["bank.com"])
        let stateNoCaution = AppState.forSnapshot(config: config, snapshotAccessibilityCaution: false)
        #expect(!stateNoCaution.siteAccessibilityCaution)

        let stateCaution = AppState.forSnapshot(config: config, snapshotAccessibilityCaution: true)
        #expect(stateCaution.siteAccessibilityCaution)

        let stateSafariCaution = AppState.forSnapshot(config: config, snapshotSafariCaution: true)
        #expect(stateSafariCaution.siteSafariCaution)

        let stateNoSafariCaution = AppState.forSnapshot(config: config, snapshotSafariCaution: false)
        #expect(!stateNoSafariCaution.siteSafariCaution)
    }
}
