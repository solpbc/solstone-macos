// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("Audio fragments")
struct AudioFragmentTests {
    @Test func productionIntervalsAndNormalSilenceMarkerContent() async throws {
        let root = try makeTempDirectory("audio-fragments")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try SingleTrackAudioWriter(url: root.appendingPathComponent("source.m4a"),
            trackType: .systemAudio, segmentStartTime: .zero)
        let intervals = writer._fragmentIntervalsForTesting
        #expect(intervals.0.isNumeric && intervals.0.seconds == 1)
        #expect(intervals.1.isNumeric && intervals.1.seconds == 1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var cursor = 0
        for (count, frequency) in [(4800, 220.0), (9600, 0.0), (4800, 660.0)] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                buffer.floatChannelData![0][frame] = frequency == 0 ? 0 : Float(0.2 * sin(2 * .pi * frequency * Double(frame) / 48_000))
            }
            writer.appendPCMBuffer(buffer, presentationTime: CMTime(value: Int64(cursor), timescale: 48_000))
            cursor += count
        }
        let timing = await writer.finish()
        #expect(timing.hasAudio && writer._acceptedFramesForTesting == cursor)
        let asset = AVURLAsset(url: writer.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let block = try #require(CMSampleBufferGetDataBuffer(buffer))
            var decoded = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: decoded.count * 4, destination: &decoded) == noErr)
            samples.append(contentsOf: decoded)
        }
        #expect(reader.status == .completed && samples.count == cursor)
        guard samples.count == cursor else { return }
        func rms(_ values: ArraySlice<Float>) -> Double {
            sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(values.count))
        }
        #expect(rms(samples[1200..<3600]) > 0.05)
        #expect(rms(samples[7200..<12000]) < 0.002)
        #expect(rms(samples[15600..<18000]) > 0.05)
    }
}
