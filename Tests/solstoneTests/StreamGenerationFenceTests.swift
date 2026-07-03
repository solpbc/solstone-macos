// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("ScreenshotCapturer StreamGenerationFence", .serialized)
@MainActor
struct ScreenshotCapturerStreamGenerationFenceTests {
    private let suppressedTrace = "restart suppressed - stream generation changed"
    private let proceedingTrace = "restart proceeding"

    @Test func systemAudioRestartSuppressedAfterStopDoesNotResurrect() async throws {
        let oldStream = FakeCaptureStream()
        let restartStartGate = OneShotContinuationGate()
        let restartingStream = FakeCaptureStream(startGates: [restartStartGate])
        let factory = FakeCaptureStreamFactory([oldStream, restartingStream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())
        manager._restartParkHookForTesting = {}

        let restartTask = Task { @MainActor in
            await manager._restartStreamForTesting()
        }
        await restartingStream.startCount.waitUntilCount(1)

        await manager.stop()
        restartStartGate.release()
        await restartTask.value

        #expect(manager.isRunning == false)
        #expect(factory.createdStreams.count == 2)
        #expect(restartingStream.stopCount.count == 1)
        #expect(manager._restartDecisionTraceForTesting.contains(suppressedTrace))
        #expect(manager._restartDecisionTraceForTesting.contains(proceedingTrace))
    }

    @Test func screenshotRestartSuppressedAfterStopDoesNotResurrect() async throws {
        let root = try makeTempDirectory("screenshot-generation-resurrection")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, FakeCaptureStream()])
        let capturer = try makeScreenshotCapturer(root: root, factory: factory)
        try await capturer.start()

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        capturer._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let restartTask = Task { @MainActor in
            await capturer._restartStreamForTesting()
        }
        await parkCount.waitUntilCount(1)

        await capturer.stop()
        parkGate.release()
        await restartTask.value

        #expect(factory.createdStreams.count == 1)
        #expect(capturer._restartDecisionTraceForTesting.contains(suppressedTrace))
        #expect(!capturer._restartDecisionTraceForTesting.contains(proceedingTrace))
    }

    @Test func systemAudioStaleRestartDoesNotTouchHealthyNewStream() async throws {
        let oldStream = FakeCaptureStream()
        let newStream = FakeCaptureStream()
        let staleStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, newStream, staleStream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        manager._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let restartTask = Task { @MainActor in
            await manager._restartStreamForTesting()
        }
        await parkCount.waitUntilCount(1)

        await manager.stop()
        try await manager.start(filter: SCContentFilter())
        #expect(manager.isRunning)
        #expect(factory.createdStreams.count == 2)

        parkGate.release()
        await restartTask.value

        #expect(manager.isRunning)
        #expect(factory.createdStreams.count == 2)
        #expect(newStream.stopCount.count == 0)
        #expect(manager._restartDecisionTraceForTesting.contains(suppressedTrace))
    }

    @Test func screenshotStaleRestartDoesNotTouchHealthyNewStream() async throws {
        let root = try makeTempDirectory("screenshot-generation-race")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldStream = FakeCaptureStream()
        let newStream = FakeCaptureStream()
        let staleStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, newStream, staleStream])
        let capturer = try makeScreenshotCapturer(root: root, factory: factory)
        try await capturer.start()

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        capturer._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let restartTask = Task { @MainActor in
            await capturer._restartStreamForTesting()
        }
        await parkCount.waitUntilCount(1)

        await capturer.stop()
        try await capturer.start()
        #expect(factory.createdStreams.count == 2)

        parkGate.release()
        await restartTask.value

        #expect(factory.createdStreams.count == 2)
        #expect(newStream.stopCount.count == 0)
        #expect(capturer._restartDecisionTraceForTesting.contains(suppressedTrace))
    }

    @Test func stopBumpHappensBeforeFirstAwait() async throws {
        let restartStopGate = OneShotContinuationGate()
        let stopGate = OneShotContinuationGate()
        let hookGate = OneShotContinuationGate()
        let hookCount = LockedCounter()
        let oldStream = FakeCaptureStream(stopGates: [restartStopGate, stopGate])
        let factory = FakeCaptureStreamFactory([oldStream, FakeCaptureStream()])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())
        manager._restartParkHookForTesting = {
            hookCount.increment()
            await hookGate.wait()
        }

        let restartTask = Task { @MainActor in
            await manager._restartStreamForTesting()
        }
        await oldStream.stopCount.waitUntilCount(1)

        let stopTask = Task { @MainActor in
            await manager.stop()
        }
        await oldStream.stopCount.waitUntilCount(2)

        restartStopGate.release()
        try await waitUntil(timeout: .seconds(2)) {
            let suppressed = await MainActor.run {
                manager._restartDecisionTraceForTesting.contains(suppressedTrace)
            }
            return suppressed || hookCount.count > 0
        }

        #expect(manager._restartDecisionTraceForTesting.contains(suppressedTrace))
        #expect(hookCount.count == 0)

        stopGate.release()
        hookGate.release()
        await restartTask.value
        await stopTask.value
    }

    @Test func systemAudioStopTimeoutDropsRefsAndAdmitsFollowup() async throws {
        let oldStream = FakeCaptureStream()
        let followupStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, followupStream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())
        let generationBeforeStop = manager._streamGenerationForTesting

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        manager._stopParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let start = Date()
        await manager.stop()
        let elapsed = Date().timeIntervalSince(start)

        #expect(parkCount.count == 1)
        #expect(elapsed < 6.0)
        #expect(manager._streamGenerationForTesting == generationBeforeStop + 1)
        #expect(manager.isRunning == false)

        parkGate.release()
        await Task.yield()
        try await manager.start(filter: SCContentFilter())

        #expect(manager.isRunning)
        #expect(factory.createdStreams.count == 2)
        #expect(followupStream.startCount.count == 1)
    }

    @Test func startBumpHappensBeforeFirstAwait() async throws {
        let oldStream = FakeCaptureStream()
        let startGate = OneShotContinuationGate()
        let newStream = FakeCaptureStream(startGates: [startGate])
        let staleStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, newStream, staleStream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        manager._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let restartTask = Task { @MainActor in
            await manager._restartStreamForTesting()
        }
        await parkCount.waitUntilCount(1)

        let startTask = Task { @MainActor in
            try? await manager.start(filter: SCContentFilter())
        }
        await newStream.startCount.waitUntilCount(1)

        parkGate.release()
        await restartTask.value

        #expect(factory.createdStreams.count == 2)
        #expect(manager._restartDecisionTraceForTesting.contains(suppressedTrace))

        startGate.release()
        await startTask.value
    }

    @Test func systemAudioRestartUsesLiveFilterOnProceed() async throws {
        let restartStopGate = OneShotContinuationGate()
        let oldStream = FakeCaptureStream(stopGates: [restartStopGate])
        let restartedStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, restartedStream])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        let oldFilter = SCContentFilter()
        let newFilter = SCContentFilter()
        try await manager.start(filter: oldFilter)
        manager._restartParkHookForTesting = {}

        let restartTask = Task { @MainActor in
            await manager._restartStreamForTesting()
        }
        await oldStream.stopCount.waitUntilCount(1)

        try await manager.updateContentFilter(newFilter)
        restartStopGate.release()
        await restartTask.value

        #expect(factory.createdStreams.count == 2)
        #expect(factory.createdFilters.count == 2)
        #expect(factory.createdFilters[0] === oldFilter)
        #expect(factory.createdFilters[1] === newFilter)
        #expect(manager._restartDecisionTraceForTesting.contains(proceedingTrace))
        #expect(!manager._restartDecisionTraceForTesting.contains(suppressedTrace))
    }

    @Test func systemAudioErrorRestartSuppressedAfterStop() async throws {
        let oldStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, FakeCaptureStream()])
        let manager = SystemAudioCaptureManager(streamFactory: factory.factory)
        try await manager.start(filter: SCContentFilter())

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        manager._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        let errorTask = Task { @MainActor in
            await manager._handleStreamErrorForTesting(NSError(domain: "StreamGenerationFence", code: 1))
        }
        await parkCount.waitUntilCount(1)

        await manager.stop()
        parkGate.release()
        await errorTask.value

        #expect(factory.createdStreams.count == 1)
        #expect(manager._restartDecisionTraceForTesting.contains(suppressedTrace))
    }

    @Test func screenshotErrorRestartSuppressedAfterStopRecordsLogTrace() async throws {
        let root = try makeTempDirectory("screenshot-generation-error")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldStream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([oldStream, FakeCaptureStream()])
        let capturer = try makeScreenshotCapturer(root: root, factory: factory)
        try await capturer.start()

        let parkGate = OneShotContinuationGate()
        let parkCount = LockedCounter()
        let healthFailureCount = LockedCounter()
        capturer.onHealthFailure = {
            healthFailureCount.increment()
        }
        capturer._restartParkHookForTesting = {
            parkCount.increment()
            await parkGate.wait()
        }

        await capturer._handleStreamErrorForTesting(NSError(domain: "StreamGenerationFence", code: 2))
        await parkCount.waitUntilCount(1)

        await capturer.stop()
        parkGate.release()
        try await waitUntil(timeout: .seconds(2)) {
            await MainActor.run {
                capturer._restartDecisionTraceForTesting.contains(suppressedTrace)
            }
        }

        #expect(factory.createdStreams.count == 1)
        #expect(capturer._restartDecisionTraceForTesting.contains(suppressedTrace))
        #expect(capturer._restartDecisionTraceForTesting.filter { $0 == suppressedTrace }.count == 1)
        #expect(healthFailureCount.count == 0)
    }

    @Test func screenshotRestartExhaustionFailsClosedAndEscalatesOnce() async throws {
        let root = try makeTempDirectory("screenshot-restart-exhaustion")
        defer { try? FileManager.default.removeItem(at: root) }

        let initialStream = FakeCaptureStream()
        let firstFailure = FakeCaptureStream(startError: FakeCaptureError.startFailed)
        let secondFailure = FakeCaptureStream(startError: FakeCaptureError.startFailed)
        let thirdFailure = FakeCaptureStream(startError: FakeCaptureError.startFailed)
        let factory = FakeCaptureStreamFactory([initialStream, firstFailure, secondFailure, thirdFailure])
        let capturer = try makeScreenshotCapturer(root: root, factory: factory)
        try await capturer.start()

        capturer._restartParkHookForTesting = {}
        let healthFailureCount = LockedCounter()
        capturer.onHealthFailure = {
            healthFailureCount.increment()
        }

        await capturer._restartStreamForTesting()

        #expect(healthFailureCount.count == 1)
        #expect(capturer._isRunningForTesting == false)
        #expect(capturer._hasStreamForTesting == false)
        #expect(capturer._isHealthCheckActiveForTesting == false)
        #expect(capturer._restartDecisionTraceForTesting.filter { $0 == proceedingTrace }.count == 3)
        #expect(factory.createdStreams.count == 4)
    }

    private func makeScreenshotCapturer(
        root: URL,
        factory: FakeCaptureStreamFactory
    ) throws -> ScreenshotCapturer {
        try ScreenshotCapturer(
            displayID: 42,
            videoURL: root.appendingPathComponent("screen.mp4"),
            width: 16,
            height: 16,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: factory.factory
        )
    }
}
