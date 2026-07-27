// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@MainActor
@Suite
struct CaptureManagerCommitTests {
    @Test func stopRecordingFinishesAndEnqueuesActiveSegment() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111111.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        _ = await manager.enqueueTransition(.stop(reason: .user))

        #expect(segment.finishCaptureCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all == [segment.outputDirectory])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isIdle)
    }

    @Test func stopRecordingDoesNotWaitForFinalizerCompletion() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111112.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        _ = await manager.enqueueTransition(.stop(reason: .user))

        #expect(finalizer.events.all == ["enqueue"])
        #expect(manager.state.isIdle)
    }

    @Test(.timeLimit(.minutes(1))) func pauseRecordingEnqueuesThenFinalizerWaitEnters() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111113.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        _ = await manager.enqueueTransition(.pause(reason: .lock, stopAudio: true))

        #expect(segment.finishCaptureCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all == [segment.outputDirectory])
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.state.isPaused)
        await finalizer.waitEntered.wait()
        #expect(finalizer.events.all == ["enqueue", "wait"])
    }

    @Test func lifecyclePauseCaptureEnqueuesButDoesNotWait() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111114.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        _ = await manager.lifecyclePauseCapture(reason: .lock, stopAudio: true)

        #expect(finalizer.enqueuedDirectories.all.count == 1)
        #expect(finalizer.events.all == ["enqueue"])
        #expect(manager.state.isPaused)
    }

    @Test(.timeLimit(.minutes(1))) func lifecycleProcessSegmentSleepEnqueuesThenFinalizerWaitEnters() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111115.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        let dir = try #require(await manager.lifecyclePauseCapture(reason: .sleep, stopAudio: true))
        #expect(finalizer.enqueuedDirectories.all == [segment.outputDirectory])
        #expect(finalizer.events.all == ["enqueue"])

        manager.lifecycleProcessSegment(dir, useSleepActivity: true)

        await finalizer.waitEntered.wait()
        #expect(finalizer.events.all == ["enqueue", "wait"])
    }

    @Test func stopRecordingWithNoActiveSegmentDoesNotEnqueue() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await manager.enqueueTransition(.stop(reason: .user))

        #expect(finalizer.enqueuedDirectories.all.isEmpty)
        #expect(finalizer.events.all.isEmpty)
        #expect(manager.state.isIdle)
    }

    @Test func startWhileLockedVetoesAfterPreparedSegmentAndStaysIdle() async throws {
        let finalizer = FakeFinalizer()
        let root = try makeTempDirectory("capture-start-locked")
        defer { try? FileManager.default.removeItem(at: root) }

        let preparedSegment = LockedValue<FakeCaptureSegment>()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: outputDirectory)
                preparedSegment.set(segment)
                return segment
            },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { true },
            unlockResumeDelay: {}
        )

        let outcome = await executor.enqueue(.start(reason: .user, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .vetoed = outcome else {
            Issue.record("expected start to be vetoed while locked")
            return
        }
        let segment = try #require(preparedSegment.current)
        #expect(segment.finishCaptureCount.count == 1)
        #expect(manager.state.isIdle)
        #expect(manager.currentSegmentForTesting == nil)
        #expect(manager.isSystemAudioRunningForTesting == false)
        #expect(finalizer.enqueuedDirectories.all.isEmpty)
        #expect(executor.lastVetoReasonForTesting == .screenLocked)
    }

    @Test func startFromErrorCommitsRecordingWithSingleStateChange() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let oldSegment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111117.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: oldSegment)
        manager.lifecycleTransitionToError(
            message: "permission denied",
            error: NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue),
            trigger: "test"
        )

        var states: [String] = []
        manager.onStateChanged = { states.append($0.label) }
        let executor = CaptureExecutor(
            delegate: manager,
            isScreenLocked: { false },
            unlockResumeDelay: {}
        )

        let outcome = await executor.enqueue(.start(reason: .autoStart, disabledMicUIDs: [], enabledMicUIDs: []))

        guard case .committed = outcome else {
            switch outcome {
            case .threw(let failure):
                Issue.record("expected start from error to commit, got failure: \(failure.message)")
            case .vetoed:
                Issue.record("expected start from error to commit, got vetoed")
            case .dropped:
                Issue.record("expected start from error to commit, got dropped")
            case .committed:
                break
            }
            return
        }
        #expect(states == ["recording"])
        #expect(oldSegment.finishCaptureCount.count == 1)
        #expect(finalizer.events.all == ["enqueue"])
        #expect(manager.state.isRecording)
    }

    private func makeManager(finalizer: FakeFinalizer) throws -> (CaptureManager, URL) {
        let root = try makeTempDirectory("capture-manager-commit")
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                FakeCaptureSegment(outputDirectory: outputDirectory)
            },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        return (manager, root)
    }
}
