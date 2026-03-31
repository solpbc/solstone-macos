// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public struct TimeoutError: Error {
    public let seconds: Double
}

func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)

        let operationTask = Task {
            do {
                let result = try await operation()
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                if !alreadyResumed {
                    continuation.resume(returning: result)
                }
            } catch {
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                if !alreadyResumed {
                    continuation.resume(throwing: error)
                }
            }
        }

        Task {
            try await Task.sleep(for: .seconds(seconds))
            let alreadyResumed = resumed.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            if !alreadyResumed {
                operationTask.cancel()
                continuation.resume(throwing: TimeoutError(seconds: seconds))
            }
        }
    }
}
