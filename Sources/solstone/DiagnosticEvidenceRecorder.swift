// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Synchronously accepts producer observations and persists them off the producer's call path.
@MainActor
internal final class DiagnosticEvidenceRecorder {
    /// Shared inert recorder for construction paths which must not create evidence or touch disk.
    static let dormant = DiagnosticEvidenceRecorder()

    private let store: DiagnosticEvidenceStore?
    private let now: @Sendable () -> Date
    private let taskStarted: @MainActor @Sendable () -> Void
    private var tail: Task<Void, Never>?

    init() {
        self.store = nil
        self.now = Date.init
        self.taskStarted = {}
    }

    init(
        store: DiagnosticEvidenceStore,
        now: @escaping @Sendable () -> Date = Date.init,
        taskStarted: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.store = store
        self.now = now
        self.taskStarted = taskStarted
    }

    /// A chained tail preserves producer enqueue order while each task still begins independently.
    func enqueue(_ code: DiagnosticEvidenceCode) {
        guard let store else { return }

        let time = now()
        let previous = tail
        let taskStarted = taskStarted
        tail = Task { @MainActor in
            taskStarted()
            await previous?.value
            _ = await store.record(code, at: time)
        }
    }

    /// Waits for work that was already enqueued. It never records or reads additional evidence.
    func drain() async {
        let pending = tail
        await pending?.value
    }

    /// Returns a stable owner-triggered snapshot after all evidence already
    /// accepted by this recorder has reached the bounded store.
    func read() async -> DiagnosticEvidenceRead {
        guard let store else { return .unavailable }
        await drain()
        return await store.read()
    }
}
