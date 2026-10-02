// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
internal struct PermissionPollScheduler {
    typealias Pass = @MainActor @Sendable () async -> Void
    typealias Cancellation = @MainActor @Sendable () -> Void

    /// Runs one pass immediately and schedules recurring passes. The result stops the recurrence.
    let armPolling: @MainActor @Sendable (@escaping Pass) -> Cancellation

    static func live(
        interval: TimeInterval = 5.0,
        tolerance: TimeInterval = 2.0,
        scheduleTimer: @escaping @MainActor @Sendable (
            _ interval: TimeInterval,
            _ repeats: Bool,
            _ delivery: @escaping @Sendable () -> Void
        ) -> Timer = { interval, repeats, delivery in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                delivery()
            }
        }
    ) -> Self {
        Self { pass in
            // Foundation delivers timer blocks nonisolated, so this crossing must be explicit here.
            let delivery: @Sendable () -> Void = {
                Task { @MainActor in
                    await pass()
                }
            }
            delivery()
            let timer = scheduleTimer(interval, true, delivery)
            timer.tolerance = tolerance
            return { timer.invalidate() }
        }
    }
}
