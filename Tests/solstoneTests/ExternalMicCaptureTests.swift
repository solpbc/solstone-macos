// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Testing
@testable import solstone

@Suite("ExternalMicCapture")
struct ExternalMicCaptureTests {
    @Test(arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16, .pcmFormatFloat64], [false, true])
    func copiesEveryHardwarePCMByteWithoutAliasing(format: AVAudioCommonFormat, interleaved: Bool) throws {
        let layout = try #require(AVAudioFormat(commonFormat: format, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: layout, frameCapacity: 17))
        buffer.frameLength = 17
        let original = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, channel) in original.enumerated() {
            memset(try #require(channel.mData), Int32(20 + index), Int(channel.mDataByteSize))
        }
        let copy = try #require(ExternalMicCapture.copyPCMBuffer(buffer))
        let copied = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
        #expect(copy.frameLength == 17)
        #expect(copied.count == original.count)
        for index in original.indices {
            let length = Int(original[index].mDataByteSize)
            #expect(Data(bytes: try #require(original[index].mData), count: length) == Data(bytes: try #require(copied[index].mData), count: length))
            memset(original[index].mData, 0, length)
            #expect(Data(bytes: try #require(original[index].mData), count: length) != Data(bytes: try #require(copied[index].mData), count: length))
        }
    }

    @Test func admittedBuffersKeepTheirDestinationUntilDrain() async throws {
        let capture = ExternalMicCapture(device: AudioInputDevice(id: 0, name: "test", uid: "test",
            manufacturer: nil, sampleRate: 48_000, transportType: .virtual))
        let old = LockedCounter(), next = LockedCounter()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        memset(try #require(buffer.floatChannelData)[0], 0, 16 * MemoryLayout<Float>.size)
        capture.setCallbacks(audio: { _, _ in old.increment() }, error: nil)
        capture._suspendProcessingForTesting()
        capture._enqueueForTesting(buffer)
        capture.setCallbacks(audio: nil, error: nil)
        capture.setCallbacks(audio: { _, _ in next.increment() }, error: nil)
        capture._resumeProcessingForTesting()
        await capture.drain()
        #expect(old.count == 1)
        #expect(next.count == 0)
        capture.stop()
    }

    @Test func summedMonoRespectsInterleavedChannelStride() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: true, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<3 {
            for frame in 0..<4 { channels[channel][frame * buffer.stride] = Float(channel + frame * 10) }
        }
        let mono = try #require(ExternalMicCapture.summedMono(buffer))
        let values = try #require(mono.floatChannelData)[0]
        for frame in 0..<4 { #expect(values[frame] == Float(3 + frame * 30)) }
    }
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
