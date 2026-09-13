// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

/// The composed lifecycle the Journal app runs on every launch, against the real native
/// supervisor: repair a stale required-model cache, spawn `journal start --hosted-parent`,
/// observe readiness through the real gate, read health from the running supervisor, then
/// prove termination leaves nothing behind using the live process-table reader production uses.
///
/// The single-supervisor port preflight is deliberately mocked open: it probes the fixed
/// convey port, which a host's own journal may legitimately hold. Its behaviour has its own
/// unit coverage; this suite owns the runner, the native process group and their teardown.
@Suite(
    "NativeIntegration lifecycle",
    .serialized,
    .enabled(
        if: NativeRuntimeFixture.isEnabled,
        "set SOLSTONE_NATIVE_INTEGRATION=1 (make integration-native) to run against the staged native journal runtime"
    )
)
struct NativeIntegrationLifecycleTests {
    @Test func staleCacheStartsReadyAndHealthyThenTerminationLeavesNoProcess() async throws {
        let fixture = try NativeRuntimeFixture(label: "lifecycle")
        defer { fixture.clear() }
        let setup = try await NativeIntegration.runAppSetup(fixture)
        try #require(setup.succeeded, "\(setup.stderr)")

        let directPort = try NativeRuntimeFixture.reserveLoopbackPort()
        let conveyPort = try NativeRuntimeFixture.reserveLoopbackPort()
        try NativeIntegration.configureDirectDoorPort(fixture, port: directPort)

        // Establish a cache, then age it: the state an upgraded Journal.app finds on relaunch.
        try await JournalRequiredModelsReconciler().reconcile(runtime: fixture.runtime, journalRoot: fixture.journalRoot)
        try NativeIntegration.staleSidecar(fixture)
        let stale = try await NativeIntegration.requiredModelsCheck(fixture)
        try #require(stale.exitCode == NativeIntegration.requiredModelsCheckDataError, "\(stale.stderr)")

        let statuses = RuntimeStatusRecorder()
        let runner = SupervisedJournalRunner(
            statusSink: { statuses.append($0) },
            gate: MockSingleSupervisorGate(result: .success),
            requiredModels: JournalRequiredModelsReconciler()
        )
        let reader = LiveJournalProcessContainmentEvidenceReader()
        let admitted = AdmittedProcesses()
        defer { NativeIntegration.killSurvivors(admitted.all()) }

        let startedAt = ContinuousClock.now
        try await runner.start(
            runtime: fixture.runtime,
            journalRoot: fixture.journalRoot,
            port: conveyPort,
            receiptContext: NativeIntegration.silentReceiptContext()
        )
        let identity = try #require(await runner.currentIdentity())
        admitted.record([identity.pid])

        // The repair ran before the spawn, against the real binary.
        let repaired = try await NativeIntegration.requiredModelsCheck(fixture)
        #expect(repaired.succeeded, "exit=\(repaired.exitCode)\n\(repaired.stderr)")

        let readiness = await JournalReadinessGate().waitUntilReady(
            journalRoot: fixture.journalRoot,
            runtime: fixture.runtime,
            timeout: .seconds(120),
            terminalCheck: { await runner.terminalReason() },
            identityProvider: { await runner.currentIdentity() },
            readinessAcceptance: { await runner.markReady(identity: $0) }
        )
        let readyAfter = startedAt.duration(to: .now)
        #expect(readiness == .ready, "\(readiness)")
        #expect(statuses.snapshot().contains(.running))

        // `journal health` asks the running supervisor over its socket with a 5 s budget; on a
        // loaded host that read can time out once, which is a scheduling fact, not a verdict.
        // Bound the retry so a starved read is still a failure, never a silent green.
        var health = JournalHealthCheckResult.unknown(JournalDiagnostic(commandLabel: "journal health"))
        let healthDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            health = await JournalHealthCheck.run(
                journalBinary: fixture.journalBinary,
                runner: SubprocessRunner(currentDirectoryURL: fixture.journalRoot),
                environment: fixture.environment
            )
            if health == .healthy { break }
            try await Task.sleep(for: .seconds(1))
        } while ContinuousClock.now < healthDeadline
        #expect(health == .healthy, "\(health)")

        // The supervisor read the configured door port from `config/journal.json` and recorded
        // it. A fresh journal whose identity ritual has not run withholds the door on purpose,
        // so the record, not a TCP connect, is the contract here; a bound door must also accept.
        let door = try #require(NativeIntegration.readDirectDoorRecord(fixture), "health/direct-door.json missing or malformed")
        #expect(door.port == directPort, "door record port \(door.port) != configured \(directPort)")
        #expect(["withheld", "bound"].contains(door.state), "unexpected door state \(door.state)")
        if door.state == "bound" {
            #expect(NativeIntegration.loopbackPortAccepts(directPort), "door recorded bound but 127.0.0.1:\(directPort) refused")
        }

        let evidence = try #require(reader.containmentEvidence(for: identity.pid))
        let group = try #require(reader.processIDs(inProcessGroup: evidence.processGroupID))
        #expect(group.contains(identity.pid))
        let descendants = reader.descendantProcessIDs(of: identity.pid) ?? []
        admitted.record(group + descendants)
        print("native-integration lifecycle: ready-after=\(readyAfter) group=\(group.count) descendants=\(descendants.count) door=\(door.state)")

        await runner.stopForTermination()
        let gone = await NativeIntegration.waitUntil(timeout: .seconds(20)) {
            admitted.all().allSatisfy { !NativeIntegration.processExists($0) }
                && (reader.processIDs(inProcessGroup: evidence.processGroupID) ?? [-1]).isEmpty
        }
        #expect(gone, "survivors after termination: \(admitted.all().filter(NativeIntegration.processExists))")
        #expect(await runner.currentIdentity() == nil)

        let healthAfterStop = await JournalHealthCheck.run(
            journalBinary: fixture.journalBinary,
            runner: SubprocessRunner(currentDirectoryURL: fixture.journalRoot),
            environment: fixture.environment
        )
        #expect(healthAfterStop != .healthy, "health still reads healthy after termination")
        #expect(fixture.forbiddenHomeArtifacts().isEmpty, "\(fixture.forbiddenHomeArtifacts())")
    }

}
