// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import JournalRuntimeTestSupport
import Testing
@testable import journal

@MainActor
@Suite("JournalUpdateRecovery")
struct JournalUpdateRecoveryTests {
    @Test func failedInstallRecoveryResetsTerminationFlagsAndRestartsSupervision() async throws {
        let fixture = try makeConfiguredFixture()
        defer { fixture.clear() }
        let runner = RecoveryRunner()
        let supervisor = JournalSupervisor(
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(try makeRuntime())),
            runner: runner,
            readinessGate: MockJournalReadinessGate(result: .ready)
        )
        let model = JournalAppModel(config: fixture.config, supervisor: supervisor)

        await model.prepareForTermination()
        #expect(model.terminationPrepared)
        #expect(model.appKitTerminationBegan)
        #expect(await runner.stopForTerminationCalls == 1)

        model.resetAfterFailedUpdaterInstall()
        await model.reestablishSupervisionAfterFailedUpdate()

        #expect(!model.terminationPrepared)
        #expect(!model.appKitTerminationBegan)
        #expect(await runner.startCalls == 1)
        #expect(await runner.runningJournalRoot == fixture.root.standardizedFileURL)

        await model.prepareForTermination()

        #expect(model.terminationPrepared)
        #expect(model.appKitTerminationBegan)
        #expect(await runner.stopForTerminationCalls == 2)
    }

    private func makeConfiguredFixture() throws -> RecoveryFixture {
        let suiteName = "app.solstone.journal.update-recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let config = JournalAppConfig(defaults: defaults, loginItemManager: RecoveryFakeLoginItemManager())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-update-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        config.journalRoot = root
        return RecoveryFixture(suiteName: suiteName, defaults: defaults, config: config, root: root)
    }
}

private actor RecoveryRunner: SupervisedChildRunning {
    private var starts = 0
    private var terminations = 0
    private var runtimeKey: String?
    private var journalRoot: URL?
    private var generation: UInt64 = 0

    var startCalls: Int { starts }
    var stopForTerminationCalls: Int { terminations }
    var runningJournalRoot: URL? { journalRoot }

    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws -> JournalChildIdentity {
        starts += 1
        generation += 1
        runtimeKey = runtime.key
        self.journalRoot = journalRoot.standardizedFileURL
        return JournalChildIdentity(pid: 6242, startTime: 300, generation: generation)
    }

    func restart() async throws -> JournalChildIdentity {
        generation += 1
        return JournalChildIdentity(pid: 6243, startTime: 301, generation: generation)
    }

    func stop() async {
        runtimeKey = nil
        journalRoot = nil
    }

    func stopForTermination() async {
        terminations += 1
        runtimeKey = nil
        journalRoot = nil
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
        self.generation == identity.generation
    }
}

private struct RecoveryFixture {
    let suiteName: String
    let defaults: UserDefaults
    let config: JournalAppConfig
    let root: URL

    @MainActor
    func clear() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class RecoveryFakeLoginItemManager: LoginItemManaging {
    func register() throws {}
    func unregister() throws {}
}
