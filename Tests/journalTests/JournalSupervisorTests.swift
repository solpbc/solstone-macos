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
    @Test func blockedRunnerGateDoesNoSpawnOrReadiness() async throws {
        let events = EventRecorder()
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "blocked")
        let blockage = SingleSupervisorGateBlockage.portConflict(diagnostic)
        let runner = RecordingRunner(
            events: events,
            gate: RecordingGate(events: events, result: .blocked(blockage))
        )
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)

        let started = await supervisor.start(journalRoot: try makeTemporaryDirectory())

        #expect(!started)
        #expect(await events.snapshot() == ["materialize", "gate"])
        #expect(supervisor.state == .blocked(diagnostic))
        #expect(supervisor.blockedReason == blockage.ownerMessage)
    }

    @Test func openGateRunsMaterializeSpawnReadinessInOrder() async throws {
        let events = EventRecorder()
        let runner = RecordingRunner(
            events: events,
            gate: RecordingGate(events: events, result: .success)
        )
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        let receiptContext = configureInMemoryReceiptContext(supervisor)

        let started = await supervisor.start(journalRoot: try makeTemporaryDirectory())

        #expect(started)
        #expect(await events.snapshot() == ["materialize", "gate", "spawn", "readiness", "markReady"])
        #expect(supervisor.state == .running)
        #expect(supervisor.journalBinaryURL != nil)
        #expect(await runner.receiptAttemptIDs() == [receiptContext.attemptID])
    }

    @Test func runtimeStatusCanBeAppliedDirectlyForSinkSimulation() async throws {
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: EventRecorder(), result: .success),
            materializer: try await RecordingMaterializer(events: EventRecorder()),
            runner: RecordingRunner(events: EventRecorder()),
            readinessGate: RecordingReadinessGate(events: EventRecorder(), result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)
        let diagnostic = JournalDiagnostic(commandLabel: "journal", outputExcerpt: "done")

        supervisor.applyRuntimeStatus(.stopped(diagnostic))

        #expect(supervisor.runtimeStatus == .stopped(diagnostic))
    }

    @Test func stopAppliesStoppedByUserBecauseRunnerStopIsSilent() async throws {
        let events = EventRecorder()
        let runner = RecordingRunner(
            events: events,
            gate: RecordingGate(events: events, result: .success)
        )
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)
        _ = await supervisor.start(journalRoot: try makeTemporaryDirectory())
        supervisor.applyRuntimeStatus(.running)

        let stopped = await supervisor.stop()

        #expect(stopped)
        #expect(await events.snapshot() == ["materialize", "gate", "spawn", "readiness", "markReady", "stop"])
        #expect(supervisor.state == .idle)
        #expect(supervisor.runtimeStatus == .stoppedByUser)
        #expect(supervisor.journalBinaryURL == nil)
    }

    @Test func restartPassthroughRerunsReadinessBeforeRunning() async throws {
        let events = EventRecorder()
        let runner = RecordingRunner(
            events: events,
            gate: RecordingGate(events: events, result: .success)
        )
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)
        let root = try makeTemporaryDirectory()
        _ = await supervisor.start(journalRoot: root)
        supervisor.applyRuntimeStatus(.running)

        let restarted = await supervisor.restart()

        #expect(restarted)
        #expect(await events.snapshot() == [
            "materialize", "gate", "spawn", "readiness", "markReady",
            "gate", "restart", "readiness", "markReady"
        ])
        #expect(supervisor.state == .running)
        #expect(supervisor.activeJournalRoot == root.standardizedFileURL)
    }

    @Test func restartGateBlockedMapsToBlockedState() async throws {
        let events = EventRecorder()
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "blocked")
        let blockage = SingleSupervisorGateBlockage.portConflict(diagnostic)
        let gate = RecordingGate(events: events, results: [.success, .blocked(blockage)])
        let runner = RecordingRunner(events: events, gate: gate)
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)
        let root = try makeTemporaryDirectory()
        _ = await supervisor.start(journalRoot: root)
        supervisor.applyRuntimeStatus(.running)

        let restarted = await supervisor.restart()

        #expect(!restarted)
        #expect(await events.snapshot() == [
            "materialize", "gate", "spawn", "readiness", "markReady",
            "gate"
        ])
        #expect(supervisor.state == .blocked(diagnostic))
        #expect(supervisor.blockedReason == blockage.ownerMessage)
    }

    @Test func restartWithoutActiveRuntimeFailsClosed() async throws {
        let events = EventRecorder()
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: RecordingRunner(events: events),
            readinessGate: RecordingReadinessGate(events: events, result: .ready)
        )
        _ = configureInMemoryReceiptContext(supervisor)

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

    @Test func lazyReceiptContextFactoryIsRedirectedAndResolvedOnlyOnce() async throws {
        let events = EventRecorder()
        let runner = RecordingRunner(events: events, gate: RecordingGate(events: events, result: .success))
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".journal-supervisor-receipts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }
        var factoryCalls = 0
        let supervisor = JournalSupervisor(
            gate: RecordingGate(events: events, result: .success),
            materializer: try await RecordingMaterializer(events: events),
            runner: runner,
            readinessGate: RecordingReadinessGate(events: events, result: .ready),
            receiptContextFactory: {
                factoryCalls += 1
                return JournalRuntimeEntryReceiptLaunch.begin(applicationSupportBaseURL: baseURL)
            }
        )

        _ = await supervisor.start(journalRoot: try makeTemporaryDirectory())
        _ = await supervisor.restart()

        #expect(factoryCalls == 1)
        #expect(await runner.receiptAttemptIDs().count == 1)
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
        _ = configureInMemoryReceiptContext(supervisor)

        await supervisor.terminate(reason: "journal-test-quit")
        let marker = ExpectedExitMarker.read(at: markerURL)

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
    private var results: [SingleSupervisorGateResult]

    init(events: EventRecorder, result: SingleSupervisorGateResult) {
        self.events = events
        results = [result]
    }

    init(events: EventRecorder, results: [SingleSupervisorGateResult]) {
        self.events = events
        self.results = results
    }

    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        await events.append("gate")
        guard !results.isEmpty else { return .success }
        if results.count == 1 {
            return results[0]
        }
        return results.removeFirst()
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
    private let gate: RecordingGate?
    private var runtimeKey: String?
    private var receiptContexts: [JournalRuntimeEntryReceiptContext] = []

    init(events: EventRecorder, markerURLForStopCheck: URL? = nil, gate: RecordingGate? = nil) {
        self.events = events
        self.markerURLForStopCheck = markerURLForStopCheck
        self.gate = gate
    }

    func start(
        runtime: MaterializedRuntime,
        journalRoot: URL,
        port: Int,
        receiptContext: JournalRuntimeEntryReceiptContext
    ) async throws {
        if let gate {
            switch await gate.prepareForSpawn(journalRoot: journalRoot) {
            case .success:
                break
            case .blocked(let blockage):
                throw SupervisedJournalRunnerError.gateBlocked(blockage)
            }
        }
        await events.append("spawn")
        receiptContexts.append(receiptContext)
        runtimeKey = runtime.key
    }

    func restart() async throws {
        if let gate {
            switch await gate.prepareForSpawn(journalRoot: URL(fileURLWithPath: "/tmp/journal-supervisor-restart")) {
            case .success:
                break
            case .blocked(let blockage):
                throw SupervisedJournalRunnerError.gateBlocked(blockage)
            }
        }
        await events.append("restart")
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

    func receiptAttemptIDs() -> [JournalRuntimeEntryAttemptID] {
        receiptContexts.map(\.attemptID)
    }

    func currentIdentity() async -> SupervisedChildIdentity? {
        nil
    }

    func terminalReason() async -> JournalDiagnostic? {
        nil
    }

    func markReady() async {
        await events.append("markReady")
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
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?,
        identityProvider: @escaping @Sendable () async -> SupervisedChildIdentity?
    ) async -> JournalReadinessResult {
        await events.append("readiness")
        return result
    }
}
