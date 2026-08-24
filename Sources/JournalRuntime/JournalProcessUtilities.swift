// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

internal struct CleanupFailure {
    let step: CleanupStep
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
    let pid: String
    var command: String?
    var hasName = false
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
    evidenceReader: any JournalProcessEvidenceReading = LiveJournalProcessEvidenceReader(),
    launchdPIDProvider: (@Sendable () async -> LegacyJournalServicePIDLookup)? = nil,
    pidExists: @Sendable (pid_t) -> Bool,
    terminate: @Sendable (pid_t, Int32) -> Int32,
    gracePeriod: Duration,
    clock: any MonotonicClock
) async -> CleanupFailure? {
    let launchdPIDLookup = await readLegacyLaunchdPID(
        runner: runner,
        launchdPIDProvider: launchdPIDProvider
    )
    guard case .known(let launchdPID) = launchdPIDLookup else {
        return CleanupFailure(step: .orphanSweep, message: "legacy service state could not be inspected")
    }

    let claim = await readJournalOrphanClaim(
        journalRoot: journalRoot,
        evidenceReader: evidenceReader,
        launchdReportedPID: launchdPID
    )
    guard case .selected(let pid) = claim.verification else {
        logOrphanSweepNoop(reason: claim.rejectionReason)
        return nil
    }

    let recheckLaunchdPIDLookup = await readLegacyLaunchdPID(
        runner: runner,
        launchdPIDProvider: launchdPIDProvider
    )
    guard case .known(let recheckLaunchdPID) = recheckLaunchdPIDLookup else {
        return CleanupFailure(step: .orphanSweep, message: "legacy service state could not be inspected")
    }
    let recheckedClaim = await readJournalOrphanClaim(
        journalRoot: journalRoot,
        evidenceReader: evidenceReader,
        launchdReportedPID: recheckLaunchdPID
    )
    guard recheckedClaim.verification.selectedPID == pid else {
        logOrphanSweepNoop(reason: recheckedClaim.rejectionReason)
        return CleanupFailure(step: .orphanSweep, message: "journal orphan changed before signal")
    }

    _ = terminate(pid, SIGTERM)

    await clock.sleep(for: gracePeriod)

    let survived = pidExists(pid)
    if survived {
        _ = terminate(pid, SIGKILL)
    }

    Logger.setup.notice("journal orphan sweep outcome=success matched=1 terminated=1 survivors=\(survived ? 1 : 0, privacy: .public)")
    return nil
}

private struct JournalOrphanClaimRead {
    let verification: JournalOrphanClaimVerification

    var rejectionReason: JournalOrphanClaimRejection {
        if case .notSelected(let reason) = verification {
            return reason
        }
        return .deadPID
    }
}

private func readJournalOrphanClaim(
    journalRoot: URL,
    evidenceReader: any JournalProcessEvidenceReading,
    launchdReportedPID: pid_t?
) async -> JournalOrphanClaimRead {
    let claimedPID = readSupervisorPID(from: journalRoot.appendingPathComponent("health/supervisor.pid"))
    let recordedStartTime = readSupervisorStartTime(from: journalRoot.appendingPathComponent("health/supervisor.start_time"))
    let evidence: JournalProcessEvidence?
    if let claimedPID {
        evidence = await evidenceReader.evidence(for: claimedPID)
    } else {
        evidence = nil
    }
    return JournalOrphanClaimRead(verification: verifyJournalOrphanClaim(
        claimedPID: claimedPID,
        recordedStartTime: recordedStartTime,
        evidence: evidence,
        currentUID: getuid(),
        currentUsername: currentUsername(),
        ownPID: getpid(),
        launchdReportedPID: launchdReportedPID
    ))
}

private func readLegacyLaunchdPID(
    runner: SubprocessRunning,
    launchdPIDProvider: (@Sendable () async -> LegacyJournalServicePIDLookup)?
) async -> LegacyJournalServicePIDLookup {
    if let launchdPIDProvider {
        return await launchdPIDProvider()
    }
    return await LegacyJournalServiceRetirer(runner: runner).currentLegacyServicePID()
}

private func logOrphanSweepNoop(reason: JournalOrphanClaimRejection) {
    Logger.setup.notice("journal orphan sweep outcome=noop reason=\(reason.rawValue, privacy: .public) matched=0 terminated=0 survivors=0")
}

internal func assertPortsReleased(
    resolution: JournalDirectDoorPortResolution,
    runner: SubprocessRunning
) async -> CleanupFailure? {
    for port in JournalLifecyclePortPreflight.orderedPorts(for: resolution) {
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

internal func assertStartupPortsAvailable(
    resolution: JournalDirectDoorPortResolution,
    runner: SubprocessRunning,
    clock: any MonotonicClock
) async -> StartupPortProbeFailure? {
    let retryDelays: [Duration] = [.seconds(2), .seconds(3)]

    for port in JournalLifecyclePortPreflight.orderedPorts(for: resolution) {
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
                if attempt < retryDelays.count {
                    await clock.sleep(for: retryDelays[attempt])
                    continue
                }
                return StartupPortProbeFailure(
                    kind: .conflict,
                    message: startupPortConflictMessage(port: port, output: output.string())
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

private func startupPortConflictMessage(port: Int, output: String) -> String {
    let culprits = parseStartupPortCulprits(output)
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
            current = value.isEmpty ? nil : StartupPortCulprit(pid: value)
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

internal func readSupervisorStartTime(from url: URL) -> Double? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Double(trimmed), value.isFinite else { return nil }
    return value
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
