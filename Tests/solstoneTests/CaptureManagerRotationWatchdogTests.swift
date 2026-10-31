// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import SolstoneCore
import Testing
@testable import solstone

@Suite("CaptureManager rotation watchdog", .serialized)
@MainActor
struct CaptureManagerRotationWatchdogTests {
    @Test func rotateSegmentTimeoutReleasesRotationAndAdmitsFollowup() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "111111.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)]
        )
        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let scheduler = FakeRecoveryScheduler()
        let finalizer = FakeFinalizer()
        let startGate = OneShotContinuationGate()
        let factoryCalls = LockedCounter()
        let now = LockedValue<Date>()
        let firstNow = fixedDate(second: 0)
        now.set(firstNow)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                if factoryCalls.count == 1 {
                    return FakeCaptureSegment(
                        outputDirectory: outputDirectory,
                        startGate: startGate
                    )
                }
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: coordinator,
            finalizer: finalizer,
            rotationTimeoutSeconds: 1.0,
            now: { now.current ?? firstNow },
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let timeoutOutcome = await rotate(manager)
        guard case .threw(let timeoutFailure) = timeoutOutcome else {
            Issue.record("expected timed-out rotate to throw")
            return
        }
        #expect(timeoutFailure.message == "Segment rotation timed out")
        #expect(manager.state.isError)
        #expect(manager.isRecoveryScheduled)
        #expect(scheduler.scheduledDelays == [5])
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
        #expect(current.finishCaptureCount.count == 1)
        expectNoPendingRotate(manager)

        let followupOutcome = await rotate(manager)
        guard case .dropped = followupOutcome else {
            Issue.record("expected follow-up rotate to drop while in error")
            return
        }
        #expect(manager.state.isError)
        #expect(manager.isRecoveryScheduled)

        await scheduler.fireNext()
        #expect(manager.state.isRecording)
        #expect(!manager.isRecoveryScheduled)
        startGate.release()
        await recovery.waitForRecoverAll(1)
    }

    @Test func rotateSegmentSupersededAfterOldFinishBailsWithoutStartingNewSegment() async throws {
        let root = try makeTempDirectory("capture-rotation-supersede-before-start")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "444441.incomplete")
        let finishGate = OneShotContinuationGate()
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)],
            finishGate: finishGate
        )
        let finalizer = FakeFinalizer()
        let recovery = CountingRecovery()
        let newStartCount = LockedCounter()
        let firstNow = fixedDate(second: 3)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                newStartCount.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery }),
            finalizer: finalizer,
            now: { firstNow },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        await current.finishCaptureCount.waitUntilCount(1)

        let pauseTask = Task { @MainActor in
            await manager.enqueueTransition(.pause(reason: .lock, stopAudio: true))
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
            }
        }

        finishGate.release()
        let rotateOutcome = await rotateTask.value
        let pauseOutcome = await pauseTask.value

        guard case .vetoed = rotateOutcome else {
            Issue.record("expected rotate to be vetoed by queued pause")
            return
        }
        guard case .committed = pauseOutcome else {
            Issue.record("expected queued pause to commit")
            return
        }
        #expect(newStartCount.count == 0)
        // Audio held across the abandoned rotation is dropped, never written anywhere.
        let handoff = try #require(current.handedOffTo.current)
        #expect(handoff.stream(for: "late") == nil && handoff.claim(AudioTrackType.systemSourceID) == nil)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isPaused)
        #expect(manager.lastVetoReasonForTesting == .queuedTerminalIntent)
        expectNoPendingRotate(manager)
        #expect(manager.isSystemAudioRunningForTesting == false)
        await recovery.waitForRecoverAll(1)
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
    }

    @Test func rotateSegmentSupersededAfterNewStartDiscardsStartedSegment() async throws {
        let root = try makeTempDirectory("capture-rotation-supersede-after-start")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "444442.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let finalizer = FakeFinalizer()
        let recovery = CountingRecovery()
        let newSegment = LockedValue<FakeCaptureSegment>()
        let startGate = OneShotContinuationGate()
        let firstNow = fixedDate(second: 4)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                let segment = FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    finishBehaviors: [.normal(outputDirectory)],
                    startGate: startGate
                )
                newSegment.set(segment)
                return segment
            },
            recoveryCoordinator: IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery }),
            finalizer: finalizer,
            now: { firstNow },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { newSegment.current?.startCount.count == 1 }
        }

        let pauseTask = Task { @MainActor in
            await manager.enqueueTransition(.pause(reason: .lock, stopAudio: true))
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
            }
        }

        startGate.release()
        let rotateOutcome = await rotateTask.value
        let pauseOutcome = await pauseTask.value

        let startedSegment = try #require(newSegment.current)
        guard case .vetoed = rotateOutcome else {
            Issue.record("expected rotate to be vetoed by queued pause")
            return
        }
        guard case .committed = pauseOutcome else {
            Issue.record("expected queued pause to commit")
            return
        }
        #expect(startedSegment.finishCaptureCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all == [])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isPaused)
        #expect(manager.lastVetoReasonForTesting == .queuedTerminalIntent)
        expectNoPendingRotate(manager)
        #expect(manager.isSystemAudioRunningForTesting == false)
        await recovery.waitForRecoverAll(1)
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
    }

    @Test func rotateSegmentSupersededByQueuedPauseBeforeFirstVeto() async throws {
        let root = try makeTempDirectory("capture-rotation-supersede-marker")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "444443.incomplete")
        let finishGate = OneShotContinuationGate()
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)],
            finishGate: finishGate
        )
        let finalizer = FakeFinalizer()
        let recovery = CountingRecovery()
        let newStartCount = LockedCounter()
        let firstNow = fixedDate(second: 5)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                newStartCount.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery }),
            finalizer: finalizer,
            now: { firstNow },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.inFlightIntentForTesting == IntentSnapshot(kind: .rotate(.boundary), stopAudio: false)
            }
        }

        // The deleted pause marker is now represented by a real queued terminal intent.
        let pauseTask = Task { @MainActor in
            await manager.enqueueTransition(.pause(reason: .lock, stopAudio: true))
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .pause(.lock), stopAudio: true))
            }
        }

        finishGate.release()
        let rotateOutcome = await rotateTask.value
        let pauseOutcome = await pauseTask.value

        guard case .vetoed = rotateOutcome else {
            Issue.record("expected rotate to be vetoed by queued pause")
            return
        }
        guard case .committed = pauseOutcome else {
            Issue.record("expected queued pause to commit")
            return
        }
        #expect(newStartCount.count == 0)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isPaused)
        #expect(manager.lastVetoReasonForTesting == .queuedTerminalIntent)
        expectNoPendingRotate(manager)
        await recovery.waitForRecoverAll(1)
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
    }

    @Test func rotateSegmentSupersededByQueuedStopSettlesIdle() async throws {
        let root = try makeTempDirectory("capture-rotation-stop-supersede")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "444444.incomplete")
        let finishGate = OneShotContinuationGate()
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)],
            finishGate: finishGate
        )
        let finalizer = FakeFinalizer()
        let recovery = CountingRecovery()
        let firstNow = fixedDate(second: 6)
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery }),
            finalizer: finalizer,
            now: { firstNow },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        await current.finishCaptureCount.waitUntilCount(1)

        let stopTask = Task { @MainActor in
            await manager.enqueueTransition(.stop(reason: .user))
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting.contains(IntentSnapshot(kind: .stop(.user), stopAudio: false))
            }
        }

        finishGate.release()
        let rotateOutcome = await rotateTask.value
        let stopOutcome = await stopTask.value

        guard case .vetoed = rotateOutcome else {
            Issue.record("expected rotate to be vetoed by queued stop")
            return
        }
        guard case .committed = stopOutcome else {
            Issue.record("expected queued stop to commit")
            return
        }
        #expect(manager.state.isIdle)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(!manager.hasSegmentTimerForTesting)
        expectNoPendingRotate(manager)
        #expect(finalizer.enqueuedDirectories.all.filter { $0 == oldDir }.count <= 1)
        #expect(manager.lastVetoReasonForTesting == .queuedTerminalIntent)
        await recovery.waitForRecoverAll(1)
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
    }

    @Test func debugRotateCoalescesBehindInFlightRotateAndUsesUpdatedDuration() async throws {
        let root = try makeTempDirectory("capture-debug-rotate-coalesce")
        defer {
            SegmentWriter.segmentDuration = 300
            try? FileManager.default.removeItem(at: root)
        }

        SegmentWriter.segmentDuration = 300
        let oldDir = try makeSegmentDir(root: root, name: "444445.incomplete")
        let finishGate = OneShotContinuationGate()
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)],
            finishGate: finishGate
        )
        let finalizer = FakeFinalizer()
        let factoryCalls = LockedCounter()
        let firstNow = fixedDate(second: 7)
        let now = LockedValue<Date>()
        now.set(firstNow)
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                now.set(firstNow.addingTimeInterval(Double(factoryCalls.count)))
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizer,
            now: { now.current ?? firstNow },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let inFlightRotate = Task { @MainActor in
            await rotate(manager)
        }
        await current.finishCaptureCount.waitUntilCount(1)

        let queuedBoundary = Task { @MainActor in
            await manager.enqueueTransition(.rotate(reason: .boundary))
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting == [IntentSnapshot(kind: .rotate(.boundary), stopAudio: false)]
            }
        }

        let debugToggle = Task { @MainActor in
            await manager.setDebugSegments(true)
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                manager.queuedIntentSnapshotForTesting == [IntentSnapshot(kind: .rotate(.debugToggle), stopAudio: false)]
            }
        }

        finishGate.release()
        let inFlightOutcome = await inFlightRotate.value
        let queuedOutcome = await queuedBoundary.value
        await debugToggle.value

        guard case .committed = inFlightOutcome else {
            Issue.record("expected in-flight rotate to commit")
            return
        }
        guard case .committed = queuedOutcome else {
            Issue.record("expected coalesced debug rotate to commit")
            return
        }
        #expect(factoryCalls.count == 2)
        #expect(SegmentWriter.segmentDuration == 60)
        #expect(manager.segmentTimeRemaining <= 60)
        #expect(manager.currentSegmentForTesting != nil)
        #expect(finalizer.enqueuedDirectories.all.count >= 2)
    }

    @Test func heartbeatTickSchedulesRecovery() async throws {
        let root = try makeTempDirectory("capture-heartbeat")
        defer { try? FileManager.default.removeItem(at: root) }

        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )

        manager.handleHeartbeatTick()

        await recovery.waitForRecoverAll(1)
    }

    @Test func startRecordingSchedulesRecovery() async throws {
        let root = try makeTempDirectory("capture-start-recovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )

        try await start(manager)

        await recovery.waitForRecoverAll(1)
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test func lifecycleResumeSchedulesRecovery() async throws {
        let root = try makeTempDirectory("capture-resume-recovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )

        manager.seedRecordingForTesting(currentSegment: FakeCaptureSegment(outputDirectory: root))
        try await manager.lifecyclePrepareResume(trigger: "test")
        manager.lifecycleCommitResume(trigger: "test")

        await recovery.waitForRecoverAll(1)
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test func startFailureClearsCurrentSegmentAndMarksNewDirectoryFailed() async throws {
        let root = try makeTempDirectory("capture-start-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "222222.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let nextStartCount = LockedCounter()
        let finalizer = FakeFinalizer()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                let segment = FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    startBehavior: .throwPartway
                )
                nextStartCount.increment()
                return segment
            },
            recoveryCoordinator: IncompleteSegmentRecoveryCoordinator(recoveryFactory: { CountingRecovery() }),
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let outcome = await rotate(manager)

        guard case .threw(let failure) = outcome else {
            Issue.record("expected failed rotate to throw")
            return
        }
        #expect(failure.message == FakeCaptureError.startFailed.localizedDescription)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(nextStartCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        let failedDirs = try findDirs(root: root, suffix: ".failed")
        #expect(!failedDirs.isEmpty)
    }

    @Test func threeRotationCyclesRecoverAfterMiddleTimeout() async throws {
        let root = try makeTempDirectory("capture-three-cycles")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDir = try makeSegmentDir(root: root, name: "333331.incomplete")
        let first = FakeCaptureSegment(outputDirectory: firstDir, finishBehaviors: [.normal(firstDir)])
        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let scheduler = FakeRecoveryScheduler()
        let finalizer = FakeFinalizer()
        let startGate = OneShotContinuationGate()
        let factoryCalls = LockedCounter()
        let now = LockedValue<Date>()
        let firstNow = fixedDate(second: 0)
        now.set(firstNow)

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                if factoryCalls.count == 2 {
                    return FakeCaptureSegment(
                        outputDirectory: outputDirectory,
                        startGate: startGate
                    )
                }
                return FakeCaptureSegment(outputDirectory: outputDirectory, finishBehaviors: [.normal(outputDirectory)])
            },
            recoveryCoordinator: coordinator,
            finalizer: finalizer,
            rotationTimeoutSeconds: 1.0,
            now: { now.current ?? firstNow },
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        manager.seedRecordingForTesting(currentSegment: first)

        let firstOutcome = await rotate(manager)
        guard case .committed = firstOutcome else {
            Issue.record("expected first rotate to commit")
            return
        }
        #expect(finalizer.enqueuedDirectories.all == [firstDir])
        #expect(manager.state.isRecording)

        now.set(fixedDate(second: 1))
        let timeoutOutcome = await rotate(manager)
        guard case .threw(let timeoutFailure) = timeoutOutcome else {
            Issue.record("expected middle rotate timeout to throw")
            return
        }
        #expect(timeoutFailure.message == "Segment rotation timed out")
        #expect(manager.state.isError)
        #expect(manager.isRecoveryScheduled)
        expectNoPendingRotate(manager)

        let followupOutcome = await rotate(manager)
        guard case .dropped = followupOutcome else {
            Issue.record("expected follow-up rotate to drop while in error")
            return
        }

        await scheduler.fireNext()
        #expect(manager.state.isRecording)
        #expect(!manager.isRecoveryScheduled)
        startGate.release()
        await recovery.waitForRecoverAll(1)
    }

    @Test func rotateSegmentTimeoutStopsAlreadyRunningPersistentStream() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout-audio")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "555551.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let startGate = OneShotContinuationGate()
        let stream = FakeCaptureStream()
        let streamFactory = FakeCaptureStreamFactory([stream])
        let scheduler = FakeRecoveryScheduler()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    startsPersistentSystemAudio: .beforeGate,
                    startGate: startGate
                )
            },
            rotationTimeoutSeconds: 1.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: streamFactory.factory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            }
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { manager.isSystemAudioRunningForTesting }
        }
        #expect(manager.isSystemAudioRunningForTesting)
        #expect(stream.stopCount.count == 0)

        let timeoutOutcome = await rotateTask.value
        guard case .threw(let timeoutFailure) = timeoutOutcome else {
            Issue.record("expected timed-out rotate to throw")
            return
        }
        #expect(timeoutFailure.message == "Segment rotation timed out")
        #expect(stream.stopCount.count == 1)
        #expect(!manager.isSystemAudioRunningForTesting)
        startGate.release()
    }

    @Test func rotateSegmentSlowFinishWithPromptStartCommits() async throws {
        let root = try makeTempDirectory("capture-rotation-slow-finish")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "555552.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.delayed(oldDir, duration: .milliseconds(500))]
        )
        let finalizer = FakeFinalizer()
        let scheduler = FakeRecoveryScheduler()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizer,
            rotationTimeoutSeconds: 0.2,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            }
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let outcome = await rotate(manager)
        guard case .committed = outcome else {
            Issue.record("expected slow finish with prompt start to commit")
            return
        }
        #expect(manager.state.isRecording)
        #expect(!manager.isRecoveryScheduled)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(try findDirs(root: root, suffix: ".failed").isEmpty)
    }

    @Test func rotateSegmentTimeoutReaperStopsLatePersistentStart() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout-reaper")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "555553.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let startGate = OneShotContinuationGate()
        let firstStream = FakeCaptureStream()
        let secondStream = FakeCaptureStream()
        let streamFactory = FakeCaptureStreamFactory([firstStream, secondStream])
        let scheduler = FakeRecoveryScheduler()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    startsPersistentSystemAudio: .bothSides,
                    startGate: startGate
                )
            },
            rotationTimeoutSeconds: 1.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: streamFactory.factory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            }
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let rotateTask = Task { @MainActor in
            await rotate(manager)
        }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { manager.isSystemAudioRunningForTesting }
        }
        #expect(streamFactory.createdStreams.count == 1)

        let timeoutOutcome = await rotateTask.value
        guard case .threw = timeoutOutcome else {
            Issue.record("expected timed-out rotate to throw")
            return
        }
        #expect(manager.state.isError)
        #expect(!manager.isSystemAudioRunningForTesting)
        #expect(firstStream.stopCount.count == 1)

        startGate.release()
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run {
                secondStream.startCount.count == 1 && secondStream.stopCount.count == 1
                    && !manager.isSystemAudioRunningForTesting
            }
        }
        #expect(streamFactory.createdStreams.count == 2)
        #expect(secondStream.startCount.count == 1)
        #expect(manager.state.isError)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(!manager.isSystemAudioRunningForTesting)
    }

    @Test func rotateSegmentThrowingStartStopsRunningPersistentStream() async throws {
        let root = try makeTempDirectory("capture-rotation-throw-audio")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "555554.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let stream = FakeCaptureStream()
        let streamFactory = FakeCaptureStreamFactory([stream])
        let finalizer = FakeFinalizer()
        let scheduler = FakeRecoveryScheduler()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                FakeCaptureSegment(
                    outputDirectory: outputDirectory,
                    startBehavior: .throwPartway,
                    startsPersistentSystemAudio: .beforeGate
                )
            },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: streamFactory.factory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            }
        )
        manager.seedRecordingForTesting(currentSegment: current)

        let outcome = await rotate(manager)
        guard case .threw(let failure) = outcome else {
            Issue.record("expected failed rotate to throw")
            return
        }
        #expect(failure.message == FakeCaptureError.startFailed.localizedDescription)
        #expect(stream.stopCount.count == 1)
        #expect(!manager.isSystemAudioRunningForTesting)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(try findDirs(root: root, suffix: ".failed").count == 1)
    }

    @Test func rotateSegmentThrowBeforeAssignmentDoesNotDoubleEnqueueOldSegment() async throws {
        let root = try makeTempDirectory("capture-rotation-throw-before-assign")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "666661.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let finalizer = FakeFinalizer()
        let factoryCalls = LockedCounter()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _ in
                factoryCalls.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizer
        )
        // No microphone fallback: missing displays must fail before assignment.
        manager.seedRecordingForTesting(currentSegment: current, sources: .screen)

        let outcome = await rotate(manager)
        guard case .threw(let failure) = outcome else {
            Issue.record("expected rotate to throw before assigning a new segment")
            return
        }
        #expect(failure.message == CaptureManager.CaptureError.notInitialized.localizedDescription)
        #expect(factoryCalls.count == 0)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(finalizer.enqueuedDirectories.all == [oldDir])

        let stopOutcome = await manager.enqueueTransition(.stop(reason: .user))
        guard case .committed = stopOutcome else {
            Issue.record("expected stop from error to commit")
            return
        }
        #expect(finalizer.enqueuedDirectories.all == [oldDir])
        #expect(current.finishCaptureCount.count == 1)
    }

    private func makeSegmentDir(root: URL, name: String) throws -> URL {
        let dir = root.appendingPathComponent("2026-05-26", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func findDirs(root: URL, suffix: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return url.lastPathComponent.hasSuffix(suffix) ? url : nil
        }
    }

    private func fixedDate(second: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 5
        components.day = 26
        components.hour = 12
        components.minute = 0
        components.second = second
        return calendar.date(from: components)!
    }

    private func start(_ manager: CaptureManager) async throws {
        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )
        let outcome = await executor.enqueue(.start(reason: .user, sources: .all, disabledMicUIDs: [], enabledMicUIDs: []))
        guard case .committed = outcome else {
            Issue.record("expected start to commit")
            return
        }
    }

    private func rotate(_ manager: CaptureManager) async -> TransitionOutcome {
        await manager.enqueueTransition(.rotate(reason: .boundary))
    }

    private func expectNoPendingRotate(_ manager: CaptureManager) {
        #expect(
            !manager.queuedIntentSnapshotForTesting.contains { snapshot in
                if case .rotate = snapshot.kind { return true }
                return false
            }
        )
        if case .rotate = manager.inFlightIntentForTesting?.kind {
            Issue.record("expected in-flight intent to not be rotate")
        }
    }

    @Test func rotateSegmentTimeoutEmptySitesAbandonsStreamsAndDropsFrames() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout-empty-sites")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "111111.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)]
        )
        let finalizer = FakeFinalizer()
        let startGate = OneShotContinuationGate()
        let streamsLock = OSAllocatedUnfairLock<[FakeCaptureStream]>(initialState: [])
        let capturersLock = OSAllocatedUnfairLock<[ScreenshotCapturer]>(initialState: [])

        final class ManagerBox: @unchecked Sendable {
            weak var manager: CaptureManager?
        }
        let box = ManagerBox()

        let capturerFactory: SegmentWriter.ScreenshotCapturerFactory = { info, videoURL, frameRate, duration, contentFilter, verbose, siteRuleLock, appendsClosedLock in
            let filter = contentFilter ?? SCContentFilter()
            let stream: FakeCaptureStream = streamsLock.withLock { streams in
                if streams.isEmpty {
                    let s = FakeCaptureStream(startGates: [startGate])
                    streams.append(s)
                    return s
                } else {
                    let s = FakeCaptureStream()
                    streams.append(s)
                    return s
                }
            }

            let capturer = try ScreenshotCapturer(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: frameRate,
                duration: duration,
                contentFilter: filter,
                verbose: verbose,
                streamFactory: { _, _, _ in stream },
                siteRuleLock: siteRuleLock,
                appendsClosedLock: appendsClosedLock
            )
            capturersLock.withLock { $0.append(capturer) }
            return capturer
        }

        let segmentFactory: CaptureManager.SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose,
                screenshotCapturerFactory: capturerFactory,
                siteRuleLock: box.manager?.siteRuleLock ?? OSAllocatedUnfairLock(initialState: false)
            )
        }

        let scheduler = FakeRecoveryScheduler()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: segmentFactory,
            finalizer: finalizer,
            rotationTimeoutSeconds: 1.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        box.manager = manager
        manager.displayInfosForTesting = [
            DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16)),
            DisplayInfo(displayID: 2, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        ]
        manager.seedRecordingForTesting(currentSegment: current, sources: CaptureSources.screen)

        let rotateTask = Task { await self.rotate(manager) }

        // Wait until display 1's startCount is 1
        while streamsLock.withLock({ $0.first?.startCount.count ?? 0 }) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let outcome = await rotateTask.value
        guard case .threw(let failure) = outcome else {
            Issue.record("expected rotate to time out")
            return
        }
        #expect(failure.message == "Segment rotation timed out")

        // Release the gate
        startGate.release()

        // Wait until both capturers exist and have left start()
        var settled = false
        for _ in 0..<100 {
            let capturers = capturersLock.withLock { $0 }
            if capturers.count >= 2 && !capturers[0]._hasStreamForTesting && !capturers[1]._hasStreamForTesting {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled, "Timed out waiting for both capturers to leave start")

        let capturers = capturersLock.withLock { $0 }
        let streams = streamsLock.withLock { $0 }
        #expect(!capturers[0]._hasStreamForTesting)
        #expect(!capturers[1]._hasStreamForTesting)
        #expect(streams[0].stopCount.count >= 1)

        let buffer = makeTestPixelBuffer(width: 16, height: 16)
        capturers[0].handleFrameFromOutput(
            generation: capturers[0]._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        capturers[1].handleFrameFromOutput(
            generation: capturers[1]._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )

        #expect(capturers[0]._submittedVideoFrameCountForTesting == 0)
        #expect(capturers[1]._submittedVideoFrameCountForTesting == 0)
    }

    @Test func rotateSegmentTimeoutCoveredSitesAbandonsStreamsAndDropsFrames() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout-covered-sites")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "111111.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)]
        )
        let finalizer = FakeFinalizer()
        let startGate = OneShotContinuationGate()
        let streamsLock = OSAllocatedUnfairLock<[FakeCaptureStream]>(initialState: [])
        let capturersLock = OSAllocatedUnfairLock<[ScreenshotCapturer]>(initialState: [])

        final class ManagerBox: @unchecked Sendable {
            weak var manager: CaptureManager?
        }
        let box = ManagerBox()

        let capturerFactory: SegmentWriter.ScreenshotCapturerFactory = { info, videoURL, frameRate, duration, contentFilter, verbose, siteRuleLock, appendsClosedLock in
            let filter = contentFilter ?? SCContentFilter()
            let stream: FakeCaptureStream = streamsLock.withLock { streams in
                if streams.isEmpty {
                    let s = FakeCaptureStream(startGates: [startGate])
                    streams.append(s)
                    return s
                } else {
                    let s = FakeCaptureStream()
                    streams.append(s)
                    return s
                }
            }

            let capturer = try ScreenshotCapturer(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: frameRate,
                duration: duration,
                contentFilter: filter,
                verbose: verbose,
                streamFactory: { _, _, _ in stream },
                siteRuleLock: siteRuleLock,
                appendsClosedLock: appendsClosedLock
            )
            capturersLock.withLock { $0.append(capturer) }
            return capturer
        }

        let segmentFactory: CaptureManager.SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose,
                screenshotCapturerFactory: capturerFactory,
                siteRuleLock: box.manager?.siteRuleLock ?? OSAllocatedUnfairLock(initialState: false)
            )
        }

        let scheduler = FakeRecoveryScheduler()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: segmentFactory,
            finalizer: finalizer,
            rotationTimeoutSeconds: 1.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        box.manager = manager
        manager.displayInfosForTesting = [
            DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16)),
            DisplayInfo(displayID: 2, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        ]
        manager.seedRecordingForTesting(currentSegment: current, sources: CaptureSources.screen)

        let rotateTask = Task { await self.rotate(manager) }

        while streamsLock.withLock({ $0.first?.startCount.count ?? 0 }) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        manager.updateSiteRule(["bank.com"])
        let p1 = SitePollSnapshot(start: 0.1, end: 0.2, windows: [SitePollWindow(windowID: 100, title: "bank.com")])
        let p2 = SitePollSnapshot(start: 0.3, end: 0.4, windows: [SitePollWindow(windowID: 100, title: "bank.com")])
        manager.siteFrameGate.addPoll(p1)
        manager.siteFrameGate.addPoll(p2)

        let outcome = await rotateTask.value
        guard case .threw(let failure) = outcome else {
            Issue.record("expected rotate to time out")
            return
        }
        #expect(failure.message == "Segment rotation timed out")

        startGate.release()

        var settled = false
        for _ in 0..<100 {
            let capturers = capturersLock.withLock { $0 }
            if capturers.count >= 2 && !capturers[0]._hasStreamForTesting && !capturers[1]._hasStreamForTesting {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled, "Timed out waiting for both capturers to leave start")

        let capturers = capturersLock.withLock { $0 }
        let streams = streamsLock.withLock { $0 }
        #expect(!capturers[0]._hasStreamForTesting)
        #expect(!capturers[1]._hasStreamForTesting)
        #expect(streams[0].stopCount.count >= 1)

        let buffer = makeTestPixelBuffer(width: 16, height: 16)
        capturers[0].handleFrameFromOutput(
            generation: capturers[0]._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        capturers[1].handleFrameFromOutput(
            generation: capturers[1]._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )

        #expect(capturers[0]._submittedVideoFrameCountForTesting == 0)
        #expect(capturers[1]._submittedVideoFrameCountForTesting == 0)
    }

    @Test func rotateSegmentTimeoutSharedGateRecoveryAdmitsFollowupFramesWithoutStall() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout-shared-gate")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "111111.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.normal(oldDir)]
        )
        let finalizer = FakeFinalizer()
        let scheduler = FakeRecoveryScheduler()
        let startGate = OneShotContinuationGate()
        let streamsLock = OSAllocatedUnfairLock<[FakeCaptureStream]>(initialState: [])
        let capturersLock = OSAllocatedUnfairLock<[ScreenshotCapturer]>(initialState: [])

        final class ManagerBox: @unchecked Sendable {
            weak var manager: CaptureManager?
        }
        let box = ManagerBox()

        let capturerFactory: SegmentWriter.ScreenshotCapturerFactory = { info, videoURL, frameRate, duration, contentFilter, verbose, siteRuleLock, appendsClosedLock in
            let filter = contentFilter ?? SCContentFilter()
            let stream: FakeCaptureStream = streamsLock.withLock { streams in
                if streams.isEmpty {
                    let s = FakeCaptureStream(startGates: [startGate])
                    streams.append(s)
                    return s
                } else {
                    let s = FakeCaptureStream()
                    streams.append(s)
                    return s
                }
            }

            let capturer = try ScreenshotCapturer(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: frameRate,
                duration: duration,
                contentFilter: filter,
                verbose: verbose,
                streamFactory: { _, _, _ in stream },
                siteRuleLock: siteRuleLock,
                appendsClosedLock: appendsClosedLock
            )
            capturersLock.withLock { $0.append(capturer) }
            return capturer
        }

        let segmentFactory: CaptureManager.SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose,
                screenshotCapturerFactory: capturerFactory,
                siteRuleLock: box.manager?.siteRuleLock ?? OSAllocatedUnfairLock(initialState: false)
            )
        }

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: segmentFactory,
            finalizer: finalizer,
            rotationTimeoutSeconds: 1.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        box.manager = manager
        manager.displayInfosForTesting = [
            DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16)),
            DisplayInfo(displayID: 2, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        ]
        manager.seedRecordingForTesting(currentSegment: current, sources: CaptureSources.screen)

        let rotateTask = Task { await self.rotate(manager) }

        while streamsLock.withLock({ $0.first?.startCount.count ?? 0 }) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        manager.updateSiteRule(["bank.com"])

        let outcome = await rotateTask.value
        guard case .threw(let failure) = outcome else {
            Issue.record("expected rotate to time out")
            return
        }
        #expect(failure.message == "Segment rotation timed out")

        startGate.release()

        var settled = false
        for _ in 0..<100 {
            let capturers = capturersLock.withLock { $0 }
            if capturers.count >= 2 && !capturers[0]._hasStreamForTesting && !capturers[1]._hasStreamForTesting {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled, "Timed out waiting for both capturers to leave start")

        #expect(manager.siteFrameGate.heldCount == 0)
        #expect(manager.siteFrameGate.stallCount == 0)
        #expect(manager.currentSegmentForTesting == nil)

        await scheduler.fireNext()
        #expect(manager.state.isRecording)

        let totalCapturers = capturersLock.withLock { $0.count }
        #expect(totalCapturers >= 4)
        let followUpCapturer = capturersLock.withLock { $0[2] }
        #expect(followUpCapturer.isSiteRuleActive)

        let buffer = makeTestPixelBuffer(width: 16, height: 16)
        let gen = followUpCapturer._streamGenerationForTesting
        let originTicks = mach_absolute_time()
        for i in 0..<SiteFrameGate.capacityPerDisplay {
            followUpCapturer.handleFrameFromOutput(
                generation: gen,
                pixelBuffer: buffer,
                isIdle: false,
                epoch: 0,
                displayTimeTicks: originTicks + UInt64(i * 1000)
            )
        }

        #expect(manager.siteFrameGate.stallCount == 0)
        #expect(manager.siteFrameGate.heldCount == SiteFrameGate.capacityPerDisplay)
        #expect(followUpCapturer._submittedVideoFrameCountForTesting == 0)

        #expect(manager.siteFrameGate.stallCount == 0)
        #expect(manager.siteFrameGate.heldCount == SiteFrameGate.capacityPerDisplay)
        #expect(followUpCapturer._submittedVideoFrameCountForTesting == 0)
    }

    @Test func rotateSegmentCommittedEmptySitesPreservesOldAndNewFrameCounts() async throws {
        let root = try makeTempDirectory("capture-rotation-committed-empty-sites")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "100000.incomplete")
        let finalizer = FakeFinalizer()
        let streamsLock = OSAllocatedUnfairLock<[FakeCaptureStream]>(initialState: [])
        let capturersLock = OSAllocatedUnfairLock<[ScreenshotCapturer]>(initialState: [])

        final class ManagerBox: @unchecked Sendable {
            weak var manager: CaptureManager?
        }
        let box = ManagerBox()

        let capturerFactory: SegmentWriter.ScreenshotCapturerFactory = { info, videoURL, frameRate, duration, contentFilter, verbose, siteRuleLock, appendsClosedLock in
            let filter = contentFilter ?? SCContentFilter()
            let stream = FakeCaptureStream()
            streamsLock.withLock { $0.append(stream) }

            let capturer = try ScreenshotCapturer(
                displayID: info.displayID,
                videoURL: videoURL,
                width: info.width,
                height: info.height,
                frameRate: frameRate,
                duration: duration,
                contentFilter: filter,
                verbose: verbose,
                streamFactory: { _, _, _ in stream },
                siteRuleLock: siteRuleLock,
                appendsClosedLock: appendsClosedLock
            )
            capturersLock.withLock { $0.append(capturer) }
            return capturer
        }

        let segmentFactory: CaptureManager.SegmentFactory = { outputDirectory, timePrefix, silenceMusic, verbose in
            SegmentWriter(
                outputDirectory: outputDirectory,
                timePrefix: timePrefix,
                silenceMusic: silenceMusic,
                verbose: verbose,
                screenshotCapturerFactory: capturerFactory,
                siteRuleLock: box.manager?.siteRuleLock ?? OSAllocatedUnfairLock(initialState: false)
            )
        }

        let scheduler = FakeRecoveryScheduler()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: segmentFactory,
            finalizer: finalizer,
            rotationTimeoutSeconds: 5.0,
            allowsEmptyDisplayConfigurationForTesting: true,
            streamFactory: defaultCaptureStreamFactory,
            recoveryScheduler: { delay, fire in
                scheduler.schedule(delay: delay, fire: fire)
            },
            isScreenLocked: { false }
        )
        box.manager = manager

        let displays = [
            DisplayInfo(displayID: 1, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16)),
            DisplayInfo(displayID: 2, width: 16, height: 16, bounds: CGRect(x: 0, y: 0, width: 16, height: 16))
        ]
        manager.displayInfosForTesting = displays

        let oldWriter = SegmentWriter(
            outputDirectory: oldDir,
            timePrefix: "100000",
            screenshotCapturerFactory: capturerFactory,
            siteRuleLock: manager.siteRuleLock
        )
        try await oldWriter.start(
            sources: CaptureSources.screen,
            displayInfos: displays,
            filters: [:]
        )
        manager.seedRecordingForTesting(currentSegment: oldWriter, sources: CaptureSources.screen)

        let initialCapturers = capturersLock.withLock { $0 }
        #expect(initialCapturers.count == 2)
        let oldCapturer1 = initialCapturers[0]
        let oldCapturer2 = initialCapturers[1]

        let buffer = makeTestPixelBuffer(width: 16, height: 16)

        // Deliver one idle and one non-idle frame to each old capturer before rotate
        oldCapturer1.handleFrameFromOutput(
            generation: oldCapturer1._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: true,
            epoch: 0
        )
        oldCapturer2.handleFrameFromOutput(
            generation: oldCapturer2._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: true,
            epoch: 0
        )
        #expect(oldCapturer1._submittedVideoFrameCountForTesting == 0)
        #expect(oldCapturer2._submittedVideoFrameCountForTesting == 0)

        oldCapturer1.handleFrameFromOutput(
            generation: oldCapturer1._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        oldCapturer2.handleFrameFromOutput(
            generation: oldCapturer2._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        #expect(oldCapturer1._submittedVideoFrameCountForTesting == 1)
        #expect(oldCapturer2._submittedVideoFrameCountForTesting == 1)

        // Rotate with ungated real capturers and an empty site list
        let outcome = await self.rotate(manager)
        guard case .committed = outcome else {
            Issue.record("expected rotate to commit")
            return
        }

        // Old counts stay 1
        #expect(oldCapturer1._submittedVideoFrameCountForTesting == 1)
        #expect(oldCapturer2._submittedVideoFrameCountForTesting == 1)

        let allCapturers = capturersLock.withLock { $0 }
        #expect(allCapturers.count == 4)
        let newCapturer1 = allCapturers[2]
        let newCapturer2 = allCapturers[3]

        // One non-idle on each new capturer makes that count 1; an idle after it does not increment
        newCapturer1.handleFrameFromOutput(
            generation: newCapturer1._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        newCapturer2.handleFrameFromOutput(
            generation: newCapturer2._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: false,
            epoch: 0
        )
        #expect(newCapturer1._submittedVideoFrameCountForTesting == 1)
        #expect(newCapturer2._submittedVideoFrameCountForTesting == 1)

        newCapturer1.handleFrameFromOutput(
            generation: newCapturer1._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: true,
            epoch: 0
        )
        newCapturer2.handleFrameFromOutput(
            generation: newCapturer2._streamGenerationForTesting,
            pixelBuffer: buffer,
            isIdle: true,
            epoch: 0
        )
        #expect(newCapturer1._submittedVideoFrameCountForTesting == 1)
        #expect(newCapturer2._submittedVideoFrameCountForTesting == 1)
    }
}
