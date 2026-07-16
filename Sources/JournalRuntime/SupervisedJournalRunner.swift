// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
@preconcurrency import Foundation
import os
import SolstoneCore

public protocol SupervisedChildRunning: Sendable {
    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws -> JournalChildIdentity
    func restart() async throws -> JournalChildIdentity
    func stop() async
    func stopForTermination() async
    func currentRuntimeKey() async -> String?
    func terminalReason() async -> JournalDiagnostic?
    func isCurrentGeneration(_ generation: UInt64) async -> Bool
    func markReady(_ identity: JournalChildIdentity) async -> Bool
}

public enum SupervisedJournalRunnerError: LocalizedError, Sendable, Equatable {
    case alreadyStopped
    case launchFailed(String)
    case spawnBlocked(SingleSupervisorGateBlockage)
    case staleLaunch
    case identityUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyStopped:
            return "journal child is not configured"
        case .launchFailed(let message):
            return message
        case .spawnBlocked(let blockage):
            return blockage.ownerMessage
        case .staleLaunch:
            return "journal launch was superseded"
        case .identityUnavailable:
            return "journal child identity could not be verified"
        }
    }
}

internal protocol JournalChildProcess: AnyObject, Sendable {
    var executableURL: URL? { get set }
    var currentDirectoryURL: URL? { get set }
    var arguments: [String]? { get set }
    var environment: [String: String]? { get set }
    var standardInput: Any? { get set }
    var standardOutput: Any? { get set }
    var standardError: Any? { get set }
    var terminationHandler: (@Sendable (any JournalChildProcess) -> Void)? { get set }
    var processIdentifier: pid_t { get }
    var terminationStatus: Int32 { get }
    var isRunning: Bool { get }

    func run() throws
}

private final class FoundationJournalChildProcess: JournalChildProcess, @unchecked Sendable {
    private let process = Process()

    var executableURL: URL? {
        get { process.executableURL }
        set { process.executableURL = newValue }
    }

    var currentDirectoryURL: URL? {
        get { process.currentDirectoryURL }
        set { process.currentDirectoryURL = newValue }
    }

    var arguments: [String]? {
        get { process.arguments }
        set { process.arguments = newValue }
    }

    var environment: [String: String]? {
        get { process.environment }
        set { process.environment = newValue }
    }

    var standardInput: Any? {
        get { process.standardInput }
        set { process.standardInput = newValue }
    }

    var standardOutput: Any? {
        get { process.standardOutput }
        set { process.standardOutput = newValue }
    }

    var standardError: Any? {
        get { process.standardError }
        set { process.standardError = newValue }
    }

    var terminationHandler: (@Sendable (any JournalChildProcess) -> Void)? {
        didSet {
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.terminationHandler?(self)
            }
        }
    }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    var isRunning: Bool {
        process.isRunning
    }

    func run() throws {
        try process.run()
    }
}

public actor SupervisedJournalRunner: SupervisedChildRunning {
    private struct LaunchRequest: Sendable {
        let runtime: MaterializedRuntime
        let journalRoot: URL
        let port: Int
    }

    private let clock: any MonotonicClock
    private let authorizationGate: any SingleSupervisorGating
    private let statusSink: @Sendable (JournalRuntimeStatus) -> Void
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let processStartTime: ProcessStartTimeReading
    private let processFactory: @Sendable () -> any JournalChildProcess
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

    private var process: (any JournalChildProcess)?
    private var parentWriteHandle: FileHandle?
    private var launchRequest: LaunchRequest?
    private var currentKey: String?
    private var currentIdentity: JournalChildIdentity?
    private var lifecycleGeneration: UInt64 = 0
    private var stopping = false
    private var breakerTripped = false
    private var terminalDiagnostic: JournalDiagnostic?
    private var backoffIndex = 0
    private var unexpectedExitTimes: [Duration] = []
    private var stabilityTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        authorizationGate: any SingleSupervisorGating = SingleSupervisorGate(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        processStartTime: @escaping ProcessStartTimeReading = defaultProcessStartTime
    ) {
        self.init(
            clock: clock,
            authorizationGate: authorizationGate,
            statusSink: statusSink,
            pidExists: pidExists,
            terminate: terminate,
            processStartTime: processStartTime,
            processFactory: { FoundationJournalChildProcess() }
        )
    }

    internal init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        authorizationGate: any SingleSupervisorGating = SingleSupervisorGate(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        processStartTime: @escaping ProcessStartTimeReading = defaultProcessStartTime,
        processFactory: @escaping @Sendable () -> any JournalChildProcess
    ) {
        self.clock = clock
        self.authorizationGate = authorizationGate
        self.statusSink = statusSink
        self.pidExists = pidExists
        self.terminate = terminate
        self.processStartTime = processStartTime
        self.processFactory = processFactory
    }

    public func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws -> JournalChildIdentity {
        Logger.journal.notice("journal-lifecycle: runner-start port=\(port, privacy: .public)")
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let replacing = currentIdentity
        await cancelPendingRelaunch()
        launchRequest = LaunchRequest(runtime: runtime, journalRoot: journalRoot, port: port)
        currentKey = runtime.key
        breakerTripped = false
        terminalDiagnostic = nil
        stopping = false
        return try await launch(runtime: runtime, journalRoot: journalRoot, port: port, generation: generation, replacing: replacing)
    }

    public func restart() async throws -> JournalChildIdentity {
        guard let launchRequest else {
            throw SupervisedJournalRunnerError.alreadyStopped
        }
        Logger.journal.notice("journal-lifecycle: runner-restart transition=restarting")
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let replacing = currentIdentity
        statusSink(.restarting)
        await cancelPendingRelaunch()
        breakerTripped = false
        terminalDiagnostic = nil
        return try await launch(
            runtime: launchRequest.runtime,
            journalRoot: launchRequest.journalRoot,
            port: launchRequest.port,
            generation: generation,
            replacing: replacing
        )
    }

    public func stop() async {
        Logger.journal.notice("journal-lifecycle: runner-stop")
        lifecycleGeneration &+= 1
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        launchRequest = nil
        currentKey = nil
        currentIdentity = nil
        terminalDiagnostic = nil
        stabilityTask?.cancel()
        stabilityTask = nil
    }

    public func stopForTermination() async {
        Logger.journal.notice("journal-lifecycle: runner-stop-for-termination")
        lifecycleGeneration &+= 1
        stopping = true
        await cancelPendingRelaunch()
        await stopCurrentProcess()
        currentIdentity = nil
    }

    public func currentRuntimeKey() async -> String? {
        currentKey
    }

    public func terminalReason() async -> JournalDiagnostic? {
        terminalDiagnostic
    }

    public func isCurrentGeneration(_ generation: UInt64) async -> Bool {
        lifecycleGeneration == generation
    }

    public func markReady(_ identity: JournalChildIdentity) async -> Bool {
        guard currentIdentity == identity,
              lifecycleGeneration == identity.generation,
              let startTime = processStartTime(identity.pid),
              abs(startTime - identity.startTime) <= journalStartTimeToleranceS,
              pidExists(identity.pid) else {
            return false
        }
        statusSink(.running)
        stabilityTask?.cancel()
        stabilityTask = Task { [weak self] in
            guard let self else { return }
            await self.sleepForStabilityAndReset()
        }
        return true
    }

    private func launch(
        runtime: MaterializedRuntime,
        journalRoot: URL,
        port: Int,
        generation: UInt64,
        replacing: JournalChildIdentity?
    ) async throws -> JournalChildIdentity {
        guard lifecycleGeneration == generation, !stopping else {
            throw SupervisedJournalRunnerError.staleLaunch
        }

        switch await authorizationGate.prepareForSpawn(
            journalRoot: journalRoot,
            context: LaunchAuthorizationContext(excludedChild: replacing)
        ) {
        case .success:
            break
        case .blocked(let blockage):
            throw SupervisedJournalRunnerError.spawnBlocked(blockage)
        }

        guard lifecycleGeneration == generation, !stopping else {
            throw SupervisedJournalRunnerError.staleLaunch
        }

        if process?.isRunning == true {
            stopping = true
            await stopCurrentProcess()
            stopping = false
        }

        guard lifecycleGeneration == generation, !stopping else {
            throw SupervisedJournalRunnerError.staleLaunch
        }

        let proc = processFactory()
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
            guard let startTime = processStartTime(proc.processIdentifier) else {
                await stopCurrentProcess()
                throw SupervisedJournalRunnerError.identityUnavailable
            }
            let identity = JournalChildIdentity(
                pid: proc.processIdentifier,
                startTime: startTime,
                generation: generation
            )
            currentIdentity = identity
            Logger.journal.notice("journal-lifecycle: runner-child-launched pid=\(proc.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
            return identity
        } catch {
            process = nil
            currentIdentity = nil
            parentWriteHandle = nil
            if let runnerError = error as? SupervisedJournalRunnerError {
                throw runnerError
            }
            throw SupervisedJournalRunnerError.launchFailed(error.localizedDescription)
        }
    }

    private func childExited(status: Int32) async {
        process = nil
        currentIdentity = nil
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
        let generation = lifecycleGeneration
        relaunchTask = Task { [weak self] in
            await self?.performBackoffRelaunch(delay: delay, generation: generation)
        }
    }

    private func cancelPendingRelaunch() async {
        relaunchTask?.cancel()
        await relaunchTask?.value
        relaunchTask = nil
    }

    private func performBackoffRelaunch(delay: Duration, generation: UInt64) async {
        await clock.sleep(for: delay)
        guard !Task.isCancelled,
              !stopping,
              !breakerTripped,
              generation == lifecycleGeneration,
              let launchRequest else { return }
        Logger.journal.notice("journal-lifecycle: runner-backoff-relaunch delaySeconds=\(delay.components.seconds, privacy: .public)")
        do {
            _ = try await launch(
                runtime: launchRequest.runtime,
                journalRoot: launchRequest.journalRoot,
                port: launchRequest.port,
                generation: generation,
                replacing: nil
            )
        } catch SupervisedJournalRunnerError.staleLaunch {
            return
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
        currentIdentity = nil
    }

    private func waitForProcessExit(_ child: any JournalChildProcess, timeout: Duration) async {
        let deadline = clock.now() + timeout
        while clock.now() < deadline {
            if !child.isRunning || !pidExists(child.processIdentifier) {
                return
            }
            await clock.sleep(for: .milliseconds(100))
        }
    }
}
