import Darwin
import Foundation
import Testing
import SolstoneCore
@testable import solstone

@Suite("App-owned journal")
@MainActor
struct AppOwnedJournalTests {
    @Test func externallyManagedDoesNotTeardownOrSpawnChild() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let migrator = MockLegacyMigrator()
        let materializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .externallyManaged(solPath: "/opt/sol/bin/sol") }
        state.legacyJournalMigrator = migrator
        state.runtimeMaterializer = materializer
        state.supervisedJournalRunner = runner

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(ready)
        #expect(migrator.teardownCalls == 0)
        #expect(materializer.materializeCalls == 0)
        #expect(runner.startCalls == 0)
    }

    @Test func migrationFailureWritesAttentionAndBlocksSpawn() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let materializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .appManaged(solPath: "/tmp/runtime/bin/sol") }
        state.legacyJournalMigrator = MockLegacyMigrator(result: .failed(JournalDiagnostic(
            commandLabel: "journal service uninstall",
            outputExcerpt: "still alive"
        )))
        state.runtimeMaterializer = materializer
        state.supervisedJournalRunner = runner

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(!ready)
        if case .stopped(let diagnostic) = state.journalRuntimeStatus {
            #expect(diagnostic.outputExcerpt?.contains(UICopy.JOURNAL_MIGRATION_BLOCKED) == true)
        } else {
            Issue.record("expected stopped attention status")
        }
        #expect(materializer.materializeCalls == 0)
        #expect(runner.startCalls == 0)
    }

    @Test func materializeFailureWritesAttentionAndBlocksSpawn() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .failure(FakeError("materialize failed")))
        state.supervisedJournalRunner = runner

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(!ready)
        if case .unknown(let diagnostic) = state.journalRuntimeStatus {
            #expect(diagnostic.outputExcerpt?.contains(UICopy.JOURNAL_MATERIALIZE_FAILED) == true)
        } else {
            Issue.record("expected unknown attention status")
        }
        #expect(runner.startCalls == 0)
    }

    @Test func portBlockWritesAttentionAndBlocksSpawn() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate(result: .blocked(JournalDiagnostic(
            commandLabel: "journal supervisor gate",
            outputExcerpt: "port 5015 still bound"
        )))
        state.supervisedJournalRunner = runner

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(!ready)
        if case .stopped(let diagnostic) = state.journalRuntimeStatus {
            #expect(diagnostic.outputExcerpt?.contains(UICopy.JOURNAL_SPAWN_BLOCKED_PORTS) == true)
        } else {
            Issue.record("expected stopped attention status")
        }
        #expect(runner.startCalls == 0)
    }

    @Test func spawnFailureWritesAttentionAndBlocksReadiness() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner(startError: FakeError("spawn failed"))
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.supervisedJournalRunner = runner
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(!ready)
        if case .stopped(let diagnostic) = state.journalRuntimeStatus {
            #expect(diagnostic.outputExcerpt?.contains(UICopy.JOURNAL_SPAWN_FAILED) == true)
        } else {
            Issue.record("expected stopped attention status")
        }
        #expect(runner.startCalls == 1)
        #expect(runner.markReadyCalls == 0)
    }

    @Test func readinessFailureWritesAttentionAndStopsChild() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.supervisedJournalRunner = runner
        state.journalReadinessGate = MockJournalReadinessGate(result: .failed(JournalDiagnostic(
            commandLabel: "journal readiness",
            timedOut: true,
            outputExcerpt: "timeout"
        )))

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(!ready)
        if case .unknown(let diagnostic) = state.journalRuntimeStatus {
            #expect(diagnostic.outputExcerpt?.contains(UICopy.JOURNAL_READINESS_TIMEOUT) == true)
        } else {
            Issue.record("expected unknown attention status")
        }
        #expect(runner.startCalls == 1)
        #expect(runner.stopCalls == 1)
        #expect(runner.markReadyCalls == 0)
    }

    @Test func readinessSuccessClearsQueuedSignalAndMarksRunnerReady() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.supervisedJournalRunner = runner
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)
        state.captureQueuedForJournalReadiness = true

        let ready = await state.ensureBundledJournalRuntime(journalRoot: try makeTemporaryDirectory())

        #expect(ready)
        #expect(!state.captureQueuedForJournalReadiness)
        #expect(runner.startCalls == 1)
        #expect(runner.markReadyCalls == 1)
    }

    @Test func installTransitionDoesNotRestartHealthyChild() async throws {
        let journalRoot = try makeTemporaryDirectory()
        let state = AppState.forLaunchDetectionTest(config: AppConfig(), detectionRunner: { false })
        let runner = MockSupervisedChildRunner()
        let gate = MockSingleSupervisorGate()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.supervisedJournalRunner = runner
        state.singleSupervisorGate = gate
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)

        let ready = await state.ensureBundledJournalRuntime(journalRoot: journalRoot)

        #expect(ready)
        var persistedConfig = state.config
        persistedConfig.journalPath = journalRoot.path
        persistedConfig.serverURL = ServiceMode.bundledServiceURL
        persistedConfig.serverKey = "k"
        persistedConfig.serviceMode = .bundled
        state.updateConfig(persistedConfig)
        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(runner.startCalls == 1)
        #expect(runner.markReadyCalls == 1)
        #expect(runner.stopCalls == 0)
        #expect(gate.prepareCalls == 1)
        #expect(state.journalDependentServicesReady)
        #expect(state.journalRuntimeStatus == .running)
    }

    @Test func overlappingStartsSpawnOnce() async throws {
        let journalRoot = try makeTemporaryDirectory()
        let state = AppState.forLaunchDetectionTest(
            config: AppConfig(serviceMode: .bundled, journalPath: journalRoot.path),
            detectionRunner: { false }
        )
        let runner = MockSupervisedChildRunner()
        let readiness = ControllableJournalReadinessGate()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.supervisedJournalRunner = runner
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = readiness

        let startup = Task { @MainActor in
            await state.ensureBundledJournalRuntime(journalRoot: journalRoot)
        }
        await readiness.awaitWaiterRegistered(journalRoot: journalRoot)
        #expect(runner.startCalls == 1)

        state.requestJournalStop()
        state.requestJournalRestart()
        await Task.yield()

        #expect(runner.stopCalls == 0)
        #expect(runner.restartCalls == 0)

        readiness.resume(journalRoot: journalRoot, with: .ready)
        let ready = await startup.value

        #expect(ready)
        #expect(state.journalRuntimeStatus == .running)
        #expect(runner.startCalls == 1)
    }

    @Test func staleStartDoesNotStopNewerChild() async throws {
        let rootA = try makeTemporaryDirectory()
        let rootB = try makeTemporaryDirectory()
        let state = AppState.forLaunchDetectionTest(
            config: AppConfig(serviceMode: .bundled, journalPath: rootA.path),
            detectionRunner: { false }
        )
        let runner = MockSupervisedChildRunner()
        let readiness = ControllableJournalReadinessGate()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.supervisedJournalRunner = runner
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = readiness

        let startA = Task { @MainActor in
            await state.ensureBundledJournalRuntime(journalRoot: rootA)
        }
        await readiness.awaitWaiterRegistered(journalRoot: rootA)
        #expect(runner.startCalls == 1)

        let startB = Task { @MainActor in
            await state.ensureBundledJournalRuntime(journalRoot: rootB)
        }
        await readiness.awaitWaiterRegistered(journalRoot: rootB)
        #expect(runner.startCalls == 2)
        readiness.resume(journalRoot: rootB, with: .ready)
        let readyB = await startB.value

        #expect(readyB)
        #expect(runner.runningJournalRoot?.standardizedFileURL.path == rootB.standardizedFileURL.path)

        readiness.resume(journalRoot: rootA, with: .failed(JournalDiagnostic(
            commandLabel: "journal readiness",
            timedOut: true,
            outputExcerpt: "timeout"
        )))
        let readyA = await startA.value

        #expect(!readyA)
        #expect(runner.stopCalls == 0)
        #expect(state.journalRuntimeStatus == .running)
        #expect(runner.runningJournalRoot?.standardizedFileURL.path == rootB.standardizedFileURL.path)
    }

    @Test func reestablishAfterFailedUpdateRespawnsChild() async throws {
        let journalRoot = try makeTemporaryDirectory()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled, journalPath: journalRoot.path))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.supervisedJournalRunner = runner
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)

        await state.reestablishSupervisedJournalAfterFailedUpdate()

        #expect(runner.startCalls == 1)
        #expect(runner.markReadyCalls == 1)
    }

    @Test func reestablishExternallyManagedIsNoOpStart() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in
            .externallyManaged(solPath: "/opt/sol/bin/sol")
        }
        state.supervisedJournalRunner = runner

        await state.reestablishSupervisedJournalAfterFailedUpdate()

        #expect(runner.startCalls == 0)
    }

    @Test func stopForUpdateStopsChildBundled() async {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        await state.stopSupervisedJournalForUpdate()

        #expect(runner.stopCalls == 1)
    }

    @Test func stopForUpdateNonBundledIsNoOp() async {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        await state.stopSupervisedJournalForUpdate()

        #expect(runner.stopCalls == 0)
    }

    @Test func requestJournalStopStopsBundledChildAndMarksStoppedByUser() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        state.requestJournalStop()
        try await waitUntilMain { state.journalRuntimeStatus.isStoppedByUser }

        #expect(runner.stopCalls == 1)
        #expect(state.journalRuntimeStatus == .stoppedByUser)
    }

    @Test func requestJournalStopExternalModeIsNoOp() {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        state.requestJournalStop()

        #expect(runner.stopCalls == 0)
        #expect(state.journalRuntimeStatus == .running)
    }

    @Test func requestJournalStartExternalModeIsNoOp() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))
        let runner = MockSupervisedChildRunner()
        state.journalRuntimeStatus = .stoppedByUser
        state.supervisedJournalRunner = runner

        state.requestJournalStart()
        try await Task.sleep(for: .milliseconds(10))

        #expect(runner.startCalls == 0)
        #expect(state.journalRuntimeStatus == .stoppedByUser)
    }

    @Test func requestJournalStartRunsBundledStartupAndMarksRunning() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalRuntimeStatus = .stoppedByUser
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.supervisedJournalRunner = runner
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)

        state.requestJournalStart()
        try await waitUntilMain { state.journalRuntimeStatus == .running && runner.startCalls == 1 }

        #expect(state.journalRuntimeStatus == .running)
        #expect(runner.startCalls == 1)
    }

    @Test func requestJournalStartFailureLeavesAttentionStatusAndErrorMessage() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.journalRuntimeStatus = .stoppedByUser
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .failure(FakeError("materialize failed")))
        state.supervisedJournalRunner = runner

        state.requestJournalStart()
        try await waitUntilMain { state.errorMessage != nil }

        #expect(state.journalRuntimeStatus != .stoppedByUser)
        #expect(state.journalRuntimeStatus != .running)
        if case .unknown = state.journalRuntimeStatus {
        } else {
            Issue.record("expected unknown attention status")
        }
        #expect(state.errorMessage != nil)
    }

    @Test func requestJournalStartAfterCleanStopDoesNotTeardownLegacyJob() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        let migrator = MockLegacyMigrator()
        state.supervisedJournalRunner = runner

        state.requestJournalStop()
        try await waitUntilMain { state.journalRuntimeStatus.isStoppedByUser }

        state.legacyJournalMigrator = migrator
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = MockRuntimeMaterializer(result: .success(try makeRuntime()))
        state.singleSupervisorGate = MockSingleSupervisorGate()
        state.journalReadinessGate = MockJournalReadinessGate(result: .ready)

        state.requestJournalStart()
        try await waitUntilMain { state.journalRuntimeStatus == .running && runner.startCalls == 1 }

        #expect(state.journalRuntimeStatus == .running)
        #expect(runner.startCalls == 1)
        #expect(migrator.teardownCalls == 0)
    }

    @Test func requestJournalStopIsReentrantNoOpWhileInFlight() async throws {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        state.requestJournalStop()
        state.requestJournalStop()
        try await waitUntilMain { state.journalRuntimeStatus.isStoppedByUser }

        #expect(runner.stopCalls == 1)
    }

    @Test func reestablishNonBundledIsNoOp() async {
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .external))
        let runner = MockSupervisedChildRunner()
        state.supervisedJournalRunner = runner

        await state.reestablishSupervisedJournalAfterFailedUpdate()

        #expect(runner.startCalls == 0)
    }

    @Test func runtimeMaterializerDoesNotDeleteLiveChildKey() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        let wrapperDir = workspace.appendingPathComponent("wrappers", isDirectory: true)
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent("solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"))
        let liveKey = "\(BundleConfig.solstonePinVersion)_py\(BundleConfig.bundledPythonBuild)_livechild"
        let liveURL = runtimeRoot.appendingPathComponent(liveKey, isDirectory: true)
        try FileManager.default.createDirectory(at: liveURL, withIntermediateDirectories: true)
        let staleURL = runtimeRoot.appendingPathComponent("\(BundleConfig.solstonePinVersion)_py\(BundleConfig.bundledPythonBuild)_stale", isDirectory: true)
        try FileManager.default.createDirectory(at: staleURL, withIntermediateDirectories: true)

        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let materializer = RuntimeMaterializer(
            runtimeRootURL: runtimeRoot,
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: URL(fileURLWithPath: "/bin/echo"),
            wheelhouseURL: wheelhouse,
            wrapperDirURL: wrapperDir,
            runner: runner
        )

        _ = try await materializer.materialize(excludingLiveKey: liveKey)

        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
    }

    @Test func runtimeMaterializeProducesRelocatableEntrypoints() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtimeRoot = workspace.appendingPathComponent("runtime dir with space", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        let wrapperDir = workspace.appendingPathComponent("wrappers", isDirectory: true)
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent("solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"))

        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let materializer = RuntimeMaterializer(
            runtimeRootURL: runtimeRoot,
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: URL(fileURLWithPath: "/bin/echo"),
            wheelhouseURL: wheelhouse,
            wrapperDirURL: wrapperDir,
            runner: runner
        )

        let runtime = try await materializer.materialize(excludingLiveKey: nil)

        let runtimeChildren = try FileManager.default.contentsOfDirectory(atPath: runtimeRoot.path)
        #expect(!runtimeChildren.contains { $0.hasPrefix(".tmp-") })
        let runtimeRootPath = runtimeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let realRunner = SubprocessRunner()
        for bin in [runtime.layout.journalBinary, runtime.layout.solBinary] {
            #expect(FileManager.default.isExecutableFile(atPath: bin.path))
            let resolvedPath = bin.resolvingSymlinksInPath().standardizedFileURL.path
            #expect(!pathContainsStagingSegment(resolvedPath))
            #expect(pathIsUnderRoot(resolvedPath, rootPath: runtimeRootPath))

            let script = try String(contentsOf: URL(fileURLWithPath: resolvedPath), encoding: .utf8)
            let lines = script.components(separatedBy: "\n")
            #expect(lines.first == "#!/bin/sh")
            #expect(!lines.contains { pathContainsStagingSegment($0) })

            let stdout = LockedArray<Data>([])
            let result = try await realRunner.run(
                executable: bin,
                arguments: ["--version"],
                environment: runtime.layout.uvEnvironment(),
                timeout: .seconds(30),
                stdoutHandler: { data in stdout.append(data) },
                stderrHandler: { _ in }
            )
            var stdoutData = Data()
            for chunk in stdout.all {
                stdoutData.append(chunk)
            }
            let stdoutText = String(decoding: stdoutData, as: UTF8.self)
            #expect(result.exitCode == 0)
            #expect(SolVersionParser.parse(stdoutText) == BundleConfig.solstonePinVersion)
        }
    }

    @Test func bundledInstallerDoesNotCallServiceStartInstallRestartOrUp() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent("solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"))
        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: installerFixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = SolstoneInstaller(
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: URL(fileURLWithPath: "/bin/echo"),
            wheelhouseURL: wheelhouse,
            runtimeRootURL: runtimeRoot,
            subprocessRunner: runner,
            failureRecordStore: InMemoryUpgradeFailureRecordStore(),
            // MUST be workspace-scoped: omitting this defaults to the REAL ~/.local/bin,
            // and this test drives a real materialize whose rewriteAliases step then
            // clobbers the operator's sol/journal wrappers with exec targets into this
            // test's temp workspace (dangling after teardown). Every `make ci` on the
            // build Mac was silently rewriting the user's wrappers (found 2026-06-10).
            wrapperDirURL: workspace.appendingPathComponent("wrappers", isDirectory: true),
            observerRegistrar: { _ in .success("observer-key") }
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: workspace.appendingPathComponent("journal", isDirectory: true),
            existingInstallChoice: .createFresh
        )
        try await waitUntilMain { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments == ["service", "install"] })
        #expect(!runner.invocations.contains { $0.arguments == ["service", "start"] })
        #expect(!runner.invocations.contains { $0.arguments == ["service", "restart"] })
        #expect(!runner.invocations.contains { $0.arguments.first == "up" })
    }

    @Test func bundledStartupDoesNotCallServiceStartInstallRestartOrUp() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        let wrapperDir = workspace.appendingPathComponent("wrappers", isDirectory: true)
        let journalRoot = workspace.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalRoot.appendingPathComponent("health", isDirectory: true), withIntermediateDirectories: true)
        try Data("manifest\n".utf8).write(to: wheelhouse.appendingPathComponent("MANIFEST.sha256"))
        try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent("solstone-\(BundleConfig.solstonePinVersion)-py3-none-any.whl"))

        let runner = FakeSubprocessRunner()
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        let childRunner = MockSupervisedChildRunner()
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.journalOwnershipResolver = { (_: Bool) async -> SolOwnership in .absent }
        state.runtimeMaterializer = RuntimeMaterializer(
            runtimeRootURL: runtimeRoot,
            uvBinaryURL: URL(fileURLWithPath: "/usr/bin/uv"),
            bundledPythonURL: URL(fileURLWithPath: "/bin/echo"),
            wheelhouseURL: wheelhouse,
            wrapperDirURL: wrapperDir,
            runner: runner
        )
        state.singleSupervisorGate = SingleSupervisorGate(
            runner: runner,
            pidExists: { _ in false },
            clock: FakeMonotonicClock(),
            orphanGracePeriod: .milliseconds(1)
        )
        state.supervisedJournalRunner = childRunner
        state.journalReadinessGate = JournalReadinessGate(
            runner: runner,
            fileExists: { $0.hasSuffix("health/supervisor.ready") },
            clock: FakeMonotonicClock(),
            pollInterval: .milliseconds(1)
        )

        let ready = await state.ensureBundledJournalRuntime(journalRoot: journalRoot)

        #expect(ready)
        #expect(childRunner.startCalls == 1)
        #expect(!runner.invocations.contains { $0.arguments == ["service", "install"] })
        #expect(!runner.invocations.contains { $0.arguments == ["service", "start"] })
        #expect(!runner.invocations.contains { $0.arguments == ["service", "restart"] })
        #expect(!runner.invocations.contains { $0.arguments.first == "up" })
    }

    @Test func singleSupervisorGateIgnoresStaleStartTimeMarker() async throws {
        let journalRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        try writeSupervisorMarkers(pid: 4242, startTime: "recorded-start", journalRoot: journalRoot)
        let runner = FakeSubprocessRunner()
        runner.enqueue("ps", .success(stdout: Data("live-start\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data("journal start --app-supervised\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        let signals = SignalRecorder()
        let gate = SingleSupervisorGate(
            runner: runner,
            pidExists: { _ in true },
            terminate: { pid, signal in signals.append(pid: pid, signal: signal); return 0 },
            clock: FakeMonotonicClock(),
            orphanGracePeriod: .milliseconds(1),
            pidWaitPollInterval: .milliseconds(1)
        )

        let result = await gate.prepareForSpawn(journalRoot: journalRoot)

        #expect(result == .success)
        #expect(signals.values.isEmpty)
    }

    @Test func singleSupervisorGateStopsMatchingSupervisorAndBlocksWhenPortsRemainBound() async throws {
        let journalRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        try writeSupervisorMarkers(pid: 4242, startTime: "live-start", journalRoot: journalRoot)
        let runner = FakeSubprocessRunner()
        runner.enqueue("ps", .success(stdout: Data("live-start\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data("journal start --app-supervised\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 0))
        let signals = SignalRecorder()
        let gate = SingleSupervisorGate(
            runner: runner,
            pidExists: { _ in true },
            terminate: { pid, signal in signals.append(pid: pid, signal: signal); return 0 },
            clock: FakeMonotonicClock(),
            orphanGracePeriod: .milliseconds(1),
            pidWaitPollInterval: .milliseconds(1)
        )

        let result = await gate.prepareForSpawn(journalRoot: journalRoot)

        if case .blocked(let diagnostic) = result {
            #expect(diagnostic.outputExcerpt?.contains("port 7657 still bound") == true)
        } else {
            Issue.record("expected blocked gate")
        }
        #expect(signals.values == [
            SignalRecord(pid: 4242, signal: SIGTERM),
            SignalRecord(pid: 4242, signal: SIGKILL)
        ])
    }

    @Test func migrationPurgeWaitsForSupervisorDeath() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let layout = SolstoneRuntimeLayout(rootURL: runtimeRoot)
        try FileManager.default.createDirectory(at: layout.versionsDir, withIntermediateDirectories: true)
        let oldVersion = layout.versionsDir.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldVersion, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.currentLink.path, withDestinationPath: "versions/old")
        let journalRoot = workspace.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot.appendingPathComponent("health", isDirectory: true), withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: journalRoot.appendingPathComponent("health/supervisor.pid"))
        let runner = FakeSubprocessRunner()
        runner.enqueue("service", .success())
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        let clock = FakeMonotonicClock()
        let pidProbe = SequencedPIDProbe(aliveResponses: [true, true, false], layout: layout)
        let migrator = LegacyJournalMigrator(
            runtimeRootURL: runtimeRoot,
            runner: runner,
            pidExists: { pidProbe.exists($0) },
            terminate: { _, _ in 0 },
            clock: clock,
            pidWaitPollInterval: .milliseconds(1),
            orphanGracePeriod: .milliseconds(1)
        )

        let result = await migrator.teardownLegacyAppManagedJournal(
            oldSolPath: workspace.appendingPathComponent("bin/sol").path,
            journalRoot: journalRoot
        )

        #expect(result == .success)
        #expect(pidProbe.sawLegacyLayoutWhileAlive)
        #expect(!FileManager.default.fileExists(atPath: layout.currentLink.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: layout.versionsDir.path).isEmpty) == true)
    }

    @Test func breakerTripsToAttentionStatus() async throws {
        let runtime = try makeExitingRuntime()
        let clock = FakeMonotonicClock()
        let recorder = StatusRecorder()
        let runner = SupervisedJournalRunner(clock: clock, statusSink: { status in
            recorder.append(status)
        })

        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        try await waitUntil {
            recorder.statuses.contains { status in
                if case .stopped(let diagnostic) = status {
                    return diagnostic.outputExcerpt == UICopy.JOURNAL_CHILD_BREAKER_TRIPPED
                }
                return false
            }
        }

        #expect(recorder.statuses.contains { status in
            if case .stopped = status { return true }
            return false
        })
        await runner.stop()
    }

    @Test func stopForTerminationReturnsWhenChildIgnoresTerm() async throws {
        let runtime = try makeSleepingRuntime()
        let runner = SupervisedJournalRunner(
            clock: FakeMonotonicClock(),
            statusSink: { _ in }
        )

        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        await runner.stopForTermination()

        #expect(await runner.currentRuntimeKey() == runtime.key)
    }

    @Test func stopCancelsArmedBackoffRelaunchBeforeSecondSpawn() async throws {
        let marker = try makeTemporaryDirectory().appendingPathComponent("launches.txt")
        let runtime = try makeMarkerExitingRuntime(markerURL: marker)
        let clock = ControllableMonotonicClock()
        let recorder = StatusRecorder()
        let runner = SupervisedJournalRunner(clock: clock, statusSink: { status in
            recorder.append(status)
        })

        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        try await waitUntil {
            launchCount(at: marker) == 1 && clock.sleepingCount >= 1
        }

        await runner.stop()

        #expect(launchCount(at: marker) == 1)
        #expect(await runner.currentRuntimeKey() == nil)
    }

    @Test func stopForTerminationCancelsArmedBackoffRelaunchAndRetainsKey() async throws {
        let marker = try makeTemporaryDirectory().appendingPathComponent("launches.txt")
        let runtime = try makeMarkerExitingRuntime(markerURL: marker)
        let clock = ControllableMonotonicClock()
        let recorder = StatusRecorder()
        let runner = SupervisedJournalRunner(clock: clock, statusSink: { status in
            recorder.append(status)
        })

        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        try await waitUntil {
            launchCount(at: marker) == 1 && clock.sleepingCount >= 1
        }

        await runner.stopForTermination()

        #expect(launchCount(at: marker) == 1)
        #expect(await runner.currentRuntimeKey() == runtime.key)
    }

    @Test func stopReturnsAndKillsWedgedChild() async throws {
        let marker = try makeTemporaryDirectory().appendingPathComponent("ready.txt")
        let runtime = try makeWedgedRuntime(markerURL: marker)
        let signals = SignalRecorder()
        let runner = SupervisedJournalRunner(
            clock: FakeMonotonicClock(),
            statusSink: { _ in },
            terminate: { pid, signal in
                signals.append(pid: pid, signal: signal)
                return Darwin.kill(pid, signal)
            }
        )

        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        // Wait until the child has installed its TERM trap (and is wedged in
        // sleep) before stopping; otherwise SIGTERM can land pre-trap and the
        // child dies without ever needing the SIGKILL escalation under test.
        try await waitUntil { launchCount(at: marker) == 1 }
        await runner.stop()

        #expect(signals.values.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(await runner.currentRuntimeKey() == nil)
    }

    @Test func terminationHandshakeRepliesWhenChildIsWedged() async throws {
        let runtime = try makeSleepingRuntime()
        let runner = SupervisedJournalRunner(
            clock: FakeMonotonicClock(),
            statusSink: { _ in }
        )
        let state = AppState.forSnapshot(config: AppConfig(serviceMode: .bundled))
        state.supervisedJournalRunner = runner
        try await runner.start(runtime: runtime, journalRoot: try makeTemporaryDirectory(), port: 5015)
        let replied = LockedValue<Bool>()

        await runApplicationTerminationHandshake(
            stopSupervisedJournal: {
                await state.stopSupervisedJournalForTermination()
            },
            reply: {
                replied.set(true)
            }
        )

        #expect(replied.current == true)
    }
}

private final class MockRuntimeMaterializer: RuntimeMaterializing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<MaterializedRuntime, Error>
    private var calls = 0

    var materializeCalls: Int { lock.withLock { calls } }

    init(result: Result<MaterializedRuntime, Error>) {
        self.result = result
    }

    func materialize(excludingLiveKey liveKey: String?) async throws -> MaterializedRuntime {
        lock.withLock { calls += 1 }
        return try result.get()
    }
}

private final class MockSupervisedChildRunner: SupervisedChildRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private var starts = 0
    private var readyMarks = 0
    private var stops = 0
    private var restarts = 0
    private var runtimeKey: String?
    private var journalRoot: URL?

    var startCalls: Int { lock.withLock { starts } }
    var markReadyCalls: Int { lock.withLock { readyMarks } }
    var stopCalls: Int { lock.withLock { stops } }
    var restartCalls: Int { lock.withLock { restarts } }
    var runningJournalRoot: URL? { lock.withLock { journalRoot } }

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start(runtime: MaterializedRuntime, journalRoot: URL, port: Int) async throws {
        lock.withLock { starts += 1 }
        if let startError {
            throw startError
        }
        lock.withLock {
            runtimeKey = runtime.key
            self.journalRoot = journalRoot.standardizedFileURL
        }
    }

    func restart() async throws {
        lock.withLock { restarts += 1 }
    }

    func stop() async {
        lock.withLock {
            stops += 1
            runtimeKey = nil
            journalRoot = nil
        }
    }

    func stopForTermination() async {
        lock.withLock {
            runtimeKey = nil
            journalRoot = nil
        }
    }

    func currentRuntimeKey() async -> String? {
        lock.withLock { runtimeKey }
    }

    func markReady() async {
        lock.withLock { readyMarks += 1 }
    }
}

private final class MockLegacyMigrator: LegacyJournalMigrating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: LegacyJournalMigrationResult
    private var calls = 0

    var teardownCalls: Int { lock.withLock { calls } }

    init(result: LegacyJournalMigrationResult = .success) {
        self.result = result
    }

    func teardownLegacyAppManagedJournal(oldSolPath: String, journalRoot: URL) async -> LegacyJournalMigrationResult {
        lock.withLock { calls += 1 }
        return result
    }
}

private final class MockSingleSupervisorGate: SingleSupervisorGating, @unchecked Sendable {
    private let lock = NSLock()
    private let result: SingleSupervisorGateResult
    private var calls = 0

    var prepareCalls: Int { lock.withLock { calls } }

    init(result: SingleSupervisorGateResult = .success) {
        self.result = result
    }

    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        lock.withLock { calls += 1 }
        return result
    }
}

private struct MockJournalReadinessGate: JournalReadinessChecking {
    var result: JournalReadinessResult

    func waitUntilReady(journalRoot: URL, runtime: MaterializedRuntime, timeout: Duration) async -> JournalReadinessResult {
        result
    }
}

private final class ControllableJournalReadinessGate: JournalReadinessChecking, @unchecked Sendable {
    private struct Waiter {
        let rootPath: String
        let continuation: CheckedContinuation<JournalReadinessResult, Never>
    }

    private let lock = NSLock()
    private var waiters: [Waiter] = []
    private var waiterRegistrationContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var queuedResults: [String: [JournalReadinessResult]] = [:]

    func awaitWaiterRegistered(journalRoot: URL) async {
        let rootPath = journalRoot.standardizedFileURL.path
        if lock.withLock({ hasWaiter(for: rootPath) }) {
            return
        }
        await withCheckedContinuation { continuation in
            let continuationToResume: CheckedContinuation<Void, Never>? = lock.withLock {
                if hasWaiter(for: rootPath) {
                    return continuation
                }
                waiterRegistrationContinuations[rootPath, default: []].append(continuation)
                return nil
            }
            continuationToResume?.resume()
        }
    }

    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration
    ) async -> JournalReadinessResult {
        let rootPath = journalRoot.standardizedFileURL.path
        if let result = lock.withLock({ takeQueuedResult(for: rootPath) }) {
            resumeWaiterRegistrationContinuations(for: rootPath)
            return result
        }
        return await withCheckedContinuation { continuation in
            let registrationContinuations = lock.withLock {
                waiters.append(Waiter(rootPath: rootPath, continuation: continuation))
                return waiterRegistrationContinuations.removeValue(forKey: rootPath) ?? []
            }
            for registrationContinuation in registrationContinuations {
                registrationContinuation.resume()
            }
        }
    }

    func resume(journalRoot: URL, with result: JournalReadinessResult) {
        let rootPath = journalRoot.standardizedFileURL.path
        let continuation: CheckedContinuation<JournalReadinessResult, Never>? = lock.withLock {
            if let index = waiters.firstIndex(where: { $0.rootPath == rootPath }) {
                return waiters.remove(at: index).continuation
            }
            queuedResults[rootPath, default: []].append(result)
            return nil
        }
        continuation?.resume(returning: result)
    }

    private func takeQueuedResult(for rootPath: String) -> JournalReadinessResult? {
        guard var results = queuedResults[rootPath], !results.isEmpty else { return nil }
        let result = results.removeFirst()
        queuedResults[rootPath] = results.isEmpty ? nil : results
        return result
    }

    private func hasWaiter(for rootPath: String) -> Bool {
        waiters.contains { $0.rootPath == rootPath }
    }

    private func resumeWaiterRegistrationContinuations(for rootPath: String) {
        let continuations = lock.withLock {
            waiterRegistrationContinuations.removeValue(forKey: rootPath) ?? []
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class FakeMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        lock.withLock { value += duration }
        await Task.yield()
    }
}

private final class ControllableMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    private var sleepers: [ControllableSleepWaiter] = []

    var sleepingCount: Int {
        lock.withLock { sleepers.count }
    }

    func now() -> Duration {
        lock.withLock { value }
    }

    func sleep(for duration: Duration) async {
        let waiter = ControllableSleepWaiter()
        lock.withLock {
            value += duration
            sleepers.append(waiter)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.setContinuation(continuation)
            }
        } onCancel: {
            waiter.resume()
        }
    }

}

private final class ControllableSleepWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func setContinuation(_ continuation: CheckedContinuation<Void, Never>) {
        var shouldResume = false
        lock.withLock {
            if resumed {
                shouldResume = true
            } else {
                self.continuation = continuation
            }
        }
        if shouldResume {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = lock.withLock {
            guard !resumed else { return nil as CheckedContinuation<Void, Never>? }
            resumed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class SequencedPIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var aliveResponses: [Bool]
    private let layout: SolstoneRuntimeLayout
    private(set) var sawLegacyLayoutWhileAlive = false

    init(aliveResponses: [Bool], layout: SolstoneRuntimeLayout) {
        self.aliveResponses = aliveResponses
        self.layout = layout
    }

    func exists(_ pid: pid_t) -> Bool {
        lock.withLock {
            let next = aliveResponses.isEmpty ? false : aliveResponses.removeFirst()
            if next, FileManager.default.fileExists(atPath: layout.currentLink.path) {
                sawLegacyLayoutWhileAlive = true
            }
            return next
        }
    }
}

private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JournalRuntimeStatus] = []

    var statuses: [JournalRuntimeStatus] {
        lock.withLock { values }
    }

    func append(_ status: JournalRuntimeStatus) {
        lock.withLock {
            values.append(status)
        }
    }
}

private struct SignalRecord: Equatable, Sendable {
    let pid: pid_t
    let signal: Int32
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SignalRecord] = []

    var values: [SignalRecord] {
        lock.withLock { records }
    }

    func append(pid: pid_t, signal: Int32) {
        lock.withLock {
            records.append(SignalRecord(pid: pid, signal: signal))
        }
    }
}

private struct FakeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private func makeRuntime() throws -> MaterializedRuntime {
    let root = try makeTemporaryDirectory()
    let layout = SolstoneRuntimeLayout(rootURL: root)
    try FileManager.default.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: layout.journalBinary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.journalBinary.path)
    return MaterializedRuntime(key: "test-key", layout: layout)
}

private func makeExitingRuntime() throws -> MaterializedRuntime {
    try makeScriptRuntime(script: "#!/bin/sh\nexit 1\n")
}

private func makeSleepingRuntime() throws -> MaterializedRuntime {
    try makeScriptRuntime(script: "#!/bin/sh\ntrap '' TERM\nsleep 30\n")
}

private func makeWedgedRuntime(markerURL: URL) throws -> MaterializedRuntime {
    try makeScriptRuntime(script: """
    #!/bin/sh
    trap '' TERM
    printf 'ready\\n' >> \(shellSingleQuoted(markerURL.path))
    sleep 30
    """)
}

private func makeMarkerExitingRuntime(markerURL: URL) throws -> MaterializedRuntime {
    try makeScriptRuntime(script: """
    #!/bin/sh
    printf 'launch\\n' >> \(shellSingleQuoted(markerURL.path))
    exit 1
    """)
}

private func makeScriptRuntime(script: String) throws -> MaterializedRuntime {
    let root = try makeTemporaryDirectory()
    let layout = SolstoneRuntimeLayout(rootURL: root)
    try FileManager.default.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
    try Data(script.utf8).write(to: layout.journalBinary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.journalBinary.path)
    return MaterializedRuntime(key: UUID().uuidString, layout: layout)
}

private func launchCount(at url: URL) -> Int {
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else {
        return 0
    }
    return text.split(separator: "\n").count
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func pathContainsStagingSegment(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0.hasPrefix(".tmp-") }
}

private func pathIsUnderRoot(_ path: String, rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-owned-journal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeSupervisorMarkers(pid: pid_t, startTime: String, journalRoot: URL) throws {
    let health = journalRoot.appendingPathComponent("health", isDirectory: true)
    try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
    try Data("\(pid)\n".utf8).write(to: health.appendingPathComponent("supervisor.pid"))
    try Data("\(startTime)\n".utf8).write(to: health.appendingPathComponent("supervisor.start_time"))
}

private func installerFixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/installer")!
    return try! Data(contentsOf: url)
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}

@MainActor
private func waitUntilMain(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<100 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}
