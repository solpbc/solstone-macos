// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Testing
@testable import solstone

@Suite("Finite microphone conversion")
struct MicrophoneConverterTests {
    private func capture(gain: Float = 1) -> ExternalMicCapture {
        ExternalMicCapture(device: AudioInputDevice(id: 0, name: "converter test", uid: "converter",
            manufacturer: nil, sampleRate: 48_000, transportType: .virtual), gain: gain)
    }
    private func format(_ rate: Double) throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
    }
    private func pcm(_ values: ArraySlice<Float>, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for (index, value) in values.enumerated() { samples[index] = value }
        return buffer
    }
    private func values(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let samples = try #require(buffer.floatChannelData)[0]
        return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }
    /// A genuine stream end, never an end-of-stream signal on individual taps.
    private func terminalTail(_ converter: AVAudioConverter) throws -> [Float] {
        var tail: [Float] = []
        for _ in 0..<1000 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4096))
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, status in
                status.pointee = .endOfStream; return nil
            }
            #expect(error == nil && status != .error)
            tail += try values(buffer)
            if status == .endOfStream { return tail }
        }
        Issue.record("Converter did not terminate after a true stream end")
        return tail
    }
    /// Output-paced reference supplies request-sized slices of one contiguous
    /// signal, with a frame cursor independent of production tap scheduling.
    private func reference(_ signal: [Float], source: AVAudioFormat, target: AVAudioFormat) throws -> [Float] {
        let converter = try #require(AVAudioConverter(from: source, to: target))
        #expect(converter.primeMethod == (source.sampleRate == target.sampleRate ? .pre : .normal))
        let input = ReferencePCMInput(signal: signal, format: source)
        var result: [Float] = []
        for _ in 0..<1000 {
            let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                guard let buffer = input.next(requested) else {
                    status.pointee = .noDataNow; return nil
                }
                status.pointee = .haveData; return buffer
            }
            #expect(error == nil && status != .error)
            result += try values(output)
            if status == .inputRanDry { break }
        }
        #expect(input.cursor == signal.count)
        let ranges = input.ranges
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == signal.count)
        for pair in zip(ranges, ranges.dropFirst()) { #expect(pair.0.upperBound == pair.1.lowerBound) }
        return result + (try terminalTail(converter))
    }

    @Test(arguments: [44100.0, 48000.0, 96000.0], [false, true])
    func completeMarkedSignalMatchesIndependentReference(rate: Double, uneven: Bool) throws {
        let source = try format(rate), target = try format(48_000)
        let instance = capture()
        var signal: [Float] = []
        var chunkSizes: [Int] = []
        for index in 0..<50 {
            let frames = uneven ? [1, 7, 97, Int(rate / 10), 113, Int(rate / 20)][index % 6] : Int(rate / 10)
            chunkSizes.append(frames)
            // Distinct piecewise levels plus an in-chunk ramp expose repeats and
            // missing chunks, including tiny markers followed by enough input.
            signal += (0..<frames).map { Float(index + 1) / 100 + Float($0) / Float(max(frames, 1)) / 1000 }
        }
        var cursor = 0
        var actual: [Float] = []
        for size in chunkSizes {
            let input = try pcm(signal[cursor..<(cursor + size)], format: source)
            let output = try #require(instance._convertForTesting(input, targetFormat: target))
            actual += try values(output); cursor += size
        }
        #expect(cursor == signal.count)
        if let converter = instance._converterForTesting {
            #expect(converter.primeMethod == .normal)
            actual += try terminalTail(converter)
        }
        let expected = try reference(signal, source: source, target: target)
        #expect(abs(actual.count - expected.count) <= 1)
        let maximumDifference = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(maximumDifference < 0.0001)
        #expect((actual.suffix(256).max() ?? 0) > 0.49)
        instance.stop()
    }

    @Test func targetFormatChangeDoesNotReuseIncompatibleConverter() throws {
        let instance = capture(), source = try format(96_000)
        let input = try pcm(Array(repeating: Float(0.3), count: 9600)[...], format: source)
        let first = try #require(instance._convertForTesting(input, targetFormat: format(48_000)))
        let second = try #require(instance._convertForTesting(input, targetFormat: format(44_100)))
        #expect(first.format.sampleRate == 48_000 && second.format.sampleRate == 44_100)
        #expect(instance._converterForTesting?.outputFormat.sampleRate == 44_100)
        #expect(second.frameLength <= 4410)
        instance.stop()
    }

    @Test func nonzeroInputRanDryIsDeliveredWithGain() async throws {
        let instance = capture(gain: 2), source = try format(44_100), target = try format(48_000)
        let received = ConverterSamples(), errors = LockedCounter()
        instance.setCallbacks(audio: { buffer, _ in received.append(buffer) }, error: { _ in errors.increment() })
        instance._suspendProcessingForTesting()
        instance._enqueueForTesting(try pcm(Array(repeating: Float(0.8), count: 4410)[...], format: source), targetFormat: target)
        instance._resumeProcessingForTesting()
        await instance.drain()
        #expect(instance._conversionStatusForTesting == .inputRanDry)
        #expect(received.frameCounts.count == 1 && (received.frameCounts.first ?? 0) > 0)
        #expect(received.samples.suffix(100).allSatisfy { $0 == 1 })
        #expect(errors.count == 0)
        instance._enqueueForTesting(try pcm(Array(repeating: Float(0.8), count: 4410)[...], format: source), targetFormat: target)
        await instance.drain()
        #expect(received.frameCounts.count == 2 && errors.count == 0)
        instance.stop()
    }

    @Test func zeroOutputIsQuietAndPartialPCMReachesDestinationWithGain() async throws {
        let instance = capture(gain: 2), source = try format(44_100), target = try format(48_000)
        let received = ConverterSamples(), errors = LockedCounter()
        instance.setCallbacks(audio: { buffer, _ in received.append(buffer) }, error: { _ in errors.increment() })
        instance._suspendProcessingForTesting()
        instance._enqueueForTesting(try pcm([Float(0.8)][...], format: source), targetFormat: target)
        instance._resumeProcessingForTesting()
        await instance.drain()
        #expect(received.frameCounts.isEmpty && errors.count == 0)
        for _ in 0..<3 {
            instance._enqueueForTesting(try pcm(Array(repeating: Float(0.8), count: 4410)[...], format: source), targetFormat: target)
        }
        await instance.drain()
        #expect(received.frameCounts.count == 3)
        #expect(received.frameCounts.allSatisfy { $0 > 0 })
        #expect(received.samples.suffix(100).allSatisfy { $0 == 1 })
        #expect(errors.count == 0)
        // A real unsupported multichannel integer layout is a conversion error,
        // distinct from a valid converter that temporarily produces no frames.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let invalid = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: invalid, frameCapacity: 16)); buffer.frameLength = 16
        for channel in 0..<3 { memset(try #require(buffer.int16ChannelData)[channel], 0, 16 * 2) }
        instance._enqueueForTesting(buffer, targetFormat: target)
        await instance.drain()
        #expect(errors.count == 1 && received.frameCounts.count == 3)
        instance.stop()
    }
}

private final class ConverterSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSamples: [Float] = []
    private var storedCounts: [Int] = []
    var frameCounts: [Int] { lock.withLock { storedCounts } }
    var samples: [Float] { lock.withLock { storedSamples } }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            storedCounts.append(Int(buffer.frameLength))
            if let values = buffer.floatChannelData {
                storedSamples += Array(UnsafeBufferPointer(start: values[0], count: Int(buffer.frameLength)))
            }
        }
    }
}

private final class ReferencePCMInput: @unchecked Sendable {
    private let lock = NSLock()
    private let signal: [Float]
    private let format: AVAudioFormat
    private var position = 0
    private var suppliedRanges: [Range<Int>] = []
    init(signal: [Float], format: AVAudioFormat) { self.signal = signal; self.format = format }
    var cursor: Int { lock.withLock { position } }
    var ranges: [Range<Int>] { lock.withLock { suppliedRanges } }
    func next(_ requested: AVAudioPacketCount) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard position < signal.count, requested > 0 else { return nil }
            let end = min(signal.count, position + Int(requested))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - position)),
                  let samples = buffer.floatChannelData else {
                Issue.record("Reference PCM allocation failed"); return nil
            }
            buffer.frameLength = buffer.frameCapacity
            for index in position..<end { samples[0][index - position] = signal[index] }
            suppliedRanges.append(position..<end); position = end
            return buffer
        }
    }
}
