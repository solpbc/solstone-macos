// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("CaptureManager rotation watchdog")
@MainActor
struct CaptureManagerRotationWatchdogTests {
    @Test func rotateSegmentTimeoutReleasesRotationAndAdmitsFollowup() async throws {
        let root = try makeTempDirectory("capture-rotation-timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "111111.incomplete")
        let current = FakeCaptureSegment(
            outputDirectory: oldDir,
            finishBehaviors: [.hang, .normal(oldDir)]
        )
        let recovery = CountingRecovery()
        let coordinator = IncompleteSegmentRecoveryCoordinator(recoveryFactory: { recovery })
        let newStartCount = LockedCounter()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, timePrefix, _, _, _ in
                let segment = FakeCaptureSegment(outputDirectory: outputDirectory)
                segment.startCount.increment()
                newStartCount.increment()
                return segment
            },
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        await manager.rotateSegmentForTesting()

        #expect(manager.isRotatingSegmentForTesting == false)
        #expect(current.finishCaptureCount.count == 1)
        try await waitUntil(timeout: .seconds(3)) {
            recovery.count.count == 1
        }

        await manager.rotateSegmentForTesting()

        #expect(manager.isRotatingSegmentForTesting == false)
        #expect(current.finishCaptureCount.count == 2)
        #expect(newStartCount.count >= 1)
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

        try await waitUntil(timeout: .seconds(3)) {
            recovery.count.count == 1
        }
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

        try await manager.startRecording()

        try await waitUntil(timeout: .seconds(3)) {
            recovery.count.count == 1
        }
        await manager.stopRecording()
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

        try await manager.lifecycleResumeCapture(trigger: "test")

        try await waitUntil(timeout: .seconds(3)) {
            recovery.count.count == 1
        }
        await manager.stopRecording()
    }

    @Test func startFailureClearsCurrentSegmentAndMarksNewDirectoryFailed() async throws {
        let root = try makeTempDirectory("capture-start-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let oldDir = try makeSegmentDir(root: root, name: "222222.incomplete")
        let current = FakeCaptureSegment(outputDirectory: oldDir, finishBehaviors: [.normal(oldDir)])
        let nextStartCount = LockedCounter()

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
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: current)

        await manager.rotateSegmentForTesting()

        #expect(manager.currentSegmentForTesting == nil)
        #expect(nextStartCount.count == 1)
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
        let factoryCalls = LockedCounter()
        let cycle2Segment = LockedValue<FakeCaptureSegment>()

        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            segmentFactory: { outputDirectory, _, _, _, _ in
                factoryCalls.increment()
                if factoryCalls.count == 1 {
                    let segment = FakeCaptureSegment(outputDirectory: outputDirectory, finishBehaviors: [.hang, .normal(outputDirectory)])
                    cycle2Segment.set(segment)
                    return segment
                }
                return FakeCaptureSegment(outputDirectory: outputDirectory, finishBehaviors: [.normal(outputDirectory)])
            },
            recoveryCoordinator: coordinator,
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: first)

        await manager.rotateSegmentForTesting()
        #expect(manager.isRotatingSegmentForTesting == false)
        await RemixQueue.shared.waitForCompletion()
        #expect(try findDirs(root: root, prefix: "333331_").count == 1)
        let cycle2 = try #require(cycle2Segment.current)
        let currentAfterCycle1 = try #require(manager.currentSegmentForTesting)
        #expect(ObjectIdentifier(currentAfterCycle1) == ObjectIdentifier(cycle2))
        let cycle2TimePrefix = String(cycle2.outputDirectory.lastPathComponent.prefix(6))
        try await waitUntil(timeout: .seconds(2), poll: .milliseconds(20)) {
            Self.currentTimePrefix() != cycle2TimePrefix
        }

        await manager.rotateSegmentForTesting()
        #expect(manager.isRotatingSegmentForTesting == false)
        let currentAfterCycle2 = try #require(manager.currentSegmentForTesting)
        #expect(ObjectIdentifier(currentAfterCycle2) == ObjectIdentifier(cycle2))
        #expect(cycle2.finishCaptureCount.count == 1)
        try await waitUntil(timeout: .seconds(3)) {
            recovery.count.count == 1
        }

        await manager.rotateSegmentForTesting()
        #expect(manager.isRotatingSegmentForTesting == false)
        #expect(cycle2.finishCaptureCount.count == 2)
        await RemixQueue.shared.waitForCompletion()
        #expect(try findDirs(root: root, prefix: "\(cycle2TimePrefix)_").count == 1)
        #expect(factoryCalls.count == 2)
    }

    @Test func userStopPausePathUsesBoundedSegmentFinish() async throws {
        let root = try makeTempDirectory("capture-user-pause")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try await makeStartedBoundedPauseWriter(root: root)
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: writer)

        let clock = ContinuousClock()
        let start = clock.now
        await manager.stopRecording()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(20))
    }

    @Test func lifecyclePausePathUsesBoundedSegmentFinish() async throws {
        let root = try makeTempDirectory("capture-lifecycle-pause")
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = try await makeStartedBoundedPauseWriter(root: root)
        let manager = CaptureManager(
            storageManager: StorageManager(baseDirectory: root),
            allowsEmptyDisplayConfigurationForTesting: true
        )
        manager.seedRecordingForTesting(currentSegment: writer)

        let clock = ContinuousClock()
        let start = clock.now
        _ = await manager.lifecyclePauseCapture(trigger: "test", stopAudio: false)
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(20))
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

    private func makeStartedBoundedPauseWriter(root: URL) async throws -> SegmentWriter {
        let dir = try makeSegmentDir(root: root, name: "444444.incomplete")
        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "444444",
            screenshotCapturerFactory: { _, _, _, _, _, _ in FakeScreenshotCapturer() },
            audioManagerFactory: { _, _, _, _ in FakeAudioManager(behavior: .hangFinishAndRemix) }
        )
        let display = DisplayInfo(
            displayID: 7,
            width: 100,
            height: 100,
            bounds: .zero
        )
        try await writer.start(displayInfos: [display], filters: [:], audioFilter: nil)
        return writer
    }

    nonisolated private static func currentTimePrefix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }
}
