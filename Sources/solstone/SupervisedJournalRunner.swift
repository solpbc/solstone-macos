// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
@preconcurrency import Foundation
import os
import SolstoneCore

internal protocol SupervisedChildRunning: Sendable {
    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws
    func restart() async throws
    func stop() async
    func stopForTermination() async
    func currentRuntimeKey() async -> String?
    func markReady() async
}

internal enum SupervisedJournalRunnerError: LocalizedError, Sendable, Equatable {
    case alreadyStopped
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStopped:
            return "journal child is not configured"
        case .launchFailed(let message):
            return message
        }
    }
}

internal actor SupervisedJournalRunner: SupervisedChildRunning {
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
    private var backoffIndex = 0
    private var unexpectedExitTimes: [Duration] = []
    private var stabilityTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    internal init(
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

    internal func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        await cancelPendingRelaunch()
        launchRequest = LaunchRequest(runtime: runtime, journalRoot: journalRoot, port: port)
        currentKey = runtime.key
        breakerTripped = false
        stopping = false
        try await launch(runtime: runtime, journalRoot: journalRoot, port: port)
    }

    internal func restart() async throws {
        guard let launchRequest else {
            throw SupervisedJournalRunnerError.alreadyStopped
        }
        statusSink(.restarting)
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        stopping = false
        breakerTripped = false
        try await launch(runtime: launchRequest.runtime, journalRoot: launchRequest.journalRoot, port: launchRequest.port)
    }

    internal func stop() async {
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        launchRequest = nil
        currentKey = nil
        stabilityTask?.cancel()
        stabilityTask = nil
    }

    internal func stopForTermination() async {
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
    }

    internal func currentRuntimeKey() async -> String? {
        currentKey
    }

    internal func markReady() async {
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
            Logger.journal.info("journal child launched pid=\(proc.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
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
        guard !expectedStop, !breakerTripped else { return }
        recordUnexpectedExit()
        if unexpectedExitTimes.count >= restartLimit {
            breakerTripped = true
            statusSink(.stopped(JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                exitCode: status,
                outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
            )))
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
        do {
            try await launch(runtime: launchRequest.runtime, journalRoot: launchRequest.journalRoot, port: launchRequest.port)
        } catch {
            statusSink(.stopped(JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            )))
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
