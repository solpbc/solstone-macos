// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("SolstoneInstaller", .serialized)
@MainActor
struct SolstoneInstallerTests {
    @Test func happyPathReachesDoneAndPreservesIdentityConfig() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        enqueueSuccessfulInstall(on: runner)
        let host = TestInstallerHost(
            config: AppConfig(
                serverURL: "https://existing.example",
                serverKey: "existing-key",
                serviceMode: .external,
                observerName: "existing-observer"
            ),
            readinessResult: true
        )
        let installer = makeInstaller(fixture: fixture, runner: runner)
        installer.attach(host: host)

        installer.start(journalURL: fixture.journalRoot, existingInstallChoice: .createFresh)

        #expect(await waitForInstallToFinish(installer))
        #expect(installer.main == .done)
        #expect(host.installerConfig.serverURL == ServiceMode.bundledServiceURL)
        #expect(host.installerConfig.serviceMode == .bundled)
        #expect(host.installerConfig.serverKey == "existing-key")
        #expect(host.installerConfig.observerName == "existing-observer")
        #expect(host.bundledCompletionUpdateCount == 1)
    }

    @Test func cancellationShortCircuitsBeforeDone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        enqueueSuccessfulInstall(on: runner)
        runner.enqueue("warm", .success(delay: .seconds(30)))
        let host = TestInstallerHost(
            config: AppConfig(serverURL: "https://existing.example", serviceMode: .external),
            readinessResult: true
        )
        let installer = makeInstaller(fixture: fixture, runner: runner)
        installer.attach(host: host)

        installer.start(journalURL: fixture.journalRoot, existingInstallChoice: .createFresh)

        #expect(await waitForInvocation(runner) { $0.arguments == ["warm"] })
        installer.cancel()

        #expect(await waitForInstallToFinish(installer))
        #expect(installer.main != .done)
        #expect(host.bundledCompletionUpdateCount == 0)
    }

    @Test func readinessFailureUsesConfirmingReadinessStateAndPreservesDiagnostics() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        enqueueSuccessfulInstall(on: runner)
        let host = TestInstallerHost(readinessResult: false)
        let installer = makeInstaller(fixture: fixture, runner: runner)
        installer.attach(host: host)

        installer.start(journalURL: fixture.journalRoot, existingInstallChoice: .createFresh)

        #expect(await waitForInstallToFinish(installer))
        #expect(installer.main == .failed(.confirmingReadiness(message: UICopy.INSTALLER_READINESS_GATE_FAILED)))
        #expect(installer.lastFailureCategory == .unknown)
        #expect(installer.lastFailureLog == "app-owned journal child did not become ready")
        #expect(host.readinessCallCount == 1)
    }

    @Test func readinessFailureDuringUpgradeRecordsInstalledVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        enqueueSuccessfulInstall(on: runner)
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let failureStore = InMemoryUpgradeFailureRecordStore()
        let host = TestInstallerHost(readinessResult: false)
        let installer = makeInstaller(
            fixture: fixture,
            runner: runner,
            failureStore: failureStore,
            solBinaryFinder: { "/fixture/sol" }
        )
        installer.attach(host: host)

        installer.retryUpgradeFailure(
            journalURL: fixture.journalRoot,
            installedVersion: BundleConfig.solstonePinVersion,
            pinnedVersion: BundleConfig.solstonePinVersion
        )

        #expect(await waitForInstallToFinish(installer))
        #expect(installer.main == .failed(.confirmingReadiness(message: UICopy.INSTALLER_READINESS_GATE_FAILED)))
        let record = try #require(failureStore.load())
        #expect(record.installed == BundleConfig.solstonePinVersion)
        #expect(record.pinned == BundleConfig.solstonePinVersion)
        #expect(record.errorDetails == "app-owned journal child did not become ready")
        #expect(host.upgradeStartedCallCount == 1)
    }

    @Test func setupFailureRemainsSolSetupFailureAndSkipsReadiness() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.workspace) }
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("setup", .success(stdout: Data(Self.failingSetupJSONL.utf8)))
        let host = TestInstallerHost(readinessResult: true)
        let installer = makeInstaller(fixture: fixture, runner: runner)
        installer.attach(host: host)

        installer.start(journalURL: fixture.journalRoot, existingInstallChoice: .createFresh)

        #expect(await waitForInstallToFinish(installer))
        #expect(installer.main == .failed(.solSetup(errorCode: "port_in_use_non_interactive", message: "port failed")))
        #expect(installer.lastFailureCategory == .unknown)
        #expect(host.readinessCallCount == 0)
    }

    private static let successfulSetupJSONL = """
    {"event":"setup.completed","status":"ok","duration_ms":10}

    """

    private static let failingSetupJSONL = """
    {"event":"step.failed","step":"doctor","error":{"code":"port_in_use_non_interactive","message":"port failed","details":"","exit_code":2}}
    {"event":"setup.completed","status":"ok","duration_ms":10}

    """

    private func enqueueSuccessfulInstall(on runner: FakeSubprocessRunner) {
        runner.enqueue("tool", .success())
        runner.enqueue("setup", .success(stdout: Data(Self.successfulSetupJSONL.utf8)))
    }

    private func makeInstaller(
        fixture: InstallerFixture,
        runner: FakeSubprocessRunner,
        failureStore: UpgradeFailureRecordStoring = InMemoryUpgradeFailureRecordStore(),
        solBinaryFinder: @escaping @Sendable () async -> String? = { nil }
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: fixture.uvBinary,
            bundledPythonURL: fixture.bundledPython,
            wheelhouseURL: fixture.wheelhouse,
            runtimeRootURL: fixture.runtimeRoot,
            subprocessRunner: runner,
            failureRecordStore: failureStore,
            wrapperDirURL: fixture.wrapperDir,
            solBinaryFinder: solBinaryFinder
        )
    }

    private func makeFixture() throws -> InstallerFixture {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-installer-\(UUID().uuidString)", isDirectory: true)
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        let wrapperDir = workspace.appendingPathComponent("wrappers", isDirectory: true)
        let bundledPython = workspace
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3.13")
        let journalRoot = workspace.appendingPathComponent("journal", isDirectory: true)
        let uvBinary = workspace.appendingPathComponent("uv")

        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try writeWheel(named: "solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl", in: wheelhouse)
        try writeWheel(named: "solstone_journal-\(BundleConfig.solstonePinVersion)-py3-none-any.whl", in: wheelhouse)
        try writeWheel(named: "solstone_journal_models-1.0.0-py3-none-any.whl", in: wheelhouse)
        try Data([0xFF, 0x00, 0xFE]).write(to: bundledPython)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledPython.path)

        return InstallerFixture(
            workspace: workspace,
            runtimeRoot: runtimeRoot,
            wheelhouse: wheelhouse,
            wrapperDir: wrapperDir,
            bundledPython: bundledPython,
            journalRoot: journalRoot,
            uvBinary: uvBinary
        )
    }

    private func writeWheel(named name: String, in wheelhouse: URL) throws {
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent(name))
    }

    private func waitForInstallToFinish(
        _ installer: SolstoneInstaller,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !installer.isInstallTaskActive {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !installer.isInstallTaskActive
    }

    private func waitForInvocation(
        _ runner: FakeSubprocessRunner,
        timeout: Duration = .seconds(2),
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
}

private struct InstallerFixture {
    let workspace: URL
    let runtimeRoot: URL
    let wheelhouse: URL
    let wrapperDir: URL
    let bundledPython: URL
    let journalRoot: URL
    let uvBinary: URL
}

@MainActor
private final class TestInstallerHost: InstallerHost {
    var installerConfig: AppConfig
    var readinessResult: Bool
    private(set) var readinessCallCount = 0
    private(set) var upgradeStartedCallCount = 0
    private(set) var bundledCompletionUpdateCount = 0

    init(config: AppConfig = AppConfig(), readinessResult: Bool) {
        installerConfig = config
        self.readinessResult = readinessResult
    }

    func updateInstallerConfig(_ config: AppConfig) {
        installerConfig = config
        if config.serverURL == ServiceMode.bundledServiceURL, config.serviceMode == .bundled {
            bundledCompletionUpdateCount += 1
        }
    }

    func notifyInstallerUpgradeStarted() {
        upgradeStartedCallCount += 1
    }

    func ensureBundledJournalRuntime(journalRoot _: URL) async -> Bool {
        readinessCallCount += 1
        return readinessResult
    }
}
