// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Capture timer ownership", .serialized)
@MainActor
struct CaptureTimerOwnershipTests {
    @Test(arguments: [true, false])
    func guardedBoundaryCannotAbsorbExplicitBoundary(guardedFirst: Bool) async throws {
        let root = try makeTempDirectory("capture-timer-mixed-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = OneShotContinuationGate()
        defer { gate.release() }
        let finalizer = FakeFinalizer()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in FakeCaptureSegment(outputDirectory: directory) },
            finalizer: finalizer, allowsEmptyDisplayConfigurationForTesting: true
        )
        let original = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("130000.incomplete"),
                                         finishGate: gate)
        manager.seedRecordingForTesting(currentSegment: original)
        let executor = CaptureExecutor(delegate: manager, isScreenLocked: { false }, unlockResumeDelay: {})
        let parked = Task { @MainActor in await executor.enqueue(.rotate(reason: .debugToggle)) }
        await original.finishCaptureCount.waitUntilCount(1)
        let revoked: @MainActor @Sendable () -> Bool = { false }
        let firstAdmission = guardedFirst ? revoked : nil
        let secondAdmission = guardedFirst ? nil : revoked
        let first = Task { @MainActor in await executor.enqueue(.rotate(reason: .boundary), admission: firstAdmission) }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { executor.queuedIntentCountForTesting == 1 }
        }
        let second = Task { @MainActor in await executor.enqueue(.rotate(reason: .boundary), admission: secondAdmission) }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { executor.queuedIntentCountForTesting == 2 }
        }
        gate.release()
        _ = await parked.value
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        if case .dropped = guardedFirst ? firstOutcome : secondOutcome {} else {
            Issue.record("revoked guarded boundary must drop")
        }
        if case .committed = guardedFirst ? secondOutcome : firstOutcome {} else {
            Issue.record("explicit boundary must execute")
        }
        #expect(finalizer.enqueuedDirectories.all.count == 2)
        _ = await executor.enqueue(.stop(reason: .user))
    }

    @Test func queuedBoundaryIsRevokedByInFlightRotation() async throws {
        let root = try makeTempDirectory("capture-timer-queued-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let finalizer = FakeFinalizer()
        let finishGate = OneShotContinuationGate()
        defer { finishGate.release() }
        let clock = LockedValue<Date>()
        clock.set(Date())
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in FakeCaptureSegment(outputDirectory: directory) },
            finalizer: finalizer,
            now: { clock.current! },
            allowsEmptyDisplayConfigurationForTesting: true
        )
        let original = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("120000.incomplete"),
                                         finishGate: finishGate)
        manager.seedRecordingForTesting(currentSegment: original)
        let oldDelivery = manager.scheduledBoundaryDeliveryForTesting()
        let rotation = Task { @MainActor in await manager.enqueueTransition(.rotate(reason: .debugToggle)) }
        await original.finishCaptureCount.waitUntilCount(1)
        let queuedBoundary = Task { @MainActor in await oldDelivery() }
        try await waitUntil(timeout: .seconds(5)) {
            await MainActor.run { manager.queuedIntentSnapshotForTesting.contains(
                IntentSnapshot(kind: .rotate(.boundary), stopAudio: false)) }
        }
        finishGate.release()
        _ = await rotation.value
        await queuedBoundary.value
        #expect(finalizer.enqueuedDirectories.all.count == 1)
        #expect(manager.state.isRecording)
        clock.set(clock.current!.addingTimeInterval(1))
        await manager.scheduledBoundaryDeliveryForTesting()()
        #expect(finalizer.enqueuedDirectories.all.count == 2)
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }

    @Test func queuedOldBoundaryCannotRotateReplacementRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finalizer = FakeFinalizer()
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { directory, _, _, _ in FakeCaptureSegment(outputDirectory: directory) },
            finalizer: finalizer,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        let original = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("110000.incomplete"))
        manager.seedRecordingForTesting(currentSegment: original)
        let oldDelivery = manager.scheduledBoundaryDeliveryForTesting()
        _ = await manager.enqueueTransition(.stop(reason: .user))
        let replacement = FakeCaptureSegment(outputDirectory: root.appendingPathComponent("110100.incomplete"))
        manager.seedRecordingForTesting(currentSegment: replacement)
        let currentDelivery = manager.scheduledBoundaryDeliveryForTesting()
        let finalizationsBefore = finalizer.enqueuedDirectories.all.count

        await oldDelivery()
        #expect(replacement.finishCaptureCount.count == 0)
        #expect(finalizer.enqueuedDirectories.all.count == finalizationsBefore)
        #expect(manager.currentSegmentForTesting === replacement)

        await currentDelivery()
        #expect(replacement.finishCaptureCount.count == 1)
        #expect(finalizer.enqueuedDirectories.all.count == finalizationsBefore + 1)
        #expect(manager.state.isRecording)
        // Delivery captured before rotation is revoked when the replacement timer is armed.
        await currentDelivery()
        #expect(finalizer.enqueuedDirectories.all.count == finalizationsBefore + 1)
        _ = await manager.enqueueTransition(.stop(reason: .user))
    }
}
