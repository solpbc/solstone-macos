// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
@preconcurrency import Foundation
import os
import SolstoneCore

public protocol SupervisedChildRunning: Sendable {
    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws
    func restart() async throws
    func stop() async
    func stopForTermination() async
    func currentRuntimeKey() async -> String?
    func terminalReason() async -> JournalDiagnostic?
    func markReady() async
}

public enum SupervisedJournalRunnerError: LocalizedError, Sendable, Equatable {
    case alreadyStopped
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStopped:
            return "journal child is not configured"
        case .launchFailed(let message):
            return message
        }
    }
}

public actor SupervisedJournalRunner: SupervisedChildRunning {
    private struct LaunchRequest: Sendable {
        let runtime: MaterializedRuntime
        let journalRoot: URL
        let port: Int
    }

    private let clock: any MonotonicClock
    private let statusSink: @Sendable (JournalRuntimeStatus) -> Void
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let backoffSchedule: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(30)
    ]
    private let restartWindow: Duration = .seconds(60)
    private let restartLimit = 5
    private let stabilityThreshold: Duration = .seconds(30)
    private let terminationWait: Duration = .seconds(10)
    private let terminationGrace: Duration = .seconds(2)

    private var process: Process?
    private var parentWriteHandle: FileHandle?
    private var launchRequest: LaunchRequest?
    private var currentKey: String?
    private var stopping = false
    private var breakerTripped = false
    private var terminalDiagnostic: JournalDiagnostic?
    private var backoffIndex = 0
    private var unexpectedExitTimes: [Duration] = []
    private var stabilityTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        }
    ) {
        self.clock = clock
        self.statusSink = statusSink
        self.pidExists = pidExists
        self.terminate = terminate
    }

    public func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        Logger.journal.notice("journal-lifecycle: runner-start port=\(port, privacy: .public)")
        await cancelPendingRelaunch()
        launchRequest = LaunchRequest(runtime: runtime, journalRoot: journalRoot, port: port)
        currentKey = runtime.key
        breakerTripped = false
        terminalDiagnostic = nil
        stopping = false
        try await launch(runtime: runtime, journalRoot: journalRoot, port: port)
    }

    public func restart() async throws {
        guard let launchRequest else {
            throw SupervisedJournalRunnerError.alreadyStopped
        }
        Logger.journal.notice("journal-lifecycle: runner-restart transition=restarting")
        statusSink(.restarting)
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        stopping = false
        breakerTripped = false
        terminalDiagnostic = nil
        try await launch(runtime: launchRequest.runtime, journalRoot: launchRequest.journalRoot, port: launchRequest.port)
    }

    public func stop() async {
        Logger.journal.notice("journal-lifecycle: runner-stop")
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        launchRequest = nil
        currentKey = nil
        terminalDiagnostic = nil
        stabilityTask?.cancel()
        stabilityTask = nil
    }

    public func stopForTermination() async {
        Logger.journal.notice("journal-lifecycle: runner-stop-for-termination")
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
    }

    public func currentRuntimeKey() async -> String? {
        currentKey
    }

    public func terminalReason() async -> JournalDiagnostic? {
        terminalDiagnostic
    }

    public func markReady() async {
        statusSink(.running)
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            guard let self else { return }
            await self.sleepForStabilityAndReset()
        }
    }

    private func launch(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        if process?.isRunning == true {
            await stopCurrentProcess()
        }

        let proc = Process()
        proc.executableURL = runtime.layout.journalBinary
        proc.currentDirectoryURL = journalRoot
        proc.arguments = ["start", "--app-supervised", String(port)]
        proc.environment = runtime.layout.uvEnvironment()

        let parentPipe = Pipe()
        proc.standardInput = parentPipe.fileHandleForReading
        parentWriteHandle = parentPipe.fileHandleForWriting

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Logger.journal.info("\(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Logger.journal.warning("\(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }
        proc.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task {
                await self?.childExited(status: status)
            }
        }

        do {
            process = proc
            try proc.run()
            Logger.journal.notice("journal-lifecycle: runner-child-launched pid=\(proc.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
        } catch {
            process = nil
            parentWriteHandle = nil
            throw SupervisedJournalRunnerError.launchFailed(error.localizedDescription)
        }
    }

    private func childExited(status: Int32) async {
        process = nil
        parentWriteHandle = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        await cancelPendingRelaunch()

        let expectedStop = stopping
        if expectedStop {
            Logger.journal.notice("journal-lifecycle: child-exit status=\(status, privacy: .public) expected=true")
        }
        guard !expectedStop, !breakerTripped else { return }
        recordUnexpectedExit()
        Logger.journal.warning("journal-lifecycle: child-exit status=\(status, privacy: .public) expected=false unexpectedCount=\(self.unexpectedExitTimes.count, privacy: .public)")
        if unexpectedExitTimes.count >= restartLimit {
            breakerTripped = true
            Logger.journal.error("journal-lifecycle: runner-breaker-tripped status=\(status, privacy: .public) unexpectedCount=\(self.unexpectedExitTimes.count, privacy: .public)")
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                exitCode: status,
                outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
            )
            terminalDiagnostic = diagnostic
            statusSink(.stopped(diagnostic))
            return
        }

        guard launchRequest != nil else { return }
        let delay = backoffSchedule[min(backoffIndex, backoffSchedule.count - 1)]
        backoffIndex = min(backoffIndex + 1, backoffSchedule.count - 1)
        relaunchTask = Task { [weak self] in
            await self?.performBackoffRelaunch(delay: delay)
        }
    }

    private func cancelPendingRelaunch() async {
        relaunchTask?.cancel()
        await relaunchTask?.value
        relaunchTask = nil
    }

    private func performBackoffRelaunch(delay: Duration) async {
        await clock.sleep(for: delay)
        guard !Task.isCancelled, !stopping, !breakerTripped, let launchRequest else { return }
        Logger.journal.notice("journal-lifecycle: runner-backoff-relaunch delaySeconds=\(delay.components.seconds, privacy: .public)")
        do {
            try await launch(runtime: launchRequest.runtime, journalRoot: launchRequest.journalRoot, port: launchRequest.port)
        } catch {
            Logger.journal.error("journal-lifecycle: runner-backoff-relaunch-failed")
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            )
            terminalDiagnostic = diagnostic
            statusSink(.stopped(diagnostic))
        }
    }

    private func recordUnexpectedExit() {
        let now = clock.now()
        unexpectedExitTimes = unexpectedExitTimes
            .filter { now - $0 <= restartWindow }
        unexpectedExitTimes.append(now)
    }

    private func sleepForStabilityAndReset() async {
        await clock.sleep(for: stabilityThreshold)
        guard !Task.isCancelled, process?.isRunning == true else { return }
        backoffIndex = 0
        unexpectedExitTimes.removeAll()
    }

    private func stopCurrentProcess() async {
        parentWriteHandle?.readabilityHandler = nil
        try? parentWriteHandle?.close()
        parentWriteHandle = nil

        guard let child = process else { return }
        await waitForProcessExit(child, timeout: terminationWait)
        if child.isRunning {
            _ = terminate(child.processIdentifier, SIGTERM)
            await waitForProcessExit(child, timeout: terminationGrace)
        }
        if child.isRunning {
            _ = terminate(child.processIdentifier, SIGKILL)
        }
        process = nil
    }

    private func waitForProcessExit(_ child: Process, timeout: Duration) async {
        let deadline = clock.now() + timeout
        while clock.now() < deadline {
            if !child.isRunning || !pidExists(child.processIdentifier) {
                return
            }
            await clock.sleep(for: .milliseconds(100))
        }
    }
}
