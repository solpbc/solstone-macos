// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                factoryCalls.increment()
                return FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizer,
            now: { firstNow },
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )

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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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
                secondStream.startCount.count == 1 && !manager.isSystemAudioRunningForTesting
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
            segmentFactory: { outputDirectory, _, _, _, _ in
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

    private func findDirs(root: URL, prefix: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return url.lastPathComponent.hasPrefix(prefix) ? url : nil
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
        let outcome = await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))
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
}
