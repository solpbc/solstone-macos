// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
internal func clampedSegmentDurationSeconds(_ rawSeconds: TimeInterval) -> Int {
    clampedSegmentDurationSeconds(rawSeconds, ceiling: SegmentWriter.segmentDuration)
}

/// Bounds a measured duration to [1, ceiling] whole seconds.
internal func clampedSegmentDurationSeconds(_ rawSeconds: TimeInterval, ceiling: TimeInterval) -> Int {
    let ceiling = max(1, Int(ceiling))
    guard rawSeconds.isFinite else {
        return ceiling
    }
    return min(max(1, Int(rawSeconds)), ceiling)
}
