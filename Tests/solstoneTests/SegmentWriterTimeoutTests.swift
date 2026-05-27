// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation
import Testing
@testable import solstone

@Suite("SegmentWriter timeout discipline")
@MainActor
struct SegmentWriterTimeoutTests {
    @Test func finishCaptureReturnsWhenCapturerStopHangs() async throws {
        let dir = try makeTempDirectory("segment-stop-hang")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeCapturer = FakeScreenshotCapturer(behavior: .hangStop)
        let fakeAudio = FakeAudioManager()
        let writer = makeWriter(
            dir: dir,
            capturer: fakeCapturer,
            audioManager: fakeAudio
        )

        try await startWriter(writer)

        let clock = ContinuousClock()
        let start = clock.now
        _ = await writer.finishCapture()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(10))
        #expect(fakeCapturer.stopCount.count == 1)
        #expect(fakeAudio.finishAllCount.count == 1)
    }

    @Test func finishCaptureReturnsWhenFinishAllHangs() async throws {
        let dir = try makeTempDirectory("segment-finishall-hang")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeAudio = FakeAudioManager(behavior: .hangFinishAll)
        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: fakeAudio
        )

        try await startWriter(writer)

        let clock = ContinuousClock()
        let start = clock.now
        let result = await writer.finishCapture()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(14))
        #expect(result?.audioInputs.isEmpty == true)
        #expect(fakeAudio.finishAllCount.count == 1)
    }

    @Test func finishReturnsWhenFinishAndRemixHangsAndLeavesSourceAudio() async throws {
        let dir = try makeTempDirectory("segment-remix-hang")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceAudio = dir.appendingPathComponent("120000_audio_system.m4a")
        try Data("audio".utf8).write(to: sourceAudio)

        let fakeAudio = FakeAudioManager(behavior: .hangFinishAndRemix)
        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: fakeAudio
        )

        try await startWriter(writer)

        let clock = ContinuousClock()
        let start = clock.now
        await writer.finish()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(20))
        #expect(FileManager.default.fileExists(atPath: sourceAudio.path))
        #expect(fakeAudio.finishAndRemixCount.count == 1)
    }

    @Test func finishAndRenameUsesBoundedFinishPath() async throws {
        let dir = try makeTempDirectory("segment-finish-rename")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        let fakeAudio = FakeAudioManager(behavior: .hangFinishAndRemix)
        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: fakeAudio
        )

        try await startWriter(writer)

        let clock = ContinuousClock()
        let start = clock.now
        _ = await writer.finishAndRename()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(20))
        #expect(fakeAudio.finishAndRemixCount.count == 1)
    }

    @Test func startFailureRollsBackStartedSources() async throws {
        let dir = try makeTempDirectory("segment-start-rollback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeCapturer = FakeScreenshotCapturer(behavior: .throwOnStart)
        let fakeAudio = FakeAudioManager()
        let writer = makeWriter(
            dir: dir,
            capturer: fakeCapturer,
            audioManager: fakeAudio
        )

        do {
            try await startWriter(writer)
            Issue.record("expected start failure")
        } catch {
            #expect(fakeCapturer.stopCount.count == 1)
            #expect(fakeAudio.startSystemAudioCount.count == 1)
            #expect(fakeAudio.finishAllCount.count == 1)
            #expect(writer.activeMicrophoneUIDs().isEmpty)
        }
    }

    @Test func finishAndRenameMarksIncompleteFailedWhenAudioRemixThrows() async throws {
        let root = try makeTempDirectory("segment-remix-throws")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeIncompleteSegmentDirectory(root: root)
        let sourceAudio = dir.appendingPathComponent("120000_audio_system.m4a")
        try Data("audio".utf8).write(to: sourceAudio)

        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: FakeAudioManager(behavior: .throwFromFinishAndRemix(SyntheticRemixError()))
        )

        try await startWriter(writer)

        let result = await writer.finishAndRename()
        let failedDir = root.appendingPathComponent("120000.failed", isDirectory: true)

        #expect(result.lastPathComponent == "120000.failed")
        #expect(FileManager.default.fileExists(atPath: failedDir.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try segmentDirectories(in: root).filter { $0.hasPrefix("120000_") }.isEmpty)
        #expect(FileManager.default.fileExists(atPath: failedDir.appendingPathComponent("120000_audio_system.m4a").path))
    }

    @Test func finishAndRenameFinalizesIncompleteWhenAudioRemixHasNoTracksToWrite() async throws {
        let root = try makeTempDirectory("segment-remix-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeIncompleteSegmentDirectory(root: root)
        try Data("video".utf8).write(to: dir.appendingPathComponent("120000_display_42_screen.mp4"))

        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: FakeAudioManager(behavior: .throwFromFinishAndRemix(AudioRemixerError.noTracksToWrite))
        )

        try await startWriter(writer)

        let result = await writer.finishAndRename()

        #expect(result.lastPathComponent.hasPrefix("120000_"))
        #expect(!result.lastPathComponent.hasSuffix(".failed"))
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.path).contains { $0.hasSuffix("_screen.mp4") })
    }

    @Test func finishAndRenameMarksIncompleteFailedWhenAudioRemixTimesOut() async throws {
        let root = try makeTempDirectory("segment-remix-timeout-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeIncompleteSegmentDirectory(root: root)

        let writer = makeWriter(
            dir: dir,
            capturer: FakeScreenshotCapturer(),
            audioManager: FakeAudioManager(behavior: .hangFinishAndRemix)
        )

        try await startWriter(writer)

        let result = await writer.finishAndRename()

        #expect(result.lastPathComponent == "120000.failed")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("120000.failed").path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    private func makeWriter(
        dir: URL,
        capturer: FakeScreenshotCapturer,
        audioManager: FakeAudioManager
    ) -> SegmentWriter {
        SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { _, _, _, _, _, _ in capturer },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
    }

    private func startWriter(_ writer: SegmentWriter) async throws {
        let display = DisplayInfo(
            displayID: 42,
            width: 100,
            height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        try await writer.start(displayInfos: [display], filters: [:], audioFilter: nil)
    }

    private func makeIncompleteSegmentDirectory(root: URL) throws -> URL {
        let dir = root.appendingPathComponent("120000.incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func segmentDirectories(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }
}
