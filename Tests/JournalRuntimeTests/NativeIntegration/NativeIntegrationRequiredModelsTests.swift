// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

/// The app-to-native contract for first setup and required-model repair, driven against the
/// staged accepted `journal` binary. Every fake these paths use in the unit gate is replaced by
/// the real command here; what this catches is a native exit code, sidecar or argv contract
/// moving under a pin bump while the Swift side still expects the old one.
@Suite(
    "NativeIntegration required models",
    .serialized,
    .enabled(
        if: NativeRuntimeFixture.isEnabled,
        "set SOLSTONE_NATIVE_INTEGRATION=1 (make integration-native) to run against the staged native journal runtime"
    )
)
struct NativeIntegrationRequiredModelsTests {
    @Test func appSetupArgvCompletesAgainstStagedRuntimeWithoutTouchingHome() async throws {
        let fixture = try NativeRuntimeFixture(label: "setup")
        defer { fixture.clear() }

        let setup = try await NativeIntegration.runAppSetup(fixture)
        #expect(setup.succeeded, "setup exit=\(setup.exitCode) reason=\(setup.terminationReason.rawValue)\n\(setup.stderr)")
        #expect(setupCompletedOK(setup.stdout), "no setup.completed/ok event in:\n\(setup.stdout.suffix(2_000))")
        #expect(fixture.forbiddenHomeArtifacts().isEmpty, "\(fixture.forbiddenHomeArtifacts())")
        print("native-integration setup: elapsed=\(setup.elapsed) home-artifacts=\(fixture.homeArtifactsOutsideJournal())")
    }

    @Test func reconcilerRepairsMissingAndStaleRequiredModelCache() async throws {
        let fixture = try NativeRuntimeFixture(label: "repair")
        defer { fixture.clear() }
        let setup = try await NativeIntegration.runAppSetup(fixture)
        try #require(setup.succeeded, "\(setup.stderr)")

        // Negative control first: the native check must be able to see a missing cache, or a
        // passing check later proves nothing.
        let missing = try await NativeIntegration.requiredModelsCheck(fixture)
        #expect(missing.terminationReason == .exit)
        #expect(missing.exitCode == NativeIntegration.requiredModelsCheckDataError, "\(missing.stderr)")

        let firstRepairStarted = ContinuousClock.now
        try await JournalRequiredModelsReconciler().reconcile(runtime: fixture.runtime, journalRoot: fixture.journalRoot)
        let firstRepair = firstRepairStarted.duration(to: .now)
        let installed = try await NativeIntegration.requiredModelsCheck(fixture)
        #expect(installed.succeeded, "exit=\(installed.exitCode)\n\(installed.stderr)")
        #expect(FileManager.default.fileExists(atPath: NativeIntegration.sidecarURL(fixture).path))

        // The upgrade state: a cache that belongs to the previous runtime's engine.
        try NativeIntegration.staleSidecar(fixture)
        let stale = try await NativeIntegration.requiredModelsCheck(fixture)
        #expect(stale.exitCode == NativeIntegration.requiredModelsCheckDataError, "\(stale.stderr)")

        let secondRepairStarted = ContinuousClock.now
        try await JournalRequiredModelsReconciler().reconcile(runtime: fixture.runtime, journalRoot: fixture.journalRoot)
        let secondRepair = secondRepairStarted.duration(to: .now)
        let repaired = try await NativeIntegration.requiredModelsCheck(fixture)
        #expect(repaired.succeeded, "exit=\(repaired.exitCode)\n\(repaired.stderr)")
        #expect(fixture.forbiddenHomeArtifacts().isEmpty)
        print("native-integration repair: first=\(firstRepair) stale-repair=\(secondRepair)")
    }

    @Test func terminationDuringRequiredModelRepairLeavesNoNativeProcess() async throws {
        let fixture = try NativeRuntimeFixture(label: "cancel")
        defer { fixture.clear() }
        let setup = try await NativeIntegration.runAppSetup(fixture)
        try #require(setup.succeeded, "\(setup.stderr)")
        try await JournalRequiredModelsReconciler().reconcile(runtime: fixture.runtime, journalRoot: fixture.journalRoot)
        try NativeIntegration.staleSidecar(fixture)
        let stale = try await NativeIntegration.requiredModelsCheck(fixture)
        try #require(stale.exitCode == NativeIntegration.requiredModelsCheckDataError, "\(stale.stderr)")

        let reader = LiveJournalProcessContainmentEvidenceReader()
        let baseline = Set(reader.descendantProcessIDs(of: getpid()) ?? [])
        let runner = SupervisedJournalRunner(
            statusSink: { _ in },
            gate: MockSingleSupervisorGate(result: .success),
            requiredModels: JournalRequiredModelsReconciler()
        )
        let conveyPort = try NativeRuntimeFixture.reserveLoopbackPort()
        let start = Task {
            try await runner.start(
                runtime: fixture.runtime,
                journalRoot: fixture.journalRoot,
                port: conveyPort,
                receiptContext: NativeIntegration.silentReceiptContext()
            )
        }

        let observed = ObservedProcesses()
        let appeared = await NativeIntegration.waitUntil(timeout: .seconds(20), pollEvery: .milliseconds(2)) {
            let current = Set(reader.descendantProcessIDs(of: getpid()) ?? [])
            let fresh = current.subtracting(baseline)
            observed.record(fresh)
            return !fresh.isEmpty
        }
        defer { NativeIntegration.killSurvivors(observed.all()) }
        #expect(appeared, "no native child appeared within 20s")

        let identityBeforeStop = await runner.currentIdentity()
        await runner.stopForTermination()
        let outcome = await start.result

        if identityBeforeStop == nil {
            // Caught during repair: the installer child existed and no supervisor had been
            // admitted. A cancelled repair must surface as cancellation, never as a started runtime.
            #expect(throws: CancellationError.self) { try outcome.get() }
        } else {
            Issue.record("the repair finished before cancellation could land (supervisor already admitted); this run proved teardown but not mid-repair cancellation")
        }

        let gone = await NativeIntegration.waitUntil(timeout: .seconds(15)) {
            let current = Set(reader.descendantProcessIDs(of: getpid()) ?? [-1])
            return observed.all().allSatisfy { !NativeIntegration.processExists($0) }
                && current.subtracting(baseline).isEmpty
        }
        #expect(gone, "native processes survived termination: \(observed.all().filter(NativeIntegration.processExists))")
        #expect(await runner.currentIdentity() == nil)
        #expect(fixture.forbiddenHomeArtifacts().isEmpty)
    }

    private func setupCompletedOK(_ stdout: String) -> Bool {
        stdout.split(separator: "\n").contains { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["event"] as? String == "setup.completed" && object["status"] as? String == "ok"
        }
    }
}

private final class ObservedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func record(_ fresh: Set<pid_t>) {
        lock.withLock { pids.formUnion(fresh) }
    }

    func all() -> [pid_t] {
        lock.withLock { Array(pids) }
    }
}
