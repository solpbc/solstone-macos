// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import JournalRuntimeTestSupport
import Testing
import SolstoneCore
@testable import solstone

@Suite("AppState terminating gates")
@MainActor
struct AppStateTerminatingGateTests {
    @Test func startRecordingNoOpsWhenTerminating() async {
        let state = AppState.forSnapshot()
        state.isTerminating = true

        await state.startRecording()

        #expect(!state.isRecording)
        #expect(state.errorMessage == nil)
    }

    @Test func requestJournalStartNoOpsWhenTerminating() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner
        state.journalRuntimeStatus = .stoppedByUser
        state.isTerminating = true

        state.requestJournalStart()
        try await Task.sleep(for: .milliseconds(10))

        #expect(runner.startCalls == 0)
        #expect(state.journalRuntimeStatus == .stoppedByUser)
    }

    @Test func requestBundledJournalRuntimeStartNoOpsWhenTerminating() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)
        state.isTerminating = true

        state.requestBundledJournalRuntimeStart()
        try await Task.sleep(for: .milliseconds(10))

        #expect(runner.startCalls == 0)
    }

    @Test func coordinateBundledJournalStartNoOpsWhenTerminating() async throws {
        let journalRoot = try makeTempDirectory("terminating-gate")
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled, journalPath: journalRoot.path))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)
        state.isTerminating = true

        let ready = await state.ensureBundledJournalRuntime(journalRoot: journalRoot)

        #expect(!ready)
        #expect(runner.startCalls == 0)
    }

    @Test func requestJournalRestartNoOpsWhenTerminating() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner
        state.isTerminating = true

        state.requestJournalRestart()
        try await Task.sleep(for: .milliseconds(10))

        #expect(runner.restartCalls == 0)
    }
}
