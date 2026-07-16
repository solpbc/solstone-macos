// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import journal

@MainActor
@Suite("JournalSupervisor")
struct JournalSupervisorTests {
    @Test func spawnBlockDoesNotRunReadiness() async throws {
        let events = EventRecorder()
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "blocked")
        let blockage = SingleSupervisorGateBlockage.portConflict(diagnostic)
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .blocked(blockage)),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events, startError: SupervisedJournalRunnerError.spawnBlocked(blockage)),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )

        let started = await supervisor.start(journalRoot: try makeTemporaryDirectory())

        #expect(!started)
        #expect(await events.snapshot() == ["materialize", "spawn"])
        #expect(supervisor.state == .blocked(diagnostic))
        #expect(supervisor.blockedReason == blockage.ownerMessage)
    }

    @Test func startRunsMaterializeSpawnReadinessInOrder() async throws {
        let events = EventRecorder()
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )

        let started = await supervisor.start(journalRoot: try makeTemporaryDirectory())

        #expect(started)
        #expect(await events.snapshot() == ["materialize", "spawn", "readiness", "markReady"])
        #expect(supervisor.state == .running)
        #expect(supervisor.journalBinaryURL != nil)
    }

    @Test func runtimeStatusCanBeAppliedDirectlyForSinkSimulation() async throws {
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: EventRecorder(), result: .success),
            materializer: try await RecordingMaterializer(events: EventRecorder()),
            runner: RecordingRunner(events: EventRecorder()),
            readinessGate: RecordingReadinessGate(events: EventRecorder(), result: .ready)
        )
        let diagnostic = JournalDiagnostic(commandLabel: "journal", outputExcerpt: "done")

        supervisor.applyRuntimeStatus(.stopped(diagnostic))

        #expect(supervisor.runtimeStatus == .stopped(diagnostic))
    }

    @Test func stopAppliesStoppedByUserBecauseRunnerStopIsSilent() async throws {
        let events = EventRecorder()
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = await supervisor.start(journalRoot: try makeTemporaryDirectory())
        supervisor.applyRuntimeStatus(.running)

        let stopped = await supervisor.stop()

        #expect(stopped)
        #expect(await events.snapshot() == ["materialize", "spawn", "readiness", "markReady", "stop"])
        #expect(supervisor.state == .idle)
        #expect(supervisor.runtimeStatus == .stoppedByUser)
        #expect(supervisor.journalBinaryURL == nil)
    }

    @Test func restartPassthroughRerunsReadinessBeforeRunning() async throws {
        let events = EventRecorder()
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        let root = try makeTemporaryDirectory()
        _ = await supervisor.start(journalRoot: root)
        supervisor.applyRuntimeStatus(.running)

        let restarted = await supervisor.restart()

        #expect(restarted)
        #expect(await events.snapshot() == [
            "materialize", "spawn", "readiness", "markReady",
            "restart", "readiness", "markReady"
        ])
        #expect(supervisor.state == .running)
        #expect(supervisor.activeJournalRoot == root.standardizedFileURL)
    }

    @Test func restartWithoutActiveRuntimeFailsClosed() async throws {
        let events = EventRecorder()
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )

        let restarted = await supervisor.restart()

        #expect(!restarted)
        #expect(await events.snapshot().isEmpty)
        if case .failed(let diagnostic) = supervisor.state {
            #expect(diagnostic.commandLabel == "journal restart")
        } else {
            Issue.record("expected failed restart state")
        }
        if case .unknown(let diagnostic) = supervisor.runtimeStatus {
            #expect(diagnostic.commandLabel == "journal restart")
        } else {
            Issue.record("expected unknown restart status")
        }
    }

    @Test func terminateWritesJournalMarkerBeforeStopLadder() async throws {
        let events = EventRecorder()
        let baseURL = try makeTemporaryDirectory()
        let markerURL = ExpectedExitMarker.markerURL(
            for: ExpectedExitMarker.journalMarkerDiscriminator,
            applicationSupportBaseURL: baseURL
        )
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let runner = RecordingRunner(events: events, markerURLForStopCheck: markerURL)
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready),
            markerURL: markerURL
        )

        await supervisor.terminate(reason: "journal-test-quit")
        let marker = ExpectedExitMarker.readAndConsume(at: markerURL)

        #expect(await events.snapshot() == ["stopForTermination-after-marker"])
        #expect(marker?.reason == "journal-test-quit")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-supervisor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor RecordingGate: SingleSupervisorGating {
    private let events: EventRecorder
    private let result: SingleSupervisorGateResult

    init(events: EventRecorder, result: SingleSupervisorGateResult) {
        self.events = events
        self.result = result
    }

    func prepareForSpawn(journalRoot: URL, context: LaunchAuthorizationContext) async -> SingleSupervisorGateResult {
        await events.append("gate")
        return result
    }
}

private actor RecordingMaterializer: RuntimeMaterializing {
    private let events: EventRecorder
    private let runtime: MaterializedRuntime

    init(events: EventRecorder) async throws {
        self.events = events
        runtime = try makeRuntime()
    }

    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        await events.append("materialize")
        return runtime
    }
}

private actor RecordingRunner: SupervisedChildRunning {
    private let events: EventRecorder
    private let markerURLForStopCheck: URL?
    private let startError: Error?
    private var runtimeKey: String?
    private var generation: UInt64 = 0

    init(events: EventRecorder, markerURLForStopCheck: URL? = nil, startError: Error? = nil) {
        self.events = events
        self.markerURLForStopCheck = markerURLForStopCheck
        self.startError = startError
    }

    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws -> JournalChildIdentity {
        await events.append("spawn")
        if let startError {
            throw startError
        }
        generation += 1
        runtimeKey = runtime.key
        return JournalChildIdentity(pid: 4242, startTime: 100, generation: generation)
    }

    func restart() async throws -> JournalChildIdentity {
        await events.append("restart")
        generation += 1
        return JournalChildIdentity(pid: 4243, startTime: 101, generation: generation)
    }

    func stop() async {
        await events.append("stop")
        runtimeKey = nil
    }

    func stopForTermination() async {
        if let markerURLForStopCheck,
           FileManager.default.fileExists(atPath: markerURLForStopCheck.path) {
            await events.append("stopForTermination-after-marker")
        } else {
            await events.append("stopForTermination-before-marker")
        }
        runtimeKey = nil
    }

    func currentRuntimeKey() async -> String? {
        runtimeKey
    }

    func terminalReason() async -> JournalDiagnostic? {
        nil
    }

    func isCurrentGeneration(_ generation: UInt64) async -> Bool {
        self.generation == generation
    }

    func markReady(_ identity: JournalChildIdentity) async -> Bool {
        await events.append("markReady")
        return self.generation == identity.generation
    }
}

private actor RecordingReadinessGate: JournalReadinessChecking {
    private let events: EventRecorder
    private let result: JournalReadinessResult

    init(events: EventRecorder, result: JournalReadinessResult) {
        self.events = events
        self.result = result
    }

    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        child: JournalChildIdentity,
        timeout: Duration,
        generationIsCurrent: @escaping @Sendable (UInt64) async -> Bool,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult {
        await events.append("readiness")
        return result
    }
}
