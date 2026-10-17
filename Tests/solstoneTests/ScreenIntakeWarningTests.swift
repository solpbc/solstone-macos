// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("ScreenIntakeWarning")
@MainActor
struct ScreenIntakeWarningTests {
    private let dummyDisplay1 = DisplayInfo(
        displayID: 101,
        width: 1920,
        height: 1080,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    private let dummyDisplay2 = DisplayInfo(
        displayID: 102,
        width: 1920,
        height: 1080,
        bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    )
    private let testMic = AudioInputDevice(
        id: 1,
        name: "Test Microphone",
        uid: "test-mic-uid",
        manufacturer: nil,
        sampleRate: 48000,
        transportType: .builtin
    )

    @Test func totalScreenStartFailureWithMicrophoneFallsBackAndReportsCouldNotStartWithoutThrowing() async throws {
        let dir = try makeTempDirectory("screen-warning-fallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        var reportedFailure: ScreenFailureKind?
        let audioManager = FakeAudioManager(behavior: .normal)

        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { _, _, _, _, _, _ in
                FakeScreenshotCapturer(behavior: .throwOnStart)
            },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
        writer.onScreenFailure = { failure in
            reportedFailure = failure
        }

        let started = try await writer.start(
            sources: [.screen, .microphone],
            displayInfos: [dummyDisplay1],
            filters: [dummyDisplay1.displayID: SCContentFilter()],
            audioFilter: nil,
            mics: [testMic]
        )

        #expect(started == CaptureSources.microphone)
        #expect(reportedFailure == .couldNotStart)
        #expect(audioManager.addMicrophoneCount.count == 1)
    }

    @Test func oneOfTwoDisplaysFailingToStartKeepsSiblingAndMicrophoneReportsCouldNotStart() async throws {
        let dir = try makeTempDirectory("screen-warning-partial")
        defer { try? FileManager.default.removeItem(at: dir) }

        var reportedFailure: ScreenFailureKind?
        var terminalStopCalled = false
        let siblingCapturer = FakeScreenshotCapturer(behavior: .normal)
        let audioManager = FakeAudioManager(behavior: .normal)

        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { info, _, _, _, _, _ in
                if info.displayID == self.dummyDisplay1.displayID {
                    return FakeScreenshotCapturer(behavior: .throwOnStart)
                } else {
                    return siblingCapturer
                }
            },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
        writer.onScreenFailure = { failure in
            reportedFailure = failure
        }
        writer.onTerminalStop = {
            terminalStopCalled = true
        }

        let started = try await writer.start(
            sources: [.screen, .microphone],
            displayInfos: [dummyDisplay1, dummyDisplay2],
            filters: [
                dummyDisplay1.displayID: SCContentFilter(),
                dummyDisplay2.displayID: SCContentFilter()
            ],
            audioFilter: nil,
            mics: [testMic]
        )

        #expect(started.contains(CaptureSources.screen))
        #expect(started.contains(CaptureSources.microphone))
        #expect(reportedFailure == .couldNotStart)
        #expect(siblingCapturer.startCount.count == 1)
        #expect(siblingCapturer.stopCount.count == 0)
        #expect(!terminalStopCalled)
    }

    @Test func oneOfTwoDisplaysMissingFilterKeepsSiblingAndMicrophoneReportsCouldNotStart() async throws {
        let dir = try makeTempDirectory("screen-warning-missing-filter-partial")
        defer { try? FileManager.default.removeItem(at: dir) }

        var reportedFailure: ScreenFailureKind?
        var terminalStopCalled = false
        let siblingCapturer = FakeScreenshotCapturer(behavior: .normal)
        let audioManager = FakeAudioManager(behavior: .normal)

        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { info, _, _, _, _, _ in
                if info.displayID == self.dummyDisplay1.displayID {
                    throw SegmentWriter.SegmentError.missingContentFilter(displayID: info.displayID)
                } else {
                    return siblingCapturer
                }
            },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
        writer.onScreenFailure = { failure in
            reportedFailure = failure
        }
        writer.onTerminalStop = {
            terminalStopCalled = true
        }

        let started = try await writer.start(
            sources: [.screen, .microphone],
            displayInfos: [dummyDisplay1, dummyDisplay2],
            filters: [
                dummyDisplay2.displayID: SCContentFilter()
            ],
            audioFilter: nil,
            mics: [testMic]
        )

        #expect(started.contains(CaptureSources.screen))
        #expect(started.contains(CaptureSources.microphone))
        #expect(reportedFailure == .couldNotStart)
        #expect(siblingCapturer.startCount.count == 1)
        #expect(siblingCapturer.stopCount.count == 0)
        #expect(!terminalStopCalled)
    }

    @Test func allDisplaysMissingFilterWithMicrophoneFallsBackAndReportsCouldNotStart() async throws {
        let dir = try makeTempDirectory("screen-warning-missing-filter-fallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        var reportedFailure: ScreenFailureKind?
        var terminalStopCalled = false
        let audioManager = FakeAudioManager(behavior: .normal)

        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { info, _, _, _, _, _ in
                throw SegmentWriter.SegmentError.missingContentFilter(displayID: info.displayID)
            },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
        writer.onScreenFailure = { failure in
            reportedFailure = failure
        }
        writer.onTerminalStop = {
            terminalStopCalled = true
        }

        let started = try await writer.start(
            sources: [.screen, .microphone],
            displayInfos: [dummyDisplay1, dummyDisplay2],
            filters: [:],
            audioFilter: nil,
            mics: [testMic]
        )

        #expect(started == CaptureSources.microphone)
        #expect(reportedFailure == .couldNotStart)
        #expect(!terminalStopCalled)
        #expect(audioManager.addMicrophoneCount.count == 1)
    }

    @Test func healthExhaustionCallsOnHealthFailureOnceAndOnScreenStopped() async throws {
        let dir = try makeTempDirectory("screen-exhaustion")
        defer { try? FileManager.default.removeItem(at: dir) }

        let initialStream = FakeCaptureStream()
        let failingStream = FakeCaptureStream(startError: FakeCaptureError.startFailed)
        let factory = FakeCaptureStreamFactory([initialStream, failingStream, failingStream, failingStream, failingStream])

        let capturer = try ScreenshotCapturer(
            displayID: dummyDisplay1.displayID,
            videoURL: dir.appendingPathComponent("screen.mp4"),
            width: 100,
            height: 100,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: factory.factory
        )
        capturer._restartParkHookForTesting = {}
        try await capturer.start()
        #expect(capturer._isRunningForTesting)

        var healthFailureCalls = 0
        var screenStoppedCalls = 0
        capturer.onHealthFailure = { healthFailureCalls += 1 }
        capturer.onScreenStopped = { screenStoppedCalls += 1 }

        await capturer._restartStreamForTesting()

        #expect(healthFailureCalls == 1)
        #expect(screenStoppedCalls == 1)
        #expect(!capturer._isRunningForTesting)
    }

    @Test func permissionInHandleStreamErrorAndRestartStreamCallsOnScreenStoppedNotOnTerminalStop() async throws {
        let dir = try makeTempDirectory("screen-permission")
        defer { try? FileManager.default.removeItem(at: dir) }

        let userDeclinedError = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "User declined screen recording"]
        )

        // Path A: handleStreamError
        let streamA = FakeCaptureStream()
        let factoryA = FakeCaptureStreamFactory([streamA])
        let capturerA = try ScreenshotCapturer(
            displayID: dummyDisplay1.displayID,
            videoURL: dir.appendingPathComponent("screen_a.mp4"),
            width: 100,
            height: 100,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: factoryA.factory
        )
        try await capturerA.start()
        #expect(capturerA._isRunningForTesting)

        var screenStoppedA = false
        var terminalStopA = false
        capturerA.onScreenStopped = { screenStoppedA = true }
        capturerA.onTerminalStop = { terminalStopA = true }

        await capturerA._handleStreamErrorForTesting(userDeclinedError)

        #expect(screenStoppedA)
        #expect(!terminalStopA)
        #expect(!capturerA._isRunningForTesting)

        // Path B: restartStream catch
        let initialStreamB = FakeCaptureStream()
        let failingStreamB = FakeCaptureStream(startError: userDeclinedError)
        let factoryB = FakeCaptureStreamFactory([initialStreamB, failingStreamB])
        let capturerB = try ScreenshotCapturer(
            displayID: dummyDisplay1.displayID,
            videoURL: dir.appendingPathComponent("screen_b.mp4"),
            width: 100,
            height: 100,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: factoryB.factory
        )
        capturerB._restartParkHookForTesting = {}
        try await capturerB.start()
        #expect(capturerB._isRunningForTesting)

        var screenStoppedB = false
        var terminalStopB = false
        capturerB.onScreenStopped = { screenStoppedB = true }
        capturerB.onTerminalStop = { terminalStopB = true }

        await capturerB._restartStreamForTesting()

        #expect(screenStoppedB)
        #expect(!terminalStopB)
        #expect(!capturerB._isRunningForTesting)
    }

    @Test func userStopCallsOnTerminalStopAndNotOnScreenStopped() async throws {
        let dir = try makeTempDirectory("screen-userstop")
        defer { try? FileManager.default.removeItem(at: dir) }

        let userStoppedError = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userStopped.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "User clicked Stop Sharing"]
        )

        let stream = FakeCaptureStream()
        let factory = FakeCaptureStreamFactory([stream])
        let capturer = try ScreenshotCapturer(
            displayID: dummyDisplay1.displayID,
            videoURL: dir.appendingPathComponent("screen_userstop.mp4"),
            width: 100,
            height: 100,
            frameRate: 1,
            duration: nil,
            contentFilter: SCContentFilter(),
            verbose: false,
            streamFactory: factory.factory
        )
        try await capturer.start()

        var screenStopped = false
        var terminalStop = false
        capturer.onScreenStopped = { screenStopped = true }
        capturer.onTerminalStop = { terminalStop = true }

        await capturer._handleStreamErrorForTesting(userStoppedError)

        #expect(terminalStop)
        #expect(!screenStopped)
        #expect(!capturer._isRunningForTesting)
    }

    @Test func staleSegmentDirectoryDoesNotSetOrClearCaptureManagerLatch() async throws {
        let root = try makeTempDirectory("stale-segment-warning")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let currentSeg = createdSegments.all.first
        #expect(currentSeg != nil)

        // Create a stale segment with a different directory
        let staleDir = root.appendingPathComponent("stale-dir")
        let staleSegment = FakeCaptureSegment(outputDirectory: staleDir)

        // Stale segment failure callback must not set latch
        staleSegment.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == nil)

        // Now set failure through the real segment
        currentSeg?.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Stale segment frame delivery must not clear latch
        staleSegment.onFrameDelivered?(dummyDisplay1.displayID)
        #expect(manager.currentScreenFailure == .couldNotStart)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func framesFromEveryDisplayInCurrentRequestedSetClearLatch() async throws {
        let root = try makeTempDirectory("frame-recovery-latch")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let currentSeg = createdSegments.all.first
        #expect(currentSeg != nil)

        // Set failure
        currentSeg?.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Deliver frame from display 0 (the requested display under allowsEmptyDisplayConfigurationForTesting)
        currentSeg?.onFrameDelivered?(0)
        #expect(manager.currentScreenFailure == nil)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func turningScreenIntakeOffClearsLatch() async throws {
        let root = try makeTempDirectory("screen-off-latch")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let currentSeg = createdSegments.all.first
        currentSeg?.onScreenFailure?(.stopped)
        #expect(manager.currentScreenFailure == .stopped)

        // Turning screen intake off directly invokes clearScreenFailure
        manager.clearScreenFailure()
        #expect(manager.currentScreenFailure == nil)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func microphoneOnlyReplacementWhileScreenIsStillRequestedDoesNotClear() async throws {
        let root = try makeTempDirectory("mic-replacement-latch")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen, .microphone], disabledMicUIDs: [], enabledMicUIDs: []))

        let seg1 = createdSegments.all.first
        seg1?.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Rotate segment with microphone only (frameless/no screen frames)
        _ = await executor.enqueue(.rotate(reason: .boundary))
        #expect(manager.currentScreenFailure == .couldNotStart)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func activeSourcesGainingScreenDoesNotClearLatch() async throws {
        let root = try makeTempDirectory("active-sources-latch")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let seg1 = createdSegments.all.first
        seg1?.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)
        #expect(manager.activeSources.contains(.screen))
        // Gaining screen in activeSources without delivered frames must keep the latch
        #expect(manager.currentScreenFailure == .couldNotStart)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func audioHealthAndScreenWarningCoexistWithoutError() {
        let state = classifyObservationRowState(
            permissionsNeedAttention: false,
            errorMessage: nil,
            initialPermissionCheckComplete: true,
            isRecording: true,
            isPaused: false,
            serviceMode: nil,
            syncPaused: false,
            isPairedIngestReady: true,
            uploadStatus: .synced
        )

        #expect(state == MenubarStatusRowState.observing)
        #expect(state != MenubarStatusRowState.error)
    }

    @Test func unpluggedDisplayDroppedFromRequestedSetClearsLatchIfRemainderFramed() async throws {
        let root = try makeTempDirectory("unplug-display-latch")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let seg1 = createdSegments.all.first
        seg1?.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Deliver frame for display 0
        seg1?.onFrameDelivered?(0)
        #expect(manager.currentScreenFailure == nil)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func replacementSegmentRequiresFreshFramesFromEveryRequestedDisplay() async throws {
        let root = try makeTempDirectory("screen-replacement-fresh-frames")
        defer { try? FileManager.default.removeItem(at: root) }

        let createdSegments = LockedArray<FakeCaptureSegment>([])
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: directory)
                createdSegments.append(segment)
                return segment
            },
            finalizer: FakeFinalizer(),
            allowsEmptyDisplayConfigurationForTesting: true
        )

        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        _ = await executor.enqueue(.start(reason: .user, sources: [.screen], disabledMicUIDs: [], enabledMicUIDs: []))

        let seg1 = try #require(createdSegments.all.first)
        manager.setRequestedDisplayIDsForTesting([1, 2])

        seg1.onScreenFailure?(.couldNotStart)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Deliver display 1 on that segment
        seg1.onFrameDelivered?(1)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Rotate
        _ = await executor.enqueue(.rotate(reason: .boundary))
        let seg2 = try #require(createdSegments.all.last)
        #expect(seg2.outputDirectory != seg1.outputDirectory)

        // Deliver only display 2 on the replacement
        seg2.onFrameDelivered?(2)
        // The failure stays
        #expect(manager.currentScreenFailure == .couldNotStart)

        // A frame from the replaced segment after rotation does not clear it
        seg1.onFrameDelivered?(1)
        #expect(manager.currentScreenFailure == .couldNotStart)

        // Delivering display 1 on the replacement then clears it
        seg2.onFrameDelivered?(1)
        #expect(manager.currentScreenFailure == nil)

        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func accessibilityIdentifiersAreStaticAndValid() {
        #expect(AXID.Menubar.screenIntake == "menubar.screen.intake")
        #expect(AXID.Settings.Status.screenIntake == "settings.status.screen.intake")
        #expect(AXID.Settings.Sources.segments == "settings.sources.segments")
    }
}
