// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing
@testable import solstone

@Suite("SegmentWriter dead capturer")
@MainActor
struct SegmentWriterDeadCapturerTests {
    @Test func startThrowsAndRollsBackWhenRealScreenshotCapturerCannotStart() async throws {
        let dir = try makeTempDirectory("segment-dead-capturer")
        defer { try? FileManager.default.removeItem(at: dir) }

        let failingStream = FakeCaptureStream(startError: FakeCaptureError.startFailed)
        let streamFactory = FakeCaptureStreamFactory([failingStream])
        let audioManager = DeadCapturerAudioManager()
        let writer = SegmentWriter(
            outputDirectory: dir,
            timePrefix: "120000",
            screenshotCapturerFactory: { info, videoURL, frameRate, duration, contentFilter, verbose in
                guard let contentFilter else {
                    throw SegmentWriter.SegmentError.missingContentFilter(displayID: info.displayID)
                }
                return try ScreenshotCapturer(
                    displayID: info.displayID,
                    videoURL: videoURL,
                    width: info.width,
                    height: info.height,
                    frameRate: frameRate,
                    duration: duration,
                    contentFilter: contentFilter,
                    verbose: verbose,
                    streamFactory: streamFactory.factory
                )
            },
            audioManagerFactory: { _, _, _, _ in audioManager }
        )
        let display = DisplayInfo(
            displayID: 42,
            width: 100,
            height: 100,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        do {
            try await writer.start(
                displayInfos: [display],
                filters: [display.displayID: SCContentFilter()],
                audioFilter: nil
            )
            Issue.record("expected SegmentWriter.start to throw")
        } catch {
            #expect(failingStream.addStreamOutputCount.count == 1)
            #expect(failingStream.startCount.count == 1)
            #expect(streamFactory.createdStreams.count == 1)
            #expect(audioManager.startSystemAudioCount.count == 1)
            #expect(audioManager.finishAllCount.count == 1)
            #expect(writer.activeMicrophoneUIDs().isEmpty)
        }
    }
}

private final class DeadCapturerAudioManager: SegmentAudioManaging, @unchecked Sendable {
    let startSystemAudioCount = LockedCounter()
    let finishAllCount = LockedCounter()

    func setSegmentStartTime(_ time: CMTime) {}

    func startSystemAudio() throws -> String {
        startSystemAudioCount.increment()
        return "system"
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {}

    func addMicrophone(_ device: AudioInputDevice) throws -> String {
        device.uid
    }

    func removeMicrophone(deviceUID: String) {}

    func hasMicrophone(deviceUID: String) -> Bool {
        false
    }

    func activeMicrophoneUIDs() -> [String] {
        ["rollback-probe"]
    }

    func getMicMetadata() -> [[String: Any]] {
        []
    }

    func finishAll() async -> [AudioRemixerInput] {
        finishAllCount.increment()
        return []
    }
}
