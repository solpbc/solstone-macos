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
        // Two ranges 3s apart (< 5s merge threshold) should merge
        let input = [
            range(start: 10.0, duration: 5.0),   // [10, 15)
            range(start: 18.0, duration: 5.0),    // [18, 23) — 3s gap
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        // Merged: [10, 23) = duration 13
        #expect(result.count == 1)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 10.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 13.0) < 0.001)
    }

    @Test func largeGapKeepsRangesSeparate() {
        // Two ranges 10s apart (> 5s merge threshold) stay separate
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
            range(start: 5.0, duration: 3.0),     // [5, 8) — 2s gap, merges
            range(start: 20.0, duration: 3.0),    // [20, 23) — 12s gap, separate
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        #expect(result.count == 2)
        // First merged range: [0, 8)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 0.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 8.0) < 0.001)
        // Second range: [20, 23)
        #expect(abs(CMTimeGetSeconds(result[1].start) - 20.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[1].duration) - 3.0) < 0.001)
    }

    @Test func unsortedInputGetsSorted() {
        // Input out of order should still merge correctly
        let input = [
            range(start: 18.0, duration: 5.0),
            range(start: 10.0, duration: 5.0),
        ]
        let result = analyzer.computeSilenceRanges(from: input, padding: 0.0)
        // 3s gap → merged to [10, 23)
        #expect(result.count == 1)
        #expect(abs(CMTimeGetSeconds(result[0].start) - 10.0) < 0.001)
        #expect(abs(CMTimeGetSeconds(result[0].duration) - 13.0) < 0.001)
    }
}
