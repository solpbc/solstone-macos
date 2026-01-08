// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Foundation
import SoundAnalysis

/// Result of system audio analysis
public struct SystemAudioAnalysisResult: Sendable {
    /// Whether any speech was detected above threshold
    public let hasSpeech: Bool
    /// Time ranges where music is dominant and speech is absent (should be silenced)
    public let silenceRanges: [CMTimeRange]

    /// Unavailable result (analysis failed)
    public static let unavailable = SystemAudioAnalysisResult(hasSpeech: true, silenceRanges: [])
}

/// Analyzes system audio for speech and music, computing silence ranges
/// for music-dominant portions while preserving speech
public final class SystemAudioAnalyzer: Sendable {
    /// Shared instance
    public static let shared = SystemAudioAnalyzer()

    private init() {}

    /// Analyze system audio file for speech presence and music silencing ranges
    /// - Parameters:
    ///   - url: URL to the audio file
    ///   - speechThreshold: Minimum confidence to consider speech detected (default 0.3)
    ///   - musicThreshold: Minimum confidence to consider music dominant (default 0.6)
    ///   - paddingSeconds: Margin around speech segments to preserve (default 0.2)
    /// - Returns: Analysis result with speech detection and silence ranges
    public func analyze(
        url: URL,
        speechThreshold: Double = 0.3,
        musicThreshold: Double = 0.6,
        paddingSeconds: Double = 0.2
    ) async -> SystemAudioAnalysisResult {
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

            let observer = ClassificationObserver(
                speechThreshold: speechThreshold,
                musicThreshold: musicThreshold
            )
            try analyzer.add(request, withObserver: observer)

            // analyze() processes the entire file at high speed
            await analyzer.analyze()

            // Compute silence ranges with padding
            let silenceRanges = computeSilenceRanges(
                from: observer.musicOnlyRanges,
                padding: paddingSeconds
            )

            return SystemAudioAnalysisResult(
                hasSpeech: observer.hasSpeech,
                silenceRanges: silenceRanges
            )
        } catch {
            Log.debug("SystemAudioAnalyzer failed: \(error.localizedDescription), failing open", verbose: true)
            return .unavailable
        }
    }

    /// Merge adjacent silence ranges and apply padding (shrink ranges at boundaries)
    private func computeSilenceRanges(
        from ranges: [CMTimeRange],
        padding: Double
    ) -> [CMTimeRange] {
        guard !ranges.isEmpty else { return [] }

        let paddingTime = CMTime(seconds: padding, preferredTimescale: 48_000)

        // Sort ranges by start time
        let sorted = ranges.sorted { CMTimeCompare($0.start, $1.start) < 0 }

        // Merge adjacent/overlapping ranges
        var merged: [CMTimeRange] = []
        var current = sorted[0]

        for range in sorted.dropFirst() {
            let currentEnd = CMTimeAdd(current.start, current.duration)
            // If ranges overlap or are adjacent (within 5 seconds), merge them
            // This bridges over brief gaps where classification fluctuated
            let gap = CMTimeSubtract(range.start, currentEnd)
            let mergeThreshold = CMTime(seconds: 5.0, preferredTimescale: 48_000)

            if CMTimeCompare(gap, mergeThreshold) <= 0 {
                // Merge: extend current range to include this one
                let newEnd = CMTimeAdd(range.start, range.duration)
                let maxEnd = CMTimeCompare(currentEnd, newEnd) > 0 ? currentEnd : newEnd
                current = CMTimeRange(start: current.start, duration: CMTimeSubtract(maxEnd, current.start))
            } else {
                // Gap is large enough, save current and start new
                merged.append(current)
                current = range
            }
        }
        merged.append(current)

        // Apply padding: shrink each range at both ends
        var padded: [CMTimeRange] = []
        for range in merged {
            let newStart = CMTimeAdd(range.start, paddingTime)
            let newDuration = CMTimeSubtract(range.duration, CMTimeMultiply(paddingTime, multiplier: 2))

            // Only keep range if it still has positive duration after padding
            if CMTimeCompare(newDuration, .zero) > 0 {
                padded.append(CMTimeRange(start: newStart, duration: newDuration))
            }
        }

        return padded
    }
}

/// Observer that collects speech and music classifications
private class ClassificationObserver: NSObject, SNResultsObserving {
    let speechThreshold: Double
    let musicThreshold: Double

    private(set) var hasSpeech = false
    private(set) var musicOnlyRanges: [CMTimeRange] = []

    init(speechThreshold: Double, musicThreshold: Double) {
        self.speechThreshold = speechThreshold
        self.musicThreshold = musicThreshold
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        let speechConfidence = classification.classification(forIdentifier: "speech")?.confidence ?? 0
        let musicConfidence = classification.classification(forIdentifier: "music")?.confidence ?? 0

        // Track if any speech detected
        if speechConfidence > speechThreshold {
            hasSpeech = true
        }

        // Track ranges where music is dominant and speech is absent
        if musicConfidence > musicThreshold && speechConfidence < speechThreshold {
            musicOnlyRanges.append(classification.timeRange)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.debug("SystemAudioAnalyzer request failed: \(error.localizedDescription)", verbose: true)
    }

    func requestDidComplete(_ request: SNRequest) {
        // Analysis complete
    }
}
