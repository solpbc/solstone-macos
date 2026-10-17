// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("Screen intake recovery boundaries")
@MainActor
struct ScreenIntakeRecoveryReviewTests {
    private func capturer(_ directory: URL, factory: FakeCaptureStreamFactory) throws -> ScreenshotCapturer {
        try ScreenshotCapturer(displayID: 101, videoURL: directory.appendingPathComponent("screen.mp4"),
            width: 100, height: 100, frameRate: 1, duration: nil,
            contentFilter: SCContentFilter(), verbose: false, streamFactory: factory.factory)
    }

    @Test func warningIsVisibleWhileRetiringTheFailedStream() async throws {
        let root = try makeTempDirectory("screen-warning-before-teardown")
        defer { try? FileManager.default.removeItem(at: root) }
        let stopGate = OneShotContinuationGate()
        defer { stopGate.release() }
        let initial = FakeCaptureStream(stopGates: [stopGate])
        let capture = try capturer(root, factory: FakeCaptureStreamFactory([initial, FakeCaptureStream()]))
        capture._restartParkHookForTesting = {}
        var warnings = 0
        capture.onScreenStopped = { warnings += 1 }
        try await capture.start()
        let restart = Task { @MainActor in await capture._restartStreamForTesting() }
        await initial.stopCount.waitUntilCount(1)
        #expect(warnings == 1)
        stopGate.release()
        await restart.value
        await capture.stop()
    }

    @Test func failedAttemptCannotDeliverFramesOrStopSharingDuringNextBackoff() async throws {
        let root = try makeTempDirectory("screen-failed-attempt-backoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let parked = OneShotContinuationGate()
        let release = OneShotContinuationGate()
        defer { release.release() }
        let factory = FakeCaptureStreamFactory([
            FakeCaptureStream(), FakeCaptureStream(startError: FakeCaptureError.startFailed), FakeCaptureStream()
        ])
        let capture = try capturer(root, factory: factory)
        var parks = 0
        capture._restartParkHookForTesting = {
            parks += 1
            if parks == 2 { parked.release(); await release.wait() }
        }
        var frames = 0
        var terminalStops = 0
        capture.onFrameDelivered = { frames += 1 }
        capture.onTerminalStop = { terminalStops += 1 }
        try await capture.start()
        let restart = Task { @MainActor in await capture._restartStreamForTesting() }
        await parked.wait()
        let output = try #require(factory.createdStreams[1].outputs.first as? VideoStreamOutput)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        output.onFrame(try #require(buffer), true)
        factory.createdDelegates[1].onError(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
        for _ in 0..<10 { await Task.yield() }
        #expect(frames == 0)
        #expect(terminalStops == 0)
        release.release()
        await restart.value
        #expect(capture._isRunningForTesting)
        await capture.stop()
    }

    @Test func stopWhileReplacementStartFailsDoesNotReportANewFailure() async throws {
        let root = try makeTempDirectory("screen-stopped-pending-failed-start")
        defer { try? FileManager.default.removeItem(at: root) }
        let startGate = OneShotContinuationGate()
        defer { startGate.release() }
        let replacement = FakeCaptureStream(startGates: [startGate], startError:
            NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        let capture = try capturer(root, factory: FakeCaptureStreamFactory([FakeCaptureStream(), replacement]))
        capture._restartParkHookForTesting = {}
        var warnings = 0
        capture.onScreenStopped = { warnings += 1 }
        try await capture.start()
        let restart = Task { @MainActor in await capture._restartStreamForTesting() }
        await replacement.startCount.waitUntilCount(1)
        let beforeStop = warnings
        #expect(beforeStop == 1)
        await capture.stop()
        startGate.release()
        await restart.value
        #expect(warnings == beforeStop)
        #expect(!capture._isRunningForTesting)
    }

    @Test func lateEnumerationFailureDoesNotWarnAfterScreenIntakeIsTurnedOff() async throws {
        let root = try makeTempDirectory("screen-enumeration-after-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = OneShotContinuationGate()
        let release = OneShotContinuationGate()
        defer { release.release() }
        let manager = CaptureManager(storageManager: StorageManager(baseDirectory: root),
            finalizer: FakeFinalizer(), microphoneDevices: { [] },
            shareableContentProvider: {
                entered.release()
                await release.wait()
                throw FakeCaptureError.startFailed
            }, pauseForProtectedVideo: false)
        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("segment"))
        manager.seedRecordingForTesting(currentSegment: segment, sources: .screen)
        let refresh = Task { @MainActor in await manager.handleDisplayChange() }
        await entered.wait()
        manager.seedRecordingForTesting(currentSegment: segment, sources: .microphone)
        manager.clearScreenFailure()
        release.release()
        await refresh.value
        #expect(manager.currentScreenFailure == nil)
        #expect(manager.activeSources == .microphone)
    }

    @Test func enumerationFailureKeepsScreenIntentAndWarningAcrossMicrophoneOnlySegments() async throws {
        let root = try makeTempDirectory("screen-enumeration-microphone-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                FakeCaptureSegment(outputDirectory: directory, successfulSources: .microphone)
            },
            finalizer: FakeFinalizer(), microphoneDevices: { [] },
            shareableContentProvider: { throw FakeCaptureError.startFailed },
            pauseForProtectedVideo: false
        )
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        let outcome = await executor.enqueue(.start(reason: .user, sources: [.screen, .microphone], disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = outcome else { Issue.record("microphone fallback did not start"); return }
        #expect(manager.activeSources == .microphone)
        #expect(manager.sessionSourcesForTesting.contains(.screen))
        #expect(manager.currentScreenFailure == .couldNotStart)
        _ = await executor.enqueue(.rotate(reason: .boundary))
        #expect(manager.activeSources == .microphone)
        #expect(manager.sessionSourcesForTesting.contains(.screen))
        #expect(manager.currentScreenFailure == .couldNotStart)
        _ = await executor.enqueue(.stop(reason: .user))
    }
}
