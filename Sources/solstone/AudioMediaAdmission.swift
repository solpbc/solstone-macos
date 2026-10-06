// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFAudio
import CoreMedia
import Foundation

/// Application-owned PCM limits shared by every still-owned segment of a
/// persistent source. Encoder-internal allocations are outside this bound.
public final class AudioMediaBudget: @unchecked Sendable {
    internal enum Stage: Int, CaseIterable { case raw, writer, temporary }
    internal struct Usage: Sendable {
        var bytes = 0
        var equivalentFrames = 0
        var jobs = 0
        var peakBytes = 0
        var peakJobs = 0
    }
    internal static let bytesPerStage = 4 * 1_024 * 1_024
    internal static let framesPerStage = 4 * 48_000
    internal static let jobsPerStage = 64
    private let lock = NSLock()
    private var usage = Array(repeating: Usage(), count: Stage.allCases.count)
    private var peakTotalBytes = 0

    public init() {}

    internal func reserve(_ stage: Stage, bytes: Int, equivalentFrames: Int = 0) -> AudioMediaLease? {
        lock.withLock {
            let current = usage[stage.rawValue]
            let jobLimit = stage == .temporary ? 8 : Self.jobsPerStage
            guard bytes > 0, bytes <= Self.bytesPerStage,
                  equivalentFrames >= 0, equivalentFrames <= Self.framesPerStage,
                  current.bytes <= Self.bytesPerStage - bytes,
                  current.equivalentFrames <= Self.framesPerStage - equivalentFrames,
                  current.jobs < jobLimit else { return nil }
            usage[stage.rawValue].bytes += bytes
            usage[stage.rawValue].equivalentFrames += equivalentFrames
            usage[stage.rawValue].jobs += 1
            usage[stage.rawValue].peakBytes = max(current.peakBytes, usage[stage.rawValue].bytes)
            usage[stage.rawValue].peakJobs = max(current.peakJobs, usage[stage.rawValue].jobs)
            peakTotalBytes = max(peakTotalBytes, usage.reduce(0) { $0 + $1.bytes })
            return AudioMediaLease(budget: self, stage: stage, bytes: bytes, equivalentFrames: equivalentFrames)
        }
    }

    fileprivate func release(_ stage: Stage, bytes: Int, equivalentFrames: Int) {
        lock.withLock {
            usage[stage.rawValue].bytes -= bytes
            usage[stage.rawValue].equivalentFrames -= equivalentFrames
            usage[stage.rawValue].jobs -= 1
        }
    }

    internal var snapshot: (stages: [Usage], peakTotalBytes: Int) {
        lock.withLock { (usage, peakTotalBytes) }
    }
}

internal final class AudioMediaLease: @unchecked Sendable {
    let budget: AudioMediaBudget
    private let stage: AudioMediaBudget.Stage
    private let bytes: Int
    private let equivalentFrames: Int
    private let lock = NSLock()
    private var released = false

    fileprivate init(budget: AudioMediaBudget, stage: AudioMediaBudget.Stage, bytes: Int, equivalentFrames: Int) {
        self.budget = budget; self.stage = stage; self.bytes = bytes; self.equivalentFrames = equivalentFrames
    }
    func release() {
        let releaseNow = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if releaseNow { budget.release(stage, bytes: bytes, equivalentFrames: equivalentFrames) }
    }
    deinit { release() }
}

/// Validates capacity before allocating PCM. The frame limit is expressed in
/// elapsed input time so a96k source gets the same duration as a44.1k source.
internal struct AudioPCMExtent {
    let frames: Int
    let bytes: Int
    let equivalentFrames: Int

    init?(frames: Int, asbd: AudioStreamBasicDescription) {
        guard frames > 0, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate >= 1, asbd.mSampleRate <= 192_000,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 64,
              asbd.mBytesPerFrame > 0, asbd.mBytesPerFrame <= 256 else { return nil }
        let duration = Double(frames) / asbd.mSampleRate
        guard duration.isFinite, duration <= 1 else { return nil }
        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(asbd.mChannelsPerFrame)
        let (frameBytes, frameOverflow) = Int(asbd.mBytesPerFrame).multipliedReportingOverflow(by: planes)
        let (bytes, overflow) = frames.multipliedReportingOverflow(by: frameBytes)
        guard !frameOverflow, !overflow, bytes > 0, bytes <= AudioMediaBudget.bytesPerStage else { return nil }
        self.frames = frames; self.bytes = bytes
        equivalentFrames = Int(ceil(duration * 48_000))
    }
    init?(_ buffer: AVAudioPCMBuffer) {
        self.init(frames: Int(buffer.frameLength), asbd: buffer.format.streamDescription.pointee)
    }
    init?(_ buffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        self.init(frames: CMSampleBufferGetNumSamples(buffer), asbd: asbd)
    }
}

/// An observation/finish signal is distinct from native ownership and from a
/// media budget becoming empty. Completed signals may safely be reused.
internal final class AudioCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var completed = false
    private var completion: (@Sendable () -> Void)?
    init() { group.enter() }
    var isComplete: Bool { lock.withLock { completed } }
    func onComplete(_ callback: @escaping @Sendable () -> Void) {
        let immediate = lock.withLock { () -> Bool in
            if completed { return true }
            // A delivery has exactly one capture-ledger subscriber.
            precondition(completion == nil)
            completion = callback
            return false
        }
        if immediate { callback() }
    }
    func complete() {
        let result = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard !completed else { return (false, nil) }
            completed = true
            let callback = completion
            completion = nil
            return (true, callback)
        }
        if result.0 { result.1?(); group.leave() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }
    }
}

internal final class AudioWriteReceipt: @unchecked Sendable {
    weak var writer: SingleTrackAudioWriter?
    let signal = AudioCompletionSignal()
    init(writer: SingleTrackAudioWriter) { self.writer = writer }
}

/// Conversion-queue owner; at most64 charged writer jobs can remain pending.
/// A fence snapshots live tickets and enqueues native observations before
/// later conversion deliveries can enter the writers.
internal final class AudioDeliveryLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [ObjectIdentifier: AudioWriteReceipt] = [:]
    func register(_ receipt: AudioWriteReceipt) {
        let identity = ObjectIdentifier(receipt)
        lock.withLock { pending[identity] = receipt }
        receipt.signal.onComplete { [weak self] in
            guard let self else { return }
            _ = self.lock.withLock { self.pending.removeValue(forKey: identity) }
        }
    }
    func observation() -> AudioDeliveryObservation {
        let receipts = lock.withLock { Array(pending.values) }
        var seen: Set<ObjectIdentifier> = []
        let fences = receipts.compactMap { receipt -> AudioCompletionSignal? in
            guard let writer = receipt.writer, seen.insert(ObjectIdentifier(writer)).inserted else { return nil }
            return writer.makeObservationFence()
        }
        return AudioDeliveryObservation(receipts: receipts, fences: fences)
    }
}

internal struct AudioDeliveryObservation: Sendable {
    let receipts: [AudioWriteReceipt]
    let fences: [AudioCompletionSignal]
    func wait() async {
        for fence in fences { await fence.wait() }
        for receipt in receipts { await receipt.signal.wait() }
    }
}

internal final class AudioCaptureDrainFence: @unchecked Sendable {
    let signal = AudioCompletionSignal()
    // Written before signal.complete, read only after awaiting that signal.
    var observation: AudioDeliveryObservation?
    func wait() async {
        await signal.wait()
        await observation?.wait()
    }
}

internal final class AudioQueuedWriterWork: @unchecked Sendable {
    var buffer: CMSampleBuffer?
    let lease: AudioMediaLease
    let receipt: AudioWriteReceipt
    var deferredForSilence = false
    init(buffer: CMSampleBuffer, lease: AudioMediaLease, receipt: AudioWriteReceipt) {
        self.buffer = buffer; self.lease = lease; self.receipt = receipt
    }
    func complete() {
        buffer = nil
        lease.release()
        receipt.signal.complete()
    }
}

internal final class AudioRawPCMWork: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
    let lease: AudioMediaLease
    init(buffer: AVAudioPCMBuffer, lease: AudioMediaLease) { self.buffer = buffer; self.lease = lease }
    func release() { buffer = nil; lease.release() }
}

internal final class AudioTemporarySampleWork {
    var buffer: CMSampleBuffer?
    let lease: AudioMediaLease
    init(buffer: CMSampleBuffer, lease: AudioMediaLease) { self.buffer = buffer; self.lease = lease }
    func release() { buffer = nil; lease.release() }
}

internal final class WeakAudioMediaBudget {
    weak var value: AudioMediaBudget?
    init(_ value: AudioMediaBudget) { self.value = value }
}
