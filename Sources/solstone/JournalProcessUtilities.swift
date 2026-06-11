// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os

internal struct CleanupFailure {
    let step: CleanupStep
    let message: String
}

internal func waitForPIDExit(
    pid: pid_t,
    timeout: Duration,
    pollInterval: Duration,
    pidExists: @Sendable (pid_t) -> Bool,
    clock: any MonotonicClock
) async -> Bool {
    let deadline = clock.now() + timeout
    while clock.now() < deadline {
        if !pidExists(pid) {
            return true
        }
        await clock.sleep(for: pollInterval)
    }
    return !pidExists(pid)
}

internal func runJournalOrphanSweep(
    runner: SubprocessRunning,
    pidExists: @Sendable (pid_t) -> Bool,
    terminate: @Sendable (pid_t, Int32) -> Int32,
    gracePeriod: Duration,
    clock: any MonotonicClock
) async -> CleanupFailure? {
    let output = LockedProcessUtilityOutput()
    let result: SubprocessResult
    do {
        result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,comm="],
            environment: nil,
            stdoutHandler: { data in
                output.append(data)
            },
            stderrHandler: { _ in }
        )
    } catch {
        return CleanupFailure(step: .orphanSweep, message: "ps failed to launch")
    }

    guard result.exitCode == 0 else {
        return CleanupFailure(step: .orphanSweep, message: "ps exited \(result.exitCode)")
    }

    let pids = parsePsOrphanRows(output.string())
    var termCount = 0
    for pid in pids {
        _ = terminate(pid, SIGTERM)
        termCount += 1
    }

    await clock.sleep(for: gracePeriod)

    let survivors = pids.filter(pidExists)
    for pid in survivors {
        _ = terminate(pid, SIGKILL)
    }

    Logger.setup.info("journal orphan sweep parsed=\(pids.count, privacy: .public) term=\(termCount, privacy: .public) survivors=\(survivors.count, privacy: .public)")
    return nil
}

internal func assertPortsReleased(
    ports: [Int],
    runner: SubprocessRunning
) async -> CleanupFailure? {
    for port in ports {
        let result: SubprocessResult
        do {
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
                environment: nil,
                stdoutHandler: { _ in },
                stderrHandler: { _ in }
            )
        } catch {
            return CleanupFailure(
                step: .ports,
                message: "lsof failed to launch probing port \(port)"
            )
        }

        switch result.exitCode {
        case 1:
            continue
        case 0:
            return CleanupFailure(step: .ports, message: "port \(port) still bound after sweep")
        default:
            return CleanupFailure(step: .ports, message: "lsof exited \(result.exitCode) probing port \(port)")
        }
    }
    return nil
}

internal func readSupervisorPID(from url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int32(trimmed), value > 0 else { return nil }
    return pid_t(value)
}

private final class LockedProcessUtilityOutput: @unchecked Sendable {
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
