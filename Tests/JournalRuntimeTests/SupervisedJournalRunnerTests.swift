// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("SupervisedJournalRunner")
struct SupervisedJournalRunnerTests {
    @Test func startAuthorizesImmediatelyBeforeSpawn() async throws {
        let harness = try await RunnerHarness(gateSteps: [.result(.success)])

        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)

        #expect(harness.gate.callCount() == 1)
        #expect(harness.events.snapshot() == ["gate:1:excluded:nil", "spawn:7000"])
    }

    @Test func restartAuthorizesBeforeStoppingAndExcludesCurrentChild() async throws {
        let harness = try await RunnerHarness(gateSteps: [.result(.success), .result(.success)])
        let first = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)
        harness.events.removeAll()

        _ = try await harness.runner.restart()

        #expect(harness.gate.contexts().map { $0.excludedChild?.pid } == [nil, first.pid])
        #expect(Array(harness.events.snapshot().prefix(1)) == ["gate:2:excluded:\(first.pid):alive:true"])
        #expect(harness.events.snapshot().contains("signal:\(first.pid):\(SIGTERM)"))
        #expect(harness.processes.spawnCount() == 2)
    }

    @Test func backoffRelaunchAuthorizesImmediatelyBeforeSpawn() async throws {
        let harness = try await RunnerHarness(
            gateSteps: [.result(.success), .result(.success)],
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)
        harness.events.removeAll()

        harness.processes.latest()?.exit(status: 7)
        await harness.clock.waitForSleepCount(1)
        harness.clock.resumeNextSleep()
        await harness.processes.waitForSpawnCount(2)

        #expect(harness.gate.callCount() == 2)
        #expect(harness.events.snapshot() == ["gate:2:excluded:nil", "spawn:7001"])
    }

    @Test func competitorAfterOwnedChildExitBlocksBackoffWithZeroSpawn() async throws {
        let blockage = portBlockage()
        let harness = try await RunnerHarness(
            gateSteps: [.result(.success), .result(.blocked(blockage))],
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)

        harness.processes.latest()?.exit(status: 7)
        await harness.clock.waitForSleepCount(1)
        harness.clock.resumeNextSleep()
        await Task.yield()

        #expect(harness.processes.spawnCount() == 1)
        #expect(harness.gate.callCount() == 2)
    }

    @Test func stopInvalidatesPendingBackoffRelaunch() async throws {
        let harness = try await RunnerHarness(
            gateSteps: [.result(.success), .result(.success)],
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)

        harness.processes.latest()?.exit(status: 7)
        await harness.clock.waitForSleepCount(1)
        let stopTask = Task { await harness.runner.stop() }
        await Task.yield()
        harness.clock.resumeNextSleep()
        await stopTask.value

        #expect(harness.processes.spawnCount() == 1)
        #expect(harness.gate.callCount() == 1)
    }

    @Test func newerStartInvalidatesOlderAuthorizationContinuation() async throws {
        let harness = try await RunnerHarness(gateSteps: [.suspended(.success), .result(.success)])

        let firstStart = Task {
            try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)
        }
        await harness.gate.waitForCallCount(1)

        let secondStart = Task {
            try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)
        }
        _ = try await secondStart.value
        harness.gate.resumeNextSuspended()

        do {
            _ = try await firstStart.value
            Issue.record("expected stale first launch")
        } catch SupervisedJournalRunnerError.staleLaunch {
        } catch {
            Issue.record("expected stale launch, got \(error)")
        }

        #expect(harness.processes.spawnCount() == 1)
        #expect(harness.gate.callCount() == 2)
    }

    @Test func terminalGateFailureLeavesOneDiagnosticAndNoPendingRetry() async throws {
        let blockage = portBlockage()
        let harness = try await RunnerHarness(
            gateSteps: [.result(.success), .result(.blocked(blockage)), .result(.success)],
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)

        harness.processes.latest()?.exit(status: 7)
        await harness.clock.waitForSleepCount(1)
        harness.clock.resumeNextSleep()
        await Task.yield()
        harness.clock.resumeNextSleep()
        await Task.yield()

        #expect(harness.statuses.stoppedCount() == 1)
        #expect(await harness.runner.terminalReason() != nil)
        #expect(harness.processes.spawnCount() == 1)
        #expect(harness.gate.callCount() == 2)
    }

    @Test func manualRestartResetsTerminalGateFailureAndReauthorizes() async throws {
        let blockage = portBlockage()
        let harness = try await RunnerHarness(
            gateSteps: [.result(.success), .result(.blocked(blockage)), .result(.success)],
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)
        harness.processes.latest()?.exit(status: 7)
        await harness.clock.waitForSleepCount(1)
        harness.clock.resumeNextSleep()
        await Task.yield()

        _ = try await harness.runner.restart()

        #expect(harness.gate.callCount() == 3)
        #expect(harness.processes.spawnCount() == 2)
        #expect(await harness.runner.terminalReason() == nil)
    }

    @Test func breakerBudgetAndBackoffScheduleArePreserved() async throws {
        let harness = try await RunnerHarness(
            gateSteps: Array(repeating: .result(.success), count: 5),
            clock: SuspendedBackoffClock()
        )
        _ = try await harness.runner.start(runtime: harness.runtime, journalRoot: harness.journalRoot, port: 5015)

        for expectedSpawnCount in 2...5 {
            harness.processes.latest()?.exit(status: Int32(expectedSpawnCount))
            await harness.clock.waitForSleepCount(expectedSpawnCount - 1)
            harness.clock.resumeNextSleep()
            await harness.processes.waitForSpawnCount(expectedSpawnCount)
        }

        harness.processes.latest()?.exit(status: 99)
        await Task.yield()

        #expect(harness.clock.sleepDurations().prefix(4).map(\.components.seconds) == [1, 2, 4, 8])
        #expect(harness.processes.spawnCount() == 5)
        #expect(harness.statuses.stoppedCount() == 1)
        #expect(await harness.runner.terminalReason()?.outputExcerpt == UICopy.JOURNAL_CHILD_BREAKER_TRIPPED)
    }
}

private struct RunnerHarness {
    let runtime: MaterializedRuntime
    let journalRoot: URL
    let events: StringEventRecorder
    let processes: FakeJournalProcessFactory
    let gate: RecordingAuthorizationGate
    let statuses: StatusRecorder
    let clock: SuspendedBackoffClock
    let runner: SupervisedJournalRunner

    init(gateSteps: [GateStep], clock: SuspendedBackoffClock = SuspendedBackoffClock()) async throws {
        runtime = try makeRuntime()
        journalRoot = runtime.layout.rootURL
        events = StringEventRecorder()
        processes = FakeJournalProcessFactory(events: events)
        gate = RecordingAuthorizationGate(events: events, processFactory: processes, steps: gateSteps)
        statuses = StatusRecorder()
        self.clock = clock
        runner = SupervisedJournalRunner(
            clock: clock,
            authorizationGate: gate,
            statusSink: { [statuses] status in statuses.append(status) },
            pidExists: { [processes] pid in processes.isRunning(pid: pid) },
            terminate: { [processes, events] pid, signal in
                events.append("signal:\(pid):\(signal)")
                processes.signal(pid: pid, status: signal)
                return 0
            },
            processStartTime: { [processes] pid in processes.startTime(pid: pid) },
            processFactory: { [processes] in processes.makeProcess() }
        )
    }
}

private enum GateStep: Sendable {
    case result(SingleSupervisorGateResult)
    case suspended(SingleSupervisorGateResult)
}

private final class RecordingAuthorizationGate: SingleSupervisorGating, @unchecked Sendable {
    private let lock = NSLock()
    private let events: StringEventRecorder
    private let processFactory: FakeJournalProcessFactory
    private var steps: [GateStep]
    private var calls: [LaunchAuthorizationContext] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var suspended: [(SingleSupervisorGateResult, CheckedContinuation<SingleSupervisorGateResult, Never>)] = []

    init(events: StringEventRecorder, processFactory: FakeJournalProcessFactory, steps: [GateStep]) {
        self.events = events
        self.processFactory = processFactory
        self.steps = steps
    }

    func prepareForSpawn(journalRoot: URL, context: LaunchAuthorizationContext) async -> SingleSupervisorGateResult {
        let (index, step) = lock.withLock {
            calls.append(context)
            let index = calls.count
            let excluded = context.excludedChild.map { String($0.pid) } ?? "nil"
            let alive = context.excludedChild.map { processFactory.isRunning(pid: $0.pid) }
            events.append("gate:\(index):excluded:\(excluded)" + (alive.map { ":alive:\($0)" } ?? ""))
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            let step = steps.isEmpty ? GateStep.result(.success) : steps.removeFirst()
            return (index, step)
        }
        _ = index
        switch step {
        case .result(let result):
            return result
        case .suspended(let result):
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    suspended.append((result, continuation))
                }
            }
        }
    }

    func callCount() -> Int {
        lock.withLock { calls.count }
    }

    func contexts() -> [LaunchAuthorizationContext] {
        lock.withLock { calls }
    }

    func waitForCallCount(_ count: Int) async {
        while callCount() < count {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if calls.count >= count {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            }
        }
    }

    func resumeNextSuspended() {
        let next = lock.withLock {
            suspended.isEmpty ? nil : suspended.removeFirst()
        }
        next?.1.resume(returning: next?.0 ?? .success)
    }
}

private final class FakeJournalProcessFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let events: StringEventRecorder
    private var nextPID: pid_t = 7000
    private var processes: [FakeJournalChildProcess] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(events: StringEventRecorder) {
        self.events = events
    }

    func makeProcess() -> any JournalChildProcess {
        lock.withLock {
            let process = FakeJournalChildProcess(pid: nextPID, startTime: TimeInterval(nextPID), events: events) { [weak self] in
                self?.notifySpawn()
            }
            nextPID += 1
            processes.append(process)
            return process
        }
    }

    func latest() -> FakeJournalChildProcess? {
        lock.withLock { processes.last }
    }

    func spawnCount() -> Int {
        lock.withLock { processes.filter(\.hasRun).count }
    }

    func waitForSpawnCount(_ count: Int) async {
        while spawnCount() < count {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if processes.filter(\.hasRun).count >= count {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            }
        }
    }

    func isRunning(pid: pid_t) -> Bool {
        lock.withLock { processes.first(where: { $0.processIdentifier == pid })?.isRunning == true }
    }

    func startTime(pid: pid_t) -> TimeInterval? {
        lock.withLock { processes.first(where: { $0.processIdentifier == pid })?.startTime }
    }

    func signal(pid: pid_t, status: Int32) {
        lock.withLock { processes.first(where: { $0.processIdentifier == pid })?.signal(status: status) }
    }

    private func notifySpawn() {
        lock.withLock {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}

private final class FakeJournalChildProcess: JournalChildProcess, @unchecked Sendable {
    var executableURL: URL?
    var currentDirectoryURL: URL?
    var arguments: [String]?
    var environment: [String: String]?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: (@Sendable (any JournalChildProcess) -> Void)?
    let processIdentifier: pid_t
    let startTime: TimeInterval
    private let events: StringEventRecorder
    private let onRun: @Sendable () -> Void
    private let lock = NSLock()
    private var running = false
    private var status: Int32 = 0
    private var ran = false

    init(pid: pid_t, startTime: TimeInterval, events: StringEventRecorder, onRun: @escaping @Sendable () -> Void) {
        processIdentifier = pid
        self.startTime = startTime
        self.events = events
        self.onRun = onRun
    }

    var terminationStatus: Int32 {
        lock.withLock { status }
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var hasRun: Bool {
        lock.withLock { ran }
    }

    func run() throws {
        lock.withLock {
            running = true
            ran = true
        }
        events.append("spawn:\(processIdentifier)")
        onRun()
    }

    func exit(status: Int32) {
        lock.withLock {
            self.status = status
            running = false
        }
        terminationHandler?(self)
    }

    func signal(status: Int32) {
        lock.withLock {
            self.status = status
            running = false
        }
    }
}

private final class SuspendedBackoffClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    private var sleeps: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var recorded: [Duration] = []

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        if duration < .seconds(1) {
            lock.withLock { value += duration }
            await Task.yield()
            return
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                recorded.append(duration)
                sleeps.append((duration, continuation))
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            }
        }
    }

    func waitForSleepCount(_ count: Int) async {
        while sleepDurations().count < count {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if recorded.count >= count {
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                    }
                }
            }
        }
    }

    func resumeNextSleep() {
        let next = lock.withLock {
            sleeps.isEmpty ? nil : sleeps.removeFirst()
        }
        guard let next else { return }
        lock.withLock { value += next.0 }
        next.1.resume()
    }

    func sleepDurations() -> [Duration] {
        lock.withLock { recorded }
    }
}

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JournalRuntimeStatus] = []

    func append(_ status: JournalRuntimeStatus) {
        lock.withLock {
            values.append(status)
        }
    }

    func stoppedCount() -> Int {
        lock.withLock {
            values.filter {
                if case .stopped = $0 { return true }
                return false
            }.count
        }
    }
}

private final class StringEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock {
            values.append(value)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { values }
    }

    func removeAll() {
        lock.withLock {
            values.removeAll()
        }
    }
}

private func portBlockage() -> SingleSupervisorGateBlockage {
    .portConflict(JournalDiagnostic(
        commandLabel: "journal supervisor gate",
        outputExcerpt: "port busy"
    ))
}
