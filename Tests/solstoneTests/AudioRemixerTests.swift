// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("AudioRemixer")
struct AudioRemixerTests {
    @Test func filterReadableAudioInputsSkipsUnreadableAndKeepsGood() async throws {
        let root = try makeTempDirectory("audio-remixer-readable")
        defer { try? FileManager.default.removeItem(at: root) }

        let good = root.appendingPathComponent("120000_audio_system.m4a")
        let corrupt = root.appendingPathComponent("120000_audio_bad.m4a")
        try await makeTinyValidM4A(at: good)
        try corruptM4A(at: corrupt)

        let goodInput = makeInput(url: good, sourceID: "system")
        let corruptInput = makeInput(url: corrupt, sourceID: "bad")

        let result = await filterReadableAudioInputs([goodInput, corruptInput])

        #expect(result.skippedUnreadable == 1)
        #expect(result.readable.map(\.url) == [good])
    }

    @Test func remixWithOnlyUnreadableInputsThrowsNoTracksToWrite() async throws {
        let root = try makeTempDirectory("audio-remixer-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("120000_audio_first.m4a")
        let second = root.appendingPathComponent("120000_audio_second.m4a")
        let output = root.appendingPathComponent("120000_audio.m4a")
        try corruptM4A(at: first)
        try corruptM4A(at: second)

        let remixer = AudioRemixer()

        do {
            _ = try await remixer.remix(
                inputs: [
                    makeInput(url: first, sourceID: "first"),
                    makeInput(url: second, sourceID: "second"),
                ],
                to: output,
                deleteSourceFiles: false
            )
            Issue.record("expected noTracksToWrite")
        } catch AudioRemixerError.noTracksToWrite {
            #expect(!FileManager.default.fileExists(atPath: output.path))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func makeInput(url: URL, sourceID: String) -> AudioRemixerInput {
        AudioRemixerInput(
            url: url,
            timingInfo: AudioTrackTimingInfo(
                startOffset: .zero,
                endOffset: CMTime(seconds: 1, preferredTimescale: 48_000),
                trackType: sourceID == "system" ? .systemAudio : .microphone(name: sourceID, deviceUID: sourceID)
            )
        )
    }
}
