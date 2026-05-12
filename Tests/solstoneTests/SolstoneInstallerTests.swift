// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import Testing
@testable import solstone

@Suite("SolstoneInstaller")
@MainActor
struct SolstoneInstallerTests {
    @Test func runningSolSetup_exitZero_transitionsTo_registering() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok"), delay: .milliseconds(0)))
        runner.enqueue("observer", .success(stdout: observerJSON, delay: .milliseconds(500)))
        runner.enqueue("install-models", .success(delay: .milliseconds(500)))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)

        try await waitUntil {
            if case .registering = installer.main { return true }
            return false
        }
    }

    @Test func solSetupArgv_includesIdempotencyFlags() async throws {
        for choice in [ExistingInstallChoice.createFresh, .acceptExisting] {
            let runner = FakeSubprocessRunner()
            let uvURL = try makeUVFixture()
            runner.enqueue("tool", .success())
            runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
            runner.enqueue("observer", .success(stdout: observerJSON))
            runner.enqueue("install-models", .success())
            let installer = makeInstaller(
                runner: runner,
                uvURL: uvURL,
                expectedDigest: sha256(Data("uv\n".utf8))
            )
            defer { installer.cancel() }

            installer.start(journalURL: URL(fileURLWithPath: "/tmp/solstone-test-journal"), existingInstallChoice: choice)
            try await waitUntil { installer.main == .done }

            let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
            #expect(setup.arguments == [
                "setup",
                "--jsonl",
                "--yes",
                "--skip-models",
                "--accept-existing-journal",
                "--journal",
                "/tmp/solstone-test-journal"
            ])
        }
    }

    @Test func detect_returnsTrue_whenSolBinaryPresent() async {
        let preferred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/sol").path
        guard FileManager.default.fileExists(atPath: preferred) else {
            return
        }

        let installer = SolstoneInstaller()
        let found = await installer.detect()
        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
    }

    @Test func failureMessage_isVerbatim_perSubprocessClass() async throws {
        try await jsonlStepFailedMessageIsVerbatim()
        try await rawSubprocessFailureUsesLastStderrLine()
        try await launchFailureUsesLocalizedDescription()
    }

    @Test func state4_concurrentObserverAndBrowser() async throws {
        try await assertState4(observerSucceeds: true, browserSucceeds: true, expectsDone: true)
        try await assertState4(observerSucceeds: true, browserSucceeds: false, expectsDone: true)
        try await assertState4(observerSucceeds: false, browserSucceeds: true, expectsDone: false)
        try await assertState4(observerSucceeds: false, browserSucceeds: false, expectsDone: false)
    }

    @Test func existingInstall_choiceSkipsSubprocess() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.first == "tool" })
        #expect(runner.invocations.contains { $0.arguments.first == "setup" })
    }

    @Test func jsonlEdgeFixtures_driveExpectedOutcomes() async throws {
        let expectations: [(String, Bool)] = [
            ("golden_ok", true),
            ("malformed_json", true),
            ("unknown_event_type", true),
            ("missing_setup_completed", false),
            ("duplicate_setup_completed", false),
            ("step_failed_unknown_code", false),
            ("empty_line", true),
            ("partial_line", true),
            ("extra_fields", true)
        ]

        for (name, shouldSucceed) in expectations {
            let runner = FakeSubprocessRunner()
            runner.enqueue("setup", .success(stdout: fixture(name)))
            runner.enqueue("observer", .success(stdout: observerJSON))
            runner.enqueue("install-models", .success())
            let installer = makeInstaller(runner: runner)
            defer { installer.cancel() }

            installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
            try await waitForTerminal(installer)

            if shouldSucceed {
                #expect(installer.main == .done)
            } else if case .failed(.solSetup) = installer.main {
                continue
            } else {
                Issue.record("expected solSetup failure for \(name), got \(installer.main)")
            }
        }
    }

    @Test func perErrorCodeFixtures_preserveCodes() async throws {
        for code in InstallerKnownValues.errorCodes {
            let runner = FakeSubprocessRunner()
            runner.enqueue("setup", .success(stdout: fixture("error_\(code)"), exitCode: 1))
            let installer = makeInstaller(runner: runner)
            defer { installer.cancel() }

            installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
            try await waitForTerminal(installer)

            if case .failed(.solSetup(let errorCode, _)) = installer.main {
                #expect(errorCode == code)
            } else {
                Issue.record("expected solSetup failure for \(code)")
            }
        }
    }

    @Test func uvChecksumMismatch_refusesToInvoke() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        let installer = makeInstaller(runner: runner, uvURL: uvURL, expectedDigest: String(repeating: "f", count: 64))

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.installSolstone(message: "bundled uv binary failed integrity check")))
        #expect(runner.invocations.isEmpty)
    }

    @Test func errorCategorization_perStderrFixture() throws {
        let expectations: [(String, ErrorCategory)] = [
            ("network", .network),
            ("disk", .disk),
            ("permission", .permission),
            ("subprocess_launch", .subprocessLaunch),
            ("unknown", .unknown)
        ]

        for (name, category) in expectations {
            let text = try stderrFixture(name)
            #expect(SolstoneInstaller.categorize(stderr: text) == category)
        }
    }

    private func jsonlStepFailedMessageIsVerbatim() async throws {
        let stdout = """
        {"event":"setup.started","version":"0.2.1","mode":"non_interactive"}
        {"event":"step.failed","step":"doctor","error":{"code":"doctor_failed","message":"exact verbatim message\\nwith newlines","details":"","exit_code":2}}
        {"event":"setup.completed","status":"failed","failed_step":"doctor"}

        """
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: Data(stdout.utf8), exitCode: 1))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitForTerminal(installer)

        if case .failed(.solSetup(_, let message)) = installer.main {
            #expect(message == "exact verbatim message\nwith newlines")
        } else {
            Issue.record("expected solSetup failure")
        }
    }

    private func rawSubprocessFailureUsesLastStderrLine() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        runner.enqueue("tool", .success(stderr: Data("last error\n".utf8), exitCode: 1))
        let installer = makeInstaller(runner: runner, uvURL: uvURL, expectedDigest: sha256(Data("uv\n".utf8)))
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == "last error")
        } else {
            Issue.record("expected installSolstone failure")
        }
    }

    private func launchFailureUsesLocalizedDescription() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        runner.enqueue("tool", .failure("launch boom"))
        let installer = makeInstaller(runner: runner, uvURL: uvURL, expectedDigest: sha256(Data("uv\n".utf8)))
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == "launch boom")
        } else {
            Issue.record("expected installSolstone launch failure")
        }
    }

    private func assertState4(observerSucceeds: Bool, browserSucceeds: Bool, expectsDone: Bool) async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue(
            "observer",
            observerSucceeds
                ? .success(stdout: observerJSON)
                : .success(stderr: Data("observer failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner, browserSucceeds: browserSucceeds)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitForTerminal(installer)

        if expectsDone {
            #expect(installer.main == .done)
        } else if case .failed(.registering(let message)) = installer.main {
            #expect(message == "observer failed")
        } else {
            Issue.record("unexpected registering state \(installer.main)")
        }
    }

    private func makeInstaller(
        runner: FakeSubprocessRunner,
        uvURL: URL? = nil,
        expectedDigest: String = BundleConfig.bundledUVSha256,
        browserSucceeds: Bool = true
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            subprocessRunner: runner,
            solBinaryFinder: { "/usr/bin/sol" },
            browserOpener: { _ in browserSucceeds },
            expectedUVDigest: expectedDigest
        )
    }

    private func waitForTerminal(_ installer: SolstoneInstaller) async throws {
        try await waitUntil {
            if case .done = installer.main { return true }
            if case .failed = installer.main { return true }
            return false
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(predicate())
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/installer")!
        return try! Data(contentsOf: url)
    }

    private func stderrFixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/installer/stderr"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeUVFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-uv-\(UUID().uuidString)")
        try Data("uv\n".utf8).write(to: url)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var observerJSON: Data {
        Data(#"{"name":"solstone-macos","key":"observer-key","prefix":"observer"}"#.utf8)
    }
}

private struct SubprocessInvocation: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
}

private final class FakeSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    struct Response: Sendable {
        var stdout: Data = Data()
        var stderr: Data = Data()
        var exitCode: Int32 = 0
        var delay: Duration = .zero
        var throwMessage: String?

        static func success(
            stdout: Data = Data(),
            stderr: Data = Data(),
            exitCode: Int32 = 0,
            delay: Duration = .zero
        ) -> Response {
            Response(stdout: stdout, stderr: stderr, exitCode: exitCode, delay: delay)
        }

        static func failure(_ message: String) -> Response {
            Response(throwMessage: message)
        }
    }

    private let lock = NSLock()
    private var responses: [String: [Response]] = [:]
    private var recordedInvocations: [SubprocessInvocation] = []
    private var didCancel = false

    var invocations: [SubprocessInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInvocations
    }

    func enqueue(_ key: String, _ response: Response) {
        lock.lock()
        responses[key, default: []].append(response)
        lock.unlock()
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        stdoutHandler: @escaping @Sendable (Data) -> Void,
        stderrHandler: @escaping @Sendable (Data) -> Void
    ) async throws -> SubprocessResult {
        let response = nextResponse(for: arguments)
        if response.delay != .zero {
            try? await Task.sleep(for: response.delay)
        }
        if let message = response.throwMessage {
            throw FakeRunError(message: message)
        }
        if !response.stdout.isEmpty {
            stdoutHandler(response.stdout)
        }
        if !response.stderr.isEmpty {
            stderrHandler(response.stderr)
        }
        return SubprocessResult(exitCode: response.exitCode, terminationReason: response.exitCode == 0 ? .exit : .exit)
    }

    func cancelAll() {
        lock.lock()
        didCancel = true
        lock.unlock()
    }

    private func nextResponse(for arguments: [String]) -> Response {
        lock.lock()
        defer { lock.unlock() }

        recordedInvocations.append(SubprocessInvocation(executable: URL(fileURLWithPath: "/fake"), arguments: arguments))
        let key = responseKey(for: arguments)
        guard var values = responses[key], !values.isEmpty else {
            return .success()
        }
        let response = values.removeFirst()
        responses[key] = values
        return response
    }

    private func responseKey(for arguments: [String]) -> String {
        guard let first = arguments.first else { return "" }
        if first == "tool" { return "tool" }
        if first == "setup" { return "setup" }
        if first == "observer" { return "observer" }
        if first == "install-models" { return "install-models" }
        return first
    }
}

private struct FakeRunError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
