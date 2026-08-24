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
        scheduleTimer: @escaping @MainActor @Sendable (
            _ interval: TimeInterval,
            _ repeats: Bool,
            _ fire: @escaping @MainActor @Sendable () -> Void
        ) -> Timer = { interval, repeats, fire in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                fire()
            }
        },
        startImmediatePass: @escaping @MainActor @Sendable (@escaping Pass) -> Void = { pass in
            Task { @MainActor in
                await pass()
            }
        }
    ) -> Self {
        Self { pass in
            startImmediatePass(pass)
            let fire: @MainActor @Sendable () -> Void = {
                Task { @MainActor in
                    await pass()
                }
            }
            let timer = scheduleTimer(5.0, true, fire)
            timer.tolerance = 2.0
            return { timer.invalidate() }
        }
    }
}
