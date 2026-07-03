// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreAudio
import CoreMedia
import Foundation
import Testing
@testable import solstone

@Suite("PerSourceAudioManager")
struct PerSourceAudioManagerTests {
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
