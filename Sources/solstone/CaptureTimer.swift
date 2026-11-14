// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Capture deadlines and health checks must keep running while a native menu tracks events.
@MainActor
internal enum CaptureTimer {
    static func schedule(
        interval: TimeInterval,
        repeats: Bool,
        delivery: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: delivery)
        // A repeating check may run a little late so the system can wake for it with other work.
        // A one-shot deadline (a segment boundary, a retry) stays exact.
        if repeats { timer.tolerance = interval / 10 }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
