// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis
import os

public struct SystemAudioAnalysisResult: Sendable {
    public let silenceRanges: [CMTimeRange]
    public let status: String
    public static let unavailable = SystemAudioAnalysisResult(silenceRanges: [], status: "unavailable")
}

/// Classification may suppress confirmed music; it never decides whether to keep audio.
public final class SystemAudioAnalyzer: Sendable {
    public static let shared = SystemAudioAnalyzer()
    private init() {}

    public func analyze(url: URL, speechThreshold: Double = 0.3, musicThreshold: Double = 0.6,
                        paddingSeconds: Double = 0.2) async -> SystemAudioAnalysisResult {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let observer = ClassificationObserver(speechThreshold: speechThreshold, musicThreshold: musicThreshold)
            try analyzer.add(request, withObserver: observer)
            let succeeded = await analyzer.analyze()
            let snapshot = observer.snapshot()
            guard succeeded, snapshot.completed, !snapshot.failed, !snapshot.malformed else {
                return .unavailable
            }
            let covered = computeSilenceRanges(from: snapshot.coverage, padding: 0)
            let complete = covered.count == 1 && CMTimeCompare(covered[0].start, .zero) <= 0
                && CMTimeCompare(CMTimeRangeGetEnd(covered[0]), duration) >= 0
            return SystemAudioAnalysisResult(
                silenceRanges: complete ? computeSilenceRanges(from: snapshot.music, padding: paddingSeconds, protecting: snapshot.protected) : [],
                status: complete ? "complete" : "incomplete"
            )
        } catch {
            Logger.audio.notice("Music analysis unavailable; preserving audio")
            return .unavailable
        }
    }

    /// Union confirmed intervals without bridging gaps, then subtract speech/unknown windows.
    func computeSilenceRanges(from ranges: [CMTimeRange], padding: Double,
                              protecting protectedRanges: [CMTimeRange] = []) -> [CMTimeRange] {
        let sorted = ranges.filter { $0.start.isNumeric && $0.duration.isNumeric && CMTimeCompare($0.duration, .zero) > 0 }
            .sorted { CMTimeCompare($0.start, $1.start) < 0 }
        var merged: [CMTimeRange] = []
        for range in sorted {
            if let last = merged.last, CMTimeCompare(range.start, CMTimeRangeGetEnd(last)) <= 0 {
                let end = CMTimeMaximum(CMTimeRangeGetEnd(last), CMTimeRangeGetEnd(range))
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: end)
            } else { merged.append(range) }
        }
        for protected in protectedRanges {
            merged = merged.flatMap { range -> [CMTimeRange] in
                let overlap = CMTimeRangeGetIntersection(range, otherRange: protected)
                guard overlap.duration.isNumeric, CMTimeCompare(overlap.duration, .zero) > 0 else { return [range] }
                var pieces: [CMTimeRange] = []
                if CMTimeCompare(range.start, overlap.start) < 0 { pieces.append(CMTimeRange(start: range.start, end: overlap.start)) }
                if CMTimeCompare(CMTimeRangeGetEnd(overlap), CMTimeRangeGetEnd(range)) < 0 {
                    pieces.append(CMTimeRange(start: CMTimeRangeGetEnd(overlap), end: CMTimeRangeGetEnd(range)))
                }
                return pieces
            }
        }
        let pad = CMTime(seconds: max(0, padding), preferredTimescale: 48_000)
        return merged.compactMap { range in
            let start = CMTimeAdd(range.start, pad)
            let end = CMTimeSubtract(CMTimeRangeGetEnd(range), pad)
            return CMTimeCompare(end, start) > 0 ? CMTimeRange(start: start, end: end) : nil
        }
    }
}

private final class ClassificationObserver: NSObject, SNResultsObserving {
    struct Snapshot {
        var music: [CMTimeRange] = []
        var protected: [CMTimeRange] = []
        var coverage: [CMTimeRange] = []
        var completed = false
        var failed = false
        var malformed = false
    }
    private let lock = NSLock()
    private var state = Snapshot()
    private let speechThreshold: Double
    private let musicThreshold: Double
    init(speechThreshold: Double, musicThreshold: Double) {
        self.speechThreshold = speechThreshold
        self.musicThreshold = musicThreshold
    }
    func snapshot() -> Snapshot { lock.withLock { state } }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        lock.withLock {
            guard let result = result as? SNClassificationResult,
                  result.timeRange.start.isNumeric, result.timeRange.duration.isNumeric,
                  CMTimeRangeGetEnd(result.timeRange).isNumeric,
                  CMTimeCompare(result.timeRange.start, .zero) >= 0,
                  CMTimeCompare(result.timeRange.duration, .zero) > 0 else {
                state.malformed = true
                return
            }
            let range = result.timeRange
            guard let speech = result.classification(forIdentifier: "speech")?.confidence,
                  let music = result.classification(forIdentifier: "music")?.confidence,
                  speech.isFinite, music.isFinite, (0...1).contains(speech), (0...1).contains(music) else {
                state.protected.append(range)
                return
            }
            state.coverage.append(range)
            if music > musicThreshold && speech < speechThreshold { state.music.append(range) }
            else { state.protected.append(range) }
        }
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.withLock { state.failed = true }
        Logger.audio.notice("Music analysis failed; preserving audio")
    }
    func requestDidComplete(_ request: SNRequest) { lock.withLock { state.completed = true } }
}
