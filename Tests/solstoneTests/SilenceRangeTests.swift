// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreMedia
import Testing
@testable import solstone

@Suite("SystemAudioAnalyzer.computeSilenceRanges")
struct SilenceRangeTests {
    private let analyzer = SystemAudioAnalyzer.shared
    private let ts: CMTimeScale = 48_000

    private func range(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: ts),
            duration: CMTime(seconds: duration, preferredTimescale: ts)
        )
    }

    @Test func emptyInputReturnsEmpty() {
        let result = analyzer.computeSilenceRanges(from: [], padding: 0.2)
        #expect(result.isEmpty)
    }

    @Test func singleRangeGetsPadding() {
        let input = [range(start: 10.0, duration: 5.0)]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.5)
        // Original: [10, 15). After 0.5s padding on each side: [10.5, 14.5) = duration 4.0
        #expect(result.count == 1)
        let r = result[0]
        #expect(abs(CMTimeGetSeconds(r.start) - 10.5) < 0.001)
        #expect(abs(CMTimeGetSeconds(r.duration) - 4.0) < 0.001)
    }

    @Test func adjacentRangesMerge() {
        // Touching ranges merge; positive gaps never do.
        let input = [
            range(start: 10.0, duration: 5.0),   // [10, 15)
            range(start: 15.0, duration: 5.0),    // [15, 20), touching
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        // Merged: [10, 20)
        #expect(result.count == 1)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 10.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 10.0) < 0.001)
    }

    @Test func largeGapKeepsRangesSeparate() {
        // A positive gap stays intact.
        let input = [
            range(start: 10.0, duration: 5.0),   // [10, 15)
            range(start: 25.0, duration: 5.0),    // [25, 30) — 10s gap
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        #expect(result.count == 2)
    }

    @Test func rangeTooSmallAfterPaddingIsDropped() {
        // A 0.3s range with 0.2s padding on each side = -0.1s duration → dropped
        let input = [range(start: 10.0, duration: 0.3)]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.2)
        #expect(result.isEmpty)
    }

    @Test func multipleRangesMergeCorrectly() {
        // Three ranges: first two merge, third is separate
        let input = [
            range(start: 0.0, duration: 3.0),    // [0, 3)
            range(start: 3.0, duration: 3.0),     // [3, 6), touching
            range(start: 20.0, duration: 3.0),    // [20, 23), separate
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        #expect(result.count == 2)
        // First merged range: [0, 6)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 0.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 6.0) < 0.001)
        // Second range: [20, 23)
        #expect(abs(CMTimeGetSeconds(result[1].start) - 20.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[1].duration) - 3.0) < 0.001)
    }

    @Test func unsortedInputGetsSorted() {
        // Input out of order should still merge correctly
        let input = [
            range(start: 15.0, duration: 5.0),
            range(start: 10.0, duration: 5.0),
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        // Touching ranges merge to [10, 20)
        #expect(result.count == 1)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 10.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 10.0) < 0.001)
    }
}
