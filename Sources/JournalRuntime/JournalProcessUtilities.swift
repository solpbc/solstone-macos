// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

internal enum CleanupFailureKind {
    case orphanOwnershipUnverified
    case orphanRetirementFailed
    case portConflict
    case portVerificationFailed
}

internal struct CleanupFailure {
    let step: CleanupStep
    let kind: CleanupFailureKind
    let message: String
}

internal enum StartupPortProbeFailureKind: Equatable, Sendable {
    case conflict
    case couldNotVerify
}

internal struct StartupPortProbeFailure: Equatable, Sendable {
    let kind: StartupPortProbeFailureKind
    let message: String
}

private struct StartupPortCulprit {
    let pid: pid_t
    var command: String?
    var hasName = false
}

internal struct JournalProcessRow: Equatable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let command: String
}

internal struct JournalOrphanSelection: Equatable, Sendable {
    let rowCount: Int
    let selected: [pid_t]
    let protected: [pid_t]
    let ambiguous: [pid_t]
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
    journalRoot: URL,
    runner: SubprocessRunning,
    pidExists: @Sendable (pid_t) -> Bool,
    terminate: @Sendable (pid_t, Int32) -> Int32,
    gracePeriod: Duration,
    clock: any MonotonicClock,
    protectedLaunchdPIDs: Set<pid_t> = [],
    excludedPIDs: Set<pid_t> = [],
    environmentReader: ProcessEnvironmentReading = defaultProcessEnvironment,
    currentUID: uid_t = getuid()
) async -> CleanupFailure? {
    let output = LockedProcessUtilityOutput()
    let result: SubprocessResult
    do {
        result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,uid=,command="],
            environment: nil,
            stdoutHandler: { data in
                output.append(data)
            },
            stderrHandler: { _ in }
        )
    } catch {
        return CleanupFailure(step: .orphanSweep, kind: .orphanOwnershipUnverified, message: "ps failed to launch")
    }

    guard result.exitCode == 0 else {
        return CleanupFailure(step: .orphanSweep, kind: .orphanOwnershipUnverified, message: "ps exited \(result.exitCode)")
    }

    let psOutput = output.string()
    let selection = selectJournalOrphans(
        from: parseJournalProcessRows(psOutput),
        rowCount: countParsedPsRows(psOutput),
        journalRoot: journalRoot,
        protectedLaunchdPIDs: protectedLaunchdPIDs,
        excludedPIDs: excludedPIDs,
        environmentReader: environmentReader,
        currentUID: currentUID
    )
    guard selection.ambiguous.isEmpty else {
        Logger.setup.warning("journal-lifecycle: orphan-sweep outcome=blocked rows=\(selection.rowCount, privacy: .public) ambiguous=\(selection.ambiguous.count, privacy: .public)")
        return CleanupFailure(
            step: .orphanSweep,
            kind: .orphanOwnershipUnverified,
            message: "journal process ownership could not be verified"
        )
    }
    let pids = selection.selected
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

    Logger.setup.notice("journal-lifecycle: orphan-sweep outcome=success rows=\(selection.rowCount, privacy: .public) selected=\(pids.count, privacy: .public) protected=\(selection.protected.count, privacy: .public) terminated=\(termCount, privacy: .public) survivors=\(survivors.count, privacy: .public)")
    guard survivors.isEmpty else {
        return CleanupFailure(
            step: .orphanSweep,
            kind: .orphanRetirementFailed,
            message: "old journal process could not be cleared"
        )
    }
    return nil
}

internal func parseJournalProcessRows(_ output: String) -> [JournalProcessRow] {
    output.split(separator: "\n").compactMap { line -> JournalProcessRow? in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]),
              let uid = UInt32(parts[2]),
              pid > 0 else {
            return nil
        }
        return JournalProcessRow(
            pid: pid_t(pid),
            ppid: pid_t(ppid),
            uid: uid_t(uid),
            command: String(parts[3])
        )
    }
}

internal func countParsedPsRows(_ output: String) -> Int {
    parseJournalProcessRows(output).count
}

internal func selectJournalOrphans(
    from rows: [JournalProcessRow],
    rowCount: Int,
    journalRoot: URL,
    protectedLaunchdPIDs: Set<pid_t>,
    excludedPIDs: Set<pid_t>,
    environmentReader: ProcessEnvironmentReading,
    currentUID: uid_t = getuid()
) -> JournalOrphanSelection {
    let canonicalRoot = SolOwnership.canonicalPath(journalRoot.path)
    var selected: [pid_t] = []
    var protected: [pid_t] = []
    var ambiguous: [pid_t] = []

    for row in rows {
        guard row.ppid == 1,
              row.uid == currentUID,
              row.command.hasPrefix("journal:") else {
            continue
        }
        if excludedPIDs.contains(row.pid) || protectedLaunchdPIDs.contains(row.pid) {
            protected.append(row.pid)
            continue
        }
        guard let environment = environmentReader(row.pid),
              let rawJournal = environment["SOLSTONE_JOURNAL"],
              !rawJournal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ambiguous.append(row.pid)
            continue
        }
        let processRoot = SolOwnership.canonicalPath(rawJournal)
        if processRoot == canonicalRoot {
            selected.append(row.pid)
        } else {
            protected.append(row.pid)
        }
    }

    return JournalOrphanSelection(
        rowCount: rowCount,
        selected: selected,
        protected: protected,
        ambiguous: ambiguous
    )
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
                kind: .portVerificationFailed,
                message: "lsof failed to launch probing port \(port)"
            )
        }

        switch result.exitCode {
        case 1:
            continue
        case 0:
            return CleanupFailure(
                step: .ports,
                kind: .portConflict,
                message: "port \(port) still bound after sweep"
            )
        default:
            return CleanupFailure(
                step: .ports,
                kind: .portVerificationFailed,
                message: "lsof exited \(result.exitCode) probing port \(port)"
            )
        }
    }
    return nil
}

internal func assertStartupPortsAvailable(
    ports: [Int],
    runner: SubprocessRunning,
    clock: any MonotonicClock,
    excludedPIDs: Set<pid_t> = []
) async -> StartupPortProbeFailure? {
    let retryDelays: [Duration] = [.seconds(2), .seconds(3)]

    for port in ports {
        for attempt in 0...retryDelays.count {
            let output = LockedProcessUtilityOutput()
            let result: SubprocessResult
            do {
                result = try await runner.run(
                    executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F"],
                    environment: nil,
                    stdoutHandler: { data in
                        output.append(data)
                    },
                    stderrHandler: { _ in }
                )
            } catch {
                return StartupPortProbeFailure(
                    kind: .couldNotVerify,
                    message: "lsof failed to launch probing port \(port)"
                )
            }

            switch result.exitCode {
            case 1:
                break
            case 0:
                guard let message = startupPortConflictMessage(
                    port: port,
                    output: output.string(),
                    excludedPIDs: excludedPIDs
                ) else {
                    break
                }
                if attempt < retryDelays.count {
                    await clock.sleep(for: retryDelays[attempt])
                    continue
                }
                return StartupPortProbeFailure(
                    kind: .conflict,
                    message: message
                )
            default:
                return StartupPortProbeFailure(
                    kind: .couldNotVerify,
                    message: "lsof exited \(result.exitCode) probing port \(port)"
                )
            }
            break
        }
    }
    return nil
}

private func startupPortConflictMessage(
    port: Int,
    output: String,
    excludedPIDs: Set<pid_t>
) -> String? {
    let allCulprits = parseStartupPortCulprits(output)
    guard !allCulprits.isEmpty else {
        return unidentifiedStartupPortMessage(port: port)
    }
    let activeCulprits = allCulprits.filter { !excludedPIDs.contains($0.pid) }
    guard !activeCulprits.isEmpty else {
        return nil
    }
    let culprits = activeCulprits
        .filter(\.hasName)
    guard !culprits.isEmpty else {
        return unidentifiedStartupPortMessage(port: port)
    }
    return culprits
        .map { culprit in
            guard let command = culprit.command, !command.isEmpty else {
                return unidentifiedStartupPortMessage(port: port)
            }
            return "journal port \(port) is held by \(command) (pid \(culprit.pid))"
        }
        .joined(separator: "\n")
}

private func unidentifiedStartupPortMessage(port: Int) -> String {
    "journal port \(port) is held by an unidentified process"
}

private func parseStartupPortCulprits(_ output: String) -> [StartupPortCulprit] {
    var culprits: [StartupPortCulprit] = []
    var current: StartupPortCulprit?

    func flushCurrent() {
        guard let current else { return }
        if let index = culprits.firstIndex(where: { $0.pid == current.pid }) {
            if culprits[index].command == nil {
                culprits[index].command = current.command
            }
            culprits[index].hasName = culprits[index].hasName || current.hasName
        } else {
            culprits.append(current)
        }
    }

    for rawLine in output.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        guard let field = line.first else { continue }
        let value = String(line.dropFirst())
        switch field {
        case "p":
            flushCurrent()
            if let pid = Int32(value), pid > 0 {
                current = StartupPortCulprit(pid: pid_t(pid))
            } else {
                current = nil
            }
        case "c":
            current?.command = value.isEmpty ? nil : value
        case "n":
            current?.hasName = true
        default:
            continue
        }
    }
    flushCurrent()
    return culprits
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
