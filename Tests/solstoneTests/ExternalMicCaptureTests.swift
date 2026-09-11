// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Testing
@testable import solstone

@Suite("ExternalMicCapture")
struct ExternalMicCaptureTests {
    @Test func stopTearsDownEngineBeforeRemovingTapWhenNeverStarted() {
        let device = AudioInputDevice(
            id: 0,
            name: "test-mic",
            uid: "test-uid",
            manufacturer: nil,
            sampleRate: 48_000,
            transportType: .virtual
        )
        let capture = ExternalMicCapture(device: device)

        capture.stop()

        // Proves stop tears down even when never started, and stops before tap removal.
        #expect(capture._teardownTraceForTesting == ["engine.stop", "removeTap"])
    }

    // A 10-input interface (Focusrite Scarlett 8i6 shape): the live mic can sit on any
    // jack, so every input is summed into the mono track rather than pinning input 1.
    @Test func summedMonoMixesEveryInputOfAMultichannelInterface() throws {
        // CoreAudio reports >2-input interfaces with a discrete layout, never a named one.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 10))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let frames: AVAudioFrameCount = 4
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<10 {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = 0
            }
        }
        // Mic on input 3, a second source on input 10; inputs 1, 2, 4-9 idle.
        for frame in 0..<Int(frames) {
            channels[2][frame] = 0.25
            channels[9][frame] = Float(frame) * 0.1
        }

        let mono = try #require(ExternalMicCapture.summedMono(buffer))

        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 48_000)
        #expect(mono.frameLength == frames)
        let samples = try #require(mono.floatChannelData)
        let expected: [Float] = [0.25, 0.35, 0.45, 0.55]
        for frame in 0..<Int(frames) {
            #expect(abs(samples[0][frame] - expected[frame]) < 1e-6)
        }
    }
}
