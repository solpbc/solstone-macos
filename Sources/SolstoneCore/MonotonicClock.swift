// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

public protocol MonotonicClock: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async
}

public struct SystemMonotonicClock: MonotonicClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() -> Duration {
        origin.duration(to: clock.now)
    }

    public func sleep(for duration: Duration) async {
        try? await clock.sleep(for: duration)
    }
}
