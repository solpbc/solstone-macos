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
    func markReady(identity: SupervisedChildIdentity) async -> Bool
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

    private enum GenerationPhase: Sendable {
        case launching
        case active
        case stopping
        case containing
        case exited
        case admissionFailed
    }

    private struct GenerationRecord: Sendable {
        let rawPID: pid_t
        let context: JournalRuntimeEntryReceiptContext
        var identity: SupervisedChildIdentity?
        var containmentDomain: JournalContainmentDomain?
        var receiptRecorded = false
        var phase: GenerationPhase
    }

    private let clock: any MonotonicClock
    private let statusSink: @Sendable (JournalRuntimeStatus) -> Void
    private let gate: any SingleSupervisorGating
    private let containmentEvidenceReader: any JournalProcessContainmentEvidenceReading
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
    private var generationRecords: [UInt64: GenerationRecord] = [:]
    private var activeGeneration: UInt64?
    private var launchGeneration: UInt64 = 0
    private var backoffIndex = 0
    private var unexpectedExitTimes: [Duration] = []
    private var stabilityTask: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?
    private var pendingRelaunchGeneration: UInt64?

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
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
            containmentEvidenceReader: LiveJournalProcessContainmentEvidenceReader(),
            processSpawner: FoundationSupervisedJournalProcessSpawner(),
            pidExists: pidExists,
            terminate: terminate
        )
    }

    init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        statusSink: @escaping @Sendable (JournalRuntimeStatus) -> Void,
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        containmentEvidenceReader: any JournalProcessContainmentEvidenceReading = LiveJournalProcessContainmentEvidenceReader(),
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
        self.containmentEvidenceReader = containmentEvidenceReader
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
        guard !hasContainingGeneration else {
            throw SupervisedJournalRunnerError.launchFailed("journal child containment is in progress")
        }
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
        guard !hasContainingGeneration else {
            throw SupervisedJournalRunnerError.launchFailed("journal child containment is in progress")
        }
        Logger.journal.notice("journal-lifecycle: runner-restart transition=restarting")
        statusSink(.restarting(generation: nil))
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
        guard let generation = activeGeneration,
              let record = generationRecords[generation],
              record.phase == .active else {
            return nil
        }
        return record.identity
    }

    public func terminalReason() async -> JournalDiagnostic? {
        terminalDiagnostic
    }

    public func markReady(identity: SupervisedChildIdentity) async -> Bool {
        guard let activeIdentity = currentActiveIdentity(), activeIdentity == identity else {
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
        receiptContext: JournalRuntimeEntryReceiptContext,
        automaticReplacement: Bool = false
    ) async throws {
        if process?.isRunning == true {
            await stopCurrentProcess()
        }

        let canonicalJournalRoot = URL(fileURLWithPath: canonicalPath(journalRoot), isDirectory: true)
        let spawnRequest = SupervisedJournalSpawnRequest(
            executableURL: runtime.layout.journalBinary,
            currentDirectoryURL: canonicalJournalRoot,
            arguments: ["start", "--hosted-parent", String(port)],
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
            // This is intentionally synchronous and immediately follows run().
            // A Process termination callback may be queued already, but it cannot
            // enter this actor before this raw generation marker exists.
            generationRecords[generation] = GenerationRecord(
                rawPID: child.processIdentifier,
                context: receiptContext,
                phase: .launching
            )
            activeGeneration = generation

            guard let evidence = containmentEvidenceReader.containmentEvidence(for: child.processIdentifier),
                  evidence.pid == child.processIdentifier,
                  evidence.processGroupID > 0,
                  evidence.processGroupID != getpgrp(),
                  let startTime = evidence.kernelStartTime,
                  startTime.isFinite else {
                if var record = generationRecords[generation] {
                    record.phase = .admissionFailed
                    generationRecords[generation] = record
                }
                activeGeneration = nil
                Logger.journal.error("journal-lifecycle: runner-child-admission-failed pid=\(child.processIdentifier, privacy: .public)")
                await stopChild(child)
                if process?.processIdentifier == child.processIdentifier {
                    process = nil
                }
                generationRecords.removeValue(forKey: generation)
                throw SupervisedJournalRunnerError.launchFailed("journal child admission could not be verified")
            }

            let identity = SupervisedChildIdentity(
                pid: child.processIdentifier,
                kernelStartTime: startTime,
                generation: generation
            )
            let domain = JournalContainmentDomain(
                processGroupID: evidence.processGroupID,
                birthKernelStartTime: startTime,
                generation: generation,
                leaderIdentity: identity
            )
            if var record = generationRecords[generation] {
                record.identity = identity
                record.containmentDomain = domain
                record.phase = .active
                generationRecords[generation] = record
            }
            if let draft = receiptContext.payloadEntryDraft(identity: identity) {
                _ = await receiptContext.sink.append(draft)
            }
            Logger.journal.notice("journal-lifecycle: runner-child-launched pid=\(child.processIdentifier, privacy: .public) port=\(port, privacy: .public)")
            if automaticReplacement,
               activeGeneration == generation,
               generationRecords[generation]?.phase == .active {
                statusSink(.restarting(generation: generation))
            }
        } catch {
            process = nil
            activeGeneration = nil
            generationRecords.removeValue(forKey: generation)
            if let runnerError = error as? SupervisedJournalRunnerError {
                throw runnerError
            }
            throw SupervisedJournalRunnerError.launchFailed(error.localizedDescription)
        }
    }

    private func childExited(status: Int32, pid: pid_t, generation: UInt64) async {
        guard let record = generationRecords[generation], record.rawPID == pid else { return }
        guard activeGeneration == generation, record.phase == .active else {
            await recordExitReceipt(generation: generation, pid: pid, status: status, expectedStop: true)
            if activeGeneration == generation {
                activeGeneration = nil
                if process?.processIdentifier == pid {
                    process = nil
                }
            }
            if record.phase == .stopping || record.phase == .admissionFailed {
                generationRecords.removeValue(forKey: generation)
            }
            return
        }

        var containingRecord = record
        containingRecord.phase = .containing
        generationRecords[generation] = containingRecord
        activeGeneration = nil
        if process?.processIdentifier == pid {
            process = nil
        }
        stabilityTask?.cancel()
        stabilityTask = nil
        await cancelPendingRelaunch()

        let expectedStop = stopping
        await recordExitReceipt(generation: generation, pid: pid, status: status, expectedStop: expectedStop)
        if expectedStop {
            Logger.journal.notice("journal-lifecycle: child-exit status=\(status, privacy: .public) expected=true")
            generationRecords.removeValue(forKey: generation)
            return
        }
        guard !breakerTripped else {
            generationRecords.removeValue(forKey: generation)
            return
        }

        let containmentResult: JournalContainmentResult
        if let domain = containingRecord.containmentDomain {
            let containment = JournalProcessContainment(
                evidenceReader: containmentEvidenceReader,
                terminate: terminate,
                clock: clock,
                gracePeriod: terminationGrace
            )
            containmentResult = await containment.retire(domain: domain)
        } else {
            // Defensive fallback: .active currently always admits its domain synchronously.
            containmentResult = .unresolved([.missingDomainAdmission])
        }
        guard !stopping,
              !breakerTripped,
              activeGeneration == nil,
              generationRecords[generation]?.phase == .containing else {
            generationRecords.removeValue(forKey: generation)
            return
        }
        switch containmentResult {
        case .unresolved:
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --hosted-parent",
                exitCode: status,
                outputExcerpt: UICopy.JOURNAL_CHILD_CONTAINMENT_UNRESOLVED
            )
            terminalDiagnostic = diagnostic
            breakerTripped = true
            generationRecords.removeValue(forKey: generation)
            statusSink(.stopped(diagnostic))
            return
        case .clean, .noActiveGeneration:
            break
        }

        generationRecords[generation]?.phase = .exited
        recordUnexpectedExit()
        Logger.journal.warning("journal-lifecycle: child-exit status=\(status, privacy: .public) expected=false unexpectedCount=\(self.unexpectedExitTimes.count, privacy: .public)")
        if unexpectedExitTimes.count >= restartLimit {
            breakerTripped = true
            Logger.journal.error("journal-lifecycle: runner-breaker-tripped status=\(status, privacy: .public) unexpectedCount=\(self.unexpectedExitTimes.count, privacy: .public)")
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --hosted-parent",
                exitCode: status,
                outputExcerpt: UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
            )
            terminalDiagnostic = diagnostic
            generationRecords.removeValue(forKey: generation)
            statusSink(.stopped(diagnostic))
            return
        }

        guard launchRequest != nil else { return }
        let delay = backoffSchedule[min(backoffIndex, backoffSchedule.count - 1)]
        backoffIndex = min(backoffIndex + 1, backoffSchedule.count - 1)
        pendingRelaunchGeneration = generation
        relaunchTask = Task { [weak self] in
            await self?.performBackoffRelaunch(delay: delay, afterGeneration: generation)
        }
    }

    private func cancelPendingRelaunch() async {
        let task = relaunchTask
        let generation = pendingRelaunchGeneration
        pendingRelaunchGeneration = nil
        task?.cancel()
        await task?.value
        relaunchTask = nil
        if let generation, generationRecords[generation]?.phase == .exited {
            generationRecords.removeValue(forKey: generation)
        }
    }

    private func performBackoffRelaunch(delay: Duration, afterGeneration generation: UInt64) async {
        await clock.sleep(for: delay)
        guard !Task.isCancelled,
              pendingRelaunchGeneration == generation,
              generationRecords[generation]?.phase == .exited,
              !stopping,
              !breakerTripped,
              let launchRequest else { return }
        pendingRelaunchGeneration = nil
        relaunchTask = nil
        generationRecords.removeValue(forKey: generation)
        Logger.journal.notice("journal-lifecycle: runner-backoff-relaunch delaySeconds=\(delay.components.seconds, privacy: .public)")
        do {
            try await launch(
                runtime: launchRequest.runtime,
                journalRoot: launchRequest.journalRoot,
                port: launchRequest.port,
                receiptContext: launchRequest.receiptContext,
                automaticReplacement: true
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
                commandLabel: "journal start --hosted-parent",
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
        guard let child = process else { return }
        if let generation = activeGeneration, var record = generationRecords[generation], record.rawPID == child.processIdentifier {
            record.phase = .stopping
            generationRecords[generation] = record
        }
        await stopChild(child)
        if process?.processIdentifier == child.processIdentifier {
            process = nil
        }
    }

    private func stopChild(_ child: any SupervisedJournalChildProcess) async {
        child.closeParentInput()
        await waitForProcessExit(child, timeout: terminationWait)
        if child.isRunning {
            _ = terminate(child.processIdentifier, SIGTERM)
            await waitForProcessExit(child, timeout: terminationGrace)
        }
        if child.isRunning {
            _ = terminate(child.processIdentifier, SIGKILL)
        }
    }

    private func currentActiveIdentity() -> SupervisedChildIdentity? {
        guard let generation = activeGeneration,
              let record = generationRecords[generation],
              record.phase == .active else {
            return nil
        }
        return record.identity
    }

    private var hasContainingGeneration: Bool {
        generationRecords.values.contains { $0.phase == .containing }
    }

    private func recordExitReceipt(
        generation: UInt64,
        pid: pid_t,
        status: Int32,
        expectedStop: Bool
    ) async {
        guard var record = generationRecords[generation],
              record.rawPID == pid,
              !record.receiptRecorded,
              let identity = record.identity else { return }
        record.receiptRecorded = true
        generationRecords[generation] = record
        if let draft = record.context.payloadExitDraft(
            identity: identity,
            expectedStop: expectedStop,
            terminationStatus: status
        ) {
            _ = await record.context.sink.append(draft)
        }
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
