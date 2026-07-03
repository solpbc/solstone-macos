// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
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

    @Test func stopRecordingWaitsForFinalizerCompletion() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111112.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        _ = await manager.enqueueTransition(.stop(reason: .user))

        #expect(finalizer.events.all == ["enqueue", "wait"])
    }

    @Test func pauseRecordingFinishesAndEnqueuesActiveSegment() async throws {
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
        try await waitUntil(timeout: .seconds(5)) {
            finalizer.events.all == ["enqueue", "wait"]
        }
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

    @Test func lifecycleProcessSegmentSleepWaitsInsideActivity() async throws {
        let finalizer = FakeFinalizer()
        let (manager, root) = try makeManager(finalizer: finalizer)
        defer { try? FileManager.default.removeItem(at: root) }

        let segment = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("111115.incomplete", isDirectory: true))
        manager.seedRecordingForTesting(currentSegment: segment)

        let dir = await manager.lifecyclePauseCapture(reason: .sleep, stopAudio: true)
        #expect(finalizer.events.all == ["enqueue"])

        manager.lifecycleProcessSegment(dir ?? root, useSleepActivity: true)

        try await waitUntil(timeout: .seconds(5)) {
            finalizer.events.all.contains("wait")
        }
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
