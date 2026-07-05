// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("JournalSetupRunnerTests")
struct JournalSetupRunnerTests {
    @Test func setupUsesExactSharedArgumentsIncludingSkipService() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("setup", .success(stdout: Data(Self.okSetupJSONL.utf8)))
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(runtime))
        )
        let journalRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: journalRoot) }

        _ = try await runner.run(journalRoot: journalRoot, skipService: true)

        let invocation = try #require(subprocess.invocations.first { $0.arguments.first == "setup" })
        #expect(invocation.executable == runtime.layout.journalBinary)
        #expect(invocation.arguments == [
            "setup",
            "--jsonl",
            "--yes",
            "--skip-models",
            "--accept-existing-journal",
            "--journal",
            journalRoot.standardizedFileURL.path,
            "--skip-service",
        ])
        #expect(invocation.timeout == .seconds(180))
        #expect(JournalSetupCommand.setupArguments(journalURL: journalRoot, skipService: false) == [
            "setup",
            "--jsonl",
            "--yes",
            "--skip-models",
            "--accept-existing-journal",
            "--journal",
            journalRoot.path,
        ])
    }

    @Test func gateBlockedShortCircuitsMaterializeAndRun() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        let materializer = MockRuntimeMaterializer(result: .success(runtime))
        let diagnostic = JournalDiagnostic(commandLabel: "gate", outputExcerpt: "busy")
        let blockage = SingleSupervisorGateBlockage.portConflict(diagnostic)
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(result: .blocked(blockage)),
            materializer: materializer
        )

        do {
            _ = try await runner.run(journalRoot: try makeTemporaryDirectory())
            Issue.record("expected gateBlocked")
        } catch let error as JournalSetupRunnerError {
            #expect(error == .gateBlocked(blockage))
        }

        #expect(materializer.materializeCalls == 0)
        #expect(subprocess.invocations.isEmpty)
    }

    @Test func materializeFailureMapsToTypedError() async throws {
        let subprocess = FakeSubprocessRunner()
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .failure(TestError(message: "materialize boom")))
        )

        do {
            _ = try await runner.run(journalRoot: try makeTemporaryDirectory())
            Issue.record("expected materializeFailed")
        } catch let error as JournalSetupRunnerError {
            #expect(error == .materializeFailed(message: "materialize boom"))
        }

        #expect(subprocess.invocations.isEmpty)
    }

    @Test func successfulJSONLEmitsOrderedProgressAndReturnsResult() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("setup", .success(stdout: Data(Self.progressSetupJSONL.utf8)))
        let events = EventRecorder()
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(runtime))
        )

        let result = try await runner.run(journalRoot: try makeTemporaryDirectory()) { event in
            await events.append(event)
        }

        #expect(await events.snapshot() == [
            .stepStarted(step: "doctor", index: 1, total: 2),
            .warning(step: "doctor", text: "port looks busy", fixHint: "try again"),
            .completed(status: "ok"),
        ])
        #expect(result.runtime.key == runtime.key)
        #expect(result.stdoutTail.contains(#""setup.completed""#))
        #expect(result.renderedLog.contains("setup ok"))
    }

    @Test func timeoutFailsWithTypedTimeout() async throws {
        try await expectSetupError(
            response: .success(delay: .milliseconds(5)),
            setupTimeout: .milliseconds(5),
            expected: .timedOut(timeout: .milliseconds(5))
        )
    }

    @Test func duplicateCompletionFails() async throws {
        try await expectSetupError(
            response: .success(stdout: Data("""
            {"event":"setup.completed","status":"ok"}
            {"event":"setup.completed","status":"ok"}

            """.utf8)),
            expected: .duplicateCompletion
        )
    }

    @Test func nonzeroExitFailsWithStderrMessage() async throws {
        try await expectSetupError(
            response: .success(
                stdout: Data(Self.okSetupJSONL.utf8),
                stderr: Data("journal failed\n".utf8),
                exitCode: 2
            ),
            expected: .setupFailed(errorCode: nil, message: "journal failed")
        )
    }

    @Test func stepFailureFailsWithStepError() async throws {
        try await expectSetupError(
            response: .success(stdout: Data("""
            {"event":"step.failed","step":"doctor","error":{"code":"port_in_use_non_interactive","message":"port failed","details":"","exit_code":2}}
            {"event":"setup.completed","status":"ok"}

            """.utf8)),
            expected: .setupFailed(errorCode: "port_in_use_non_interactive", message: "port failed")
        )
    }

    @Test func failedSetupCompletedFails() async throws {
        try await expectSetupError(
            response: .success(stdout: Data("""
            {"event":"setup.completed","status":"failed","failed_step":"doctor"}

            """.utf8)),
            expected: .setupFailed(errorCode: nil, message: "setup failed at doctor")
        )
    }

    @Test func missingSetupCompletedFails() async throws {
        try await expectSetupError(
            response: .success(stdout: Data(#"{"event":"step.started","step":"doctor","index":1,"total":2}"#.utf8)),
            expected: .missingCompletion
        )
    }

    @Test func installModelsIsInvokedAndDoesNotBlockCompletion() async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("setup", .success(stdout: Data(Self.okSetupJSONL.utf8)))
        subprocess.enqueue("install-models", .success(delay: .seconds(2)))
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(runtime))
        )
        let start = ContinuousClock.now

        _ = try await runner.run(journalRoot: try makeTemporaryDirectory())
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(1))
        let sawInstallModels = await waitForInvocation(subprocess) { invocation in
            invocation.arguments == ["install-models"]
        }
        #expect(sawInstallModels)
    }

    private static let okSetupJSONL = """
    {"event":"setup.completed","status":"ok","duration_ms":10}

    """

    private static let progressSetupJSONL = """
    {"event":"step.started","step":"doctor","index":1,"total":2}
    {"event":"step.warning","step":"doctor","text":"port looks busy","fix_hint":"try again"}
    {"event":"setup.completed","status":"ok","duration_ms":10}

    """

    private func expectSetupError(
        response: FakeSubprocessRunner.Response,
        setupTimeout: Duration = .seconds(180),
        expected: JournalSetupRunnerError
    ) async throws {
        let runtime = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: runtime.layout.rootURL) }
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("setup", response)
        let runner = JournalSetupRunner(
            subprocessRunner: subprocess,
            gate: MockSingleSupervisorGate(),
            materializer: MockRuntimeMaterializer(result: .success(runtime)),
            setupTimeout: setupTimeout
        )

        do {
            _ = try await runner.run(journalRoot: try makeTemporaryDirectory())
            Issue.record("expected \(expected)")
        } catch let error as JournalSetupRunnerError {
            #expect(error == expected)
        }
    }

    private func waitForInvocation(
        _ runner: FakeSubprocessRunner,
        timeout: Duration = .seconds(1),
        matching predicate: (SubprocessInvocation) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if runner.invocations.contains(where: predicate) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return runner.invocations.contains(where: predicate)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-setup-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor EventRecorder {
    private var events: [JournalSetupProgressEvent] = []

    func append(_ event: JournalSetupProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [JournalSetupProgressEvent] {
        events
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
