// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

internal protocol JournalReadinessChecking: Sendable {
    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration
    ) async -> JournalReadinessResult
}

internal enum JournalReadinessResult: Equatable, Sendable {
    case ready
    case failed(JournalDiagnostic)
}

internal struct JournalReadinessGate: JournalReadinessChecking {
    private let runner: SubprocessRunning
    private let fileExists: @Sendable (String) -> Bool
    private let clock: any MonotonicClock
    private let pollInterval: Duration

    internal init(
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        clock: any MonotonicClock = SystemMonotonicClock(),
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.runner = runner
        self.fileExists = fileExists
        self.clock = clock
        self.pollInterval = pollInterval
    }

    internal func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration
    ) async -> JournalReadinessResult {
        let readyPath = journalRoot.appendingPathComponent("health/supervisor.ready").path
        let deadline = clock.now() + timeout
        var lastDiagnostic: JournalDiagnostic?

        while clock.now() < deadline {
            if fileExists(readyPath) {
                return .ready
            }
            switch await JournalHealthCheck.run(
                journalBinary: runtime.layout.journalBinary,
                runner: runner,
                environment: runtime.layout.uvEnvironment()
            ) {
            case .healthy:
                return .ready
            case .stopped(let diagnostic), .unknown(let diagnostic):
                lastDiagnostic = diagnostic
            }
            await clock.sleep(for: pollInterval)
        }

        return .failed(lastDiagnostic ?? JournalDiagnostic(
            commandLabel: "journal readiness",
            timedOut: true,
            outputExcerpt: UICopy.JOURNAL_READINESS_TIMEOUT
        ))
    }
}
