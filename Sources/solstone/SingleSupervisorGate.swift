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
    private let pidWaitPollInterval: Duration

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
        orphanGracePeriod: Duration = .seconds(3),
        pidWaitPollInterval: Duration = .milliseconds(100)
    ) {
        self.runner = runner
        self.pidExists = pidExists
        self.terminate = terminate
        self.clock = clock
        self.orphanGracePeriod = orphanGracePeriod
        self.pidWaitPollInterval = pidWaitPollInterval
    }

    internal func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        let healthDir = journalRoot.appendingPathComponent("health", isDirectory: true)
        if let pid = readSupervisorPID(from: healthDir.appendingPathComponent("supervisor.pid")),
           let recordedStartTime = readSupervisorStartTime(from: healthDir.appendingPathComponent("supervisor.start_time")),
           pidExists(pid) {
            // The journalRoot that contains health/ is the journal-path authority.
            // We compare the marker against `ps -o lstart=` for deterministic PID
            // identity; process title is only logged as a diagnostic fallback.
            if let liveStartTime = await processStartTime(pid: pid),
               liveStartTime == recordedStartTime {
                let title = await processTitle(pid: pid) ?? ""
                Logger.setup.warning("single-supervisor gate found existing supervisor pid=\(pid, privacy: .public) title=\(title, privacy: .public)")
                Logger.setup.warning("journal-lifecycle: gate-terminate signal=SIGTERM pid=\(pid, privacy: .public)")
                _ = terminate(pid, SIGTERM)
                let exited = await waitForPIDExit(
                    pid: pid,
                    timeout: orphanGracePeriod,
                    pollInterval: pidWaitPollInterval,
                    pidExists: pidExists,
                    clock: clock
                )
                if !exited {
                    Logger.setup.warning("journal-lifecycle: gate-terminate signal=SIGKILL pid=\(pid, privacy: .public)")
                    _ = terminate(pid, SIGKILL)
                }
            } else {
                let title = await processTitle(pid: pid) ?? ""
                Logger.setup.notice("journal-lifecycle: gate-ignored-stale-marker pid=\(pid, privacy: .public) title=\(title, privacy: .public)")
            }
        }

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

    private func processStartTime(pid: pid_t) async -> String? {
        let output = LockedSupervisorGateOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-p", String(pid), "-o", "lstart="],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else { return nil }
            let startTime = output.string().trimmingCharacters(in: .whitespacesAndNewlines)
            return startTime.isEmpty ? nil : startTime
        } catch {
            return nil
        }
    }

    private func processTitle(pid: pid_t) async -> String? {
        let output = LockedSupervisorGateOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-p", String(pid), "-o", "command="],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else { return nil }
            let title = output.string().trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        } catch {
            return nil
        }
    }
}

private final class LockedSupervisorGateOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }

    func string() -> String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}
