// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("SupervisedJournalRunner")
struct SupervisedJournalRunnerTests {
    @Test func launchGatesWithCanonicalRootAndDoesNotStampJournalEnvironment() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let gate = RecordingRunnerGate(result: .success)
        let spawner = RecordingProcessSpawner(pid: 4242)
        let runner = SupervisedJournalRunner(
            clock: NoopRunnerClock(),
            statusSink: { _ in },
            gate: gate,
            evidenceReader: FixedStartTimeReader(startTime: 1_000.0),
            processSpawner: spawner,
            pidExists: { _ in false }
        )

        try await runner.start(
            runtime: fixture.runtime,
            journalRoot: fixture.linkedJournalRoot,
            port: 5015,
            receiptContext: makeReceiptFixture().context
        )

        let requests = spawner.spawnRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.executableURL == fixture.runtime.layout.journalBinary)
        #expect(requests.first?.currentDirectoryURL.path == canonicalPath(fixture.realJournalRoot))
        #expect(requests.first?.arguments == ["start", "--app-supervised", "5015"])
        #expect(requests.first?.environment["SOLSTONE_JOURNAL"] == nil)
        #expect(gate.roots() == [canonicalPath(fixture.realJournalRoot)])
        #expect(await runner.currentIdentity()?.pid == 4242)
        #expect(await runner.currentIdentity()?.kernelStartTime == 1_000.0)
        await runner.stop()
    }

    @Test func gateBlockedPreventsSpawn() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "blocked")
        let blockage = SingleSupervisorGateBlockage.portConflict(diagnostic)
        let spawner = RecordingProcessSpawner(pid: 4242)
        let runner = SupervisedJournalRunner(
            clock: NoopRunnerClock(),
            statusSink: { _ in },
            gate: RecordingRunnerGate(result: .blocked(blockage)),
            evidenceReader: FixedStartTimeReader(startTime: 1_000.0),
            processSpawner: spawner,
            pidExists: { _ in false }
        )

        do {
            try await runner.start(
                runtime: fixture.runtime,
                journalRoot: fixture.realJournalRoot,
                port: 5015,
                receiptContext: makeReceiptFixture().context
            )
            Issue.record("expected gateBlocked")
        } catch let error as SupervisedJournalRunnerError {
            #expect(error == .gateBlocked(blockage))
        }

        #expect(spawner.spawnRequests().isEmpty)
    }

    @Test func writesPayloadEntryForInitialRestartAndBackoffAdmissionsBeforeExit() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let receipts = makeReceiptFixture()
        let spawner = RecordingProcessSpawner(pids: [4242, 4243, 4244])
        let runner = SupervisedJournalRunner(
            clock: NoopRunnerClock(),
            statusSink: { _ in },
            gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTimes: [1_000, 2_000, 3_000]),
            processSpawner: spawner,
            pidExists: { _ in false }
        )

        try await runner.start(
            runtime: fixture.runtime,
            journalRoot: fixture.realJournalRoot,
            port: 5015,
            receiptContext: receipts.context
        )
        try await runner.restart()
        spawner.exit(spawn: 1, status: 9)
        try await waitForSpawnCount(spawner, count: 3)

        let entries = payloadEntries(receipts.sink.storedRecords(attemptID: receipts.context.attemptID))
        #expect(entries.map(\.generation) == [1, 2, 3])
        #expect(payloadExits(receipts.sink.storedRecords(attemptID: receipts.context.attemptID)).count == 1)
    }

    @Test func writesExactlyOneTerminalExitAfterObservedExpectedAndUnexpectedExit() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let expected = makeReceiptFixture()
        let expectedSpawner = RecordingProcessSpawner(pids: [4242])
        let expectedRunner = SupervisedJournalRunner(
            clock: NoopRunnerClock(), statusSink: { _ in }, gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTime: 1_000), processSpawner: expectedSpawner, pidExists: { _ in false }
        )
        try await expectedRunner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015, receiptContext: expected.context)
        await expectedRunner.stop()
        #expect(payloadExits(expected.sink.storedRecords(attemptID: expected.context.attemptID)).isEmpty)
        expectedSpawner.exit(spawn: 0, status: 0)
        try await waitForPayloadExitCount(expected.sink, attemptID: expected.context.attemptID, count: 1)
        #expect(payloadExits(expected.sink.storedRecords(attemptID: expected.context.attemptID)).map(\.expectedStop) == [true])

        let unexpected = makeReceiptFixture()
        let unexpectedSpawner = RecordingProcessSpawner(pids: [4243, 4244])
        let unexpectedRunner = SupervisedJournalRunner(
            clock: NoopRunnerClock(), statusSink: { _ in }, gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTimes: [2_000, 3_000]), processSpawner: unexpectedSpawner, pidExists: { _ in false }
        )
        try await unexpectedRunner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015, receiptContext: unexpected.context)
        unexpectedSpawner.exit(spawn: 0, status: 9)
        try await waitForSpawnCount(unexpectedSpawner, count: 2)
        try await waitForPayloadExitCount(unexpected.sink, attemptID: unexpected.context.attemptID, count: 1)
        #expect(payloadExits(unexpected.sink.storedRecords(attemptID: unexpected.context.attemptID)).map(\.expectedStop) == [false])
    }

    @Test func writesNoExitForUnadmittedOrStillLiveStoppedChild() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let unadmitted = makeReceiptFixture()
        let unadmittedSpawner = RecordingProcessSpawner(pids: [4242])
        let unadmittedRunner = SupervisedJournalRunner(
            clock: NoopRunnerClock(), statusSink: { _ in }, gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTimes: [nil]), processSpawner: unadmittedSpawner, pidExists: { _ in false }
        )
        try await unadmittedRunner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015, receiptContext: unadmitted.context)
        unadmittedSpawner.exit(spawn: 0, status: 9)
        await Task.yield()
        #expect(payloadEntries(unadmitted.sink.storedRecords(attemptID: unadmitted.context.attemptID)).isEmpty)
        #expect(payloadExits(unadmitted.sink.storedRecords(attemptID: unadmitted.context.attemptID)).isEmpty)

        let live = makeReceiptFixture()
        let liveSpawner = RecordingProcessSpawner(pids: [4243], closeParentInputStopsProcess: false)
        let liveRunner = SupervisedJournalRunner(
            clock: AdvancingRunnerClock(), statusSink: { _ in }, gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTime: 3_000), processSpawner: liveSpawner, pidExists: { _ in true },
            terminate: { _, _ in 0 }
        )
        try await liveRunner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015, receiptContext: live.context)
        await liveRunner.stop()
        #expect(payloadExits(live.sink.storedRecords(attemptID: live.context.attemptID)).isEmpty)
    }

    @Test func keepsPIDReuseExitsBoundToTheirAdmittedKernelStartTime() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.clear() }
        let receipts = makeReceiptFixture()
        let spawner = RecordingProcessSpawner(pids: [4242, 4242])
        let runner = SupervisedJournalRunner(
            clock: NoopRunnerClock(), statusSink: { _ in }, gate: RecordingRunnerGate(result: .success),
            evidenceReader: FixedStartTimeReader(startTimes: [1_000, 2_000]), processSpawner: spawner, pidExists: { _ in false }
        )
        try await runner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015, receiptContext: receipts.context)
        try await runner.restart()
        await runner.stop()
        spawner.exit(spawn: 0, status: 0)
        try await waitForPayloadExitCount(receipts.sink, attemptID: receipts.context.attemptID, count: 1)
        spawner.exit(spawn: 1, status: 0)
        try await waitForPayloadExitCount(receipts.sink, attemptID: receipts.context.attemptID, count: 2)

        let records = receipts.sink.storedRecords(attemptID: receipts.context.attemptID)
        #expect(payloadEntries(records).map(\.childKernelStartTimeMicroseconds) == [1_000_000_000, 2_000_000_000])
        #expect(payloadExits(records).map(\.childKernelStartTimeMicroseconds) == [1_000_000_000, 2_000_000_000])
    }
}

private struct ReceiptFixture {
    let context: JournalRuntimeEntryReceiptContext
    let sink: InMemoryJournalRuntimeEntryReceiptSink
}

private func makeReceiptFixture() -> ReceiptFixture {
    let sink = InMemoryJournalRuntimeEntryReceiptSink()
    let attemptID = JournalRuntimeEntryAttemptID()
    let identity = JournalRuntimeEntryReceiptAppIdentity(
        appPID: 1,
        bundleIdentifier: "app.solstone.journal",
        bundleShortVersion: "2.0.0",
        bundleVersion: "25",
        locationClass: .standard,
        appKernelStartTimeMicroseconds: 1_000_000
    )
    _ = sink.appendSynchronously(.outerEntry(.init(
        attemptID: attemptID,
        observedAtUnixMilliseconds: 1,
        appIdentity: identity
    )))
    let context = JournalRuntimeEntryReceiptContext(
        attemptID: attemptID,
        sink: sink,
        appIdentity: identity,
        candidateProvenance: JournalRuntimeEntryCandidateProvenance(
            source: "J",
            target: .init(bundleIdentifier: "app.solstone.journal", bundleShortVersion: "2.0.0", bundleVersion: "25"),
            runtimeArchiveSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            releaseReceiptSHA256: String(repeating: "c", count: 64),
            signingReceiptSHA256: String(repeating: "d", count: 64),
            runtimeTreeSHA256: String(repeating: "e", count: 64)
        )
    )
    return ReceiptFixture(context: context, sink: sink)
}

private func payloadEntries(_ records: [JournalRuntimeEntryReceipt]) -> [JournalRuntimeEntryReceiptPayloadEntryDraft] {
    records.compactMap {
        guard case let .payloadEntry(entry) = $0 else { return nil }
        return entry.draft
    }
}

private func payloadExits(_ records: [JournalRuntimeEntryReceipt]) -> [JournalRuntimeEntryReceiptPayloadExitDraft] {
    records.compactMap {
        guard case let .payloadExit(entry) = $0 else { return nil }
        return entry.draft
    }
}

private func waitForSpawnCount(_ spawner: RecordingProcessSpawner, count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if spawner.spawnRequests().count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for child spawn")
}

private func waitForPayloadExitCount(
    _ sink: InMemoryJournalRuntimeEntryReceiptSink,
    attemptID: JournalRuntimeEntryAttemptID,
    count: Int
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if payloadExits(sink.storedRecords(attemptID: attemptID)).count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for payload exit receipt")
}

private struct RunnerFixture {
    let root: URL
    let runtime: MaterializedRuntime
    let realJournalRoot: URL
    let linkedJournalRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervised-runner-\(UUID().uuidString)", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let layout = SolstoneRuntimeLayout(rootURL: runtimeRoot)
        try layout.ensureCreated()
        runtime = MaterializedRuntime(key: "test-key", layout: layout)
        realJournalRoot = root.appendingPathComponent("real journal", isDirectory: true)
        linkedJournalRoot = root.appendingPathComponent("journal-link", isDirectory: true)
        try FileManager.default.createDirectory(at: realJournalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedJournalRoot, withDestinationURL: realJournalRoot)
    }

    func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingRunnerGate: SingleSupervisorGating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: SingleSupervisorGateResult
    private var journalRoots: [String] = []

    init(result: SingleSupervisorGateResult) {
        self.result = result
    }

    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        lock.withLock {
            journalRoots.append(canonicalPath(journalRoot))
        }
        return result
    }

    func roots() -> [String] {
        lock.withLock { journalRoots }
    }
}

private final class RecordingProcessSpawner: SupervisedJournalProcessSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private let pids: [pid_t]
    private let closeParentInputStopsProcess: Bool
    private var requests: [SupervisedJournalSpawnRequest] = []
    private var children: [RecordingChildProcess] = []

    convenience init(pid: pid_t) {
        self.init(pids: [pid])
    }

    init(pids: [pid_t], closeParentInputStopsProcess: Bool = true) {
        self.pids = pids
        self.closeParentInputStopsProcess = closeParentInputStopsProcess
    }

    func makeChildProcess(for request: SupervisedJournalSpawnRequest) -> any SupervisedJournalChildProcess {
        lock.withLock {
            let index = children.count
            let child = RecordingChildProcess(
                pid: pids[min(index, pids.count - 1)],
                request: request,
                spawner: self,
                closeParentInputStopsProcess: closeParentInputStopsProcess
            )
            children.append(child)
            return child
        }
    }

    func spawnRequests() -> [SupervisedJournalSpawnRequest] {
        lock.withLock { requests }
    }

    fileprivate func recordSpawn(_ request: SupervisedJournalSpawnRequest) {
        lock.withLock {
            requests.append(request)
        }
    }

    func exit(spawn: Int, status: Int32) {
        let child = lock.withLock {
            children.indices.contains(spawn) ? children[spawn] : nil
        }
        child?.exit(status: status)
    }
}

private final class RecordingChildProcess: SupervisedJournalChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let request: SupervisedJournalSpawnRequest
    private let spawner: RecordingProcessSpawner
    private let closeParentInputStopsProcess: Bool
    private var running = false
    private var terminationHandler: (@Sendable (Int32, pid_t) -> Void)?

    init(
        pid: pid_t,
        request: SupervisedJournalSpawnRequest,
        spawner: RecordingProcessSpawner,
        closeParentInputStopsProcess: Bool
    ) {
        self.pid = pid
        self.request = request
        self.spawner = spawner
        self.closeParentInputStopsProcess = closeParentInputStopsProcess
    }

    var processIdentifier: pid_t {
        pid
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    func setTerminationHandler(_ handler: @escaping @Sendable (Int32, pid_t) -> Void) {
        lock.withLock {
            terminationHandler = handler
        }
    }

    func run() throws {
        lock.withLock {
            running = true
        }
        spawner.recordSpawn(request)
    }

    func closeParentInput() {
        if closeParentInputStopsProcess {
            lock.withLock {
                running = false
            }
        }
    }

    func exit(status: Int32) {
        let handler = lock.withLock { () -> (@Sendable (Int32, pid_t) -> Void)? in
            running = false
            return terminationHandler
        }
        handler?(status, pid)
    }
}

private final class FixedStartTimeReader: JournalProcessEvidenceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var startTimes: [Double?]

    convenience init(startTime: Double) {
        self.init(startTimes: [startTime])
    }

    init(startTimes: [Double?]) {
        self.startTimes = startTimes
    }

    func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        let startTime = lock.withLock {
            startTimes.isEmpty ? nil : startTimes.removeFirst()
        }
        return JournalProcessEvidence(
            pid: pid,
            ppid: 1,
            uid: getuid(),
            username: currentUsername(),
            kernelStartTime: startTime
        )
    }
}

private final class NoopRunnerClock: MonotonicClock, @unchecked Sendable {
    func now() -> Duration { .zero }
    func sleep(for duration: Duration) async {}
}

private final class AdvancingRunnerClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero

    func now() -> Duration {
        lock.withLock { current }
    }

    func sleep(for duration: Duration) async {
        lock.withLock { current += duration }
    }
}
