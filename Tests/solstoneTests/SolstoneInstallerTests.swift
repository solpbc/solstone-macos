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
            var fixtureURLs: (workspace: URL, runtimeRoot: URL, wheelhouse: URL)?
            var finderValues: [String?] = ["/usr/bin/sol"]
            if choice == .createFresh {
                let fixture = try makeStagedInstallFixture()
                fixtureURLs = fixture
                let stagedSolPath = SolstoneRuntimeLayout
                    .staging(rootURL: fixture.runtimeRoot, version: BundleConfig.solstonePinVersion)
                    .solBinary
                    .path
                finderValues = [nil, stagedSolPath]
                enqueueSuccessfulBundledPythonPreflight(runner)
                runner.enqueue("tool", .success())
                runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
            }
            let finder = SequencedSolBinaryFinder(finderValues)
            runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
            runner.enqueue("observer", .success(stdout: observerJSON))
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
                "/tmp/solstone-test-journal"
            ])
            let observer = try #require(runner.invocations.first { $0.arguments.first == "observer" })
            let expectedJournalPath = choice == .createFresh
                ? setup.executable.path
                : journalPath(siblingOf: "/usr/bin/sol")
            #expect(observer.executable.path == expectedJournalPath)
            #expect(observer.arguments == [
                "observer",
                "--json",
                "create",
                "solstone-macos",
                "--reuse-existing"
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

    @Test func failureMessage_isVerbatim_perSubprocessClass() async throws {
        try await jsonlStepFailedMessageIsVerbatim()
        try await rawSubprocessFailureUsesLastStderrLine()
        try await launchFailureUsesLocalizedDescription()
    }

    @Test func state4_observerResultDrivesTerminalState() async throws {
        try await assertState4(observerSucceeds: true, expectsDone: true)
        try await assertState4(observerSucceeds: false, expectsDone: false)
    }

    @Test func upgradeReadinessGateDefersObserverCreateUntilUpCompletes() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let upDone = LockedStringBox()
        let observerSawUp = LockedStringBox()
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal",
            readinessGate: .success(delay: .milliseconds(50), sideEffect: {
                upDone.set("done")
            }),
            observer: .success(stdout: observerJSON, sideEffect: {
                observerSawUp.set(upDone.value == "done" ? "yes" : "no")
            })
        )
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(observerSawUp.value == "yes")
        #expect(runner.invocations.filter { $0.arguments.first == "observer" }.count == 1)
    }

    @Test func freshInstallReadinessGateDefersObserverCreateUntilUpCompletes() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedSolPath = SolstoneRuntimeLayout
            .staging(rootURL: fixtureURLs.runtimeRoot, version: BundleConfig.solstonePinVersion)
            .solBinary
            .path
        let finder = SequencedSolBinaryFinder([nil, stagedSolPath])
        let upDone = LockedStringBox()
        let observerSawUp = LockedStringBox()
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success(delay: .milliseconds(50), sideEffect: {
            upDone.set("done")
        }))
        runner.enqueue("observer", .success(stdout: observerJSON, sideEffect: {
            observerSawUp.set(upDone.value == "done" ? "yes" : "no")
        }))
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

        #expect(observerSawUp.value == "yes")
        #expect(runner.invocations.filter { $0.arguments.first == "observer" }.count == 1)
    }

    @Test func readinessGateTimeoutStderrFailsRegisteringWithoutStillRunningCopy() async throws {
        let installer = try await installerAfterUpgradeReadinessFailure(
            readinessGate: .success(
                stderr: Data("Service did not become ready within 60s — run 'journal service status' or 'journal doctor' for diagnostics\n".utf8),
                exitCode: 1
            )
        )

        if case .failed(.registering(let message)) = installer.main {
            #expect(message == UICopy.INSTALLER_READINESS_TIMEOUT)
            #expect(!message.contains("still running"))
        } else {
            Issue.record("expected registering failure")
        }
        let details = installer.upgradeFailureRecord?.errorDetails ?? ""
        #expect(!details.contains("still running"))
    }

    @Test func readinessGateOuterTimeoutFailsAsReadinessTimeout() async throws {
        let installer = try await installerAfterUpgradeReadinessFailure(
            readinessGate: .success(delay: .milliseconds(10)),
            readinessGateTimeout: .milliseconds(10)
        )

        if case .failed(.registering(let message)) = installer.main {
            #expect(message == UICopy.INSTALLER_READINESS_TIMEOUT)
        } else {
            Issue.record("expected registering failure")
        }
        #expect(installer.upgradeFailureRecord?.installed == BundleConfig.solstonePinVersion)
    }

    @Test func readinessGateLaunchFailureUsesGateFailureCopy() async throws {
        let installer = try await installerAfterUpgradeReadinessFailure(
            readinessGate: .failure("launch boom")
        )

        if case .failed(.registering(let message)) = installer.main {
            #expect(message == UICopy.INSTALLER_READINESS_GATE_FAILED)
            #expect(!message.contains("still running"))
        } else {
            Issue.record("expected registering failure")
        }
    }

    @Test func readinessGateOtherNonzeroUsesGateFailureCopyAndLogDetail() async throws {
        let installer = try await installerAfterUpgradeReadinessFailure(
            readinessGate: .success(stderr: Data("launchctl failed\n".utf8), exitCode: 1)
        )

        if case .failed(.registering(let message)) = installer.main {
            #expect(message == UICopy.INSTALLER_READINESS_GATE_FAILED)
        } else {
            Issue.record("expected registering failure")
        }
        #expect(installer.upgradeFailureRecord?.errorDetails.contains("launchctl failed") == true)
    }

    @Test func postActivationRegisteringFailurePersistsReprobedPinnedVersion() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal",
            observer: .success(stderr: Data("observer failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
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
            resolvedJournal: "/tmp/journal",
            observer: .success(stderr: Data("observer failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("--version", .success(exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
        )
        try await waitForTerminal(installer)

        let record = try #require(store.load())
        #expect(record.installed == nil)
        #expect(upgradeFailedStatusMessage(installedVersion: record.installed, pinnedVersion: record.pinned) == "upgrade may be incomplete — couldn't confirm the running version")
    }

    @Test func upgradeFailureRetryConfirmedNewAcceptsExistingAndRegisters() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success())
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: BundleConfig.solstonePinVersion,
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        let upIndex = try #require(runner.invocations.firstIndex { $0.arguments.first == "up" })
        let observerIndex = try #require(runner.invocations.firstIndex { $0.arguments.first == "observer" })
        #expect(upIndex < observerIndex)
    }

    @Test func upgradeFailureRetryUnknownAcceptsExistingAndRegisters() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success())
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.retryUpgradeFailure(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            installedVersion: nil,
            pinnedVersion: BundleConfig.solstonePinVersion
        )
        try await waitUntil { installer.main == .done }

        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        let upIndex = try #require(runner.invocations.firstIndex { $0.arguments.first == "up" })
        let observerIndex = try #require(runner.invocations.firstIndex { $0.arguments.first == "observer" })
        #expect(upIndex < observerIndex)
    }

    @Test func singleInFlightStartRejectedDuringReadinessGate() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success(delay: .milliseconds(50)))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil {
            runner.invocations.contains { $0.arguments.first == "up" }
        }
        installer.start(journalURL: URL(fileURLWithPath: "/tmp/other-journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.main == .done }

        #expect(runner.invocations.filter { $0.arguments.first == "setup" }.count == 1)
        #expect(runner.invocations.filter { $0.arguments.first == "up" }.count == 1)
        #expect(runner.invocations.filter { $0.arguments.first == "observer" }.count == 1)
    }

    @Test func togglingServiceModeDoesNotCancelActiveInstall() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("up", .success(delay: .milliseconds(500)))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil {
            runner.invocations.contains { $0.arguments.first == "up" }
        }
        let midFlightMain = installer.main

        var serviceMode: ServiceMode = .bundled
        serviceMode = .external
        serviceMode = .bundled

        #expect(serviceMode == .bundled)
        #expect(installer.isInstallTaskActive)
        #expect(installer.main == midFlightMain)

        try await waitUntil { installer.main == .done }
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
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        #expect(stageIndex < serviceIndex)
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
        let stagedSolPath = SolstoneRuntimeLayout
            .staging(rootURL: fixtureURLs.runtimeRoot, version: BundleConfig.solstonePinVersion)
            .solBinary
            .path
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let finder = SequencedSolBinaryFinder([nil, stagedSolPath])
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
        #expect(Array(setup.arguments.suffix(2)) == ["--journal", "/tmp/journal"])
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == BundleConfig.solstonePinVersion)
    }

    @Test func acceptExistingSkipsPreclean() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message.contains("/tmp/journal"))
            #expect(message.contains("unload failed"))
            #expect(runner.invocations.filter { $0.arguments == ["service", "install"] }.count == 1)
            #expect(runner.invocations.filter { $0.arguments == ["service", "start"] }.count == 1)
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message.contains(journal.path))
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message.contains("/tmp/journal"))
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message.contains("/tmp/journal"))
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message.contains("/tmp/journal"))
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
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
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
        #expect(install.timeout == .seconds(120))
        #expect(!install.arguments.contains("--reinstall"))
        assertRuntimeEnvironment(try #require(install.environment), layout: stagedLayout)
    }

    @Test func stagedInstallVersionMismatchDoesNotActivate() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone 0.0.0\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.installSolstone(message: "staged solstone version mismatch")))
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == nil)
    }

    @Test func stagedInstallWheelhouseCardinalityFailuresDoNotActivate() async throws {
        for wheelNames in [[], [
            "solstone-\(BundleConfig.solstonePinVersion)-py3-none-macosx_14_0_arm64.whl",
            "solstone-\(BundleConfig.solstonePinVersion)-2-py3-none-macosx_14_0_arm64.whl"
        ]] {
            let runner = FakeSubprocessRunner()
            let fixtureURLs = try makeStagedInstallFixture(wheelNames: wheelNames)
            defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
            let finder = SequencedSolBinaryFinder([nil])
            enqueueSuccessfulBundledPythonPreflight(runner)
            let installer = makeInstaller(
                runner: runner,
                wheelhouseURL: fixtureURLs.wheelhouse,
                runtimeRootURL: fixtureURLs.runtimeRoot,
                solBinaryFinder: { finder.next() }
            )
            defer { installer.cancel() }

            installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
            try await waitForTerminal(installer)

            if case .failed(.installSolstone(let message)) = installer.main {
                #expect(message.contains("expected exactly one bundled solstone-\(BundleConfig.solstonePinVersion)-*.whl"))
            } else {
                Issue.record("expected installSolstone failure")
            }
            #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == nil)
        }
    }

    @Test func stagedInstallTimeoutDoesNotActivate() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(delay: .milliseconds(50)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallTimeout: .milliseconds(10)
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.installSolstone(message: "uv tool install solstone failed")))
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == nil)
    }

    @Test func stagedInstallRetriesThenSucceeds() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(exitCode: 1))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallMaxAttempts: 2,
            stagedInstallRetryBackoff: .zero
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == BundleConfig.solstonePinVersion)
        #expect(runner.invocations.filter { $0.arguments.first == "tool" }.count == 2)
    }

    @Test func stagedInstallAllAttemptsFailDoNotActivate() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let activeBefore = SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot)
        let finder = SequencedSolBinaryFinder([nil])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(stderr: Data("download failed\n".utf8), exitCode: 1))
        runner.enqueue("tool", .success(stderr: Data("download failed\n".utf8), exitCode: 1))
        runner.enqueue("tool", .success(stderr: Data("download failed\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallMaxAttempts: 3,
            stagedInstallRetryBackoff: .zero
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.installSolstone(message: "download failed")))
        #expect(!runner.invocations.contains { $0.arguments.first == "--version" })
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == activeBefore)
        #expect(runner.invocations.filter { $0.arguments.first == "tool" }.count == 3)
    }

    @Test func stagedInstallSucceedsFirstTryRunsOnce() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallMaxAttempts: 3,
            stagedInstallRetryBackoff: .zero
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(runner.invocations.filter { $0.arguments.first == "tool" }.count == 1)
    }

    @Test func stagedInstallTimeoutAttemptCountsAsOneFailure() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(delay: .milliseconds(50)))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallTimeout: .milliseconds(10),
            stagedInstallMaxAttempts: 2,
            stagedInstallRetryBackoff: .zero
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == BundleConfig.solstonePinVersion)
        #expect(runner.invocations.filter { $0.arguments.first == "tool" }.count == 2)
    }

    @Test func stagedInstallRetryReusesOfflineArgsAndEnv() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(exitCode: 1))
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() },
            stagedInstallMaxAttempts: 2,
            stagedInstallRetryBackoff: .zero
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let installInvocations = runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }
        let lastInstall = try #require(installInvocations.last)
        #expect(installInvocations.count == 2)
        #expect(lastInstall.arguments.contains("--find-links"))
        #expect(lastInstall.arguments.contains("--no-index"))
        #expect(lastInstall.arguments.contains("--offline"))
        #expect(lastInstall.arguments.contains("--python"))
        #expect(lastInstall.arguments.contains("--no-python-downloads"))
        #expect(lastInstall.arguments.contains("--force"))
        let environment = try #require(lastInstall.environment)
        #expect(environment["UV_TOOL_DIR"] == stagedLayout.toolsDir.path)
        #expect(environment["UV_TOOL_BIN_DIR"] == stagedLayout.binDir.path)
    }

    @Test func stagedInstallRemovesStaleSameVersionBeforeStaging() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        try FileManager.default.createDirectory(at: stagedLayout.binDir, withIntermediateDirectories: true)
        let staleMarker = stagedLayout.binDir.appendingPathComponent("stale")
        try Data("stale\n".utf8).write(to: staleMarker)
        let finder = SequencedSolBinaryFinder([nil, stagedLayout.solBinary.path])
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
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

        #expect(!FileManager.default.fileExists(atPath: staleMarker.path))
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == BundleConfig.solstonePinVersion)
    }

    @Test func stagedInstallRefusesActiveSameVersion() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: BundleConfig.solstonePinVersion
        )
        try stagedLayout.ensureCreated()
        try stagedLayout.activate()
        let finder = SequencedSolBinaryFinder([nil])
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solBinaryFinder: { finder.next() }
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(installer.main == .failed(.installSolstone(message: "cannot re-stage the active version (out of scope this lode)")))
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == BundleConfig.solstonePinVersion)
        #expect(runner.invocations.isEmpty)
    }

    @Test func uvAndPostInstallSubprocessesReceiveRuntimeEnvironment() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: "\(BundleConfig.solstonePinVersion)+test-token"
        )
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        let install = try #require(runner.invocations.first { $0.arguments.starts(with: ["tool", "install"]) })
        assertRuntimeEnvironment(try #require(install.environment), layout: stagedLayout)

        for arguments in [
            ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", "/tmp/journal", "--skip-service"],
            ["service", "install"],
            ["service", "start"],
            ["observer", "--json", "create", "solstone-macos", "--reuse-existing"],
            ["install-models"]
        ] {
            let invocation = try #require(runner.invocations.first { $0.arguments == arguments })
            let environment = try #require(invocation.environment)
            assertRuntimeEnvironment(environment, layout: stagedLayout)
        }

        for arguments in [
            ["config", "show"],
            ["service", "uninstall"]
        ] {
            let invocation = try #require(runner.invocations.first { $0.arguments == arguments })
            #expect(invocation.environment == nil)
        }
        #expect(runner.invocations.filter { $0.executable.lastPathComponent == "ps" }.allSatisfy { $0.environment == nil })
        #expect(runner.invocations.filter { $0.executable.lastPathComponent == "lsof" }.allSatisfy { $0.environment == nil })
        #expect(runner.invocations.first { $0.arguments.first == "setup" }?.executable.path == journalPath(siblingOf: stagedLayout.solBinary.path))
    }

    @Test func appManagedUpgradeStageFailureDoesNotStopOldService() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let activeBefore = SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot)
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(stderr: Data("download failed\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/caller/default"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(!runner.invocations.contains { $0.arguments.first == "service" })
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "ps" })
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "lsof" })
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == activeBefore)
        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == "download failed")
        } else {
            Issue.record("expected installSolstone failure")
        }
    }

    @Test func appManagedUpgradeVersionMismatchDoesNotStopOldService() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let activeBefore = SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot)
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone 9.9.9\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/caller/default"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        #expect(!runner.invocations.contains { $0.arguments.first == "service" })
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "ps" })
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "lsof" })
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == activeBefore)
        if case .failed(.installSolstone(let message)) = installer.main {
            #expect(message == "staged solstone version mismatch")
        } else {
            Issue.record("expected installSolstone failure")
        }
    }

    @Test func appManagedUpgradeSetupUsesResolvedJournalAndStagedBinary() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: "\(BundleConfig.solstonePinVersion)+test-token"
        )
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
        #expect(setup.executable.path == stagedLayout.binDir.appendingPathComponent("journal").path)
        #expect(setup.arguments == ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", "/resolved/journal", "--skip-service"])
        assertRuntimeEnvironment(try #require(setup.environment), layout: stagedLayout)
    }

    @Test func appManagedUpgradeDoesNotInstallServiceBeforeStagedSetup() async throws {
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

        let invocations = runner.invocations
        let stageIndex = try #require(invocations.firstIndex { $0.arguments.starts(with: ["tool", "install"]) })
        let verifyIndex = try #require(invocations.firstIndex { $0.arguments == ["--version"] })
        let oldStopIndex = try #require(invocations.firstIndex { $0.arguments == ["service", "uninstall"] })
        let setupIndex = try #require(invocations.firstIndex { $0.arguments.first == "setup" })
        let newInstallIndex = try #require(invocations.firstIndex { $0.arguments == ["service", "install"] })
        #expect(stageIndex < verifyIndex)
        #expect(verifyIndex < oldStopIndex)
        #expect(oldStopIndex < setupIndex)
        #expect(setupIndex < newInstallIndex)
    }

    @Test func appManagedUpgradeRestoresWrappersAndCurrentAfterPostStopFailure() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let oldLayout = SolstoneRuntimeLayout.staging(rootURL: fixtureURLs.runtimeRoot, version: "old-runtime")
        try oldLayout.ensureCreated()
        try oldLayout.activate()
        let wrapperDir = try makeTemporaryDirectory(prefix: "solstone-wrapper")
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        let solWrapper = wrapperDir.appendingPathComponent("sol")
        let journalWrapper = wrapperDir.appendingPathComponent("journal")
        try Data("old sol\n".utf8).write(to: solWrapper)
        try Data("old journal\n".utf8).write(to: journalWrapper)
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal",
            setupSideEffect: {
                try? Data("new sol\n".utf8).write(to: solWrapper)
                try? Data("new journal\n".utf8).write(to: journalWrapper)
            },
            newStart: .success(stderr: Data("new service failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let markerStore = InMemoryInProgressUpgradeMarkerStore()
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            inProgressMarkerStore: markerStore,
            wrapperDirURL: wrapperDir
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitForTerminal(installer)

        let solContents = try String(contentsOf: solWrapper, encoding: .utf8)
        let journalContents = try String(contentsOf: journalWrapper, encoding: .utf8)
        #expect(solContents == "old sol\n")
        #expect(journalContents == "old journal\n")
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == "old-runtime")
        #expect(markerStore.load()?.phase == .startingService)
        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("wrapper restore: sol: restored; journal: restored"))
            #expect(message.contains("current rollback: restored versions/old-runtime"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
    }

    @Test func appManagedUpgradeInstallsAndStartsServiceAgainstStagedRuntime() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let stagedLayout = SolstoneRuntimeLayout.staging(
            rootURL: fixtureURLs.runtimeRoot,
            version: "\(BundleConfig.solstonePinVersion)+test-token"
        )
        let runtimeRootURL = fixtureURLs.runtimeRoot
        let activeAtInstall = LockedStringBox()
        let activeAtStart = LockedStringBox()
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal",
            newInstall: .success(sideEffect: {
                activeAtInstall.set(SolstoneRuntimeLayout.readActiveVersion(rootURL: runtimeRootURL))
            }),
            newStart: .success(sideEffect: {
                activeAtStart.set(SolstoneRuntimeLayout.readActiveVersion(rootURL: runtimeRootURL))
            })
        )
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .createFresh)
        try await waitUntil { installer.main == .done }

        for arguments in [["service", "install"], ["service", "start"]] {
            let invocation = try #require(runner.invocations.first { $0.arguments == arguments })
            #expect(invocation.executable.path == stagedLayout.binDir.appendingPathComponent("journal").path)
            assertRuntimeEnvironment(try #require(invocation.environment), layout: stagedLayout)
        }
        #expect(SolstoneRuntimeLayout.readActiveVersion(rootURL: fixtureURLs.runtimeRoot) == "\(BundleConfig.solstonePinVersion)+test-token")
        #expect(activeAtInstall.value == "\(BundleConfig.solstonePinVersion)+test-token")
        #expect(activeAtStart.value == "\(BundleConfig.solstonePinVersion)+test-token")
    }

    @Test func appManagedUpgradeRecoveryRestartsOldServiceAndReportsJournalPath() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let store = InMemoryUpgradeFailureRecordStore()
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/resolved/journal",
            newStart: .success(stderr: Data("new service failed\n".utf8), exitCode: 1)
        )
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/caller/default"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
        )
        try await waitForTerminal(installer)

        let recoveryInstall = try #require(runner.invocations.last { $0.arguments == ["service", "install"] })
        let recoveryStart = try #require(runner.invocations.last { $0.arguments == ["service", "start"] })
        #expect(recoveryInstall.executable.path == "/usr/bin/journal")
        #expect(recoveryStart.executable.path == "/usr/bin/journal")
        #expect(recoveryInstall.environment == nil)
        #expect(recoveryStart.environment == nil)
        if case .failed(.upgradeCutoverFailed(let message)) = installer.main {
            #expect(message.contains("journal: /resolved/journal"))
            #expect(message.contains("old service restart: service install/start ok"))
        } else {
            Issue.record("expected upgradeCutoverFailed")
        }
        let record = try #require(store.load())
        #expect(record.errorDetails.contains("journal: /resolved/journal"))
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
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/existing-journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )
        defer { installer.cancel() }

        _ = await installer.detect()
        try await waitUntil { installer.main == .done }

        let setup = try #require(runner.invocations.first { $0.arguments.first == "setup" })
        #expect(setup.arguments.contains("--journal"))
        #expect(setup.arguments.contains("/tmp/existing-journal"))
        #expect(setup.arguments.contains("--skip-service"))
        #expect(!setup.arguments.contains(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal").path))
    }

    @Test func appManagedUpgradeAbortsBeforeDestructiveWorkWhenJournalRootMissing() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        runner.enqueue("config", .success(stderr: Data("config failed\n".utf8), exitCode: 2))
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") },
            fileExists: { _ in false }
        )
        defer { installer.cancel() }

        _ = await installer.detect()
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

    @Test func postDetectOutdatedAutoUpgradesOnceAndReachesDone() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            solOwnershipResolver: { _ in .appManaged(solPath: "/usr/bin/sol") }
        )
        defer { installer.cancel() }

        _ = await installer.detect()
        try await waitUntil { installer.main == .done }

        #expect(!installer.upgradeInProgress)
        #expect(installer.upgradeFailureRecord == nil)
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }.count == 1)
    }

    @Test func postInstallOutdatedProbeDoesNotAutoUpgrade() async throws {
        let runner = FakeSubprocessRunner()
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        let installer = makeInstaller(runner: runner)
        defer { installer.cancel() }

        installer.start(journalURL: URL(fileURLWithPath: "/tmp/journal"), existingInstallChoice: .acceptExisting)
        try await waitUntil { installer.probedVersion == .outdated(installed: "0.3.1", pinned: BundleConfig.solstonePinVersion) }

        #expect(installer.main == .done)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
    }

    @Test func currentPinFailureRecordDoesNotSuppressAutoUpgrade() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        await installer.probeVersionAndAutoUpgrade()
        try await waitUntil { installer.main == .done }

        #expect(runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }.count == 1)
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        let card = terminalCardState(
            main: installer.main,
            probe: installer.probedVersion,
            failureRecord: installer.upgradeFailureRecord
        )
        if case .upgradeFailed = card {
            Issue.record("expected non-upgradeFailed terminal card, got \(card)")
        }
    }

    @Test func currentProbeClearsCurrentPinFailureRecord() async {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner, failureRecordStore: store)

        await installer.probeVersionAndAutoUpgrade()

        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(store.clearCallCount == 1)
    }

    @Test func currentProbeClearsStalePinFailureRecord() async {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: "0.3.7",
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner, failureRecordStore: store)

        await installer.probeVersionAndAutoUpgrade()

        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(store.clearCallCount == 1)
    }

    @Test func currentProbeWithNoFailureRecordIsNoOp() async {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(runner: runner, failureRecordStore: store)

        await installer.probeVersionAndAutoUpgrade()

        #expect(store.clearCallCount == 0)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
        #expect(installer.upgradeFailureRecord == nil)
    }

    @Test func unknownProbeWithFailureRecordIsNoOp() async {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("unparseable\n".utf8)))
        let installer = makeInstaller(runner: runner, failureRecordStore: store)

        await installer.probeVersionAndAutoUpgrade()

        #expect(installer.probedVersion == .unknown)
        #expect(store.clearCallCount == 0)
        #expect(installer.upgradeFailureRecord != nil)
        #expect(store.load() != nil)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
    }

    @Test func missingBinaryProbeWithFailureRecordIsNoOp() async {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: "details"
        ))
        let runner = FakeSubprocessRunner()
        let installer = makeInstaller(runner: runner, failureRecordStore: store, solBinaryFinder: { nil })

        await installer.probeVersionAndAutoUpgrade()

        #expect(installer.probedVersion == nil)
        #expect(store.clearCallCount == 0)
        #expect(installer.upgradeFailureRecord != nil)
        #expect(store.load() != nil)
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["tool", "install"]) })
    }

    @Test func staleUpgradeFailureRecordClearsAndAutoUpgradeFires() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.3.1",
            pinned: "0.3.7",
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        await installer.probeVersionAndAutoUpgrade()
        try await waitUntil { installer.main == .done }

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }.count == 1)
    }

    @Test func failedAutoUpgradePersistsProbedInstalledVersion() async throws {
        let store = InMemoryUpgradeFailureRecordStore(record: UpgradeFailureRecord(
            installed: "0.2.0",
            pinned: "0.3.7",
            errorDetails: "old"
        ))
        let runner = FakeSubprocessRunner()
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.8\n".utf8)))
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(stderr: Data("error: failed to download solstone\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        await installer.probeVersionAndAutoUpgrade()
        try await waitUntil {
            if case .failed = installer.main { return true }
            return false
        }

        #expect(installer.upgradeFailureRecord?.installed == "0.3.8")
        #expect(installer.upgradeFailureRecord?.pinned == BundleConfig.solstonePinVersion)
    }

    @Test func concurrentAutoUpgradeFireStartsSingleRun() async throws {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) 0.3.1\n".utf8)))
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot
        )
        defer { installer.cancel() }

        let first = Task { await installer.probeVersionAndAutoUpgrade() }
        let second = Task { await installer.probeVersionAndAutoUpgrade() }
        await first.value
        await second.value
        try await waitUntil { installer.main == .done }

        #expect(runner.invocations.filter { $0.arguments.starts(with: ["tool", "install"]) }.count == 1)
    }

    @Test func upgradeRunFailurePersistsFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success(stderr: Data("error: failed to download solstone\n".utf8), exitCode: 1))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
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
        let markerStore = InMemoryInProgressUpgradeMarkerStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(runner, resolvedJournal: "/tmp/journal")
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store,
            inProgressMarkerStore: markerStore
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
        )
        try await waitUntil { installer.main == .done }

        #expect(installer.upgradeFailureRecord == nil)
        #expect(store.load() == nil)
        #expect(markerStore.load() == nil)
        #expect(markerStore.clearCallCount >= 1)
    }

    @Test func modelsFailureDuringUpgradeDoesNotPersistFailureRecord() async throws {
        let store = InMemoryUpgradeFailureRecordStore()
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        runner.enqueue("config", .success(stdout: Data("path: /tmp/journal\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
        runner.enqueue("tool", .success())
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        runner.enqueue("service", .success(stdout: Data("Service was not installed\n".utf8)))
        runner.enqueue("ps", .success(stdout: Data()))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("lsof", .success(exitCode: 1))
        runner.enqueue("setup", .success(stdout: fixture("golden_ok")))
        runner.enqueue("service", .success())
        runner.enqueue("service", .success())
        runner.enqueue("observer", .success(stdout: observerJSON))
        runner.enqueue("install-models", .success(stderr: Data("models failed\n".utf8), exitCode: 1))
        runner.enqueue("--version", .success(stdout: Data("sol (solstone) \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            failureRecordStore: store
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
        ) == .failed(.installSolstone(message: "error: failed to download solstone")))
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

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
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
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        let finder = SequencedSolBinaryFinder([nil])
        enqueueSuccessfulBundledPythonPreflight(runner)
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
            #expect(message == "last error")
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
        enqueueSuccessfulBundledPythonPreflight(runner)
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
        let installer = makeInstaller(
            runner: runner,
            solOwnershipResolver: { _ in .externallyManaged(solPath: solPath) }
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
        inProgressMarkerStore: InProgressUpgradeMarkerStoring = InMemoryInProgressUpgradeMarkerStore(),
        runtimeVersionTokenProvider: @escaping @Sendable () -> String = { "test-token" },
        wrapperDirURL: URL? = nil,
        solBinaryFinder: @escaping @Sendable () async -> String? = { "/usr/bin/sol" },
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        fileExists: @escaping @Sendable (String) -> Bool = defaultTestFileExists,
        stagedInstallTimeout: Duration = .seconds(120),
        stagedInstallMaxAttempts: Int = 1,
        stagedInstallRetryBackoff: Duration = .zero,
        stagedVerifyTimeout: Duration = .seconds(10),
        readinessGateTimeout: Duration = .seconds(120)
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            bundledPythonURL: pythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: runner,
            failureRecordStore: failureRecordStore,
            inProgressMarkerStore: inProgressMarkerStore,
            runtimeVersionTokenProvider: runtimeVersionTokenProvider,
            wrapperDirURL: wrapperDirURL ?? makeWrapperDirURL(),
            solBinaryFinder: solBinaryFinder,
            solOwnershipResolver: solOwnershipResolver,
            connectionTester: connectionTester,
            fileExists: fileExists,
            stagedInstallTimeout: stagedInstallTimeout,
            stagedInstallMaxAttempts: stagedInstallMaxAttempts,
            stagedInstallRetryBackoff: stagedInstallRetryBackoff,
            stagedVerifyTimeout: stagedVerifyTimeout,
            readinessGateTimeout: readinessGateTimeout
        )
    }

    private func makeInstaller(
        runner: FakeSubprocessRunner,
        uvURL: URL? = nil,
        pythonURL: URL? = testBundledPythonURL,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        failureRecordStore: UpgradeFailureRecordStoring = InMemoryUpgradeFailureRecordStore(),
        inProgressMarkerStore: InProgressUpgradeMarkerStoring = InMemoryInProgressUpgradeMarkerStore(),
        runtimeVersionTokenProvider: @escaping @Sendable () -> String = { "test-token" },
        wrapperDirURL: URL? = nil,
        solBinaryFinder: @escaping @Sendable () async -> String? = { "/usr/bin/sol" },
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        fileExists: @escaping @Sendable (String) -> Bool = defaultTestFileExists,
        pidExists: @escaping @Sendable (pid_t) -> Bool,
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { _, _ in 0 },
        pidWaitTimeout: Duration = .seconds(1),
        pidWaitPollInterval: Duration = .milliseconds(1),
        orphanGracePeriod: Duration = .milliseconds(1),
        stagedInstallTimeout: Duration = .seconds(120),
        stagedInstallMaxAttempts: Int = 1,
        stagedInstallRetryBackoff: Duration = .zero,
        stagedVerifyTimeout: Duration = .seconds(10),
        readinessGateTimeout: Duration = .seconds(120)
    ) -> SolstoneInstaller {
        SolstoneInstaller(
            uvBinaryURL: uvURL,
            bundledPythonURL: pythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: runner,
            failureRecordStore: failureRecordStore,
            inProgressMarkerStore: inProgressMarkerStore,
            runtimeVersionTokenProvider: runtimeVersionTokenProvider,
            wrapperDirURL: wrapperDirURL ?? makeWrapperDirURL(),
            solBinaryFinder: solBinaryFinder,
            solOwnershipResolver: solOwnershipResolver,
            connectionTester: connectionTester,
            fileExists: fileExists,
            pidExists: pidExists,
            terminate: terminate,
            pidWaitTimeout: pidWaitTimeout,
            pidWaitPollInterval: pidWaitPollInterval,
            orphanGracePeriod: orphanGracePeriod,
            stagedInstallTimeout: stagedInstallTimeout,
            stagedInstallMaxAttempts: stagedInstallMaxAttempts,
            stagedInstallRetryBackoff: stagedInstallRetryBackoff,
            stagedVerifyTimeout: stagedVerifyTimeout,
            readinessGateTimeout: readinessGateTimeout
        )
    }

    private func waitForTerminal(_ installer: SolstoneInstaller) async throws {
        try await waitUntil {
            if case .done = installer.main { return true }
            if case .failed = installer.main { return true }
            return false
        }
    }

    private func installerAfterUpgradeReadinessFailure(
        readinessGate: FakeSubprocessRunner.Response,
        readinessGateTimeout: Duration = .seconds(120)
    ) async throws -> SolstoneInstaller {
        let runner = FakeSubprocessRunner()
        let fixtureURLs = try makeStagedInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURLs.workspace) }
        enqueueSuccessfulUpgrade(
            runner,
            resolvedJournal: "/tmp/journal",
            readinessGate: readinessGate
        )
        runner.enqueue("--version", .success(stdout: Data("solstone \(BundleConfig.solstonePinVersion)\n".utf8)))
        let installer = makeInstaller(
            runner: runner,
            wheelhouseURL: fixtureURLs.wheelhouse,
            runtimeRootURL: fixtureURLs.runtimeRoot,
            readinessGateTimeout: readinessGateTimeout
        )
        defer { installer.cancel() }

        installer.start(
            journalURL: URL(fileURLWithPath: "/tmp/journal"),
            existingInstallChoice: .createFresh,
            upgradeFromInstalledVersion: "0.3.1"
        )
        try await waitForTerminal(installer)
        return installer
    }

    private func enqueueSuccessfulUpgrade(
        _ runner: FakeSubprocessRunner,
        resolvedJournal: String = "/tmp/journal",
        psOutput: String = "",
        setupSideEffect: (@Sendable () -> Void)? = nil,
        newInstall: FakeSubprocessRunner.Response = .success(),
        newStart: FakeSubprocessRunner.Response = .success(),
        readinessGate: FakeSubprocessRunner.Response = .success(),
        observer: FakeSubprocessRunner.Response? = nil
    ) {
        runner.enqueue("config", .success(stdout: Data("path: \(resolvedJournal)\n".utf8)))
        enqueueSuccessfulBundledPythonPreflight(runner)
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
        runner.enqueue("observer", observer ?? .success(stdout: observerJSON))
        runner.enqueue("install-models", .success())
    }

    private func enqueueSuccessfulBundledPythonPreflight(_ runner: FakeSubprocessRunner) {
        runner.enqueue(
            "codesign",
            .success(stderr: Data("Identifier=app.solstone.observer.python\n".utf8))
        )
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

    private var observerJSON: Data {
        Data(#"{"name":"solstone-macos","key":"observer-key","prefix":"observer"}"#.utf8)
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

@Suite("InProgressUpgradeMarkerStore")
@MainActor
struct InProgressUpgradeMarkerStoreTests {
    @Test func userDefaultsStoreRoundTripsMarker() throws {
        let suiteName = "solstone-upgrade-marker-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsInProgressUpgradeMarkerStore(defaults: defaults)
        let marker = makeMarker()

        #expect(store.load() == nil)
        store.save(marker)
        #expect(store.load() == marker)
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func inMemoryStoreRoundTripsMarker() {
        let store = InMemoryInProgressUpgradeMarkerStore()
        let marker = makeMarker()

        #expect(store.load() == nil)
        store.save(marker)
        #expect(store.load() == marker)
        store.clear()
        #expect(store.load() == nil)
    }

    private func makeMarker() -> InProgressUpgradeMarker {
        InProgressUpgradeMarker(
            upgradeID: "upgrade-id",
            pinned: "0.3.8",
            oldVersion: "0.3.1",
            oldSolPath: "/usr/bin/sol",
            resolvedJournalPath: "/tmp/journal",
            stagedRuntimeID: "0.3.8+token",
            stagedRuntimePath: "/tmp/runtime/versions/0.3.8+token",
            phase: .settingUp
        )
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
