// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import ObjCHelpers
import os

/// Track type for audio recording
public enum AudioTrackType: Sendable, Equatable {
    case systemAudio
    case microphone(name: String, deviceUID: String)

    public static let systemSourceID = "system"

    public var displayName: String {
        switch self {
        case .systemAudio:
            return "System Audio"
        case let .microphone(name, _):
            return name
        }
    }

    /// Returns the device UID for microphones, "system" for system audio
    public var sourceID: String {
        switch self {
        case .systemAudio:
            return Self.systemSourceID
        case let .microphone(_, deviceUID):
            return deviceUID
        }
    }
}

/// Timing information for a track, used during remix
public struct AudioTrackTimingInfo: Sendable {
    /// When this track started relative to segment start
    public let startOffset: CMTime
    /// When this track ended relative to segment start
    public let endOffset: CMTime
    /// The track type
    public let trackType: AudioTrackType
    /// Whether any audio was actually written to this track
    public let hasAudio: Bool

    public init(startOffset: CMTime, endOffset: CMTime, trackType: AudioTrackType, hasAudio: Bool = true) {
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.trackType = trackType
        self.hasAudio = hasAudio
    }
}

public struct AudioRecordingFailure: Codable, Sendable, Equatable {
    public let stage: String
    public let domain: String
    public let code: Int
    public var count: Int = 1
}

public struct AudioWriterStatistics: Codable, Sendable {
    public var receivedFrames: Int = 0
    public var acceptedFrames: Int = 0
    public var droppedFrames: Int = 0
    public var writerStatus: String = "recording"
    public var failures: [AudioRecordingFailure] = []
    /// Accepted zero PCM synthesized to preserve elapsed placement, not capture.
    public var generatedFrames: Int?
    public var gapCount: Int?
    /// Absent in older evidence. Incomplete counters are observed lower bounds.
    public var statisticsAvailable: Bool?
    public var statisticsComplete: Bool?
    enum CodingKeys: String, CodingKey {
        case receivedFrames = "received_frames", acceptedFrames = "accepted_frames"
        case droppedFrames = "dropped_frames", writerStatus = "writer_status", failures
        case statisticsAvailable = "statistics_available", statisticsComplete = "statistics_complete"
        case generatedFrames = "generated_frames", gapCount = "gap_count"
    }
}

/// Writes audio from a single source to its own M4A file
/// Tracks timing offset for later remix alignment
public final class SingleTrackAudioWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let outputURL: URL
    private let trackType: AudioTrackType
    private let segmentStartTime: CMTime
    private let verbose: Bool
    private let onStatistics: (@Sendable (AudioWriterStatistics) -> Void)?
    private var statistics = AudioWriterStatistics(generatedFrames: 0, gapCount: 0, statisticsAvailable: true, statisticsComplete: false)
    // Native append/finalization may hold `lock` indefinitely. Evidence and
    // ownership queries never acquire it or call AVFoundation.
    private let snapshotLock = NSLock()
    private var publishedStatistics = AudioWriterStatistics(generatedFrames: 0, gapCount: 0, statisticsAvailable: true, statisticsComplete: false)
    private var nativeQuiescent = false
    public let mediaBudget: AudioMediaBudget
    private let nativeQueue = DispatchQueue(label: "app.solstone.audio.native", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var admissionClosed = false
    private var admissionTerminal = false
    private var windowAdmitted = false
    private var admissionOrdinal: UInt64 = 0
    private var observationFence: (ordinal: UInt64, signal: AudioCompletionSignal)?
    private var admittedReceived = 0
    private var admittedDropped = 0
    private var admittedFailures: [AudioRecordingFailure] = []
    private var captureCountersIncomplete = false
    private var backendStatistics = AudioWriterStatistics(generatedFrames: 0, gapCount: 0, statisticsAvailable: true, statisticsComplete: false)
    private let reportQueue = DispatchQueue(label: "app.solstone.audio.evidence", qos: .utility)
    private var reportPending = false
    // Native-queue work remains charged until its captured-silence batch has
    // actually been accepted or failed, including a short observation batch.
    private var pendingSilentWork: [AudioQueuedWriterWork] = []
    private var retiredSilentWork: [AudioQueuedWriterWork] = []

    private var sessionStarted = false
    private var isFinished = false
    private var firstBufferTime: CMTime?
    private var lastBufferTime: CMTime?
    private let lock = NSLock()
    private var timelineFailed = false
    private var lastFormat: CMFormatDescription?
    private var lastSampleRate: Double = 48_000
    // A segment is normally five minutes; the extra minute admits shutdown
    // latency without allowing an invalid timestamp to allocate arbitrary PCM.
    private static let maximumTimelineSeconds = 360.0
#if DEBUG || SOLSTONE_TEST_SUPPORT
    internal private(set) var _appendAttemptCountForTesting: Int = 0
    internal var _fragmentIntervalsForTesting: (CMTime, CMTime) { (writer.movieFragmentInterval, writer.initialMovieFragmentInterval) }
    internal var _acceptedFramesForTesting: Int { statisticsSnapshot.acceptedFrames }
    internal var _finishAdmissionHookForTesting: (@Sendable () async -> Void)?
    internal var _nativeAppendHookForTesting: (@Sendable () -> Void)?
    internal var _nativeStartWritingHookForTesting: (@Sendable () -> Void)?
    internal var _nativeStartSessionHookForTesting: (@Sendable () -> Void)?
    internal var _copyAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _reportAdmissionHookForTesting: (@Sendable () -> Void)?
    internal var _paddingAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _boundaryClipAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _appendAdmissionForTesting: (@Sendable (Int) -> Bool)?
    internal var _silentBufferAdmissionForTesting: (@Sendable (Int, CMTime) -> Bool)?
    internal var _segmentStartTimeForTesting: CMTime { segmentStartTime }
    internal func _clipBoundaryForTesting(_ buffer: CMSampleBuffer, skipping: Int) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(buffer) else { return nil }
        return clipBoundary(buffer, skipping: skipping, frames: CMSampleBufferGetNumSamples(buffer) - skipping, format: format)
    }
#endif

    // Silence batching state
    private var silenceStartTime: CMTime?
    private var silenceAccumulatedSamples: Int = 0
    private var lastSilentBufferFormat: CMFormatDescription?
    private var lastSilentBufferSampleRate: Double = 48000

    /// RMS threshold below which audio is considered silent (approx -60dB)
    /// Very conservative to avoid cutting real audio
    private static let silenceThreshold: Float = 0.001

    /// Maximum silence duration before forcing a flush (1 second worth of samples at 48kHz)
    private static let maxSilenceSamples: Int = 48000

    public var onComplete: (() -> Void)?

    /// Audio settings for output (AAC, 48kHz, mono)
    private static nonisolated(unsafe) let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]

    /// Target sample rate for all tracks
    public static let targetSampleRate: Double = 48_000

    /// Creates a single-track audio writer
    /// - Parameters:
    ///   - url: Output file URL (.m4a)
    ///   - trackType: The type of audio track
    ///   - segmentStartTime: The segment's start time (for offset calculation)
    ///   - verbose: Enable verbose logging
    public init(url: URL, trackType: AudioTrackType, segmentStartTime: CMTime, verbose: Bool = false,
                mediaBudget: AudioMediaBudget = AudioMediaBudget(),
                onStatistics: (@Sendable (AudioWriterStatistics) -> Void)? = nil) throws {
        // Remove existing file if present
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        self.writer = try AVAssetWriter(url: url, fileType: .m4a)
        self.writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        self.writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        self.outputURL = url
        self.trackType = trackType
        self.segmentStartTime = segmentStartTime
        self.verbose = verbose
        self.onStatistics = onStatistics
        self.mediaBudget = mediaBudget

        // Create the single audio input
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SingleTrackAudioWriterError.cannotAddInput
        }

        writer.add(input)
        self.input = input

        Logger.audio.info("Created audio writer: \(trackType.displayName, privacy: .public) -> \(url.lastPathComponent, privacy: .public)")
    }

    /// Appends audio from a CMSampleBuffer (from SCStream)
    /// Uses silence batching to reduce encoder invocations during quiet periods
    /// - Parameter sampleBuffer: The audio sample buffer
    public func appendAudio(_ capturedBuffer: CMSampleBuffer) {
        appendAudio(capturedBuffer, queuedWork: nil)
        completeRetiredSilence()
    }

    /// Capture destinations copy/admit bounded media here; native start and
    /// append run exclusively after this method has released routing locks.
    @discardableResult
    internal func enqueueAudio(_ buffer: CMSampleBuffer) -> AudioWriteReceipt? {
        enqueueAudio(buffer, ownsPCM: false)
    }

    @discardableResult
    internal func enqueuePCMBuffer(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) -> AudioWriteReceipt? {
        guard buffer.frameLength > 0 else { return nil }
        guard let extent = AudioPCMExtent(buffer), buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let temporary = mediaBudget.reserve(.temporary, bytes: extent.bytes) else {
            rejectUnpreparedPCM(buffer, presentationTime: presentationTime, stage: "admission_size")
            return nil
        }
        var sample: CMSampleBuffer?
        var receipt: AudioWriteReceipt?
        autoreleasepool {
            sample = createSampleBuffer(from: buffer, presentationTime: presentationTime)
            if let sample { receipt = enqueueAudio(sample, ownsPCM: true) }
            else { rejectUnpreparedPCM(buffer, presentationTime: presentationTime, stage: "admission_copy") }
        }
        sample = nil
        temporary.release()
        return receipt
    }

    private func rejectUnpreparedPCM(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime, stage: String) {
        // Construct timing only, so an allocation failure still counts exactly
        // the in-window suffix. This never copies or retains producer PCM.
        admissionLock.withLock {
            guard !admissionClosed else { return }
            let total = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            var eligible = total
            if presentationTime.isNumeric, rate.isFinite, rate >= 1, rate <= 192_000,
               !windowAdmitted, CMTimeSubtract(presentationTime, segmentStartTime).seconds >= -1,
               presentationTime < segmentStartTime {
                let first = CMTimeConvertScale(CMTimeSubtract(segmentStartTime, presentationTime),
                    timescale: Int32(rate), method: .roundTowardPositiveInfinity)
                var skipped = min(total, max(0, Int(first.value)))
                func sampleTime(_ index: Int) -> CMTime {
                    CMTimeAdd(presentationTime, CMTime(value: Int64(index), timescale: Int32(rate)))
                }
                if skipped > 0, sampleTime(skipped - 1) >= segmentStartTime { skipped -= 1 }
                if skipped < total, sampleTime(skipped) < segmentStartTime { skipped += 1 }
                eligible -= skipped
            }
            guard eligible > 0 else { return }
            admissionTerminal = true
            noteAdmission(frames: eligible, dropped: eligible, stage: stage)
        }
    }

    private func enqueueAudio(_ captured: CMSampleBuffer, ownsPCM: Bool) -> AudioWriteReceipt? {
        admissionLock.withLock {
            guard !admissionClosed else { return nil }
            let count = CMSampleBufferGetNumSamples(captured)
            guard count > 0 else { return nil }
            let time = CMSampleBufferGetPresentationTimeStamp(captured)
            let relative = CMTimeSubtract(time, segmentStartTime).seconds
            guard let extent = AudioPCMExtent(captured), time.isNumeric, relative.isFinite,
                  relative + sampleDuration(captured).seconds <= Self.maximumTimelineSeconds,
                  let format = CMSampleBufferGetFormatDescription(captured),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
                admissionTerminal = true
                noteAdmission(frames: count, dropped: count, stage: "admission_size")
                return nil
            }
            var skipped = 0
            if relative < 0 {
                guard !windowAdmitted, relative >= -1 else {
                    admissionTerminal = true
                    noteAdmission(frames: count, dropped: count, stage: "timeline")
                    return nil
                }
                let offset = CMTimeConvertScale(CMTimeSubtract(segmentStartTime, time),
                    timescale: Int32(asbd.mSampleRate), method: .roundTowardPositiveInfinity)
                skipped = min(count, max(0, Int(offset.value)))
                if skipped > 0 {
                    var previous = CMSampleTimingInfo()
                    if CMSampleBufferGetSampleTimingInfo(captured, at: skipped - 1, timingInfoOut: &previous) == noErr,
                       previous.presentationTimeStamp >= segmentStartTime { skipped -= 1 }
                }
                if skipped < count {
                    var first = CMSampleTimingInfo()
                    if CMSampleBufferGetSampleTimingInfo(captured, at: skipped, timingInfoOut: &first) == noErr,
                       first.presentationTimeStamp < segmentStartTime { skipped += 1 }
                }
            }
            let eligible = count - skipped
            guard eligible > 0 else { return nil }
            noteAdmission(frames: eligible)
            guard !admissionTerminal else {
                noteAdmission(frames: 0, dropped: eligible, stage: "admission_terminal")
                return nil
            }
            // Charge the entire retained owned block, even if a later logical
            // view could contain fewer frames. System input always gets a copy.
            let retainedBytes = ownsPCM && skipped == 0
                ? max(extent.bytes, CMSampleBufferGetDataBuffer(captured).map { CMBlockBufferGetDataLength($0) } ?? 0)
                : eligible * (extent.bytes / extent.frames)
            let equivalent = Int(ceil(Double(eligible) * 48_000 / asbd.mSampleRate))
            guard admissionOrdinal < UInt64.max,
                  let lease = mediaBudget.reserve(.writer, bytes: retainedBytes, equivalentFrames: equivalent) else {
                admissionTerminal = true
                noteAdmission(frames: 0, dropped: eligible, stage: "admission_queue")
                return nil
            }
            var admitted: CMSampleBuffer?
            if ownsPCM && skipped == 0 { admitted = captured }
            else {
                guard let temporary = mediaBudget.reserve(.temporary, bytes: retainedBytes * 2) else {
                    lease.release(); admissionTerminal = true
                    noteAdmission(frames: 0, dropped: eligible, stage: "admission_copy_budget")
                    return nil
                }
                autoreleasepool {
#if DEBUG || SOLSTONE_TEST_SUPPORT
                    if _copyAdmissionForTesting?(retainedBytes) == false { return }
#endif
                    admitted = clipBoundary(captured, skipping: skipped, frames: eligible, format: format)
                }
                // The admitted backing block is now charged to the writer;
                // temporary PCM staging has been destroyed by this point.
                temporary.release()
            }
            guard let admitted else {
                lease.release(); admissionTerminal = true
                noteAdmission(frames: 0, dropped: eligible, stage: skipped > 0 ? "boundary_clip" : "admission_copy")
                return nil
            }
            windowAdmitted = true
            admissionOrdinal += 1
            let receipt = AudioWriteReceipt(writer: self)
            let work = AudioQueuedWriterWork(buffer: admitted, lease: lease, receipt: receipt)
            nativeQueue.async { [self] in
                autoreleasepool {
                    if let buffer = work.buffer { appendAudio(buffer, queuedWork: work) }
                }
                if !work.deferredForSilence { work.complete() }
                completeRetiredSilence()
            }
            return receipt
        }
    }

    private func appendAudio(_ capturedBuffer: CMSampleBuffer, queuedWork: AudioQueuedWriterWork?) {
        lock.lock()

        if isFinished {
            lock.unlock()
            return
        }

        var sampleBuffer = capturedBuffer
        var numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { lock.unlock(); return }
        var currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var duration = sampleDuration(sampleBuffer)
        var relative = CMTimeSubtract(currentTime, segmentStartTime).seconds
        guard !timelineFailed, currentTime.isNumeric, duration.isNumeric, duration.seconds > 0,
              relative.isFinite,
              relative + duration.seconds <= Self.maximumTimelineSeconds,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate.isFinite, asbd.mSampleRate >= 1, asbd.mSampleRate <= 192_000,
              asbd.mBytesPerFrame > 0, asbd.mBytesPerFrame <= 256,
              asbd.mChannelsPerFrame > 0, asbd.mChannelsPerFrame <= 64 else {
            if queuedWork == nil { statistics.receivedFrames += numSamples }
            recordFailure(stage: "timeline", error: nil, dropped: numSamples)
            lock.unlock(); return
        }
        if relative < 0 {
            // A persistent tap can straddle a newly attached segment. Only its
            // in-window suffix belongs to this writer; keep the capture clock.
            guard !sessionStarted, relative >= -1 else {
                if queuedWork == nil { statistics.receivedFrames += numSamples }
                recordFailure(stage: "timeline", error: nil, dropped: numSamples)
                lock.unlock(); return
            }
            let skippedTime = CMTimeConvertScale(CMTimeSubtract(segmentStartTime, currentTime),
                timescale: Int32(asbd.mSampleRate), method: .roundTowardPositiveInfinity)
            var skipped = min(numSamples, max(0, Int(skippedTime.value)))
            // Rational host/sample additions can round by a clock tick. Check
            // the adjacent actual sample PTS rather than excluding one too many.
            if skipped > 0 {
                var previous = CMSampleTimingInfo()
                if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: skipped - 1, timingInfoOut: &previous) == noErr,
                   previous.presentationTimeStamp >= segmentStartTime { skipped -= 1 }
            }
            if skipped < numSamples {
                var first = CMSampleTimingInfo()
                if CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: skipped, timingInfoOut: &first) == noErr,
                   first.presentationTimeStamp < segmentStartTime { skipped += 1 }
            }
            numSamples -= skipped
            guard numSamples > 0 else { lock.unlock(); return }
            guard let clipped = clipBoundary(sampleBuffer, skipping: skipped, frames: numSamples, format: format) else {
                if queuedWork == nil { statistics.receivedFrames += numSamples }
                recordFailure(stage: "boundary_clip", error: nil, dropped: numSamples)
                lock.unlock(); return
            }
            sampleBuffer = clipped
            currentTime = CMSampleBufferGetPresentationTimeStamp(clipped)
            duration = sampleDuration(clipped)
            relative = CMTimeSubtract(currentTime, segmentStartTime).seconds
        }
        if queuedWork == nil { statistics.receivedFrames += numSamples }
        publishStatistics()
        if !sessionStarted {
#if DEBUG || SOLSTONE_TEST_SUPPORT
            _nativeStartWritingHookForTesting?()
#endif
            guard writer.status == .unknown, writer.startWriting() else {
                recordFailure(stage: "start", error: writer.error, dropped: numSamples)
                lock.unlock()
                return
            }
            do {
#if DEBUG || SOLSTONE_TEST_SUPPORT
                _nativeStartSessionHookForTesting?()
#endif
                try ObjCExceptionCatcher.`try` { writer.startSession(atSourceTime: .zero) }
            } catch {
                recordFailure(stage: "start", error: error, dropped: numSamples)
                lock.unlock()
                return
            }
            sessionStarted = true
            // Raw media and durable source origin share the segment clock.
            firstBufferTime = segmentStartTime
        }
        let firstTime = segmentStartTime
        let priorEnd = lastBufferTime ?? segmentStartTime
        let gap = CMTimeSubtract(currentTime, priorEnd).seconds
        guard gap >= -1.0 / asbd.mSampleRate else {
            recordFailure(stage: "timeline", error: nil, dropped: numSamples)
            lock.unlock(); return
        }
        if gap > 0.5 / asbd.mSampleRate {
            if silenceAccumulatedSamples > 0 { flushSilence(firstTime: firstTime) }
            guard appendPadding(from: priorEnd, to: currentTime, format: format, rate: asbd.mSampleRate) else {
                timelineFailed = true
                recordFailure(stage: "padding", error: nil, dropped: numSamples)
                lock.unlock(); return
            }
        }
        lastFormat = format; lastSampleRate = asbd.mSampleRate
        lastBufferTime = CMTimeAdd(currentTime, duration)
        // Check if this buffer is silent
        let isSilent = isBufferSilent(sampleBuffer)

        if isSilent {
            if let queuedWork {
                queuedWork.deferredForSilence = true
                pendingSilentWork.append(queuedWork)
            }
            // Start or continue silence accumulation
            if silenceStartTime == nil {
                silenceStartTime = currentTime
            }
            silenceAccumulatedSamples += numSamples

            // Cache format for creating silent buffer later
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                lastSilentBufferFormat = format
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    lastSilentBufferSampleRate = asbd.mSampleRate
                }
            }

            // Check if we should flush (max silence duration reached)
            let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(asbd.mChannelsPerFrame)
            let byteLimit = (AudioMediaBudget.bytesPerStage / 2) / (Int(asbd.mBytesPerFrame) * planes)
            let batchFrames = min(Self.maxSilenceSamples, Int(ceil(asbd.mSampleRate)), max(1, byteLimit))
            if silenceAccumulatedSamples >= batchFrames {
                flushSilence(firstTime: firstTime)
            }

            lock.unlock()
            return
        }

        // Non-silent buffer - flush any accumulated silence first
        if silenceAccumulatedSamples > 0 {
            flushSilence(firstTime: firstTime)
        }

        let adjustedTime = CMTimeSubtract(currentTime, firstTime)
        if let retimedBuffer = createRetimedSampleBuffer(sampleBuffer, newTime: adjustedTime) {
            appendChecked(retimedBuffer, frames: numSamples)
        } else { recordFailure(stage: "retime", error: nil, dropped: numSamples) }
        lock.unlock()
    }

    /// Check if a sample buffer contains silence (RMS below threshold)
    private func isBufferSilent(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return false
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer, length > 0 else {
            return false
        }

        // Determine sample format from format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return false
        }

        // Calculate RMS based on format
        let rms: Float
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float format
            let floatPtr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            let sampleCount = length / MemoryLayout<Float>.size
            var sumSquares: Float = 0
            for i in 0..<sampleCount {
                let sample = floatPtr[i]
                sumSquares += sample * sample
            }
            rms = sqrt(sumSquares / Float(max(1, sampleCount)))
        } else if asbd.mBitsPerChannel == 16 {
            // Int16 format
            let int16Ptr = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            let sampleCount = length / MemoryLayout<Int16>.size
            var sumSquares: Float = 0
            for i in 0..<sampleCount {
                let sample = Float(int16Ptr[i]) / 32768.0
                sumSquares += sample * sample
            }
            rms = sqrt(sumSquares / Float(max(1, sampleCount)))
        } else {
            // Unknown format, assume not silent
            return false
        }

        return rms < Self.silenceThreshold
    }

    /// Flush accumulated silence in bounded buffers without discarding its tail
    /// Must be called with lock held
    private func flushSilence(firstTime: CMTime) {
        let frames = silenceAccumulatedSamples
        defer {
            silenceStartTime = nil; silenceAccumulatedSamples = 0
            retiredSilentWork += pendingSilentWork
            pendingSilentWork.removeAll(keepingCapacity: true)
        }
        guard frames > 0, let startTime = silenceStartTime, let formatDesc = lastSilentBufferFormat,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              lastSilentBufferSampleRate.isFinite, lastSilentBufferSampleRate >= 1,
              lastSilentBufferSampleRate <= 192_000, asbd.mBytesPerFrame > 0 else {
            if frames > 0 { timelineFailed = true; recordFailure(stage: "silence", error: nil, dropped: frames) }
            return
        }
        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(asbd.mChannelsPerFrame)
        let byteFrames = (AudioMediaBudget.bytesPerStage / 2) / (Int(asbd.mBytesPerFrame) * planes)
        let chunkLimit = min(Int(lastSilentBufferSampleRate.rounded(.down)), byteFrames)
        guard chunkLimit > 0 else {
            timelineFailed = true; recordFailure(stage: "silence", error: nil, dropped: frames); return
        }
        // The final quiet input can cross the batching threshold. Keep each
        // generated allocation bounded while encoding every original frame.
        var consumed = 0
        while consumed < frames {
            let count = min(frames - consumed, chunkLimit)
            let time = CMTimeAdd(CMTimeSubtract(startTime, firstTime),
                CMTime(seconds: Double(consumed) / lastSilentBufferSampleRate, preferredTimescale: 1_000_000_000))
            guard let silent = createSilentBuffer(sampleCount: count, presentationTime: time,
                formatDescription: formatDesc, sampleRate: lastSilentBufferSampleRate) else {
                timelineFailed = true
                recordFailure(stage: "silence", error: nil, dropped: frames - consumed)
                return
            }
            let accepted = autoreleasepool {
                silent.buffer.map { appendChecked($0, frames: count) } ?? false
            }
            silent.release()
            if !accepted {
                // appendChecked accounted for this attempted chunk. The suffix
                // never reached it and must be accounted for exactly once.
                let suffix = frames - consumed - count
                if suffix > 0 { recordFailure(stage: "silence", error: nil, dropped: suffix) }
                return
            }
            consumed += count
        }
    }

    @discardableResult
    private func appendChecked(_ buffer: CMSampleBuffer, frames: Int, generated: Bool = false) -> Bool {
        var acceptedSuccessfully = false
        // An unencoded required interval cannot be followed by success-looking
        // shifted media. Preserve the accepted prefix and park this source.
        defer { if !acceptedSuccessfully { timelineFailed = true } }
        guard !timelineFailed else {
            recordFailure(stage: "timeline", error: nil, dropped: generated ? 0 : frames)
            return false
        }
        guard writer.status == .writing else {
            recordFailure(stage: generated ? "padding_writer" : "writer", error: writer.error, dropped: generated ? 0 : frames)
            return false
        }
        if !generated {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while writer.status == .writing, !input.isReadyForMoreMediaData,
                  ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        guard input.isReadyForMoreMediaData else {
            recordFailure(stage: generated ? "padding_backpressure" : "backpressure", error: writer.error, dropped: generated ? 0 : frames)
            return false
        }
        do {
            var accepted = false
#if DEBUG || SOLSTONE_TEST_SUPPORT
            if _appendAdmissionForTesting?(frames) == false {
                recordFailure(stage: generated ? "padding_append" : "append", error: nil, dropped: generated ? 0 : frames)
                return false
            }
            _appendAttemptCountForTesting += 1
            _nativeAppendHookForTesting?()
#endif
            try ObjCExceptionCatcher.`try` { accepted = input.append(buffer) }
            if accepted {
                acceptedSuccessfully = true
                if generated { statistics.generatedFrames = (statistics.generatedFrames ?? 0) + frames }
                else { statistics.acceptedFrames += frames }
                publishStatistics()
            } else { recordFailure(stage: generated ? "padding_append" : "append", error: writer.error, dropped: generated ? 0 : frames) }
            return accepted
        } catch {
            recordFailure(stage: generated ? "padding_append" : "append", error: error, dropped: generated ? 0 : frames)
            return false
        }
    }

    private func appendPadding(from start: CMTime, to end: CMTime, format: CMFormatDescription, rate: Double) -> Bool {
        let seconds = CMTimeSubtract(end, start).seconds
        guard !timelineFailed, seconds.isFinite, seconds >= 0, seconds <= Self.maximumTimelineSeconds else { return false }
        var remaining = Int((seconds * rate).rounded())
        guard remaining > 0 else { return true }
        statistics.gapCount = (statistics.gapCount ?? 0) + 1
        var cursor = start
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
        while remaining > 0 {
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
            let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(asbd.mChannelsPerFrame)
            let byteFrames = max(1, (AudioMediaBudget.bytesPerStage / 2) / (Int(asbd.mBytesPerFrame) * planes))
            let frames = min(remaining, min(Int(rate), byteFrames))
#if DEBUG || SOLSTONE_TEST_SUPPORT
            if _paddingAdmissionForTesting?(frames) == false { return false }
#endif
            // Filling a long elapsed hole is a burst, unlike real-time taps.
            // Let the encoder consume it, with one deadline for the whole gap.
            while writer.status == .writing, !input.isReadyForMoreMediaData,
                  ProcessInfo.processInfo.systemUptime < readyDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard let silence = createSilentBuffer(sampleCount: frames,
                presentationTime: CMTimeSubtract(cursor, segmentStartTime), formatDescription: format, sampleRate: rate) else { return false }
            let accepted = autoreleasepool {
                silence.buffer.map { appendChecked($0, frames: frames, generated: true) } ?? false
            }
            silence.release()
            guard accepted else { return false }
            cursor = CMTimeAdd(cursor, CMTime(seconds: Double(frames) / rate, preferredTimescale: 1_000_000_000))
            remaining -= frames
        }
        lastBufferTime = end
        return true
    }

    /// Called with lock held. Bound distinct failure records; publish the first
    /// occurrence immediately, then the coalesced totals at finish.
    private func recordFailure(stage: String, error: Error?, dropped: Int = 0) {
        statistics.droppedFrames += dropped
        let native = error as NSError?
        let failure = AudioRecordingFailure(stage: stage, domain: native?.domain ?? "SolstoneAudioWriter", code: native?.code ?? 1)
        if let index = statistics.failures.firstIndex(where: { $0.stage == failure.stage && $0.domain == failure.domain && $0.code == failure.code }) {
            statistics.failures[index].count += 1
        } else if statistics.failures.count < 16 {
            statistics.failures.append(failure)
            Logger.audio.notice("Audio writer issue: \(stage, privacy: .public), code \(failure.code, privacy: .public)")
        }
        publishStatistics()
        scheduleReport()
    }

    private func sampleDuration(_ sample: CMSampleBuffer) -> CMTime {
        if let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           asbd.mSampleRate.isFinite, asbd.mSampleRate > 0, asbd.mSampleRate <= 192_000 {
            return CMTime(value: Int64(CMSampleBufferGetNumSamples(sample)), timescale: Int32(asbd.mSampleRate))
        }
        return CMSampleBufferGetDuration(sample)
    }

    /// Create a silent CMSampleBuffer with the given parameters
    private func createSilentBuffer(sampleCount: Int, presentationTime: CMTime, formatDescription: CMFormatDescription, sampleRate: Double) -> AudioTemporarySampleWork? {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if _silentBufferAdmissionForTesting?(sampleCount, presentationTime) == false { return nil }
#endif
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let extent = AudioPCMExtent(frames: sampleCount, asbd: asbd),
              let lease = mediaBudget.reserve(.temporary, bytes: extent.bytes) else {
            return nil
        }

        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1
        let bytesPerSample = Int(asbd.mBytesPerFrame) * planes
        let dataSize = sampleCount * bytesPerSample

        // Allocate zeroed memory
        guard let silentMemory = calloc(1, dataSize) else { return nil }

        // Create block buffer that owns the memory
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: silentMemory,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else {
            free(silentMemory)
            return nil
        }

        // Create sample buffer
        var silentBuffer: CMSampleBuffer?
        let sampleTime = sampleRate.rounded(.down) == sampleRate
            ? CMTime(value: 1, timescale: Int32(sampleRate))
            : CMTime(seconds: 1 / sampleRate, preferredTimescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(
            duration: sampleTime,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &silentBuffer
        )

        guard status == noErr, let silentBuffer else { return nil }
        return AudioTemporarySampleWork(buffer: silentBuffer, lease: lease)
    }

    /// Appends audio from an AVAudioPCMBuffer (from AVAudioEngine/external mics)
    /// - Parameters:
    ///   - buffer: The PCM audio buffer
    ///   - presentationTime: The presentation timestamp for this buffer
    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) {
        // Convert PCM buffer to CMSampleBuffer
        guard let sampleBuffer = createSampleBuffer(from: buffer, presentationTime: presentationTime) else {
            lock.withLock {
                guard !isFinished else { return }
                statistics.receivedFrames += Int(buffer.frameLength)
                publishStatistics()
                recordFailure(stage: "convert", error: nil, dropped: Int(buffer.frameLength))
            }
            Logger.audio.warning("Failed to convert PCM buffer to CMSampleBuffer for \(self.trackType.displayName, privacy: .public)")
            return
        }

        appendAudio(sampleBuffer)
    }

    /// Finishes writing and returns timing info
    /// - Returns: Timing information for remix alignment
    public func finish(captureCutoff: CMTime? = nil) async -> AudioTrackTimingInfo {
        let fence = admissionLock.withLock { () -> AudioCompletionSignal in
            admissionClosed = true
            return makeObservationFenceLocked()
        }
        await fence.wait()
        lock.withLock {
            if admissionLock.withLock({ admissionTerminal }) { timelineFailed = true }
        }
        // extractTimingState also flushes any pending silence
        let (firstTime, lastTime, startTime, wasStarted) = extractTimingState(captureCutoff: captureCutoff)
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if let hook = _finishAdmissionHookForTesting { await hook() }
#endif

        // Finalize the input/session only while the writer is still .writing.
        // On sleep/lock, ScreenCaptureKit tears the stream down and AVFoundation
        // moves the writer out of .writing; calling markAsFinished()/endSession()
        // then raises an uncaught ObjC NSException (objc_exception_throw -> SIGABRT)
        // that bypasses Swift do/catch. The allowlist guard skips finalize once the
        // writer has left .writing, and the ObjC barrier contains the case where the
        // writer still reports .writing but its underlying session is already invalid.
        if wasStarted {
            do {
                try ObjCExceptionCatcher.`try` {
                    if writer.status == .writing {
                        input.markAsFinished()

                        // End the session at the adjusted last media time
                        if let firstTime = firstTime, let lastTime = lastTime {
                            let adjustedEndTime = CMTimeSubtract(lastTime, firstTime)
                            writer.endSession(atSourceTime: adjustedEndTime)
                        }
                    }
                }
            } catch {
                lock.withLock { recordFailure(stage: "finish", error: error) }
                Logger.audio.error("Audio finalize threw for \(self.trackType.displayName, privacy: .public), dropping segment audio: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Calculate timing offsets
        let startOffset: CMTime
        let endOffset: CMTime

        if let firstTime = firstTime {
            startOffset = CMTimeSubtract(firstTime, startTime)
        } else {
            startOffset = .zero
        }

        if let lastTime = lastTime {
            endOffset = CMTimeSubtract(lastTime, startTime)
        } else {
            endOffset = startOffset
        }

        // Finalize writer only if it was started
        if wasStarted && writer.status == .writing {
            await writer.finishWriting()

            if writer.status == .failed {
                Logger.audio.error("Audio writer error for \(self.trackType.displayName, privacy: .public): \(String(describing: self.writer.error), privacy: .public)")
            } else {
                let duration = CMTimeGetSeconds(CMTimeSubtract(endOffset, startOffset))
                Logger.audio.info("Saved audio: \(self.outputURL.lastPathComponent, privacy: .public) (\(String(format: "%.1f", duration), privacy: .public)s)")
            }
        } else if !wasStarted {
            // No audio was written - clean up the empty file
            Logger.audio.info("No audio written for \(self.trackType.displayName, privacy: .public), removing empty file")
            try? FileManager.default.removeItem(at: outputURL)
        }

        let finalStatistics = lock.withLock { () -> AudioWriterStatistics in
            let observed = statisticsSnapshot
            statistics.writerStatus = observed.receivedFrames == 0 && observed.failures.isEmpty ? "no_audio"
                : (writer.status == .completed ? "completed" : "failed")
            if wasStarted && writer.status != .completed { recordFailure(stage: "finish", error: writer.error) }
            statistics.statisticsComplete = true
            publishStatistics(quiescent: true)
            return statisticsSnapshot
        }
        onStatistics?(finalStatistics)
        onComplete?()

        return AudioTrackTimingInfo(
            startOffset: startOffset,
            endOffset: endOffset,
            trackType: trackType,
            hasAudio: finalStatistics.acceptedFrames > 0
        )
    }

    /// Returns the output file URL
    public var url: URL {
        return outputURL
    }

    public var statisticsSnapshot: AudioWriterStatistics { snapshotLock.withLock { publishedStatistics } }
    public var nativeWriterIsQuiescent: Bool { snapshotLock.withLock { nativeQuiescent } }

    /// Called under the writer lock, before and after potentially blocking calls.
    private func publishStatistics(quiescent: Bool = false) {
        snapshotLock.withLock {
            backendStatistics = statistics
            publishedStatistics = mergedStatisticsLocked()
            if quiescent { nativeQuiescent = true }
        }
    }

    private func mergedStatisticsLocked() -> AudioWriterStatistics {
        var result = backendStatistics
        result.receivedFrames = Self.counterSum(result.receivedFrames, admittedReceived)
        result.droppedFrames = Self.counterSum(result.droppedFrames, admittedDropped)
        if captureCountersIncomplete { result.statisticsComplete = false }
        for failure in admittedFailures {
            if let index = result.failures.firstIndex(where: { $0.stage == failure.stage && $0.domain == failure.domain && $0.code == failure.code }) {
                result.failures[index].count = Self.counterSum(result.failures[index].count, failure.count)
            } else if result.failures.count < 16 { result.failures.append(failure) }
        }
        return result
    }

    private static func counterSum(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    private func noteAdmission(frames: Int, dropped: Int = 0, stage: String? = nil, error: Error? = nil,
                               incomplete: Bool = false) {
        snapshotLock.withLock {
            admittedReceived = Self.counterSum(admittedReceived, frames)
            admittedDropped = Self.counterSum(admittedDropped, dropped)
            captureCountersIncomplete = captureCountersIncomplete || incomplete
            if let stage {
                let native = error as NSError?
                let failure = AudioRecordingFailure(stage: stage, domain: native?.domain ?? "SolstoneAudioAdmission", code: native?.code ?? 1)
                if let index = admittedFailures.firstIndex(where: { $0.stage == stage && $0.domain == failure.domain && $0.code == failure.code }) {
                    admittedFailures[index].count = Self.counterSum(admittedFailures[index].count, 1)
                } else if admittedFailures.count < 16 { admittedFailures.append(failure) }
            }
            publishedStatistics = mergedStatisticsLocked()
        }
        scheduleReport()
    }

    private func scheduleReport() {
        guard onStatistics != nil else { return }
        let schedule = snapshotLock.withLock { () -> Bool in
            guard !reportPending else { return false }
            reportPending = true
            return true
        }
        guard schedule else { return }
        reportQueue.async { [self] in
#if DEBUG || SOLSTONE_TEST_SUPPORT
            _reportAdmissionHookForTesting?()
#endif
            // Read the current snapshot after any delayed report admission.
            // Clear before delivery; at most one additional report can queue.
            let current = snapshotLock.withLock { () -> AudioWriterStatistics in
                reportPending = false
                return publishedStatistics
            }
            onStatistics?(current)
        }
    }

    /// Commit capture failures independently of a held conversion/native queue.
    /// Raw-rate rejected frames cannot be invented as48k writer admissions.
    internal func reportCaptureFailure(_ error: Error) {
        admissionLock.withLock {
            let admissionFailure = (error as NSError).domain == "SolstoneAudioAdmission"
            if admissionFailure { admissionTerminal = true }
            noteAdmission(frames: 0, stage: admissionFailure ? "admission_capture" : "capture", error: error, incomplete: true)
        }
    }

    internal func makeObservationFence() -> AudioCompletionSignal {
        admissionLock.withLock { makeObservationFenceLocked() }
    }

    private func makeObservationFenceLocked() -> AudioCompletionSignal {
        if let existing = observationFence, existing.ordinal == admissionOrdinal { return existing.signal }
        let signal = AudioCompletionSignal()
        observationFence = (admissionOrdinal, signal)
        nativeQueue.async { [self] in
            autoreleasepool {
                lock.withLock {
                    if let firstTime = firstBufferTime, silenceAccumulatedSamples > 0 { flushSilence(firstTime: firstTime) }
                }
            }
            completeRetiredSilence()
            signal.complete()
        }
        return signal
    }

    private func completeRetiredSilence() {
        let retired = lock.withLock { () -> [AudioQueuedWriterWork] in
            let work = retiredSilentWork
            retiredSilentWork.removeAll(keepingCapacity: true)
            return work
        }
        for work in retired { work.complete() }
    }

    // MARK: - Private

    /// Extract timing state for use in async contexts (lock cannot be held across await)
    /// Also flushes any pending silence before marking as finished
    private func extractTimingState(captureCutoff: CMTime?) -> (firstTime: CMTime?, lastTime: CMTime?, startTime: CMTime, wasStarted: Bool) {
        lock.lock()

        // Flush any pending silence before finishing
        if let firstTime = firstBufferTime, silenceAccumulatedSamples > 0 {
            flushSilence(firstTime: firstTime)
        }
        if !timelineFailed, sessionStarted, let cutoff = captureCutoff, cutoff.isNumeric,
           let lastTime = lastBufferTime, let format = lastFormat,
           cutoff > lastTime {
            let offset = CMTimeSubtract(cutoff, segmentStartTime).seconds
            if offset.isFinite, offset <= Self.maximumTimelineSeconds,
               appendPadding(from: lastTime, to: cutoff, format: format, rate: lastSampleRate) {
                lastBufferTime = cutoff
            } else {
                timelineFailed = true
                recordFailure(stage: "padding", error: nil)
            }
        }

        isFinished = true
        let firstTime = firstBufferTime
        let lastTime = lastBufferTime
        let startTime = segmentStartTime
        let wasStarted = sessionStarted
        lock.unlock()
        return (firstTime, lastTime, startTime, wasStarted)
    }

#if DEBUG || SOLSTONE_TEST_SUPPORT
    /// Test-only: force the recorded last-buffer time so finish() computes an
    /// invalid endSession source time, reproducing the sleep/lock ObjC throw from
    /// a writer that still reports .writing. Excluded from shipping builds.
    internal func _forceLastBufferTimeForTesting(_ time: CMTime) {
        lock.lock()
        lastBufferTime = time
        lock.unlock()
    }
#endif

    private func createRetimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, newTime: CMTime) -> CMSampleBuffer? {
        var newSampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTimeMultiplyByRatio(sampleDuration(sampleBuffer), multiplier: 1, divisor: Int32(max(1, CMSampleBufferGetNumSamples(sampleBuffer)))),
            presentationTimeStamp: newTime,
            decodeTimeStamp: CMTime.invalid
        )

        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )

        return status == noErr ? newSampleBuffer : nil
    }

    /// Copy only the eligible PCM frames, preserving packed or planar layout.
    /// Range-copy also needs sample-size entries which captured PCM may omit.
    private func clipBoundary(_ buffer: CMSampleBuffer, skipping: Int, frames: Int, format: CMFormatDescription) -> CMSampleBuffer? {
#if DEBUG || SOLSTONE_TEST_SUPPORT
        if skipping > 0, _boundaryClipAdmissionForTesting?(frames) == false { return nil }
#endif
        var first = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(buffer, at: skipping, timingInfoOut: &first) == noErr else { return nil }
        var result: CMSampleBuffer?
        let pcmFormat = AVAudioFormat(cmAudioFormatDescription: format)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: Int32(skipping), frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr,
              CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: frames,
                sampleTimingEntryCount: 1, sampleTimingArray: &first, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &result) == noErr, let result,
              CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr else { return nil }
        return result
    }

    private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        let format = pcmBuffer.format
        let frameCount = pcmBuffer.frameLength

        guard frameCount > 0 else { return nil }

        // Create audio stream basic description
        var asbd = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Create format description
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else { return nil }

        // Get the float channel data
        guard let floatData = pcmBuffer.floatChannelData?[0] else { return nil }

        // Create block buffer
        let dataSize = Int(frameCount) * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?

        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let block = blockBuffer else { return nil }

        // Copy data to block buffer
        status = CMBlockBufferReplaceDataBytes(
            with: floatData,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )

        guard status == noErr else { return nil }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        return status == noErr ? sampleBuffer : nil
    }
}

/// Errors for SingleTrackAudioWriter
public enum SingleTrackAudioWriterError: Error, LocalizedError {
    case cannotAddInput

    public var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add audio input to writer"
        }
    }
}
