// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import Testing
import SolstoneCore
@testable import solstone

private let testBundledPythonURL = URL(fileURLWithPath: "/bin/echo")

@Suite("SolstoneInstaller")
@MainActor
struct SolstoneInstallerTests {
    @Test func exclusiveOperationInProgressMatchesActiveMainStates() {
        let installer = makeInstaller(runner: FakeSubprocessRunner())
        defer { installer.cancel() }
        let progress = SubprocessProgress(phase: "phase")
        let cases: [(MainState, Bool)] = [
            (.detecting, false),
            (.awaitingChoice(existingInstall: false), false),
            (.awaitingChoice(existingInstall: true), false),
            (.cleaningUp(progress), true),
            (.installingSolstone(progress), true),
            (.runningSolSetup(progress), true),
            (.registering(progress), true),
            (.externallyManaged(solPath: "/opt/sol"), false),
            (.done, false),
            (.failed(.installSolstone(message: "failed")), false)
        ]

        for (state, expected) in cases {
            installer.main = state
            #expect(installer.exclusiveOperationInProgress == expected)
        }
    }

    @Test func runningSolSetup_exitZero_transitionsTo_registering() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok"), delay: .milliseconds(0)))
        runner.enqueue("install-models", .success(delay: .milliseconds(500)))
        let registrar = FakeObserverRegistrar(delay: .milliseconds(500))
        let installer = makeInstaller(runner: runner, observerRegistrar: registrar.register)
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
            var fixtureURLs: (workspace: URL, runtimeRoot: URL, wheelhouse: URL)?
            var finderValues: [String?] = ["/usr/bin/sol"]
            if choice == .createFresh {
                let fixture = try makeStagedInstallFixture()
                fixtureURLs = fixture
                finderValues = [nil]
                runner.enqueue("tool", .success())
                runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
            }
            let finder = SequencedSolBinaryFinder(finderValues)
            runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
            runner.enqueue("install-models", .success())
            let installer = makeInstaller(
                runner: runner,
                uvURL: uvURL,
                wheelhouseURL: fixtureURLs?.wheelhouse,
                runtimeRootURL: fixtureURLs?.runtimeRoot,
                solBinaryFinder: { finder.next() }
            )
            defer {
                if let fixtureURLs {
                    try? FileManager.default.removeItem(at: fixtureURLs.workspace)
                }
            }
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
                "/tmp/solstone-test-journal",
                "--skip-service"
            ])
        }
    }

    @Test func detect_returnsTrue_whenAppManagedSolBinaryPresent() async {
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )
        let found = await installer.detect()
        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
    }

    @Test func failureMessage_isVerbatimForSetupAndNormalizedForMaterialization() async throws {
        try await jsonlStepFailedMessageIsVerbatim()
        try await rawSubprocessFailureUsesLastStderrLine()
        try await launchFailureUsesLocalizedDescription()
    }

    @Test func state4_observerResultDrivesTerminalState() async throws {
        try await assertState4(observerSucceeds: true, expectsDone: true)
        try await assertState4(observerSucceeds: false, expectsDone: false)
    }

    @Test func postActivationRegisteringFailurePersistsReprobedPinnedVersion() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal"
        )
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let registrar = FakeObserverRegistrar(result: .failure(ObserverRegistrationFailure(
            category: .unknown,
            message: "couldn't register this observer",
            logExcerpt: "observer failed"
        )))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store,
            observerRegistrar: registrar.register
        )
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitForTerminal(installer)

        let record = try #require(store.load())
        #expect(record.installed == BundleConfig.solstonePinVersion)
        #expect(upgradeFailedStatusMessage(installedVersion: record.installed, pinnedVersion: record.pinned) == "upgraded solstone to \(BundleConfig.solstonePinVersion) — couldn't register this observer")
    }

    @Test func postActivationRegisteringFailurePersistsUnknownWhenReprobeNil() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal"
        )
        runner.enqueue("--version", .success(exitCode: 1))
        let registrar = FakeObserverRegistrar(result: .failure(ObserverRegistrationFailure(
            category: .unknown,
            message: "couldn't register this observer",
            logExcerpt: "observer failed"
        )))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store,
            observerRegistrar: registrar.register
        )
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitForTerminal(installer)

        let record = try #require(store.load())
        #expect(record.installed == nil)
        #expect(upgradeFailedStatusMessage(installedVersion: record.installed, pinnedVersion: record.pinned) == "upgrade may be incomplete — couldn't confirm the running version")
    }

    @Test func readinessGateHappyPathClearsFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success())
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner, failureRecordStore: store)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
    }

    @Test func existingInstall_choiceSkipsSubprocess() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.first == "tool" })
        #expect(runner.invocations.contains { $0.arguments.first == "setup" })
    }

    @Test func createFreshRunsPrecleanBeforeUvInstall() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let calls = runner.invocations.map(\.arguments)
        let configIndex = try #require(calls.firstIndex { $0 == ["config", "show"] })
        let stageIndex = try #require(calls.firstIndex { $0.starts(with: ["tool", "install"]) })
        let serviceIndex = try #require(calls.firstIndex { $0 == ["service", "uninstall"] })
        #expect(configIndex < stageIndex)
        #expect(serviceIndex < stageIndex)
    }

    @Test func upgradePathTargetsResolvedJournalNotCallerDefault() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/data/solstone/relocated-journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.arguments == [
            "setup",
            "--jsonl",
            "--yes",
            "--skip-models",
            "--accept-existing-journal",
            "--journal",
            "/data/solstone/relocated-journal",
            "--skip-service"
        ])
        #expect(!setup.arguments.contains("/tmp/journal"))
    }

    @Test func precleanInvokesJournalWhenSiblingExists() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            fileExists: { $0.hasSuffix("/journal") }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let uninstall = try #require(runner.invocations.first { $0.arguments == ["service", "uninstall"] })
        #expect(uninstall.executable.lastPathComponent == "journal")
    }

    @Test func precleanFailsSetupNeededWhenJournalSiblingMissing() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            fileExists: { _ in false }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.cleanup(
            step: .resolveJournal,
            message: cleanupMessage(step: .resolveJournal, why: UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE)
        )))
        #expect(!runner.invocations.contains { $0.arguments == ["service", "uninstall"] })
    }

    @Test func precleanConfigShowInvokesJournalWhenSiblingExists() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            fileExists: { $0.hasSuffix("/journal") }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let config = try #require(runner.invocations.first { $0.arguments == ["config", "show"] })
        #expect(config.executable.lastPathComponent == "journal")
    }

    @Test func precleanConfigShowDoesNotRunWhenJournalSiblingMissing() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            fileExists: { _ in false }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.cleanup(
            step: .resolveJournal,
            message: cleanupMessage(step: .resolveJournal, why: UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE)
        )))
        #expect(!runner.invocations.contains { $0.arguments == ["config", "show"] })
    }

    @Test func precleanConfigFailureSanitizesDiagnosticExcerpt() async throws {
        let runner = FakeSubprocessRunner()
        let home = NSHomeDirectory()
        let oldSolPath = "\(home)/Library/Application Support/sol/runtime/current/bin/sol"
        runner.enqueue(
            "config",
            .success(stderr: Data("config failed\n\(home)/journal/private detail\n".utf8), exitCode: 2)
        )
        let installer = makeInstaller(
            runner: runner,
            solBinaryFinder: { oldSolPath },
            fileExists: { $0.hasSuffix("/journal") }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.lastFailureLog == "config failed ~/journal/private detail")
    }

    @Test func createFreshSkipsPrecleanWhenNoExistingBinary() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let finder = SequencedSolBinaryFinder([nil])
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.first == "config" })
        #expect(!runner.invocations.contains { $0.arguments.first == "service" })
        #expect(runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.arguments == [
            "setup",
            "--jsonl",
            "--yes",
            "--skip-models",
            "--accept-existing-journal",
            "--journal",
            "/tmp/journal",
            "--skip-service"
        ])
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == nil)
        let runtimeChildren = try FileManager.default.contentsOfDirectory(
            at: fixtureURLs.runtimeRoot,
            includingPropertiesForKeys: nil
        )
        #expect(runtimeChildren.contains { $0.lastPathComponent.hasPrefix("\(BundleConfig.solstonePinVersion)_py\(BundleConfig.bundledPythonBuild)_") })
    }

    @Test func createFreshContentAddressedInstallProbesMaterializedJournalBinary() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let finder = SequencedSolBinaryFinder([nil])
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.probedVersion == .current(version: BundleConfig.solstonePinVersion) }

        #expect(installer.main == .done)
        let state = terminalCardState(
            main: installer.main,
            probe: installer.probedVersion,
            failureRecord: installer.upgradeFailureRecord
        )
        #expect(state == .installedCurrent(version: BundleConfig.solstonePinVersion))
        #expect(state.axToken == "installed_current")
        // One --version is consumed by RuntimeMaterializer verification, and one by the post-install probe.
        #expect(runner.invocations.filter { $0.arguments == ["--version"] }.count >= 2)
    }

    @Test func acceptExistingSkipsPreclean() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.first == "config" })
        #expect(!runner.invocations.contains { $0.arguments.first == "service" })
    }

    @Test func runSolSetupInvokesJournal() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.executable.lastPathComponent == "journal")
    }

    @Test func runInstallModelsInvokesJournal() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil {
            runner.invocations.contains { $0.arguments.first == "install-models" }
        }

        let installModels = try #require(runner.invocations.first { $0.arguments.first == "install-models" })
        #expect(installModels.executable.lastPathComponent == "journal")
    }

    @Test func precleanFailsWhenJournalPathCannotResolve() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("config", .success(stderr: Data("config failed\n".utf8), exitCode: 2))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.cleanup(step: .resolveJournal, message: cleanupMessage(step: .resolveJournal, why: "config failed"))))
    }

    @Test func precleanFailsWhenConfigOutputUnparseable() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("config", .success(stdout: Data("path: relative/not-absolute\n".utf8)))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.cleanup(step: .resolveJournal, message: cleanupMessage(step: .resolveJournal, why: "could not find the journal"))))
        #expect(!runner.invocations.contains { $0.arguments.first == "setup" })
    }

    @Test func precleanTreatsServiceUninstallNonzeroAsFatal() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success(stderr: Data("unload failed\n".utf8), exitCode: 1))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("unload failed"))
            #expect(runner.invocations.filter { $0.arguments == ["service", "uninstall"] }.count == 1)
            #expect(runner.invocations.filter { $0.arguments == ["service", "install"] }.isEmpty)
            #expect(runner.invocations.filter { $0.arguments == ["service", "start"] }.isEmpty)
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func precleanSkipsPidWaitWhenPidFileMissingOrDead() async throws {
        let journal = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: journal) }
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: journal.path)
        let probes = LockedProbeCounter(result: false)
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { pid in probes.record(pid) }
        )
        defer { installer.cancel() }

        installer.start(journalURL: journal, existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(probes.count == 0)
    }

    @Test func precleanProceedsImmediatelyWhenCapturedPidAlreadyDead() async throws {
        let journal = try makeTemporaryDirectory()
        try writeSupervisorPID(12345, journal: journal)
        defer { try? FileManager.default.removeItem(at: journal) }
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: journal.path)
        let probes = LockedProbeCounter(result: false)
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { pid in probes.record(pid) },
            pidWaitPollInterval: .milliseconds(500)
        )
        defer { installer.cancel() }

        installer.start(journalURL: journal, existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(probes.count <= 2)
    }

    @Test func precleanWaitsForLiveSupervisorPidThenContinues() async throws {
        let journal = try makeTemporaryDirectory()
        try writeSupervisorPID(1234, journal: journal)
        defer { try? FileManager.default.removeItem(at: journal) }
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: journal.path)
        let probes = SequencedPIDProbe([true, true, false, false])
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { pid in probes.next(pid) }
        )
        defer { installer.cancel() }

        installer.start(journalURL: journal, existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(probes.count >= 3)
    }

    @Test func precleanFailsWhenSupervisorPidSurvivesTimeout() async throws {
        let journal = try makeTemporaryDirectory()
        try writeSupervisorPID(4321, journal: journal)
        defer { try? FileManager.default.removeItem(at: journal) }
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: \(journal.path)\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { _ in true },
            pidWaitTimeout: .milliseconds(5),
            pidWaitPollInterval: .milliseconds(1)
        )
        defer { installer.cancel() }

        installer.start(journalURL: journal, existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("supervisor pid 4321 still alive"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func precleanOrphanSweepKillsOnlyPPIDOneJournalPrefix() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal", psOutput: """
          111     1 journal:foo
          222     2 journal:bar
          333     1 other-process
        """)
        let signals = LockedSignalRecorder()
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { _ in false },
            terminate: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(signals.values == [SignalRecord(pid: 111, signal: SIGTERM)])
    }

    @Test func precleanOrphanSweepSIGKILLsSurvivors() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal", psOutput: "111 1 journal:foo\n")
        let signals = LockedSignalRecorder()
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { _ in true },
            terminate: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(signals.values == [
            SignalRecord(pid: 111, signal: SIGTERM),
            SignalRecord(pid: 111, signal: SIGKILL)
        ])
    }

    @Test func precleanFailsWhenLsofReportsBoundPort7657() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success())
        runner.enqueue("ps", .success())
        runner.enqueue("lsof", .success(exitCode: 0))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("port 7657 still bound"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func precleanFailsWhenLsofReportsBoundPort5015() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success())
        runner.enqueue("ps", .success())
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 0))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("port 5015 still bound"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func precleanAcceptsLsofExitOneAsUnbound() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(runner.invocations.filter { $0.executable.lastPathComponent == "lsof" }.count == 2)
    }

    @Test func precleanFailsWhenLsofReturnsUnexpectedExit() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success())
        runner.enqueue("ps", .success())
        runner.enqueue("lsof", .success(exitCode: 2))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("lsof exited 2"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func precleanIdempotentOnHealthyButStoppedInstall() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let signals = LockedSignalRecorder()
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            pidExists: { _ in false },
            terminate: { pid, signal in signals.append(pid: pid, signal: signal); return 0 }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(signals.values.isEmpty)
    }

    @Test func failureMessageFormatForEveryCleanupStep() {
        for step in CleanupStep.allCases {
            let message = cleanupMessage(step: step, why: "why")
            #expect(message.hasPrefix("upgrade pre-clean failed at \(step.displayName) — "))
        }
    }

    @Test func uvToolInstallArgvNoLongerContainsReinstall() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let install = try #require(runner.invocations.first { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(Array(install.arguments.prefix(2)) == ["tool", "install"])
        #expect(URL(fileURLWithPath: install.arguments[2]).lastPathComponent == "solstone-\(BundleConfig.solstonePinVersion)-py3-none-macosx_14_0_arm64.whl")
        #expect(Array(install.arguments.dropFirst(3)) == [
            "--find-links",
            fixtureURLs.wheelhouse.path,
            "--no-index",
            "--offline",
            "--python",
            testBundledPythonURL.path,
            "--no-python-downloads",
            "--force"
        ])
        #expect(install.timeout == nil)
        #expect(!install.arguments.contains("--reinstall"))
        let environment = try #require(install.environment)
        #expect(environment["UV_TOOL_DIR"]?.contains("\(fixtureURLs.runtimeRoot.path)/.tmp-") == true)
        #expect(environment["UV_TOOL_BIN_DIR"]?.contains("\(fixtureURLs.runtimeRoot.path)/.tmp-") == true)
        #expect(environment["UV_PYTHON_INSTALL_DIR"]?.contains("\(fixtureURLs.runtimeRoot.path)/.tmp-") == true)
    }

    @Test func appManagedUpgradeSetupUsesResolvedJournalAndMaterializedBinary() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/resolved/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/caller/default"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.executable.path.hasPrefix(fixtureURLs.runtimeRoot.path))
        #expect(setup.executable.path.hasSuffix("/bin/journal"))
        #expect(setup.arguments == ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", "/resolved/journal", "--skip-service"])
        let materializedRoot = setup.executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        assertRuntimeEnvironment(
            try #require(setup.environment),
            layout: SolstoneRuntimeLayout(rootURL: materializedRoot)
        )
    }

    @Test func observerCreateSuccessWritesBundledServiceConfig() async throws {
        let appState = AppState.forSnapshot()
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let registrar = FakeObserverRegistrar()
        let installer = makeInstaller(
            runner: runner,
            connectionTester: { _, _ in nil },
            observerRegistrar: registrar.register
        )
        installer.attach(appState: appState)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(appState.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(appState.config.serverKey == "observer-key")
        #expect(appState.config.serviceMode == .bundled)
        #expect(registrar.invocationCount == 1)
        let descriptor = try #require(registrar.lastDescriptor)
        #expect(descriptor.platform == "darwin")
        #expect(descriptor.streamType == "desktop")
    }

    @Test func registerOnceGuardSkipsRegistrationWhenHandleSaved() async throws {
        let appState = AppState.forSnapshot(config: AppConfig(
            serverURL: ServiceMode.bundledServiceURL,
            serverKey: "saved-key",
            serviceMode: .bundled
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let registrar = FakeObserverRegistrar(result: .success("new-key"))
        let installer = makeInstaller(runner: runner, observerRegistrar: registrar.register)
        installer.attach(appState: appState)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(registrar.invocationCount == 0)
        #expect(appState.config.serverURL == ServiceMode.bundledServiceURL)
        #expect(appState.config.serverKey == "saved-key")
        #expect(appState.config.serviceMode == .bundled)
    }

    @Test func observerRegisterFailureRoutesToRegisteringFailure() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let registrar = FakeObserverRegistrar(result: .failure(ObserverRegistrationFailure(
            category: .network,
            message: "couldn't reach the journal to register this observer",
            logExcerpt: "network failed"
        )))
        let installer = makeInstaller(runner: runner, observerRegistrar: registrar.register)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitForTerminal(installer)

        if case .failed(.registering(let message)) = installer.main {
            #expect(message == "couldn't reach the journal to register this observer")
        } else {
            Issue.record("expected registering failure, got \(installer.main)")
        }
        #expect(installer.lastFailureCategory == .network)
        #expect(registrar.invocationCount == 1)
    }

    @Test func postInstallAutoTestSucceedsAfterDone() async throws {
        let appState = AppState.forSnapshot()
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
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

    @Test func externalManagedDetectCurrentOnlyProbesVersionAndPreservesConfig() async throws {
        try await assertExternalManagedDetect(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "existing-key", serviceMode: nil),
            versionStdout: "sol (solstone) \(BundleConfig.solstonePinVersion)\n",
            expectedProbe: .current(version: BundleConfig.solstonePinVersion)
        )
    }

    @Test func externalManagedDetectOutdatedOnlyProbesVersionAndPreservesConfig() async throws {
        try await assertExternalManagedDetect(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "existing-key", serviceMode: nil),
            versionStdout: "sol (solstone) 0.3.1\n",
            expectedProbe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion)
        )
    }

    @Test func externalManagedDetectUnknownOnlyProbesVersionAndPreservesConfig() async throws {
        try await assertExternalManagedDetect(
            config: AppConfig(serverURL: "http://localhost:5015", serverKey: "existing-key", serviceMode: nil),
            versionStdout: "unparseable\n",
            expectedProbe: .unknown
        )
    }

    @Test func externalManagedDetectWithPersistedBundledModeDoesNotDestructOrMutateConfig() async throws {
        try await assertExternalManagedDetect(
            config: AppConfig(serverURL: ServiceMode.bundledServiceURL, serverKey: "bundled-key", serviceMode: .bundled),
            versionStdout: "sol (solstone) 0.3.1\n",
            expectedProbe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion)
        )
    }

    @Test func staleRuntimeWithExternalWrapperAndCredsDoesNotDestructOrMutateConfig() async throws {
        try await assertExternalManagedDetect(
            config: AppConfig(serverURL: "http://127.0.0.1:5015", serverKey: "loopback-key", serviceMode: nil),
            versionStdout: "sol (solstone) 0.3.1\n",
            expectedProbe: .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion),
            solPath: "/repo/.venv/bin/sol"
        )
    }

    @Test func appManagedUpgradePassesResolvedJournalRootToSetup() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/existing-journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/caller/default"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.arguments.contains("--journal"))
        #expect(setup.arguments.contains("/tmp/existing-journal"))
        #expect(setup.arguments.contains("--skip-service"))
        #expect(!setup.arguments.contains(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal").path))
    }

    @Test func appManagedUpgradeAbortsBeforeDestructiveWorkWhenJournalRootMissing() async throws {
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(
            runner: runner,
            fileExists: { _ in false }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/caller/default"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.cleanup(
            step: .resolveJournal,
            message: cleanupMessage(step: .resolveJournal, why: UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE)
        )))
        assertNoDestructiveInstallerInvocations(runner)
    }

    @Test func detectAbsentKeepsFreshInstallChoiceUnchanged() async {
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in .absent }
        )

        let found = await installer.detect()

        #expect(!found)
        #expect(installer.main == .awaitingChoice(existingInstall: false))
        #expect(runner.invocations.isEmpty)
    }

    @Test func concurrentDetectCoalescesOwnershipResolution() async {
        let runner = FakeSubprocessRunner()
        let resolverCalls = LockedCounter()
        let gate = OneShotContinuationGate()
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in
                resolverCalls.increment()
                await gate.wait()
                return .absent
            }
        )

        let first = Task { await installer.detect() }
        await resolverCalls.waitUntilCount(1)
        let second = Task { await installer.detect() }

        let secondResult = await second.value
        gate.release()
        let firstResult = await first.value

        #expect(secondResult)
        #expect(!firstResult)
        #expect(resolverCalls.count == 1)
        #expect(installer.main == .awaitingChoice(existingInstall: false))
        #expect(runner.invocations.isEmpty)
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

    @Test func probeVersionWithoutSolBinaryReportsUnknown() async {
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(
            runner: runner,
            solBinaryFinder: { nil }
        )

        await installer.probeVersion()

        #expect(installer.probedVersion == .unknown)
    }

    @Test func postInstallOutdatedProbeDoesNotAutoUpgrade() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.probedVersion == .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion) }

        #expect(installer.main == .done)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
    }

    @Test func appManagedDetectCurrentClearsCurrentPinFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            failureRecordStore: store,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )

        let found = await installer.detect()
        try await waitUntil { installer.probedVersion == .current(version: BundleConfig.solstonePinVersion) }

        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(store.clearCallCount == 1)
    }

    @Test func appManagedDetectCurrentClearsStalePinFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: "0.3.7",
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            failureRecordStore: store,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )

        let found = await installer.detect()
        try await waitUntil { installer.probedVersion == .current(version: BundleConfig.solstonePinVersion) }

        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(store.clearCallCount == 1)
    }

    @Test func appManagedDetectCurrentWithNoFailureRecordIsNoOp() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            failureRecordStore: store,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )

        let found = await installer.detect()
        try await waitUntil { installer.probedVersion == .current(version: BundleConfig.solstonePinVersion) }

        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
        #expect(store.clearCallCount == 0)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
    }

    @Test func appManagedDetectUnknownWithFailureRecordIsNoOp() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("unparseable\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            failureRecordStore: store,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )

        let found = await installer.detect()
        try await waitUntil { installer.probedVersion == .unknown }

        #expect(found)
        #expect(installer.main == .awaitingChoice(existingInstall: true))
        #expect(installer.probedVersion == .unknown)
        #expect(store.clearCallCount == 0)
        #expect(installer.upgradeFailureRecord != nil)
        #expect(store.load() != nil)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
    }

    @Test func upgradeRunFailurePersistsFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("service", .success(stdout: Data("Service was not installed\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("tool", .success(stderr: Data("error: failed to download solstone\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitForTerminal(installer)

        let record = try #require(store.load())
        #expect(record.installed == "0.3.1")
        #expect(record.pinned == BundleConfig.solstonePinVersion)
        #expect(record.errorDetails.contains("error: failed to download solstone"))
        #expect(terminalCardState(
            main: installer.main,
            probe: installer.probedVersion,
            failureRecord: installer.upgradeFailureRecord
        ) == .upgradeFailed(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion, errorDetails: record.errorDetails))
    }

    @Test func successfulUpgradeClearsFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        UserDefaults.standard.set(Data("stale marker".utf8), forKey: "SolstoneInProgressUpgradeMarker")
        defer { UserDefaults.standard.removeObject(forKey: "SolstoneInProgressUpgradeMarker") }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitUntil { installer.main == .done }

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(UserDefaults.standard.object(forKey: "SolstoneInProgressUpgradeMarker") == nil)
    }

    @Test func modelsFailureDuringUpgradeDoesNotPersistFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success(stdout: Data("Service was not installed\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        runner.enqueue("install-models", .success(stderr: Data("models failed\n".utf8), exitCode: 1))
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitUntil {
            if case .failed("models failed") = installer.modelsProgress { return true }
            return false
        }
        try await waitUntil { installer.probedVersion == .current(version: BundleConfig.solstonePinVersion) }

        #expect(installer.main == .done)
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(terminalCardState(
            main: installer.main,
            probe: installer.probedVersion,
            failureRecord: installer.upgradeFailureRecord
        ) == .installedCurrent(version: BundleConfig.solstonePinVersion))
    }

    @Test func freshInstallFailureDoesNotPersistUpgradeRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        runner.enqueue("tool", .success(stderr: Data("error: failed to download solstone\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(terminalCardState(
            main: installer.main,
            probe: installer.probedVersion,
            failureRecord: installer.upgradeFailureRecord
        ) == .failed(.installSolstone(message: UICopy.JOURNAL_MATERIALIZE_FAILED)))
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == nil)
    }

    @Test func upgradeStartClearsRecordSynchronously() {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(runner: runner, failureRecordStore: store)
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: "0.3.1",
            pinnedVersion: BundleConfig.solstonePinVersion
        )

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(installer.upgradeInProgress)
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
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        runner.enqueue("tool", .success(stderr: Data("last error\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            uvURL: uvURL,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == UICopy.JOURNAL_MATERIALIZE_FAILED)
        } else {
            Issue.record("expected installSolstone failure")
        }
    }

    private func launchFailureUsesLocalizedDescription() async throws {
        let runner = FakeSubprocessRunner()
        let uvURL = try makeUVFixture()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        runner.enqueue("tool", .failure("launch boom"))
        let installer = makeInstaller(
            runner: runner,
            uvURL: uvURL,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == UICopy.JOURNAL_MATERIALIZE_FAILED)
        } else {
            Issue.record("expected installSolstone launch failure")
        }
    }

    private func assertState4(observerSucceeds: Bool, expectsDone: Bool) async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("install-models", .success())
        let registrar = FakeObserverRegistrar(result: observerSucceeds
            ? .success("observer-key")
            : .failure(ObserverRegistrationFailure(
                category: .unknown,
                message: "observer failed",
                logExcerpt: "observer failed"
            ))
        )
        let installer = makeInstaller(runner: runner, observerRegistrar: registrar.register)
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

    private func assertExternalManagedDetect(
        config: AppConfig,
        versionStdout: String,
        expectedProbe: VersionProbeResult,
        solPath: String = "/opt/homebrew/bin/sol"
    ) async throws {
        let appState = AppState.forSnapshot(config: config)
        let originalURL = appState.config.serverURL
        let originalKey = appState.config.serverKey
        let originalMode = appState.config.serviceMode
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data(versionStdout.utf8)))
        let registrar = FakeObserverRegistrar()
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in .externallyManaged(solPath: solPath) },
            observerRegistrar: registrar.register
        )
        installer.attach(appState: appState)
        defer { installer.cancel() }

        let found = await installer.detect()
        try await waitUntil { installer.probedVersion == expectedProbe }

        #expect(found)
        #expect(installer.main == .externallyManaged(solPath: solPath))
        #expect(appState.config.serverURL == originalURL)
        #expect(appState.config.serverKey == originalKey)
        #expect(appState.config.serviceMode == originalMode)
        #expect(registrar.invocationCount == 0)
        assertNoDestructiveInstallerInvocations(runner)
    }

    private func assertNoDestructiveInstallerInvocations(_ runner: FakeSubprocessRunner) {
        let destructiveFirstArguments = Set(["tool", "service", "setup", "observer", "install-models"])
        #expect(!runner.invocations.contains { invocation in
            guard let first = invocation.arguments.first else { return false }
            return destructiveFirstArguments.contains(first)
        })
    }

    private func makeInstaller(
        runner: FakeSubprocessRunner,
        uvURL: URL? = nil,
        pythonURL: URL? = testBundledPythonURL,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        failureRecordStore: UpgradeFailureRecordStoring = InMemoryUpgradeFailureRecordStore(),
        wrapperDirURL: URL? = nil,
        solBinaryFinder: @escaping @Sendable () async -> String? = { "/usr/bin/sol" },
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        observerRegistrar: @escaping ObserverRegistrar = { _ in .success("observer-key") },
        fileExists: @escaping @Sendable (String) -> Bool = defaultTestFileExists
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            bundledPythonURL: pythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: runner,
            failureRecordStore: failureRecordStore,
            wrapperDirURL: wrapperDirURL ?? makeWrapperDirURL(),
            solBinaryFinder: solBinaryFinder,
            solOwnershipResolver: solOwnershipResolver,
            connectionTester: connectionTester,
            observerRegistrar: observerRegistrar,
            fileExists: fileExists
        )
    }

    private func makeInstaller(
        runner: FakeSubprocessRunner,
        uvURL: URL? = nil,
        pythonURL: URL? = testBundledPythonURL,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        failureRecordStore: UpgradeFailureRecordStoring = InMemoryUpgradeFailureRecordStore(),
        wrapperDirURL: URL? = nil,
        solBinaryFinder: @escaping @Sendable () async -> String? = { "/usr/bin/sol" },
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        observerRegistrar: @escaping ObserverRegistrar = { _ in .success("observer-key") },
        fileExists: @escaping @Sendable (String) -> Bool = defaultTestFileExists,
        pidExists: @escaping @Sendable (pid_t) -> Bool,
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { _, _ in 0 },
        pidWaitTimeout: Duration = .seconds(1),
        pidWaitPollInterval: Duration = .milliseconds(1),
        orphanGracePeriod: Duration = .milliseconds(1)
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            bundledPythonURL: pythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: runner,
            failureRecordStore: failureRecordStore,
            wrapperDirURL: wrapperDirURL ?? makeWrapperDirURL(),
            solBinaryFinder: solBinaryFinder,
            solOwnershipResolver: solOwnershipResolver,
            connectionTester: connectionTester,
            observerRegistrar: observerRegistrar,
            fileExists: fileExists,
            pidExists: pidExists,
            terminate: terminate,
            pidWaitTimeout: pidWaitTimeout,
            pidWaitPollInterval: pidWaitPollInterval,
            orphanGracePeriod: orphanGracePeriod
        )
    }

    private func waitForTerminal(_ installer: SolstoneInstaller) async throws {
        try await waitUntil {
            if case .done = installer.main { return true }
            if case .failed = installer.main { return true }
            return false
        }
    }

    private func enqueueSuccessfulUpgrade(
        _ runner: FakeSubprocessRunner,
        resolvedJournal: String = "/tmp/journal",
        psOutput: String = "",
        setupSideEffect: (@Sendable () -> Void)? = nil,
        newInstall: FakeSubprocessRunner.Response = .success(),
        newStart: FakeSubprocessRunner.Response = .success(),
        readinessGate: FakeSubprocessRunner.Response = .success()
    ) {
        runner.enqueue("config", .success(stdout: Data("path: \(resolvedJournal)\n".utf8)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success(stdout: Data("Service was not installed\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data(psOutput.utf8)))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok"), sideEffect: setupSideEffect))
        runner.enqueue("service", newInstall)
        runner.enqueue("service", newStart)
        runner.enqueue("up", readinessGate)
        runner.enqueue("install-models", .success())
    }

    private func makeWrapperDirURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-wrapper-dir-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanupMessage(step: CleanupStep, why: String) -> String {
        "upgrade pre-clean failed at \(step.displayName) — \(why)"
    }

    private func assertRuntimeEnvironment(_ environment: [String: String]) {
        let layout = SolstoneRuntimeLayout()
        #expect(environment["UV_PYTHON_INSTALL_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_PYTHON_CACHE_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_CACHE_DIR"] == layout.cacheDir.path)
        #expect(environment["UV_TOOL_DIR"] == layout.toolsDir.path)
        #expect(environment["UV_TOOL_BIN_DIR"] == layout.binDir.path)
    }

    private func assertRuntimeEnvironment(_ environment: [String: String], layout: SolstoneRuntimeLayout) {
        #expect(environment["UV_PYTHON_INSTALL_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_PYTHON_CACHE_DIR"] == layout.pythonDir.path)
        #expect(environment["UV_CACHE_DIR"] == layout.cacheDir.path)
        #expect(environment["UV_TOOL_DIR"] == layout.toolsDir.path)
        #expect(environment["UV_TOOL_BIN_DIR"] == layout.binDir.path)
    }

    private func makeStagedInstallFixture(
        wheelNames: [String] = ["solstone-\(BundleConfig.solstonePinVersion)-py3-none-macosx_14_0_arm64.whl"]
    ) throws -> (workspace: URL, runtimeRoot: URL, wheelhouse: URL) {
        let workspace = try makeTemporaryDirectory(prefix: "solstone-staged-install")
        let runtimeRoot = workspace.appendingPathComponent("runtime", isDirectory: true)
        let wheelhouse = workspace.appendingPathComponent("wheelhouse", isDirectory: true)
        try FileManager.default.createDirectory(at: wheelhouse, withIntermediateDirectories: true)
        for name in wheelNames {
            try Data("wheel\n".utf8).write(to: wheelhouse.appendingPathComponent(name))
        }
        return (workspace, runtimeRoot, wheelhouse)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstone-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSupervisorPID(_ pid: pid_t, journal: URL) throws {
        let health = journal.appendingPathComponent("health", isDirectory: true)
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        try Data("\(pid)".utf8).write(to: health.appendingPathComponent("supervisor.pid"))
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

}

@Suite("UpgradeFailureRecordStore")
@MainActor
struct UpgradeFailureRecordStoreTests {
    @Test func userDefaultsStoreRoundTripsRecord() throws {
        let suiteName = "solstone-upgrade-record-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsUpgradeFailureRecordStore(defaults: defaults)
        let record = UpgradeFailureRecord(installed: "0.3.1", pinned: "0.3.8", errorDetails: "details")

        store.save(record)
        #expect(store.load() == record)

        store.clear()
        #expect(store.load() == nil)
    }

    @Test func userDefaultsStoreLoadsLegacyRecordWithInstalledString() throws {
        let suiteName = "solstone-upgrade-record-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsUpgradeFailureRecordStore(defaults: defaults)
        defaults.set(
            Data(#"{"installed":"0.3.1","pinned":"0.3.8","errorDetails":"details"}"#.utf8),
            forKey: "SolstoneUpgradeFailureRecord"
        )

        #expect(store.load() == UpgradeFailureRecord(installed: "0.3.1", pinned: "0.3.8", errorDetails: "details"))
    }

    @Test func inMemoryStoreRoundTripsRecord() {
        let store = InMemoryUpgradeFailureRecordStore()
        let record = UpgradeFailureRecord(installed: "0.3.1", pinned: "0.3.8", errorDetails: "details")

        #expect(store.load() == nil)
        store.save(record)
        #expect(store.load() == record)
        store.clear()
        #expect(store.load() == nil)
    }
}

private final class SequencedSolBinaryFinder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]

    init(_ values: [String?]) {
        self.values = values
    }

    func next() -> String? {
        lock.withLock {
            if values.isEmpty { return nil }
            return values.removeFirst()
        }
    }
}

private final class SequencedPIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    private var calls = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    var count: Int {
        lock.withLock { calls }
    }

    func next(_ pid: pid_t) -> Bool {
        lock.withLock {
            calls += 1
            if values.isEmpty { return false }
            return values.removeFirst()
        }
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.withLock { storedValue }
    }

    func set(_ value: String?) {
        lock.withLock {
            storedValue = value
        }
    }
}

private final class LockedProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    var count: Int {
        lock.withLock { calls }
    }

    func record(_ pid: pid_t) -> Bool {
        lock.withLock {
            calls += 1
            return result
        }
    }
}

private struct SignalRecord: Equatable {
    let pid: pid_t
    let signal: Int32
}

private func journalPath(siblingOf solPath: String) -> String {
    URL(fileURLWithPath: solPath)
        .deletingLastPathComponent()
        .appendingPathComponent("journal")
        .path
}

private func defaultTestFileExists(_ path: String) -> Bool {
    path.hasSuffix("/journal")
}

private final class LockedSignalRecorder: @unchecked Sendable {
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
