// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

internal enum JournalRestartStep: CaseIterable, Sendable {
    case resolveJournal
    case orphanSweep
    case staleStateMoveAside
    case serviceRestart
    case reProbe

    var rawValue: String {
        switch self {
        case .resolveJournal:
            return "resolve-journal"
        case .orphanSweep:
            return "orphan-sweep"
        case .staleStateMoveAside:
            return "stale-state-move-aside"
        case .serviceRestart:
            return "journal-restart"
        case .reProbe:
            return "re-probe"
        }
    }
}

internal struct JournalRestartFailure: Error, Equatable, Sendable {
    let step: JournalRestartStep
    let ownerMessage: String
    let diagnostic: JournalDiagnostic
}

internal enum JournalRestartOutcome: Equatable, Sendable {
    case success
    case failure(JournalRestartFailure)
}

internal struct JournalRestartLogEvent: Equatable, Sendable {
    let step: JournalRestartStep
    let outcome: String
    let detail: String?
}

internal struct JournalRuntimeDebounceState: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var firstFailureAt: Date?

    mutating func reset() {
        consecutiveFailures = 0
        firstFailureAt = nil
    }

    mutating func apply(
        outcome: JournalRuntimeProbeOutcome,
        now: Date,
        currentStatus: JournalRuntimeStatus
    ) -> JournalRuntimeStatus {
        switch outcome {
        case .reachable:
            reset()
            return .running
        case .binaryMissing:
            reset()
            return .setupNeeded
        case .unreachable(let diagnostic):
            return debouncedFailure(
                now: now,
                currentStatus: currentStatus,
                attentionStatus: .stopped(diagnostic)
            )
        case .unknown(let diagnostic):
            return debouncedFailure(
                now: now,
                currentStatus: currentStatus,
                attentionStatus: .unknown(diagnostic)
            )
        }
    }

    private mutating func debouncedFailure(
        now: Date,
        currentStatus: JournalRuntimeStatus,
        attentionStatus: JournalRuntimeStatus
    ) -> JournalRuntimeStatus {
        switch currentStatus {
        case .stopped, .unknown:
            return attentionStatus
        case .running, .stoppedByUser, .restarting, .setupNeeded:
            // Compiler-completeness only; AppState's probe guard skips stopped-by-user.
            break
        }
        if firstFailureAt == nil {
            firstFailureAt = now
        }
        consecutiveFailures += 1
        let span = now.timeIntervalSince(firstFailureAt ?? now)
        return consecutiveFailures >= 3 && span >= 10.0 ? attentionStatus : currentStatus
    }
}

internal let staleStateRelativePaths: [String] = [
    "health/supervisor.ready",
    "health/supervisor.pid",
    "health/supervisor.start_time",
    "health/supervisor.lock",
    "health/callosum.sock",
    "health/convey.port"
]

internal func parseJournalPath(from output: String) -> String? {
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("path: ") else { continue }
        let path = String(trimmed.dropFirst("path: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        return path.isEmpty ? nil : path
    }
    return nil
}

internal func parsePsOrphanRows(_ output: String) -> [pid_t] {
    output.split(separator: "\n").compactMap { line -> pid_t? in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]) else {
            return nil
        }
        let command = String(parts[2])
        // Runtime journal child process titles use this prefix; asserted per task and verified live by the calling session.
        guard pid > 0, ppid == 1, command.hasPrefix("journal:") else {
            return nil
        }
        return pid_t(pid)
    }
}

internal func moveAsideStaleStateFiles(
    journalRoot: URL,
    fileManager: FileManager = .default
) -> [JournalRestartLogEvent] {
    staleStateRelativePaths.map { relativePath in
        let fileURL = journalRoot.appendingPathComponent(relativePath)
        let backupURL = URL(fileURLWithPath: fileURL.path + ".bak")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return JournalRestartLogEvent(
                step: .staleStateMoveAside,
                outcome: "noop",
                detail: "\(relativePath):missing"
            )
        }

        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: fileURL, to: backupURL)
            return JournalRestartLogEvent(
                step: .staleStateMoveAside,
                outcome: "success",
                detail: "\(relativePath):moved"
            )
        } catch {
            return JournalRestartLogEvent(
                step: .staleStateMoveAside,
                outcome: "error",
                detail: "\(relativePath):\(error.localizedDescription)"
            )
        }
    }
}

internal struct JournalRestartRunner: @unchecked Sendable {
    private let runner: SubprocessRunning
    private let journalPathProvider: @Sendable (URL) async -> String?
    private let terminate: @Sendable (pid_t) -> Void
    private let fileManager: FileManager
    private let reprobe: @Sendable () async -> JournalRuntimeProbeOutcome
    private let logSink: (@Sendable (JournalRestartLogEvent) -> Void)?
    private let journalBinary: URL

    internal init(
        runner: SubprocessRunning = SubprocessRunner(),
        journalPathProvider: (@Sendable (URL) async -> String?)? = nil,
        terminate: @escaping @Sendable (pid_t) -> Void = { pid in
            _ = Darwin.kill(pid, SIGTERM)
        },
        fileManager: FileManager = .default,
        reprobe: @escaping @Sendable () async -> JournalRuntimeProbeOutcome,
        logSink: (@Sendable (JournalRestartLogEvent) -> Void)? = nil,
        journalBinary: URL
    ) {
        self.runner = runner
        self.journalPathProvider = journalPathProvider ?? { journalBinary in
            await Self.defaultJournalPathProvider(journalBinary: journalBinary, runner: runner)
        }
        self.terminate = terminate
        self.fileManager = fileManager
        self.reprobe = reprobe
        self.logSink = logSink
        self.journalBinary = journalBinary
    }

    internal func run() async -> JournalRestartOutcome {
        guard let journalPath = await journalPathProvider(journalBinary) else {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal config show",
                outputExcerpt: "no journal path"
            )
            let failure = JournalRestartFailure(
                step: .resolveJournal,
                ownerMessage: "restart failed — journal path could not be read",
                diagnostic: diagnostic
            )
            emit(step: .resolveJournal, outcome: "error", detail: "no-journal-path")
            return .failure(failure)
        }
        emit(step: .resolveJournal, outcome: "success", detail: journalPath)

        await runOrphanSweep()

        let moveEvents = moveAsideStaleStateFiles(
            journalRoot: URL(fileURLWithPath: journalPath, isDirectory: true),
            fileManager: fileManager
        )
        emitMoveAsideSummary(moveEvents)

        let output = LockedJournalOutput()
        let restartResult: SubprocessResult
        do {
            restartResult = try await runner.run(
                executable: journalBinary,
                arguments: ["service", "restart"],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { data in output.append(data) }
            )
        } catch {
            let failure = JournalRestartFailure(
                step: .serviceRestart,
                ownerMessage: "restart failed — journal did not restart",
                diagnostic: JournalDiagnostic(
                    commandLabel: "journal service restart",
                    outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
                )
            )
            emit(step: .serviceRestart, outcome: "error", detail: error.localizedDescription)
            return .failure(failure)
        }
        guard restartResult.exitCode == 0 else {
            let failure = JournalRestartFailure(
                step: .serviceRestart,
                ownerMessage: "restart failed — journal did not restart",
                diagnostic: JournalDiagnostic(
                    commandLabel: "journal service restart",
                    exitCode: restartResult.exitCode,
                    outputExcerpt: sanitizeJournalDiagnosticOutput(output.string)
                )
            )
            emit(step: .serviceRestart, outcome: "error", detail: "exit=\(restartResult.exitCode)")
            return .failure(failure)
        }
        emit(step: .serviceRestart, outcome: "success", detail: nil)

        do {
            let reprobe = self.reprobe
            let outcome = try await withTimeout(seconds: 10.0) {
                await reprobe()
            }
            guard outcome == .reachable else {
                let diagnostic = Self.postRestartDiagnostic(outcome: outcome)
                let failure = JournalRestartFailure(
                    step: .reProbe,
                    ownerMessage: "restart failed — journal did not come back",
                    diagnostic: diagnostic
                )
                emit(step: .reProbe, outcome: "error", detail: "\(outcome)")
                return .failure(failure)
            }
            emit(step: .reProbe, outcome: "success", detail: nil)
            return .success
        } catch {
            let failure = JournalRestartFailure(
                step: .reProbe,
                ownerMessage: "restart failed — journal did not come back",
                diagnostic: JournalDiagnostic(
                    commandLabel: "journal health",
                    timedOut: error is TimeoutError,
                    outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
                )
            )
            emit(step: .reProbe, outcome: "error", detail: error.localizedDescription)
            return .failure(failure)
        }
    }

    private static func postRestartDiagnostic(outcome: JournalRuntimeProbeOutcome) -> JournalDiagnostic {
        switch outcome {
        case .unreachable(let diagnostic), .unknown(let diagnostic):
            return JournalDiagnostic(
                commandLabel: diagnostic.commandLabel,
                timedOut: diagnostic.timedOut,
                exitCode: diagnostic.exitCode,
                outputExcerpt: diagnostic.outputExcerpt ?? "post-restart check failed"
            )
        case .binaryMissing:
            return JournalDiagnostic(commandLabel: "journal health", outputExcerpt: "journal binary missing after restart")
        case .reachable:
            return JournalDiagnostic(commandLabel: "journal health")
        }
    }

    private static func defaultJournalPathProvider(
        journalBinary: URL,
        runner: SubprocessRunning
    ) async -> String? {
        let output = LockedJournalOutput()
        do {
            let result = try await runner.run(
                executable: journalBinary,
                arguments: ["config", "show"],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else { return nil }
            return parseJournalPath(from: output.string)
        } catch {
            return nil
        }
    }

    private func runOrphanSweep() async {
        let output = LockedJournalOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,ppid=,comm="],
                environment: nil,
                stdoutHandler: { data in output.append(data) },
                stderrHandler: { _ in }
            )
            guard result.exitCode == 0 else {
                emit(step: .orphanSweep, outcome: "error", detail: "exit=\(result.exitCode)")
                return
            }
            let pids = parsePsOrphanRows(output.string)
            guard !pids.isEmpty else {
                emit(step: .orphanSweep, outcome: "noop", detail: "no-orphans")
                return
            }
            for pid in pids {
                terminate(pid)
            }
            emit(step: .orphanSweep, outcome: "success", detail: "terminated=\(pids.count)")
        } catch {
            emit(step: .orphanSweep, outcome: "error", detail: error.localizedDescription)
        }
    }

    private func emitMoveAsideSummary(_ events: [JournalRestartLogEvent]) {
        let moved = events.filter { $0.outcome == "success" }.count
        let errors = events.filter { $0.outcome == "error" }.count
        if errors > 0 {
            emit(step: .staleStateMoveAside, outcome: "error", detail: "moved=\(moved) errors=\(errors)")
        } else if moved == 0 {
            emit(step: .staleStateMoveAside, outcome: "noop", detail: "moved=0")
        } else {
            emit(step: .staleStateMoveAside, outcome: "success", detail: "moved=\(moved)")
        }
    }

    private func emit(step: JournalRestartStep, outcome: String, detail: String?) {
        let event = JournalRestartLogEvent(step: step, outcome: outcome, detail: detail)
        let detailSuffix = detail.map { " detail=\($0)" } ?? ""
        if outcome == "error" {
            Logger.setup.warning("journal-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        } else {
            Logger.setup.info("journal-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        }
        logSink?(event)
    }
}

private final class LockedJournalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var string: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }
}
