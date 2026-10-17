// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import solstone
@testable import SolstoneCore

private final class NowBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now
    }
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

private final class WindowBox: @unchecked Sendable {
    var windows: [OnScreenWindowRecord] = []
}

@Suite("ProtectedVideoMonitorTests")
struct ProtectedVideoMonitorTests {
    private func makeTempDirectory(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/var/tmp").appendingPathComponent("solstone-monitor-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func makeManager(
        root: URL,
        nowBox: NowBox,
        windowBox: WindowBox,
        notificationCenter: NotificationCenter = NotificationCenter(),
        segmentFactory: @escaping CaptureManager.SegmentFactory = { outputDirectory, _, _, _ in
            FakeCaptureSegment(outputDirectory: outputDirectory)
        },
        unlockResumeDelay: (@MainActor @Sendable () async throws -> Void)? = nil,
        transitionTimeoutSeconds: TimeInterval = 30,
        allowsEmptyDisplayConfigurationForTesting: Bool = true
    ) -> CaptureManager {
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: segmentFactory,
            allowsEmptyDisplayConfigurationForTesting: allowsEmptyDisplayConfigurationForTesting,
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows },
            workspaceNotificationCenter: notificationCenter,
            unlockResumeDelay: unlockResumeDelay,
            transitionTimeoutSeconds: transitionTimeoutSeconds
        )
        manager.setNowForTesting { nowBox.now }
        return manager
    }

    // 1. Recording + match: first await checkProtectedVideo() is paused with {.protectedVideo}, segment finalized, system audio and mics stopped.
    @Test @MainActor func recordingMatchPausesWithProtectedVideoAndFinalizesSegment() async throws {
        let root = try makeTempDirectory("pause-match")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        await manager.checkProtectedVideo()

        #expect(manager.state == .paused(reasons: [.protectedVideo]))
        #expect(segment.finishCaptureCount.count >= 1)
    }

    // 2. Clear for 2.9 s, including posts of didLaunchApplication, didActivateApplication, and didDeactivateApplication on the injected center, stays paused. At 3.0 s, recording and a new segment. The burst must not move clearSince.
    @Test @MainActor func clearDebounceAndNotificationBurst() async throws {
        let root = try makeTempDirectory("debounce")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let nc = NotificationCenter()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox, notificationCenter: nc)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Window clears
        windowBox.windows = []
        await manager.checkProtectedVideo()
        let initialClearSince = try #require(manager.clearSinceForTesting)

        // Advance 1.0s and post burst of notifications
        nowBox.advance(by: 1.0)
        nc.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.post(name: NSWorkspace.didDeactivateApplicationNotification, object: nil)

        // Advance by 1.9s (total 2.9s from clearSince)
        nowBox.advance(by: 1.9)
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))
        #expect(manager.clearSinceForTesting == initialClearSince)

        // Advance 0.1s (total 3.0s)
        nowBox.advance(by: 0.1)
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)
    }

    // 3. Owner pause that sets lifecycleOwnerPauseIsHeld: window clears, resume is vetoed while held, owner releases, next check records. Do not expect an owner resume alone to clear .protectedVideo.
    @Test @MainActor func ownerPauseHeldVetoesResumeUntilReleased() async throws {
        let root = try makeTempDirectory("owner-held")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Protected video appears
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Owner pauses
        _ = await manager.enqueueTransition(.pause(reason: .user, stopAudio: true))
        #expect(manager.state == .paused(reasons: [.user, .protectedVideo]))

        // Window clears
        windowBox.windows = []
        await manager.checkProtectedVideo()

        // Owner resume alone does NOT clear .protectedVideo
        _ = await manager.enqueueTransition(.resume(reason: .user))
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Set owner pause held
        manager.lifecycleManager.ownerPauseIsHeld = { true }

        // Debounce expires (3.0s)
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()

        // Resume was vetoed because owner pause is held
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Owner releases
        manager.lifecycleManager.ownerPauseIsHeld = { false }

        // Next check records
        await manager.checkProtectedVideo()
        #expect(manager.state == .recording)
    }

    // 4. Already paused for .protectedVideo, or paused for .lock while unlockResumeDelay is suspended: matching checks enqueue no pause. Releasing the delay does not return .dropped.
    @Test @MainActor func matchingChecksEnqueueNoPauseWhileAlreadyPausedOrUnlockSuspended() async throws {
        let root = try makeTempDirectory("unlock-suspended")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let unlockGate = OneShotContinuationGate()

        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox,
            unlockResumeDelay: {
                await unlockGate.wait()
            }
        )

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // 4a. Already paused for .protectedVideo
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Matching check enqueues no pause
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // 4b. Paused for .lock while unlockResumeDelay is suspended
        await manager.lifecycleManager.handleScreenLocked()
        #expect(manager.state == .paused(reasons: [.protectedVideo, .lock]))

        // Window clears for protected video, resume reasons leaves lock
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.lock]))

        // Now start unlock resume with delay suspended
        let resumeTask = Task { @MainActor in
            await manager.enqueueTransition(.resume(reason: .unlock))
        }

        // Matching window appears while unlockResumeDelay is suspended
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        // Check protected video does not enqueue pause
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.lock]))

        // Release unlock delay
        unlockGate.release()
        let outcome = await resumeTask.value
        if case .dropped = outcome {
            Issue.record("expected resume outcome not to be .dropped")
        }
    }

    // 5. Segment factory suspended, five checks during that prepare, factory called once. Releasing it reaches recording.
    @Test @MainActor func segmentFactorySuspendedFiveChecksCallsFactoryOnce() async throws {
        let root = try makeTempDirectory("factory-suspended")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let factoryGate = OneShotContinuationGate()
        let factoryCallCount = LockedCounter()

        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox,
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCallCount.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory, startGate: factoryGate)
            }
        )

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Pause for protected video
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Window clears and debounce expires
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)

        // Launch resume check in background task
        let resumeTask = Task { @MainActor in
            await manager.checkProtectedVideo()
        }

        try await waitUntil(timeout: .seconds(5)) {
            factoryCallCount.count == 1
        }

        // Perform 5 checks while prepare is suspended
        let checkCount = LockedCounter()
        var checkTasks: [Task<Void, Never>] = []
        for _ in 1...5 {
            checkTasks.append(Task { @MainActor in
                checkCount.increment()
                await manager.checkProtectedVideo()
            })
        }

        try await waitUntil(timeout: .seconds(5)) {
            guard checkCount.count == 5 else { return false }
            return await MainActor.run {
                manager.lifecycleManager.queuedIntentCountForTesting == 1
            }
        }

        #expect(factoryCallCount.count == 1)

        // Release gate and reach recording
        factoryGate.release()
        await resumeTask.value
        for task in checkTasks {
            await task.value
        }

        #expect(manager.state == .recording)
        #expect(factoryCallCount.count == 1)
    }

    // 6. Two prepares that hit a short real transitionTimeoutSeconds. On the injected clock the next attempt is not earlier than 10 s, then not earlier than 30 s.
    @Test @MainActor func transitionTimeoutBackoffStepDelays() async throws {
        let root = try makeTempDirectory("backoff-delays")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()

        // Short transitionTimeoutSeconds
        let manager = makeManager(
            root: root,
            nowBox: nowBox,
            windowBox: windowBox,
            segmentFactory: { outputDirectory, _, _, _ in
                // Hangs to cause transition timeout
                FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    startGate: OneShotContinuationGate()
                )
            },
            transitionTimeoutSeconds: 0.05
        )

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        // Pause for protected video
        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Clear window and wait debounce
        windowBox.windows = []
        await manager.checkProtectedVideo()
        nowBox.advance(by: 3.0)

        // First resume attempt hits 0.05s timeout
        let beforeFirstAttempt = nowBox.now
        await manager.checkProtectedVideo()

        // Next attempt not earlier than 10s
        let resumeNotBefore1 = try #require(manager.resumeNotBeforeForTesting)
        #expect(resumeNotBefore1 >= beforeFirstAttempt.addingTimeInterval(10))

        // Check at 5s: still paused, no prepare triggered
        nowBox.advance(by: 5.0)
        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        // Advance past 10s: second attempt hits timeout
        nowBox.advance(by: 5.1)
        let beforeSecondAttempt = nowBox.now
        await manager.checkProtectedVideo()

        // Next attempt not earlier than 30s
        let resumeNotBefore2 = try #require(manager.resumeNotBeforeForTesting)
        #expect(resumeNotBefore2 >= beforeSecondAttempt.addingTimeInterval(30))
    }

    // 7. Microphone-only is not paused. A start whose shareableContentProvider throws and continues microphone-only is not paused.
    @Test @MainActor func microphoneOnlyIsNotPaused() async throws {
        let root = try makeTempDirectory("mic-only")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment, sources: .microphone)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        await manager.checkProtectedVideo()

        #expect(manager.state == .recording)

        // A failed requested screen stays requested, while only the microphone is
        // active. Protected video must not pause that microphone-only capture.
        struct SyntheticScreenProviderError: Error {}
        let manager2 = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory, successfulSources: .microphone)
            },
            allowsEmptyDisplayConfigurationForTesting: false,
            shareableContentProvider: {
                throw SyntheticScreenProviderError()
            },
            pauseForProtectedVideo: true,
            protectedVideoTitlePatterns: [],
            protectedVideoTimerEnabled: false,
            windowList: { windowBox.windows }
        )
        manager2.setNowForTesting { nowBox.now }

        let startResult = try await manager2.lifecycleStartCapture(
            reason: .user,
            sources: [.screen, .microphone],
            disabledMicUIDs: [],
            enabledMicUIDs: [],
            shouldVetoCommit: { false }
        )
        #expect(startResult == .committed)
        #expect(manager2.state == .recording)
        #expect(manager2.sessionSourcesForTesting.contains(.screen))
        #expect(manager2.activeSources == .microphone)

        await manager2.checkProtectedVideo()
        #expect(manager2.state == .recording)
    }

    // 8. Toggle off via updateProtectedVideoSettings(pause: false, ...), then await checkProtectedVideo(), becomes recording with the clock unmoved.
    @Test @MainActor func toggleOffResumesWithClockUnmoved() async throws {
        let root = try makeTempDirectory("toggle-off")
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = NowBox()
        let windowBox = WindowBox()
        let manager = makeManager(root: root, nowBox: nowBox, windowBox: windowBox)

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000_300.incomplete"))
        manager.seedRecordingForTesting(currentSegment: segment)

        windowBox.windows = [
            OnScreenWindowRecord(windowID: 101, pid: 200, ownerName: "Google Chrome", title: "Netflix")
        ]

        await manager.checkProtectedVideo()
        #expect(manager.state == .paused(reasons: [.protectedVideo]))

        manager.updateProtectedVideoSettings(pause: false, patterns: [])
        let clockBefore = nowBox.now

        await manager.checkProtectedVideo()

        #expect(manager.state == .recording)
        #expect(nowBox.now == clockBefore)
    }
}
