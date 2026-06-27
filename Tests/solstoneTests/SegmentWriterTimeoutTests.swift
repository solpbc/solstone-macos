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

        _ = await writer.finishCapture()

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

        let result = await writer.finishCapture()

        #expect(result?.audioInputs.isEmpty == true)
        #expect(fakeAudio.finishAllCount.count == 1)
    }

    @Test func finishCaptureCoalescesConcurrentCallers() async throws {
        let dir = try makeTempDirectory("segment-finish-coalesce")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeCapturer = FakeScreenshotCapturer(behavior: .hangStop)
        let fakeAudio = FakeAudioManager()
        let writer = makeWriter(
            dir: dir,
            capturer: fakeCapturer,
            audioManager: fakeAudio,
            capturerStopTimeoutSeconds: 0.05
        )

        try await startWriter(writer)

        async let first = writer.finishCapture()
        async let second = writer.finishCapture()
        let results = await (first, second)

        #expect(fakeCapturer.stopCount.count == 1)
        #expect(fakeAudio.finishAllCount.count == 1)
        #expect(results.0?.segmentDirectory == results.1?.segmentDirectory)
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

    private func makeWriter(
        dir: URL,
        capturer: FakeScreenshotCapturer,
        audioManager: FakeAudioManager,
        capturerStopTimeoutSeconds: TimeInterval = 1.0,
        audioFinishTimeoutSeconds: TimeInterval = 1.0
    ) -> SegmentWriter {
        SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            capturerStopTimeoutSeconds: capturerStopTimeoutSeconds,
            audioFinishTimeoutSeconds: audioFinishTimeoutSeconds,
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

}
