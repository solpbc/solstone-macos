// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation

/// Carries audio across a segment rotation. The old segment stops taking audio
/// at one instant, the cutoff, which is also the new segment's origin. Audio
/// that arrives after the old segment let go of a source is split at the cutoff:
/// what was captured before it still goes to the old writer, and the rest is
/// held until the new segment's writer for that source attaches. The new
/// segment then begins with what was captured instead of padding, and nothing
/// falls between the two.
public final class AudioRotationHandoff: @unchecked Sendable {
    /// Held audio is bounded. Past this, the new writer pads the gap honestly.
    let maximumHeldSeconds: Double

    private let lock = NSLock()
    private var _cutoff: CMTime?
    private var streams: [String: AudioHandoffStream] = [:]
    private var releases: [String: @MainActor () -> Void] = [:]
    private var discarded = false

    public convenience init() { self.init(maximumHeldSeconds: 5) }

    init(maximumHeldSeconds: Double) {
        self.maximumHeldSeconds = maximumHeldSeconds
    }

    /// The old segment's cutoff and the new segment's origin, once handed off.
    public var cutoff: CMTime? { lock.withLock { _cutoff } }

    func setCutoff(_ time: CMTime) {
        lock.withLock { if _cutoff == nil, time.isNumeric { _cutoff = time } }
    }

    /// One source's stream, created by whichever side of the old segment lets go first.
    func stream(for sourceID: String) -> AudioHandoffStream? {
        lock.withLock {
            guard !discarded else { return nil }
            if let stream = streams[sourceID] { return stream }
            let stream = AudioHandoffStream(maximumHeldSeconds: maximumHeldSeconds)
            streams[sourceID] = stream
            return stream
        }
    }

    /// Runs if no new writer claims the source, so it stops delivering into a closed
    /// stream. It must undo only its own redirect, never a newer destination.
    func setRelease(for sourceID: String, _ release: @escaping @MainActor () -> Void) {
        lock.withLock { if !discarded, streams[sourceID] != nil { releases[sourceID] = release } }
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

/// One source's audio between the old segment letting go and the new writer
/// attaching. Held audio is copied (so the capture's buffers are released at
/// once) and coalesced into contiguous chunks, so the flush is a few writer
/// jobs, not one per buffer.
final class AudioHandoffStream: @unchecked Sendable {
    private struct Chunk {
        let pcm: AVAudioPCMBuffer
        let start: CMTime
        var end: CMTime { CMTimeAdd(start, CMTime(value: Int64(pcm.frameLength), timescale: CMTimeScale(pcm.format.sampleRate))) }
    }

    private enum Output {
        case pcm((AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?)
        case sample((CMSampleBuffer) -> Void)

        @discardableResult
        func send(_ pcm: AVAudioPCMBuffer, at time: CMTime) -> AudioWriteReceipt? {
            switch self {
            case .pcm(let forward): return forward(pcm, time)
            case .sample(let forward):
                if let sample = AudioHandoffStream.sampleBuffer(from: pcm, presentationTime: time) { forward(sample) }
                return nil
            }
        }
    }

    private static let chunkSeconds = 0.5
    /// Each chunk is one writer job at the flush; the writer admits 64 at once.
    private static let maximumChunks = 32
    private let maximumHeldSeconds: Double
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var heldSecondsTotal = 0.0
    private var cutoff: CMTime?
    private var predecessor: Output?
    private var successor: Output?
    private var closed = false
    private var droppedFrames = 0

    init(maximumHeldSeconds: Double) {
        self.maximumHeldSeconds = maximumHeldSeconds
    }

    var heldSeconds: Double { lock.withLock { heldSecondsTotal } }

    /// The old writer, for audio captured before the cutoff that arrives after it let go.
    func setPredecessor(cutoff: CMTime, pcm forward: @escaping (AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?) {
        setPredecessor(cutoff: cutoff, output: .pcm(forward))
    }

    func setPredecessor(cutoff: CMTime, sample forward: @escaping (CMSampleBuffer) -> Void) {
        setPredecessor(cutoff: cutoff, output: .sample(forward))
    }

    private func setPredecessor(cutoff: CMTime, output: Output) {
        lock.withLock {
            guard !closed, self.cutoff == nil, cutoff.isNumeric else { return }
            self.cutoff = cutoff
            predecessor = output
            // Anything already held arrived before the cutoff was known.
            let held = chunks
            chunks.removeAll(); heldSecondsTotal = 0
            for chunk in held { route(chunk.pcm, at: chunk.start) }
        }
    }

    /// Microphone audio: mono PCM with its presentation time.
    func receive(pcm buffer: AVAudioPCMBuffer, at time: CMTime) -> AudioWriteReceipt? {
        lock.withLock {
            guard !closed else { return nil }
            // A buffer wholly after the cutoff goes straight on, untouched.
            if case .some(.pcm(let forward)) = successor, let cutoff, time >= cutoff { return forward(buffer, time) }
            route(buffer, at: time)
            return nil
        }
    }

    /// System audio: a captured sample buffer, copied out before it is held.
    func receive(sample buffer: CMSampleBuffer) {
        lock.withLock {
            guard !closed else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            if case .some(.sample(let forward)) = successor, let cutoff, time >= cutoff { forward(buffer); return }
            guard let pcm = Self.pcm(from: buffer) else {
                droppedFrames += CMSampleBufferGetNumSamples(buffer); return
            }
            route(pcm, at: time)
        }
    }

    /// Flush held audio into the new microphone writer, then forward what follows.
    /// Returns the frames this stream could not carry, for the new segment's record.
    @discardableResult
    func attach(pcm forward: @escaping (AVAudioPCMBuffer, CMTime) -> AudioWriteReceipt?) -> Int {
        attach(.pcm(forward))
    }

    @discardableResult
    func attach(sample forward: @escaping (CMSampleBuffer) -> Void) -> Int {
        attach(.sample(forward))
    }

    private func attach(_ output: Output) -> Int {
        lock.withLock {
            guard !closed else { return 0 }
            let held = chunks
            chunks.removeAll(); heldSecondsTotal = 0
            for chunk in held { output.send(chunk.pcm, at: chunk.start) }
            successor = output
            return droppedFrames
        }
    }

    func close() {
        lock.withLock {
            closed = true
            chunks.removeAll(); heldSecondsTotal = 0
            predecessor = nil; successor = nil
        }
    }

    /// Splits at the cutoff: the earlier part to the old writer, the rest held or forwarded.
    private func route(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        let rate = buffer.format.sampleRate
        guard buffer.frameLength > 0, rate > 0, time.isNumeric else { return }
        var remainder = buffer, start = time
        if let cutoff, time < cutoff {
            // Round up, so the held part never starts before the new origin (it would be trimmed).
            let before = min(Int(buffer.frameLength), Int(ceil(CMTimeSubtract(cutoff, time).seconds * rate)))
            if before > 0, let head = Self.slice(buffer, from: 0, count: before) { predecessor?.send(head, at: time) }
            guard before < Int(buffer.frameLength),
                  let tail = Self.slice(buffer, from: before, count: Int(buffer.frameLength) - before) else { return }
            remainder = tail
            start = CMTimeAdd(time, CMTime(value: Int64(before), timescale: CMTimeScale(rate)))
        }
        if let successor { successor.send(remainder, at: start); return }
        hold(remainder, at: start)
    }

    private func hold(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        let rate = buffer.format.sampleRate
        let seconds = Double(buffer.frameLength) / rate
        guard heldSecondsTotal + seconds <= maximumHeldSeconds else { droppedFrames += Int(buffer.frameLength); return }
        // A contiguous buffer of the same format extends the last chunk in place.
        if let last = chunks.last, last.pcm.format.isEqual(buffer.format),
           abs(CMTimeSubtract(time, last.end).seconds) <= SingleTrackAudioWriter.timestampJitterTolerance,
           Self.append(buffer, to: last.pcm) {
        } else {
            let remaining = AVAudioFrameCount(max(0, (maximumHeldSeconds - heldSecondsTotal) * rate))
            let capacity = max(min(AVAudioFrameCount(rate * Self.chunkSeconds), remaining), buffer.frameLength)
            guard chunks.count < Self.maximumChunks,
                  let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: capacity),
                  Self.append(buffer, to: chunk) else { droppedFrames += Int(buffer.frameLength); return }
            chunks.append(Chunk(pcm: chunk, start: time))
        }
        heldSecondsTotal += seconds
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
        return true
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, from start: Int, count: Int) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        guard count > 0, bytesPerFrame > 0, start + count <= Int(buffer.frameLength),
              let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        part.frameLength = AVAudioFrameCount(count)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData else { return nil }
            memcpy(dst, src.advanced(by: start * bytesPerFrame), count * bytesPerFrame)
        }
        return part
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
