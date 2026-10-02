// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import CoreMedia
import AVFoundation
import Foundation
import Testing
@testable import solstone

@Suite("PerSourceAudioManager")
struct PerSourceAudioManagerTests {
    @Test func reconnectKeepsEarlierFramesEvenWhenOneRejoinFails() async throws {
        let root = try makeTempDirectory("audio-reconnect")
        defer { try? FileManager.default.removeItem(at: root) }
        let failStart = LockedValue<Bool>()
        let manager = PerSourceAudioManager(
            outputDirectory: root, timePrefix: "120000", captureManager: MicrophoneCaptureManager(),
            startMicrophoneCapture: { _ in
                if failStart.current == true { throw FakeCaptureError.startFailed }
            }
        )
        manager.setSegmentStartTime(.zero)
        let mic = AudioInputDevice(id: 42, name: "test mic", uid: "test-mic", manufacturer: "test", sampleRate: 48_000, transportType: .usb)
        _ = try manager.addMicrophone(mic)
        let original = try #require(manager._sourceWriterForTesting(mic.uid))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        for i in 0..<960 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.5 }
        original.appendPCMBuffer(buffer, presentationTime: .zero)
        manager.removeMicrophone(deviceUID: mic.uid)
        #expect(!manager.hasMicrophone(deviceUID: mic.uid))
        failStart.set(true)
        #expect(throws: FakeCaptureError.self) { try manager.addMicrophone(mic) }
        #expect(manager._sourceWriterForTesting(mic.uid) === original)
        failStart.set(false)
        _ = try manager.addMicrophone(mic)
        #expect(manager._sourceWriterForTesting(mic.uid) === original)
        original.appendPCMBuffer(buffer, presentationTime: CMTime(seconds: 0.02, preferredTimescale: 48_000))
        let inputs = await manager.finishAll()
        #expect(inputs.count == 1)
        let input = try #require(inputs.first)
        let asset = AVURLAsset(url: input.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        #expect(reader.status == .completed)
        #expect(frames == 1920)
        #expect(throws: SegmentWriter.SegmentError.self) { try manager.addMicrophone(mic) }
    }

    @Test func removedMicTrackIsIncludedBeforeFinishAllSnapshotAndDoesNotLeak() async throws {
        let root = try makeTempDirectory("per-source-audio-manager")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PerSourceAudioManager(outputDirectory: root, timePrefix: "120000")
        manager.setSegmentStartTime(.zero)

        _ = try manager.startSystemAudio()
        manager.appendSystemAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))

        let mic = AudioInputDevice(
            id: AudioDeviceID(42),
            name: "test mic",
            uid: "test-mic-uid",
            manufacturer: "sol",
            sampleRate: 48_000,
            transportType: .usb
        )
        let micWriter = try SingleTrackAudioWriter(
            url: root.appendingPathComponent("120000_audio_test-mic-uid.m4a"),
            trackType: .microphone(name: mic.name, deviceUID: mic.uid),
            segmentStartTime: .zero
        )
        micWriter.appendAudio(try makeNonSilentAudioSampleBuffer(seconds: 0.02))
        manager._addSourceWriterForTesting(micWriter, device: mic)

        manager.removeMicrophone(deviceUID: mic.uid)
        let micMetadata = manager.getMicMetadata()

        let inputs = await manager.finishAll()
        let sourceIDs = inputs.map { $0.timingInfo.trackType.sourceID }
        #expect(sourceIDs.contains(mic.uid))
        #expect(micMetadata.contains { metadata in
            metadata["device_uid"] as? String == mic.uid
        })

        #expect(await manager.finishAll().isEmpty)
        #expect(manager.getMicMetadata().isEmpty)
    }
}
