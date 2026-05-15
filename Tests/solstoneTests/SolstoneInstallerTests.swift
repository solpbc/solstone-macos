// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
import SolstoneCore
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
                uvURL: uvURL
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

    @Test func state4_observerResultDrivesTerminalState() async throws {
        try await assertState4(observerSucceeds: true, expectsDone: true)
        try await assertState4(observerSucceeds: false, expectsDone: false)
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

    @Test func observerCreateSuccessWritesBundledServiceConfig() async throws {
        let appState = AppState.forSnapshot()
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner, connectionTester: { _, _ in nil })
        installer.attach(appState: appState)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(appState.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(appState.config.serverKey == "observer-key")
        #expect(appState.config.serviceMode == .bundled)
    }

    @Test func postInstallAutoTestSucceedsAfterDone() async throws {
        let appState = AppState.forSnapshot()
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            connectionTester: { _, _ in
                try? await Task.sleep(for: .milliseconds(100))
                return nil
            }
        )
        installer.attach(appState: appState)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)

        try await waitUntil { installer.postInstallAutoTest == .verifying }
        try await waitUntil { installer.postInstallAutoTest == .success }
    }

    @Test func postInstallAutoTestFailsOnConnectionError() async throws {
        let appState = AppState.forSnapshot()
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner, connectionTester: { _, _ in "offline" })
        installer.attach(appState: appState)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)

        try await waitUntil {
            if case .failure("offline") = installer.postInstallAutoTest { return true }
            return false
        }
    }

    @Test func probeVersionMapsCurrentVersion() async {
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner)

        await installer.probeVersion()

        #expect(installer.probedVersion == .current(version: BundleConfig.solstonePinVersion))
    }

    @Test func probeVersionMapsOutdatedVersion() async {
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        let installer = makeInstaller(runner: runner)

        await installer.probeVersion()

        #expect(installer.probedVersion == .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion))
    }

    @Test func probeVersionMapsUnparseableVersionToUnknown() async {
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("unparseable\n".utf8)))
        let installer = makeInstaller(runner: runner)

        await installer.probeVersion()

        #expect(installer.probedVersion == .unknown)
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
        let installer = makeInstaller(runner: runner, uvURL: uvURL)
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
        let installer = makeInstaller(runner: runner, uvURL: uvURL)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == "launch boom")
        } else {
            Issue.record("expected installSolstone launch failure")
        }
    }

    private func assertState4(observerSucceeds: Bool, expectsDone: Bool) async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue(
            "observer",
            observerSucceeds
                ? .success(stdout: observerJSON)
                : .success(stderr: Data("observer failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
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
        connectionTester: @escaping @Sendable (String, String) async -> String? = { _, _ in nil }
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            subprocessRunner: runner,
            solBinaryFinder: { "/usr/bin/sol" },
            connectionTester: connectionTester
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

    private var observerJSON: Data {
        Data(#"{"name":"solstone-macos","key":"observer-key","prefix":"observer"}"#.utf8)
    }
}
