// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import AVFAudio
import CoreMedia

/// Value copy taken on the tap before its producer can reuse PCM or time.
internal struct MicrophoneBufferTime: Sendable {
    let host: UInt64?
    let sample: Int64?
    let rate: Double
    init(_ time: AVAudioTime) {
        host = time.isHostTimeValid ? time.hostTime : nil
        sample = time.isSampleTimeValid ? time.sampleTime : nil
        rate = time.sampleRate
    }
}

/// Owned by the conversion queue. Sample continuity wins over host jitter;
/// sample-only extrapolation requires a same-epoch anchor with both clocks.
internal struct MicrophoneBufferClock {
    private var anchor: (sample: Int64, host: CMTime)?
    private var expectedSample: Int64?
    private var expectedHost: CMTime?
    private var rate: Double?
    static let hostContinuityTolerance = 0.002

    mutating func reset() { self = Self() }

    mutating func admit(_ time: MicrophoneBufferTime, frames: Int, sampleRate: Double) -> (time: CMTime, continuous: Bool)? {
        guard frames > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        if rate != sampleRate { reset(); rate = sampleRate }
        let sample = time.sample.flatMap { time.rate == sampleRate ? $0 : nil }
        let captured: CMTime
        if let host = time.host {
            captured = CMClockMakeHostTimeFromSystemUnits(host)
        } else if let sample, let anchor {
            let delta = sample.subtractingReportingOverflow(anchor.sample)
            guard !delta.overflow else { return nil }
            captured = CMTimeAdd(anchor.host, CMTime(seconds: Double(delta.partialValue) / sampleRate, preferredTimescale: 1_000_000_000))
        } else { return nil }
        guard captured.isNumeric else { return nil }
        let continuous: Bool
        if let sample, let expectedSample {
            let delta = sample.subtractingReportingOverflow(expectedSample)
            continuous = !delta.overflow && abs(Double(delta.partialValue)) <= 1
        } else if let expectedHost {
            continuous = abs(CMTimeSubtract(captured, expectedHost).seconds) <= Self.hostContinuityTolerance
        } else { continuous = false }
        if let sample, time.host != nil { anchor = (sample, captured) }
        if let sample {
            let end = sample.addingReportingOverflow(Int64(frames))
            guard !end.overflow else { return nil }
            expectedSample = end.partialValue
        } else { expectedSample = nil }
        expectedHost = CMTimeAdd(captured, CMTime(seconds: Double(frames) / sampleRate, preferredTimescale: 1_000_000_000))
        return (captured, continuous)
    }
}
