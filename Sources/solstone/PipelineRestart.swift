// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

internal enum RestartFailureStep: CaseIterable, Sendable {
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
            return "serv" + "ice-restart"
        case .reProbe:
            return "re-probe"
        }
    }
}

internal struct PipelineRestartFailure: Error, Equatable, Sendable {
    let step: RestartFailureStep
    let ownerMessage: String
}

internal enum PipelineRestartOutcome: Equatable, Sendable {
    case success
    case failure(PipelineRestartFailure)
}

internal struct PipelineRestartLogEvent: Equatable, Sendable {
    let step: RestartFailureStep
    let outcome: String
    let detail: String?
}

internal struct PipelineDebounceState: Sendable {
    private(set) var consecutiveFailures = 0
    private(set) var firstFailureAt: Date?

    mutating func reset() {
        consecutiveFailures = 0
        firstFailureAt = nil
    }

    mutating func apply(
        outcome: PipelineLivenessProbeOutcome,
        now: Date,
        currentlyDead: Bool
    ) -> (pipelineDead: Bool, pipelineBinaryMissing: Bool) {
        switch outcome {
        case .reachable:
            reset()
            return (false, false)
        case .binaryMissing:
            reset()
            return (false, true)
        case .unreachable:
            if currentlyDead {
                return (true, false)
            }
            if firstFailureAt == nil {
                firstFailureAt = now
            }
            consecutiveFailures += 1
            let span = now.timeIntervalSince(firstFailureAt ?? now)
            return (consecutiveFailures >= 3 && span >= 10.0, false)
        }
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
        guard pid > 0, ppid == 1, command.hasPrefix("sol:") else {
            return nil
        }
        return pid_t(pid)
    }
}

internal func moveAsideStaleStateFiles(
    journalRoot: URL,
    fileManager: FileManager = .default
) -> [PipelineRestartLogEvent] {
    staleStateRelativePaths.map { relativePath in
        let fileURL = journalRoot.appendingPathComponent(relativePath)
        let backupURL = URL(fileURLWithPath: fileURL.path + ".bak")

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return PipelineRestartLogEvent(
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
            return PipelineRestartLogEvent(
                step: .staleStateMoveAside,
                outcome: "success",
                detail: "\(relativePath):moved"
            )
        } catch {
            return PipelineRestartLogEvent(
                step: .staleStateMoveAside,
                outcome: "error",
                detail: "\(relativePath):\(error.localizedDescription)"
            )
        }
    }
}

internal struct PipelineRestartRunner: @unchecked Sendable {
    private let runner: SubprocessRunning
    private let journalPathProvider: @Sendable (String) async -> String?
    private let terminate: @Sendable (pid_t) -> Void
    private let fileManager: FileManager
    private let reprobe: @Sendable () async -> PipelineLivenessProbeOutcome
    private let logSink: (@Sendable (PipelineRestartLogEvent) -> Void)?
    private let solPath: String

    internal init(
        runner: SubprocessRunning = SubprocessRunner(),
        journalPathProvider: (@Sendable (String) async -> String?)? = nil,
        terminate: @escaping @Sendable (pid_t) -> Void = { pid in
            _ = Darwin.kill(pid, SIGTERM)
        },
        fileManager: FileManager = .default,
        reprobe: @escaping @Sendable () async -> PipelineLivenessProbeOutcome,
        logSink: (@Sendable (PipelineRestartLogEvent) -> Void)? = nil,
        solPath: String
    ) {
        self.runner = runner
        self.journalPathProvider = journalPathProvider ?? { solPath in
            await Self.defaultJournalPathProvider(solPath: solPath, runner: runner)
        }
        self.terminate = terminate
        self.fileManager = fileManager
        self.reprobe = reprobe
        self.logSink = logSink
        self.solPath = solPath
    }

    internal func run() async -> PipelineRestartOutcome {
        guard let journalPath = await journalPathProvider(solPath) else {
            let failure = PipelineRestartFailure(
                step: .resolveJournal,
                ownerMessage: "restart failed at journal path — could not find the journal"
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

        let restartResult: SubprocessResult
        do {
            restartResult = try await runner.run(
                executable: URL(fileURLWithPath: solPath),
                arguments: ["service", "restart"],
                environment: nil,
                stdoutHandler: { _ in },
                stderrHandler: { _ in }
            )
        } catch {
            let failure = PipelineRestartFailure(
                step: .serviceRestart,
                ownerMessage: "restart failed at pipeline restart — command did not complete"
            )
            emit(step: .serviceRestart, outcome: "error", detail: error.localizedDescription)
            return .failure(failure)
        }
        guard restartResult.exitCode == 0 else {
            let failure = PipelineRestartFailure(
                step: .serviceRestart,
                ownerMessage: "restart failed at pipeline restart — command did not complete"
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
                let failure = PipelineRestartFailure(
                    step: .reProbe,
                    ownerMessage: "restart failed at pipeline check — pipeline did not come back"
                )
                emit(step: .reProbe, outcome: "error", detail: "\(outcome)")
                return .failure(failure)
            }
            emit(step: .reProbe, outcome: "success", detail: nil)
            return .success
        } catch {
            let failure = PipelineRestartFailure(
                step: .reProbe,
                ownerMessage: "restart failed at pipeline check — pipeline did not come back"
            )
            emit(step: .reProbe, outcome: "error", detail: error.localizedDescription)
            return .failure(failure)
        }
    }

    private static func defaultJournalPathProvider(
        solPath: String,
        runner: SubprocessRunning
    ) async -> String? {
        let output = LockedPipelineOutput()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: solPath),
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
        let output = LockedPipelineOutput()
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

    private func emitMoveAsideSummary(_ events: [PipelineRestartLogEvent]) {
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

    private func emit(step: RestartFailureStep, outcome: String, detail: String?) {
        let event = PipelineRestartLogEvent(step: step, outcome: outcome, detail: detail)
        let detailSuffix = detail.map { " detail=\($0)" } ?? ""
        if outcome == "error" {
            Logger.setup.warning("pipeline-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        } else {
            Logger.setup.info("pipeline-restart step=\(step.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)\(detailSuffix, privacy: .public)")
        }
        logSink?(event)
    }
}

private final class LockedPipelineOutput: @unchecked Sendable {
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
