// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

internal protocol SingleSupervisorGating: Sendable {
    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult
}

internal enum SingleSupervisorGateResult: Equatable, Sendable {
    case success
    case blocked(JournalDiagnostic)
}

internal struct SingleSupervisorGate: SingleSupervisorGating {
    private let runner: SubprocessRunning
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let clock: any MonotonicClock
    private let orphanGracePeriod: Duration

    internal init(
        runner: SubprocessRunning = SubprocessRunner(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        clock: any MonotonicClock = SystemMonotonicClock(),
        orphanGracePeriod: Duration = .seconds(3)
    ) {
        self.runner = runner
        self.pidExists = pidExists
        self.terminate = terminate
        self.clock = clock
        self.orphanGracePeriod = orphanGracePeriod
    }

    internal func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        if let failure = await runJournalOrphanSweep(
            runner: runner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock
        ) {
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=orphan-sweep detail=\(failure.message, privacy: .public)")
            return .blocked(JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: failure.message
            ))
        }

        if let failure = await assertPortsReleased(ports: [7657, 5015], runner: runner) {
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=ports-not-released ports=7657,5015 detail=\(failure.message, privacy: .public)")
            return .blocked(JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: failure.message
            ))
        }

        return .success
    }
}
