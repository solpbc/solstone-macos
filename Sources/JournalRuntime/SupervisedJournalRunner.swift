// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
@preconcurrency import Foundation
import os
import SolstoneCore

public struct SupervisedChildIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let kernelStartTime: Double
    public let generation: UInt64

    public init(pid: pid_t, kernelStartTime: Double, generation: UInt64) {
        self.pid = pid
        self.kernelStartTime = kernelStartTime
        self.generation = generation
    }
}

public protocol SupervisedChildRunning: Sendable {
    func start(
        runtime: MaterializedRuntime,
        journalRoot: URL,
        port: Int,
        receiptContext: JournalRuntimeEntryReceiptContext
    ) async throws
    func restart() async throws
    func stop() async
    func stopForTermination() async
    func currentRuntimeKey() async -> String?
    func currentIdentity() async -> SupervisedChildIdentity?
    func terminalReason() async -> JournalDiagnostic?
    func markReady() async
}

public enum SupervisedJournalRunnerError: LocalizedError, Sendable, Equatable {
    case alreadyStopped
    case gateBlocked(SingleSupervisorGateBlockage)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyStopped:
            return "journal child is not configured"
        case .gateBlocked(let blockage):
            return blockage.ownerMessage
        case .launchFailed(let message):
            return message
        }
    }
}

internal struct SupervisedJournalSpawnRequest: Sendable {
    let executableURL: URL
    let currentDirectoryURL: URL
    let arguments: [String]
    let environment: [String: String]
}

internal protocol SupervisedJournalProcessSpawning: Sendable {
    func makeChildProcess(for request: SupervisedJournalSpawnRequest) -> any SupervisedJournalChildProcess
}

internal protocol SupervisedJournalChildProcess: AnyObject, Sendable {
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }

    func setTerminationHandler(_ handler: @escaping @Sendable (Int32, pid_t) -> Void)
    func run() throws
    func closeParentInput()
}

private struct FoundationSupervisedJournalProcessSpawner: SupervisedJournalProcessSpawning {
    func makeChildProcess(for request: SupervisedJournalSpawnRequest) -> any SupervisedJournalChildProcess {
        FoundationSupervisedJournalChildProcess(request: request)
    }
}

private final class FoundationSupervisedJournalChildProcess: SupervisedJournalChildProcess, @unchecked Sendable {
    private let process = Process()
    private let parentWriteHandle: FileHandle
    private let stdoutReadHandle: FileHandle
    private let stderrReadHandle: FileHandle
    private let lock = NSLock()
    private var parentInputClosed = false

    init(request: SupervisedJournalSpawnRequest) {
        process.executableURL = request.executableURL
        process.currentDirectoryURL = request.currentDirectoryURL
        process.arguments = request.arguments
        process.environment = request.environment

        let parentPipe = Pipe()
        process.standardInput = parentPipe.fileHandleForReading
        parentWriteHandle = parentPipe.fileHandleForWriting

        let stdoutPipe = Pipe()
        stdoutReadHandle = stdoutPipe.fileHandleForReading
        process.standardOutput = stdoutPipe
        stdoutReadHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Logger.journal.info("\(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }

        let stderrPipe = Pipe()
        stderrReadHandle = stderrPipe.fileHandleForReading
        process.standardError = stderrPipe
        stderrReadHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Logger.journal.warning("\(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        }
    }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    func setTerminationHandler(_ handler: @escaping @Sendable (Int32, pid_t) -> Void) {
        process.terminationHandler = { child in
            handler(child.terminationStatus, child.processIdentifier)
        }
    }

    func run() throws {
        try process.run()
    }

    func closeParentInput() {
        lock.withLock {
            guard !parentInputClosed else { return }
            parentInputClosed = true
            parentWriteHandle.readabilityHandler = nil
            try? parentWriteHandle.close()
        }
    }

    deinit {
        stdoutReadHandle.readabilityHandler = nil
        stderrReadHandle.readabilityHandler = nil
        closeParentInput()
    }
}

public actor SupervisedJournalRunner: SupervisedChildRunning {
    private struct LaunchRequest: Sendable {
        let runtime: MaterializedRuntime
        let journalRoot: URL
        let port: Int
        let receiptContext: JournalRuntimeEntryReceiptContext
    }

    private struct AdmittedReceiptIdentity: Sendable {
        let identity: SupervisedChildIdentity
        let context: JournalRuntimeEntryReceiptContext
    }

    private let clock: any MonotonicClock
    private let statusSink: @Sendable (JournalRuntimeStatus) -> Void
    private let gate: any SingleSupervisorGating
    private let evidenceReader: any JournalProcessEvidenceReading
    private let processSpawner: any SupervisedJournalProcessSpawning
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

    private var process: (any SupervisedJournalChildProcess)?
    private var launchRequest: LaunchRequest?
    private var currentKey: String?
    private var stopping = false
    private var breakerTripped = false
    private var terminalDiagnostic: JournalDiagnostic?
    private var childIdentity: SupervisedChildIdentity?
    private var admittedReceiptIdentities: [UInt64: AdmittedReceiptIdentity] = [:]
    private var launchGeneration: UInt64 = 0
    private var backoffIndex = 0
    private var unexpectedExitTimes: [Duration] = []
    private var stabilityTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        evidenceReader: any JournalProcessEvidenceReading = LiveJournalProcessEvidenceReader(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        }
    ) {
        self.init(
            clock: clock,
            statusSink: statusSink,
            gate: gate,
            evidenceReader: evidenceReader,
            processSpawner: FoundationSupervisedJournalProcessSpawner(),
            pidExists: pidExists,
            terminate: terminate
        )
    }

    init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        evidenceReader: any JournalProcessEvidenceReading = LiveJournalProcessEvidenceReader(),
        processSpawner: any SupervisedJournalProcessSpawning,
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
        self.gate = gate
        self.evidenceReader = evidenceReader
        self.processSpawner = processSpawner
        self.pidExists = pidExists
        self.terminate = terminate
    }

    public func start(
        runtime: MaterializedRuntime,
        journalRoot: URL,
        port: Int,
        receiptContext: JournalRuntimeEntryReceiptContext
    ) async throws {
        Logger.journal.notice("journal-lifecycle: runner-start port=\(port, privacy: .public)")
        await cancelPendingRelaunch()
        launchRequest = LaunchRequest(
            runtime: runtime,
            journalRoot: journalRoot,
            port: port,
            receiptContext: receiptContext
        )
        currentKey = runtime.key
        breakerTripped = false
        terminalDiagnostic = nil
        stopping = false
        try await launch(
            runtime: runtime,
            journalRoot: journalRoot,
            port: port,
            receiptContext: receiptContext
        )
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
        try await launch(
            runtime: launchRequest.runtime,
            journalRoot: launchRequest.journalRoot,
            port: launchRequest.port,
            receiptContext: launchRequest.receiptContext
        )
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

    public func currentIdentity() async -> SupervisedChildIdentity? {
        childIdentity
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

    private func launch(
        runtime: MaterializedRuntime,
        journalRoot: URL,
        port: Int,
        receiptContext: JournalRuntimeEntryReceiptContext
    ) async throws {
        if process?.isRunning == true {
            await stopCurrentProcess()
        }

        let canonicalJournalRoot = URL(fileURLWithPath: canonicalPath(journalRoot), isDirectory: true)
        let spawnRequest = SupervisedJournalSpawnRequest(
            executableURL: runtime.layout.journalBinary,
            currentDirectoryURL: canonicalJournalRoot,
            arguments: ["start", "--app-supervised", String(port)],
            environment: runtime.environment
        )
        switch await gate.prepareForSpawn(journalRoot: canonicalJournalRoot) {
        case .success:
            Logger.journal.notice("journal-lifecycle: runner-gate-open")
        case .blocked(let blockage):
            throw SupervisedJournalRunnerError.gateBlocked(blockage)
        }

        let child = processSpawner.makeChildProcess(for: spawnRequest)
        launchGeneration += 1
        let generation = launchGeneration
        child.setTerminationHandler { [weak self] status, pid in
            Task {
                await self?.childExited(status: status, pid: pid, generation: generation)
            }
        }

        do {
            process = child
            try child.run()
            if let startTime = await evidenceReader.kernelStartTime(for: child.processIdentifier) {
                let identity = SupervisedChildIdentity(
                    pid: child.processIdentifier,
                    kernelStartTime: startTime,
                    generation: generation
                )
                childIdentity = identity
                admittedReceiptIdentities[generation] = AdmittedReceiptIdentity(
                    identity: identity,
                    context: receiptContext
                )
                if let draft = receiptContext.payloadEntryDraft(identity: identity) {
                    _ = await receiptContext.sink.append(draft)
                }
            } else {
                childIdentity = nil
            }
            Logger.journal.notice("journal-lifecycle: runner-child-launched pid=\(child.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
        } catch {
            process = nil
            childIdentity = nil
            admittedReceiptIdentities.removeValue(forKey: generation)
            throw SupervisedJournalRunnerError.launchFailed(error.localizedDescription)
        }
    }

    private func childExited(status: Int32, pid: pid_t, generation: UInt64) async {
        if process?.processIdentifier == pid {
            process = nil
        }
        if childIdentity?.generation == generation {
            childIdentity = nil
        }
        stabilityTask?.cancel()
        stabilityTask = nil
        await cancelPendingRelaunch()

        let expectedStop = stopping
        if let admitted = admittedReceiptIdentities[generation], admitted.identity.pid == pid {
            admittedReceiptIdentities.removeValue(forKey: generation)
            if let draft = admitted.context.payloadExitDraft(
                identity: admitted.identity,
                expectedStop: expectedStop,
                terminationStatus: status
            ) {
                _ = await admitted.context.sink.append(draft)
            }
        }
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
            try await launch(
                runtime: launchRequest.runtime,
                journalRoot: launchRequest.journalRoot,
                port: launchRequest.port,
                receiptContext: launchRequest.receiptContext
            )
        } catch SupervisedJournalRunnerError.gateBlocked(let blockage) {
            Logger.journal.error("journal-lifecycle: runner-backoff-gate-blocked")
            let diagnostic = blockage.diagnostic
            terminalDiagnostic = diagnostic
            breakerTripped = true
            statusSink(.stopped(diagnostic))
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
        process?.closeParentInput()
        childIdentity = nil

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

    private func waitForProcessExit(_ child: any SupervisedJournalChildProcess, timeout: Duration) async {
        let deadline = clock.now() + timeout
        while clock.now() < deadline {
            if !child.isRunning || !pidExists(child.processIdentifier) {
                return
            }
            await clock.sleep(for: .milliseconds(100))
        }
    }
}
