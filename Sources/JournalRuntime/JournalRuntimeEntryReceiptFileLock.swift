// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore

internal enum JournalRuntimeEntryReceiptLockResult {
    case acquired
    case timedOut
    case failed
}

internal struct JournalRuntimeEntryReceiptFileLock {
    let url: URL
    let clock: any MonotonicClock
    let timeout: Duration

    func withExclusiveLock<Result>(_ body: () -> Result) -> (JournalRuntimeEntryReceiptLockResult, Result?) {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return (.failed, nil) }
        defer { close(descriptor) }

        let deadline = clock.now() + timeout
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                defer { _ = flock(descriptor, LOCK_UN) }
                return (.acquired, body())
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return (.failed, nil) }
            guard clock.now() < deadline else { return (.timedOut, nil) }
            usleep(10_000)
        }
    }
}
