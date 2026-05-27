// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("RemixQueue timeout")
struct RemixQueueTimeoutTests {
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
        let queue = RemixQueue { _, _ in
            FakeRemixer(behaviors.removeFirst(default: .success))
        }
        await queue.setOnSegmentComplete { _ in
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: firstDir, timePrefix: "120000", inputURL: firstAudio))
        await queue.enqueue(makeJob(dir: secondDir, timePrefix: "120100", inputURL: secondAudio))

        try await waitUntil(timeout: .seconds(65)) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path)
        }
        try await waitUntil(timeout: .seconds(5)) {
            completionCount.count == 1
        }
        await queue.waitForCompletion()

        #expect(await queue.isProcessingForTesting == false)
        #expect(completionCount.count == 1)
    }

    @Test func genericRemixFailureIsFailedAndQueueStopsWithoutUpload() async throws {
        let root = try makeTempDirectory("remix-queue-generic-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try makeDir(root: root, name: "120000.incomplete")
        let audio = dir.appendingPathComponent("120000_audio_system.m4a")
        try Data("audio".utf8).write(to: audio)
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let completionCount = LockedCounter()
        let queue = RemixQueue { _, _ in
            FakeRemixer(.throwing(SyntheticRemixError()))
        }
        await queue.setOnSegmentComplete { _ in
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))

        try await waitUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path)
        }
        await queue.waitForCompletion()

        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)
        #expect(await queue.isProcessingForTesting == false)
        #expect(completionCount.count == 0)
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
        await queue.setOnSegmentComplete { url in
            completedURL.set(url)
            completionCount.increment()
        }

        await queue.enqueue(makeJob(dir: dir, timePrefix: "120000", inputURL: audio))

        try await waitUntil(timeout: .seconds(5)) {
            completionCount.count == 1
        }
        await queue.waitForCompletion()

        let finalURL = try #require(completedURL.current)
        #expect(finalURL.lastPathComponent.hasPrefix("120000_"))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: finalURL.path).contains { $0.hasSuffix("_screen.mp4") })
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
            captureStartTime: Date().addingTimeInterval(-1),
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

    private func segmentDirectories(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }
}
