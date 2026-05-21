// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("Pipeline liveness")
@MainActor
struct PipelineLivenessTests {
    @Test func debounceThreeFailuresUnderTenSecondsDoesNotTrip() {
        var state = PipelineDebounceState()
        let start = Date(timeIntervalSince1970: 100)

        #expect(!state.apply(outcome: .unreachable, now: start, currentlyDead: false).pipelineDead)
        #expect(!state.apply(outcome: .unreachable, now: start.addingTimeInterval(4), currentlyDead: false).pipelineDead)
        #expect(!state.apply(outcome: .unreachable, now: start.addingTimeInterval(9), currentlyDead: false).pipelineDead)
    }

    @Test func debounceThreeFailuresSpanningTenSecondsTrips() {
        var state = PipelineDebounceState()
        let start = Date(timeIntervalSince1970: 100)

        _ = state.apply(outcome: .unreachable, now: start, currentlyDead: false)
        _ = state.apply(outcome: .unreachable, now: start.addingTimeInterval(5), currentlyDead: false)
        let result = state.apply(outcome: .unreachable, now: start.addingTimeInterval(10), currentlyDead: false)

        #expect(result.pipelineDead)
        #expect(!result.pipelineBinaryMissing)
    }

    @Test func debounceReachableClearsDeadImmediately() {
        var state = PipelineDebounceState()
        let start = Date(timeIntervalSince1970: 100)

        _ = state.apply(outcome: .unreachable, now: start, currentlyDead: false)
        _ = state.apply(outcome: .unreachable, now: start.addingTimeInterval(5), currentlyDead: false)
        _ = state.apply(outcome: .unreachable, now: start.addingTimeInterval(10), currentlyDead: false)
        let result = state.apply(outcome: .reachable, now: start.addingTimeInterval(11), currentlyDead: true)

        #expect(!result.pipelineDead)
        #expect(!result.pipelineBinaryMissing)
    }

    @Test func debounceSingleTransientFailureDoesNotTrip() {
        var state = PipelineDebounceState()
        let start = Date(timeIntervalSince1970: 100)

        #expect(!state.apply(outcome: .unreachable, now: start, currentlyDead: false).pipelineDead)
        #expect(!state.apply(outcome: .reachable, now: start.addingTimeInterval(1), currentlyDead: false).pipelineDead)
    }

    @Test func binaryMissingClearsDeadAndSetsBinaryMissing() {
        var state = PipelineDebounceState()
        let result = state.apply(
            outcome: .binaryMissing,
            now: Date(timeIntervalSince1970: 100),
            currentlyDead: true
        )

        #expect(!result.pipelineDead)
        #expect(result.pipelineBinaryMissing)
    }

    @Test func probeReturnsBinaryMissingWhenLocatorFails() async {
        let runner = SequencedSubprocessFake()

        let outcome = await PipelineLivenessProbe.run(runner: runner, findSolBinary: { nil })

        #expect(outcome == .binaryMissing)
        #expect(runner.invocations.isEmpty)
    }

    @Test func probeMapsHealthResult() async {
        let healthyRunner = SequencedSubprocessFake()
        healthyRunner.enqueue(arguments: ["health"], .success())
        let healthy = await PipelineLivenessProbe.run(
            runner: healthyRunner,
            findSolBinary: { "/usr/bin/sol" }
        )

        let unhealthyRunner = SequencedSubprocessFake()
        unhealthyRunner.enqueue(arguments: ["health"], .success(exitCode: 1))
        let unhealthy = await PipelineLivenessProbe.run(
            runner: unhealthyRunner,
            findSolBinary: { "/usr/bin/sol" }
        )

        #expect(healthy == .reachable)
        #expect(unhealthy == .unreachable)
    }

    @Test func orphanSweepKillsOnlyPpidOneSolProcesses() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runner = SequencedSubprocessFake()
        runner.enqueue(arguments: ["-axo", "pid=,ppid=,comm="], .success(stdout: """
          PID  PPID COMM
          111     1 sol:supervisor
          222     2 sol:worker
          333     1 bash
          444     1 /Applications/solstone.app/Contents/MacOS/solstone
          555     1 sol:service
          666     1 sol: foo bar
         -777     1 sol:negative-pid
          888    -1 sol:negative-ppid
          not-a-pid 1 sol:bad
        """))
        runner.enqueue(arguments: ["service", "restart"], .success())
        let terminated = LockedPIDRecorder()
        let restart = PipelineRestartRunner(
            runner: runner,
            journalPathProvider: { _ in temp.path },
            terminate: { pid in terminated.append(pid) },
            reprobe: { .reachable },
            solPath: "/usr/bin/sol"
        )

        let outcome = await restart.run()

        #expect(outcome == .success)
        #expect(terminated.values == [111, 555, 666])
    }

    @Test func staleStateMoveAsideSkipsMissingAndOverwritesBak() throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let health = temp.appendingPathComponent("health")
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        let pid = health.appendingPathComponent("supervisor.pid")
        let pidBackup = URL(fileURLWithPath: pid.path + ".bak")
        try Data("new".utf8).write(to: pid)
        try Data("old".utf8).write(to: pidBackup)

        let events = moveAsideStaleStateFiles(journalRoot: temp)

        #expect(events.count == staleStateRelativePaths.count)
        #expect(!FileManager.default.fileExists(atPath: pid.path))
        #expect((try String(contentsOf: pidBackup, encoding: .utf8)) == "new")
        #expect(events.contains { $0.detail == "health/supervisor.pid:moved" })
        #expect(events.contains { $0.detail == "health/supervisor.ready:missing" })
    }

    @Test func restartSuccessLogsAllStepsAndRestoresError() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.errorMessage = "existing"
        state.pipelineSolBinaryFinder = { "/usr/bin/sol" }
        let events = LockedEventRecorder()
        state.pipelineRestartLogSink = { event in events.append(event) }
        state.pipelineRestartRunnerFactory = { solPath, logSink in
            let runner = SequencedSubprocessFake()
            runner.enqueue(arguments: ["-axo", "pid=,ppid=,comm="], .success(stdout: ""))
            runner.enqueue(arguments: ["service", "restart"], .success())
            return PipelineRestartRunner(
                runner: runner,
                journalPathProvider: { _ in temp.path },
                terminate: { _ in },
                reprobe: { .reachable },
                logSink: logSink,
                solPath: solPath
            )
        }

        state.requestPipelineRestart()
        try await waitUntil {
            events.values.contains { $0.step == .reProbe } && !state.isRestartingPipeline
        }

        #expect(state.errorMessage == "existing")
        #expect(!state.pipelineDead)
        #expect(!state.pipelineBinaryMissing)
        #expect(stepCounts(events.values) == Dictionary(uniqueKeysWithValues: RestartFailureStep.allCases.map { ($0, 1) }))
    }

    @Test func restartReprobeFailureAfterCommandSuccessFails() async throws {
        let temp = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .done
        state.pipelineSolBinaryFinder = { "/usr/bin/sol" }
        let events = LockedEventRecorder()
        state.pipelineRestartLogSink = { event in events.append(event) }
        state.pipelineRestartRunnerFactory = { solPath, logSink in
            let runner = SequencedSubprocessFake()
            runner.enqueue(arguments: ["-axo", "pid=,ppid=,comm="], .success(stdout: ""))
            runner.enqueue(arguments: ["service", "restart"], .success())
            return PipelineRestartRunner(
                runner: runner,
                journalPathProvider: { _ in temp.path },
                terminate: { _ in },
                reprobe: { .unreachable },
                logSink: logSink,
                solPath: solPath
            )
        }

        state.requestPipelineRestart()
        try await waitUntil {
            state.errorMessage == "restart failed at pipeline check — pipeline did not come back"
        }

        #expect(state.errorMessage == "restart failed at pipeline check — pipeline did not come back")
    }

    @Test func restartResolveJournalFailureHaltsBeforeSideEffects() async {
        let runner = SequencedSubprocessFake()
        let terminated = LockedPIDRecorder()
        let events = LockedEventRecorder()
        let restart = PipelineRestartRunner(
            runner: runner,
            journalPathProvider: { _ in nil },
            terminate: { pid in terminated.append(pid) },
            reprobe: { .reachable },
            logSink: { event in events.append(event) },
            solPath: "/usr/bin/sol"
        )

        let outcome = await restart.run()

        #expect(outcome == .failure(PipelineRestartFailure(
            step: .resolveJournal,
            ownerMessage: "restart failed at journal path — could not find the journal"
        )))
        #expect(runner.invocations.isEmpty)
        #expect(terminated.values.isEmpty)
        #expect(events.values == [
            PipelineRestartLogEvent(step: .resolveJournal, outcome: "error", detail: "no-journal-path")
        ])
    }

    @Test func externalModeTransitionClearsPipelineStateAndStopsTimer() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.pipelineDead = true
        state.pipelineBinaryMissing = true

        state.updateConfig(AppConfig(serviceMode: .external))

        #expect(!state.pipelineDead)
        #expect(!state.pipelineBinaryMissing)
    }

    @Test @MainActor func pipelineSurfaceAvailabilityRequiresInstalledBundledState() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.installer.main = .detecting
        state.pipelineBinaryMissing = true

        #expect(!state.bundledPipelineStatusAvailable)
        #expect(!state.bundledPipelineRestartAvailable)

        state.installer.main = .done

        #expect(state.bundledPipelineStatusAvailable)
        #expect(!state.bundledPipelineRestartAvailable)

        state.pipelineBinaryMissing = false

        #expect(state.bundledPipelineRestartAvailable)

        state.updateConfig(AppConfig(serviceMode: .external))

        #expect(!state.bundledPipelineStatusAvailable)
        #expect(!state.bundledPipelineRestartAvailable)
    }

    private func stepCounts(_ events: [PipelineRestartLogEvent]) -> [RestartFailureStep: Int] {
        Dictionary(grouping: events, by: \.step).mapValues(\.count)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }
}

private final class SequencedSubprocessFake: SubprocessRunning, @unchecked Sendable {
    struct Outcome: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let throwMessage: String?

        static func success(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) -> Outcome {
            Outcome(stdout: stdout, stderr: stderr, exitCode: exitCode, throwMessage: nil)
        }

        static func failure(_ message: String) -> Outcome {
            Outcome(stdout: "", stderr: "", exitCode: 0, throwMessage: message)
        }
    }

    private let lock = NSLock()
    private var queuedByArguments: [String: [Outcome]] = [:]
    private var fifo: [Outcome] = []
    private var recordedInvocations: [SubprocessInvocation] = []

    var invocations: [SubprocessInvocation] {
        lock.withLock { recordedInvocations }
    }

    func enqueue(arguments: [String], _ outcome: Outcome) {
        lock.withLock {
            queuedByArguments[key(arguments), default: []].append(outcome)
        }
    }

    func enqueueFIFO(_ outcome: Outcome) {
        lock.withLock {
            fifo.append(outcome)
        }
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        let outcome = nextOutcome(executable: executable, arguments: arguments)
        if let message = outcome.throwMessage {
            throw FakeRunError(message: message)
        }
        if !outcome.stdout.isEmpty {
            stdoutHandler(Data(outcome.stdout.utf8))
        }
        if !outcome.stderr.isEmpty {
            stderrHandler(Data(outcome.stderr.utf8))
        }
        return SubprocessResult(exitCode: outcome.exitCode, terminationReason: .exit)
    }

    func cancelAll() {}

    private func nextOutcome(executable: URL, arguments: [String]) -> Outcome {
        lock.withLock {
            recordedInvocations.append(SubprocessInvocation(executable: executable, arguments: arguments))
            let key = key(arguments)
            if var queued = queuedByArguments[key], !queued.isEmpty {
                let outcome = queued.removeFirst()
                queuedByArguments[key] = queued
                return outcome
            }
            if !fifo.isEmpty {
                return fifo.removeFirst()
            }
            return .success()
        }
    }

    private func key(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1f}")
    }
}

private final class LockedPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []

    var values: [pid_t] {
        lock.withLock { pids }
    }

    func append(_ pid: pid_t) {
        lock.withLock {
            pids.append(pid)
        }
    }
}

private final class LockedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineRestartLogEvent] = []

    var values: [PipelineRestartLogEvent] {
        lock.withLock { events }
    }

    func append(_ event: PipelineRestartLogEvent) {
        lock.withLock {
            events.append(event)
        }
    }
}
