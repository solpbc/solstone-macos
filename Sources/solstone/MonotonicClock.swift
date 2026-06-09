// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal protocol MonotonicClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async
}

internal struct SystemMonotonicClock: MonotonicClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    internal init() {
        origin = clock.now
    }

    internal func now() -> Duration {
        origin.duration(to: clock.now)
    }

    internal func sleep(for duration: Duration) async {
        try? await clock.sleep(for: duration)
    }
}
