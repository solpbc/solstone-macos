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

}
