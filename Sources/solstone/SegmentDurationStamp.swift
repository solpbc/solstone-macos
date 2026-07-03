// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
internal func clampedSegmentDurationSeconds(_ rawSeconds: TimeInterval) -> Int {
    let ceiling = max(1, Int(SegmentWriter.segmentDuration))
    guard rawSeconds.isFinite else {
        return ceiling
    }
    return min(max(1, Int(rawSeconds)), ceiling)
}
