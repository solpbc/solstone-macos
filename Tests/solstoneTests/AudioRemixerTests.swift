// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("AudioRemixer")
struct AudioRemixerTests {
    @Test func remixWithOnlyUnreadableInputsThrowsUnreadableSources() async throws {
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
                to: output
            )
            Issue.record("expected unreadableSources")
        } catch AudioRemixerError.unreadableSources(let sourceIDs) {
            #expect(sourceIDs == ["first", "second"])
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

@Suite("AudioPreservation")
struct AudioPreservationTests {
    @Test func musicSilencingPreservesOtherFramesInTheSameBuffer() throws {
        let sample = try makeNonSilentAudioSampleBuffer(seconds: 0.02)
        let music = CMTimeRange(start: CMTime(value: 240, timescale: 48_000), duration: CMTime(value: 240, timescale: 48_000))
        let silenced = try #require(AudioBufferUtils.silencedCopy(of: sample, ranges: [music]))
        let block = try #require(CMSampleBufferGetDataBuffer(silenced))
        var samples = [Float](repeating: -1, count: 960)
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * 4, destination: &samples) == noErr)
        #expect(samples[0..<240].allSatisfy { $0 == 0.1 })
        #expect(samples[240..<480].allSatisfy { $0 == 0 })
        #expect(samples[480..<960].allSatisfy { $0 == 0.1 })
        let unknown = CMTimeRange(start: .invalid, duration: .positiveInfinity)
        #expect(AudioBufferUtils.silencedCopy(of: sample, ranges: [unknown]) == nil)
    }

    @Test func positiveGapsAndOverlappingSpeechRemainProtected() {
        let analyzer = SystemAudioAnalyzer.shared
        func range(_ start: Double, _ end: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: end, preferredTimescale: 48_000))
        }
        let result = analyzer.computeSilenceRanges(from: [range(0, 2), range(3, 5)], padding: 0, protecting: [range(1, 4)])
        #expect(result.count == 2)
        #expect(result[0].start.seconds == 0 && CMTimeRangeGetEnd(result[0]).seconds == 1)
        #expect(result[1].start.seconds == 4 && CMTimeRangeGetEnd(result[1]).seconds == 5)
        let gap = analyzer.computeSilenceRanges(from: [range(0, 2), range(3, 5)], padding: 0)
        #expect(gap.count == 2)
    }

    @Test func finalSilenceFlushCountsOriginalFramesAndKeepsTail() async throws {
        let root = try makeTempDirectory("writer-silence-tail")
        defer { try? FileManager.default.removeItem(at: root) }
        let statistics = LockedValue<AudioWriterStatistics>()
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("tail.m4a"), trackType: .systemAudio,
            segmentStartTime: .zero, onStatistics: { statistics.set($0) })
        writer.appendAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        let quiet = try #require(AudioBufferUtils.silencedCopy(of: makeNonSilentAudioSampleBuffer(seconds: 0.02)))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                      presentationTimeStamp: CMTime(value: 960, timescale: 48_000), decodeTimeStamp: .invalid)
        var later: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: quiet,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &later) == noErr)
        writer.appendAudio(try #require(later))
        let info = await writer.finish()
        let final = try #require(statistics.current)
        #expect(final.receivedFrames == 1920)
        #expect(final.acceptedFrames == 1920)
        #expect(final.droppedFrames == 0)
        #expect(final.writerStatus == "completed")
        #expect(abs(info.endOffset.seconds - 0.04) < 0.0001)
        let asset = AVURLAsset(url: writer.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        #expect(reader.status == .completed)
        #expect(frames == 1920)
    }
}
