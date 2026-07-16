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

        try await runner.start(runtime: fixture.runtime, journalRoot: fixture.linkedJournalRoot, port: 5015)

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
            try await runner.start(runtime: fixture.runtime, journalRoot: fixture.realJournalRoot, port: 5015)
            Issue.record("expected gateBlocked")
        } catch let error as SupervisedJournalRunnerError {
            #expect(error == .gateBlocked(blockage))
        }

        #expect(spawner.spawnRequests().isEmpty)
    }
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
    private let pid: pid_t
    private var requests: [SupervisedJournalSpawnRequest] = []

    init(pid: pid_t) {
        self.pid = pid
    }

    func makeChildProcess(for request: SupervisedJournalSpawnRequest) -> any SupervisedJournalChildProcess {
        RecordingChildProcess(pid: pid, request: request, spawner: self)
    }

    func spawnRequests() -> [SupervisedJournalSpawnRequest] {
        lock.withLock { requests }
    }

    fileprivate func recordSpawn(_ request: SupervisedJournalSpawnRequest) {
        lock.withLock {
            requests.append(request)
        }
    }
}

private final class RecordingChildProcess: SupervisedJournalChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private let request: SupervisedJournalSpawnRequest
    private let spawner: RecordingProcessSpawner
    private var running = false
    private var terminationHandler: (@Sendable (Int32, pid_t) -> Void)?

    init(pid: pid_t, request: SupervisedJournalSpawnRequest, spawner: RecordingProcessSpawner) {
        self.pid = pid
        self.request = request
        self.spawner = spawner
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
        lock.withLock {
            running = false
        }
    }
}

private struct FixedStartTimeReader: JournalProcessEvidenceReading {
    let startTime: Double

    func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        JournalProcessEvidence(
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
