// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation

/// Carries audio across a segment rotation. The old segment stops taking audio
/// at one instant, the cutoff, which is also the new segment's origin. Audio
/// that arrives after the cutoff is held per source until the new segment's
/// writer for that source attaches, so the new segment begins with what was
/// captured rather than with padding, and nothing falls between the two.
public final class AudioRotationHandoff: @unchecked Sendable {
    /// Held audio is bounded. Past this, the new writer pads the gap honestly.
    static let maximumHeldSeconds: Double = 5

    private let lock = NSLock()
    private var _cutoff: CMTime?
    private var streams: [String: AudioHandoffStream] = [:]
    private var releases: [String: @MainActor () -> Void] = [:]
    private var discarded = false

    public init() {}

    /// The old segment's cutoff and the new segment's origin, once handed off.
    public var cutoff: CMTime? { lock.withLock { _cutoff } }

    func setCutoff(_ time: CMTime) {
        lock.withLock { if _cutoff == nil, time.isNumeric { _cutoff = time } }
    }

    /// The old segment hands off one source. `release` runs if no new writer
    /// claims it, so the source stops delivering into a closed handoff.
    func stream(for sourceID: String, release: (@MainActor () -> Void)? = nil) -> AudioHandoffStream? {
        lock.withLock {
            guard !discarded else { return nil }
            let stream = streams[sourceID] ?? AudioHandoffStream()
            streams[sourceID] = stream
            if let release { releases[sourceID] = release }
            return stream
        }
    }

    /// The new segment claims a source once; its held audio goes to that writer first.
    func claim(_ sourceID: String) -> AudioHandoffStream? {
        lock.withLock {
            guard !discarded else { return nil }
            releases[sourceID] = nil
            return streams.removeValue(forKey: sourceID)
        }
    }

    /// The rotation is over. Unclaimed audio is dropped and its source released.
    /// Claimed streams keep forwarding to their new writers.
    @MainActor
    func discard() {
        let unclaimed = lock.withLock { () -> [(AudioHandoffStream, (@MainActor () -> Void)?)] in
            discarded = true
            let pending = streams.map { ($0.value, releases[$0.key]) }
            streams.removeAll()
            releases.removeAll()
            return pending
        }
        for (stream, release) in unclaimed {
            stream.close()
            release?()
        }
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal func _heldSecondsForTesting(_ sourceID: String) -> Double {
        lock.withLock { streams[sourceID] }?.heldSeconds ?? 0
    }
#endif
}

/// One source's audio between the cutoff and its new writer. Held audio is
/// copied (so the capture's buffers are released at once) and coalesced into
/// contiguous chunks, so the flush is a few writer jobs, not one per buffer.
final class AudioHandoffStream: @unchecked Sendable {
    private struct Chunk {
        let pcm: AVAudioPCMBuffer
        let start: CMTime
        var end: CMTime { CMTimeAdd(start, CMTime(value: Int64(pcm.frameLength), timescale: CMTimeScale(pcm.format.sampleRate))) }
    }

    private static let chunkSeconds = 0.5
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var heldFrames: [Double: Int] = [:]
    private var forwardPCM: ((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)?
    private var forwardSample: ((CMSampleBuffer) -> Void)?
    private var closed = false

    var heldSeconds: Double {
        lock.withLock { heldFrames.reduce(0) { $0 + Double($1.value) / $1.key } }
    }

    /// Microphone audio: mono PCM with its presentation time.
    func receive(pcm buffer: AVAudioPCMBuffer, at time: CMTime) -> AudioWriteReceipt? {
        lock.withLock {
            guard !closed else { return nil }
            if let forwardPCM { return forwardPCM(buffer, time) }
            hold(buffer, at: time)
            return nil
        }
    }

    /// System audio: a captured sample buffer, copied out before it is held.
    func receive(sample buffer: CMSampleBuffer) {
        lock.withLock {
            guard !closed else { return }
            if let forwardSample { forwardSample(buffer); return }
            guard let pcm = Self.pcm(from: buffer) else { return }
            hold(pcm, at: CMSampleBufferGetPresentationTimeStamp(buffer))
        }
    }

    /// Flush held audio into the microphone writer, then forward what follows.
    func attach(pcm forward: @escaping (AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?) {
        lock.withLock {
            guard !closed else { return }
            for chunk in takeChunks() { _ = forward(chunk.pcm, chunk.start) }
            forwardPCM = forward
        }
    }

    /// Flush held audio into the system writer, then forward what follows.
    func attach(sample forward: @escaping (CMSampleBuffer) -> Void) {
        lock.withLock {
            guard !closed else { return }
            for chunk in takeChunks() {
                if let sample = Self.sampleBuffer(from: chunk.pcm, presentationTime: chunk.start) { forward(sample) }
            }
            forwardSample = forward
        }
    }

    func close() {
        lock.withLock {
            closed = true
            chunks.removeAll()
            heldFrames.removeAll()
            forwardPCM = nil
            forwardSample = nil
        }
    }

    private func takeChunks() -> [Chunk] {
        let taken = chunks
        chunks.removeAll()
        heldFrames.removeAll()
        return taken
    }

    private func hold(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        guard frames > 0, rate > 0, time.isNumeric else { return }
        let held = heldFrames.reduce(0) { $0 + Double($1.value) / $1.key }
        guard held + Double(frames) / rate <= AudioRotationHandoff.maximumHeldSeconds else { return }
        // A contiguous buffer of the same format extends the last chunk in place.
        if let last = chunks.last, last.pcm.format.isEqual(buffer.format),
           abs(CMTimeSubtract(time, last.end).seconds) <= SingleTrackAudioWriter.timestampJitterTolerance,
           Self.append(buffer, to: last.pcm) {
        } else {
            let capacity = max(AVAudioFrameCount(rate * Self.chunkSeconds), buffer.frameLength)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: capacity),
                  Self.append(buffer, to: chunk) else { return }
            chunks.append(Chunk(pcm: chunk, start: time))
        }
        heldFrames[rate, default: 0] += frames
    }

    /// Appends `buffer`'s frames after `chunk`'s, for any linear PCM layout.
    private static func append(_ buffer: AVAudioPCMBuffer, to chunk: AVAudioPCMBuffer) -> Bool {
        let bytesPerFrame = Int(chunk.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, chunk.frameCapacity - chunk.frameLength >= buffer.frameLength else { return false }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
        guard source.count == destination.count else { return false }
        let offset = Int(chunk.frameLength) * bytesPerFrame
        let size = Int(buffer.frameLength) * bytesPerFrame
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  Int(source[index].mDataByteSize) >= size else { return false }
            memcpy(dst.advanced(by: offset), src, size)
        }
        chunk.frameLength += buffer.frameLength
        for index in destination.indices { destination[index].mDataByteSize = UInt32(Int(chunk.frameLength) * bytesPerFrame) }
        return true
    }

    static func pcm(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { return nil }
        return pcm
    }

    static func sampleBuffer(from pcm: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        guard pcm.frameLength > 0 else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
                sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
              let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}
