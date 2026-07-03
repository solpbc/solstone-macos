// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("RemixQueue timeout")
struct RemixQueueTimeoutTests {
    @Test func duplicateEnqueueWhileProcessingIsIgnored() async throws {
        let root = try makeTempDirectory("remix-queue-dedup")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let audio = dir.appendingPathComponent("120000_audio_system.m4a")
        try Data("audio".utf8).write(to: audio)

        let gate = RemixGate()
        let fakeRemixer = FakeRemixer(.gatedSuccess(gate))
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))
        await fakeRemixer.waitForRemixStart()

        #expect(await queue.inFlightPaths().contains(dir.standardizedFileURL.path))

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))
        gate.release()
        await queue.waitForCompletion()

        let finalized = try segmentDirectories(in: root).filter {
            $0.hasPrefix("120000_") && !$0.hasSuffix(".failed") && !$0.hasSuffix(".incomplete")
        }
        #expect(fakeRemixer.remixCount.count == 1)
        #expect(completionCount.count == 1)
        #expect(finalized.count == 1)
        #expect(await queue.inFlightPaths().isEmpty)
    }

    @Test func timedOutJobIsFailedAndQueueContinues() async throws {
        let root = try makeTempDirectory("remix-queue")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDir = try makeDir(root: root, name: "120000.incomplete")
        let secondDir = try makeDir(root: root, name: "120100.incomplete")
        let firstAudio = firstDir.appendingPathComponent("120000_audio_system.m4a")
        let secondAudio = secondDir.appendingPathComponent("120100_audio_system.m4a")
        try Data("audio".utf8).write(to: firstAudio)
        try Data("audio".utf8).write(to: secondAudio)

        let behaviors = LockedArray<FakeRemixer.Behavior>([.hang, .success])
        let completionCount = LockedCounter()
        let outcomes = LockedArray<SegmentReconciliation>([])
        let queue = RemixQueue(remixTimeoutSeconds: 0.25) { _, _ in
            FakeRemixer(behaviors.removeFirst(default: .success))
        }
        await queue.setOnSegmentComplete { _, reconciliation in
            outcomes.append(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: firstDir, timePrefix: "120000", inputURL: firstAudio))
        await queue.enqueue(makeJob(dir: secondDir, timePrefix: "120100", inputURL: secondAudio))

        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
        #expect(await queue.isProcessingForTesting == false)
        #expect(completionCount.count == 2)
        #expect(outcomes.all.contains { reconciliation in
            if case .failed = reconciliation { return true }
            return false
        })
        #expect(await queue.inFlightPaths().isEmpty)
    }

    @Test func genericRemixFailureIsFailedAndReportsFailedOutcome() async throws {
        let root = try makeTempDirectory("remix-queue-generic-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let audio = dir.appendingPathComponent("120000_audio_system.m4a")
        try Data("audio".utf8).write(to: audio)
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let completionCount = LockedCounter()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in
            FakeRemixer(.throwing(SyntheticRemixError()))
        }
        await queue.setOnSegmentComplete { _, reconciliation in
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))

        await queue.waitForCompletion()

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        #expect(await queue.isProcessingForTesting == false)
        #expect(completionCount.count == 1)
        let outcome = try #require(completedOutcome.current)
        guard case .failed = outcome else {
            Issue.record("Expected failed reconciliation outcome")
            return
        }
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_audio_system.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try segmentDirectories(in: root).filter { $0.hasPrefix("120000_") }.isEmpty)
    }

    @Test func noTracksToWriteJobFinalizesAndUploadsVideoOnly() async throws {
        let root = try makeTempDirectory("remix-queue-no-tracks")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let audio = dir.appendingPathComponent("120000_audio_system.m4a")
        let screen = dir.appendingPathComponent("120000_display_42_screen.mp4")
        try Data("audio".utf8).write(to: audio)
        try Data("video".utf8).write(to: screen)

        let completionCount = LockedCounter()
        let completedURL = LockedValue<URL>()
        let queue = RemixQueue { _, _ in
            FakeRemixer(.throwing(AudioRemixerError.noTracksToWrite))
        }
        await queue.setOnSegmentComplete { url, _ in
            completedURL.set(url)
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))

        await queue.waitForCompletion()

        let finalURL = try #require(completedURL.current)
        #expect(finalURL.lastPathComponent.hasPrefix("120000_"))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: finalURL.path).contains { $0.hasSuffix("_screen.mp4") })
    }

    @Test func emptyInputsWithAudioSourcesReconstructsAndFinalizes() async throws {
        let root = try makeTempDirectory("remix-queue-reconstruct")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_system.m4a"))
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_BuiltInMicrophoneDevice.m4a"))
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, reconciliation in
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000"))

        await queue.waitForCompletion()
        let maybeFinalDir = try finalizedSegmentDirectory(in: root, timePrefix: "120000")
        let finalDir = try #require(maybeFinalDir)

        #expect(completionCount.count == 1)
        let outcome = try #require(completedOutcome.current)
        guard case .recovered = outcome else {
            Issue.record("Expected recovered reconciliation")
            return
        }
        #expect(fakeRemixer.recordedInputs.all.first?.count == 2)
        #expect(fakeRemixer.remixCount.count == 1)
        #expect(FileManager.default.fileExists(atPath: finalDir.appendingPathComponent("\(finalDir.lastPathComponent)_audio.m4a").path))
    }

    @Test func emptyInputsWithoutAudioSourcesFinalizesScreenOnly() async throws {
        let root = try makeTempDirectory("remix-queue-no-audio-sources")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000"))

        await queue.waitForCompletion()
        let maybeFinalDir = try finalizedSegmentDirectory(in: root, timePrefix: "120000")
        let finalDir = try #require(maybeFinalDir)

        #expect(completionCount.count == 1)
        #expect(fakeRemixer.remixCount.count == 0)
        #expect(!FileManager.default.fileExists(atPath: finalDir.appendingPathComponent("\(finalDir.lastPathComponent)_audio.m4a").path))
    }

    @Test func emptyInputsWithSilentAudioSourcesFinalizesScreenOnly() async throws {
        let root = try makeTempDirectory("remix-queue-silent-reconstruct")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_system.m4a"))
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_BuiltInMicrophoneDevice.m4a"))
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let fakeRemixer = FakeRemixer(.throwing(AudioRemixerError.noTracksToWrite))
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000"))

        await queue.waitForCompletion()
        let maybeFinalDir = try finalizedSegmentDirectory(in: root, timePrefix: "120000")
        let finalDir = try #require(maybeFinalDir)

        #expect(completionCount.count == 1)
        #expect(FileManager.default.fileExists(atPath: finalDir.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
    }

    @Test func emptyInputsWithFailedReconstructionMarksFailedAndReportsOutcome() async throws {
        let root = try makeTempDirectory("remix-queue-reconstruct-fails")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let systemAudio = dir.appendingPathComponent("120000_audio_system.m4a")
        let micAudio = dir.appendingPathComponent("120000_audio_BuiltInMicrophoneDevice.m4a")
        try await makeTinyValidM4A(at: systemAudio)
        try await makeTinyValidM4A(at: micAudio)
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let fakeRemixer = FakeRemixer(.throwing(SyntheticRemixError()))
        let completionCount = LockedCounter()
        let completedURL = LockedValue<URL>()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { url, reconciliation in
            completedURL.set(url)
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000"))

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        await queue.waitForCompletion()

        #expect(completionCount.count == 1)
        #expect(completedURL.current == dir)
        let outcome = try #require(completedOutcome.current)
        guard case .failed = outcome else {
            Issue.record("Expected failed reconciliation outcome")
            return
        }
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(systemAudio.lastPathComponent).path))
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(micAudio.lastPathComponent).path))
        #expect(try segmentDirectories(in: root).filter { $0.hasPrefix("120000_") }.isEmpty)
    }

    @Test func emptyInputsWithUnreadableAudioSourcesMarksFailedWithoutFinalizing() async throws {
        let root = try makeTempDirectory("remix-queue-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let corruptAudio = dir.appendingPathComponent("120000_audio_system.m4a")
        try corruptM4A(at: corruptAudio)
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        // .success is the trap-guard: .failed is reachable here ONLY via correct .unreadable
        // classification. A wrong .unreadable->.ready impl would finalize _NNN and fail this test.
        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, reconciliation in
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000"))

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        await queue.waitForCompletion()

        #expect(completionCount.count == 1)
        let outcome = try #require(completedOutcome.current)
        guard case .failed = outcome else { Issue.record("Expected failed reconciliation"); return }
        #expect(fakeRemixer.remixCount.count == 0)  // unreadable path never remixes
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_audio_system.m4a").path))
        #expect(try segmentDirectories(in: root).filter { $0.hasPrefix("120000_") }.isEmpty)
    }

    @Test func orphanWithReadableAudioSourcesReconstructsAndFinalizes() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-readable")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let mp4 = dir.appendingPathComponent("120000_display_42_screen.mp4")
        try await makeTinyValidMP4(at: mp4, seconds: 1.2)
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_system.m4a"))
        let expectedDuration = try await probedMP4DurationSeconds(mp4)
        let segmentKey = "120000_\(expectedDuration)"

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, reconciliation in
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        let finalDir = root.appendingPathComponent(segmentKey, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: finalDir.path))
        #expect(completionCount.count == 1)
        #expect(fakeRemixer.remixCount.count == 1)
        let outcome = try #require(completedOutcome.current)
        guard case .recovered = outcome else {
            Issue.record("Expected recovered reconciliation")
            return
        }
        #expect(FileManager.default.fileExists(atPath: finalDir.appendingPathComponent("\(segmentKey)_audio.m4a").path))
    }

    @Test func carriedDurationControlsSegmentKey() async throws {
        let root = try makeTempDirectory("remix-queue-carried-duration")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let queue = RemixQueue { _, _ in FakeRemixer(.success) }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000", capturedDurationSeconds: 7))
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_7", isDirectory: true).path))
    }

    @Test func carriedDurationClampsOverCeiling() async throws {
        let root = try makeTempDirectory("remix-queue-carried-duration-ceiling")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let queue = RemixQueue { _, _ in FakeRemixer(.success) }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000", capturedDurationSeconds: 999))
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_300", isDirectory: true).path))
    }

    @Test func orphanWithSubsecondMP4ClampsToOne() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-subsecond")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try await makeTinyValidMP4(at: dir.appendingPathComponent("120000_display_42_screen.mp4"), seconds: 0.2)
        let queue = RemixQueue { _, _ in FakeRemixer(.success) }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_1", isDirectory: true).path))
    }

    @Test func orphanDurationProbeTimeoutStampsCeilingAndFinalizes() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-duration-timeout")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))
        let queue = RemixQueue(
            durationProbeTimeoutSeconds: 0.01,
            durationLoader: { _ in
                try await Task.sleep(for: .seconds(60))
                return CMTime(seconds: 1, preferredTimescale: 600)
            }
        ) { _, _ in
            FakeRemixer(.success)
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000_300", isDirectory: true).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed", isDirectory: true).path))
    }

    @Test func orphanWithoutMP4MarksFailedWithoutCompletionAndReleasesInFlight() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-no-mp4")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in FakeRemixer(.success) }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(completionCount.count == 0)
        #expect(await queue.inFlightPaths().isEmpty)
    }

    @Test func orphanWithInvalidDurationMP4MarksFailedWithoutCompletion() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-invalid-duration")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let mp4 = dir.appendingPathComponent("120000_display_42_screen.mp4")
        try Data("video".utf8).write(to: mp4)

        let completionCount = LockedCounter()
        let queue = RemixQueue(
            durationLoader: { _ in throw SyntheticRemixError() }
        ) { _, _ in
            FakeRemixer(.success)
        }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        await queue.waitForCompletion()

        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(completionCount.count == 0)
    }

    @Test func orphanWithCorruptAudioMarksFailedAndReportsReconciliation() async throws {
        let root = try makeTempDirectory("remix-queue-orphan-corrupt-audio")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try await makeTinyValidMP4(at: dir.appendingPathComponent("120000_display_42_screen.mp4"), seconds: 1.2)
        let corruptAudio = dir.appendingPathComponent("120000_audio_system.m4a")
        try corruptM4A(at: corruptAudio)

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let completedOutcome = LockedValue<SegmentReconciliation>()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, reconciliation in
            completedOutcome.set(reconciliation)
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        await queue.waitForCompletion()

        #expect(completionCount.count == 1)
        let outcome = try #require(completedOutcome.current)
        guard case .failed = outcome else {
            Issue.record("Expected failed reconciliation")
            return
        }
        #expect(fakeRemixer.remixCount.count == 0)
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(corruptAudio.lastPathComponent).path))
    }

    @Test func emptyInputsWithPreexistingConsolidatedAudioDoesNotReconstruct() async throws {
        let root = try makeTempDirectory("remix-queue-existing-audio")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_system.m4a"))
        try await makeTinyValidM4A(at: dir.appendingPathComponent("120000_audio_BuiltInMicrophoneDevice.m4a"))
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let existingBytes = Data("existing audio".utf8)
        try existingBytes.write(to: dir.appendingPathComponent("120000_5_audio.m4a"))

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeEmptyJob(dir: dir, timePrefix: "120000", capturedDurationSeconds: 5))

        await queue.waitForCompletion()
        let maybeFinalDir = try finalizedSegmentDirectory(in: root, timePrefix: "120000")
        let finalDir = try #require(maybeFinalDir)

        let consolidatedAudio = finalDir.appendingPathComponent("\(finalDir.lastPathComponent)_audio.m4a")
        #expect(completionCount.count == 1)
        #expect(fakeRemixer.remixCount.count == 0)
        #expect(try Data(contentsOf: consolidatedAudio) == existingBytes)
    }

    @Test func orphanWithTimePrefixConsolidatedAudioDoesNotReconstructAndRenamesAudio() async throws {
        let root = try makeTempDirectory("remix-queue-existing-time-prefix-audio")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let mp4 = dir.appendingPathComponent("120000_display_42_screen.mp4")
        try await makeTinyValidMP4(at: mp4, seconds: 1.2)
        let expectedDuration = try await probedMP4DurationSeconds(mp4)
        let segmentKey = "120000_\(expectedDuration)"
        let existingBytes = Data("existing time prefix audio".utf8)
        try existingBytes.write(to: dir.appendingPathComponent("120000_audio.m4a"))

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        let finalDir = root.appendingPathComponent(segmentKey, isDirectory: true)
        let consolidatedAudio = finalDir.appendingPathComponent("\(segmentKey)_audio.m4a")
        #expect(completionCount.count == 1)
        #expect(fakeRemixer.remixCount.count == 0)
        #expect(try Data(contentsOf: consolidatedAudio) == existingBytes)
    }

    @Test func orphanMixedFormFilesAreRenamedIdempotently() async throws {
        let root = try makeTempDirectory("remix-queue-idempotent-rename")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let timePrefixMP4 = dir.appendingPathComponent("120000_display_99_screen.mp4")
        try await makeTinyValidMP4(at: timePrefixMP4, seconds: 1.2)
        let expectedDuration = try await probedMP4DurationSeconds(timePrefixMP4)
        let segmentKey = "120000_\(expectedDuration)"

        try await makeTinyValidMP4(
            at: dir.appendingPathComponent("\(segmentKey)_display_42_screen.mp4"),
            seconds: 1.2
        )
        let existingAudioBytes = Data("existing segment key audio".utf8)
        try existingAudioBytes.write(to: dir.appendingPathComponent("\(segmentKey)_audio.m4a"))
        try Data("source audio".utf8).write(to: dir.appendingPathComponent("120000_audio_system.m4a"))
        try Data("{\"ok\":true}".utf8).write(to: dir.appendingPathComponent("120000_meta.json"))
        try Data("unrelated".utf8).write(to: dir.appendingPathComponent("note.txt"))

        let fakeRemixer = FakeRemixer(.success)
        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in fakeRemixer }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        let finalDir = root.appendingPathComponent(segmentKey, isDirectory: true)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: finalDir.path))
        #expect(completionCount.count == 1)
        #expect(fakeRemixer.remixCount.count == 0)
        #expect(names.contains("\(segmentKey)_display_42_screen.mp4"))
        #expect(names.contains("\(segmentKey)_display_99_screen.mp4"))
        #expect(names.contains("\(segmentKey)_audio_system.m4a"))
        #expect(names.contains("\(segmentKey)_meta.json"))
        #expect(names.contains("note.txt"))
        #expect(!names.contains { $0.hasPrefix("\(segmentKey)_\(expectedDuration)_") })
        #expect(try Data(contentsOf: finalDir.appendingPathComponent("\(segmentKey)_audio.m4a")) == existingAudioBytes)
    }

    @Test func orphanCommitFailureLeavesIncompleteDirectoryAndDoesNotComplete() async throws {
        let root = try makeTempDirectory("remix-queue-commit-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let mp4 = dir.appendingPathComponent("120000_display_42_screen.mp4")
        try await makeTinyValidMP4(at: mp4, seconds: 1.2)
        let expectedDuration = try await probedMP4DurationSeconds(mp4)
        let segmentKey = "120000_\(expectedDuration)"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(segmentKey, isDirectory: true),
            withIntermediateDirectories: true
        )

        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in FakeRemixer(.success) }
        await queue.setOnSegmentComplete { _, _ in
            completionCount.increment()
        }

        await queue.enqueue(makeOrphanJob(dir: dir, timePrefix: "120000"))
        await queue.waitForCompletion()

        #expect(completionCount.count == 0)
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(await queue.inFlightPaths().isEmpty)
    }

    private func makeDir(root: URL, name: String) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeJob(dir: URL, timePrefix: String, inputURL: URL) -> RemixQueue.RemixJob {
        RemixQueue.RemixJob(
            segmentDirectory: dir,
            timePrefix: timePrefix,
            capturedDurationSeconds: 1,
            audioInputs: [
                AudioRemixerInput(
                    url: inputURL,
                    timingInfo: AudioTrackTimingInfo(
                        startOffset: .zero,
                        endOffset: CMTime(seconds: 1, preferredTimescale: 600),
                        trackType: .systemAudio
                    )
                )
            ],
            debugKeepRejected: false,
            silenceMusic: true,
            micMetadataJSON: nil
        )
    }

    private func makeEmptyJob(
        dir: URL,
        timePrefix: String,
        capturedDurationSeconds: Int? = 1
    ) -> RemixQueue.RemixJob {
        RemixQueue.RemixJob(
            segmentDirectory: dir,
            timePrefix: timePrefix,
            capturedDurationSeconds: capturedDurationSeconds,
            audioInputs: [],
            debugKeepRejected: false,
            silenceMusic: true,
            micMetadataJSON: nil
        )
    }

    private func makeOrphanJob(dir: URL, timePrefix: String) -> RemixQueue.RemixJob {
        RemixQueue.RemixJob(
            segmentDirectory: dir,
            timePrefix: timePrefix,
            capturedDurationSeconds: nil,
            audioInputs: [],
            debugKeepRejected: false,
            silenceMusic: true,
            micMetadataJSON: nil
        )
    }

    private func probedMP4DurationSeconds(_ url: URL) async throws -> Int {
        let duration = try await AVURLAsset(url: url).load(.duration)
        return Int(CMTimeGetSeconds(duration))
    }

    private func segmentDirectories(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    private func finalizedSegmentDirectory(in root: URL, timePrefix: String) throws -> URL? {
        let names = try segmentDirectories(in: root)
        guard let name = names.first(where: {
            $0.hasPrefix("\(timePrefix)_") && !$0.hasSuffix(".failed") && !$0.hasSuffix(".incomplete")
        }) else {
            return nil
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }
}
