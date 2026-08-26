// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import os
import SolstoneCore

private let pidWaitTimeoutDefault: Duration = .seconds(10)
private let pidWaitPollIntervalDefault: Duration = .milliseconds(250)
private let orphanGracePeriodDefault: Duration = .seconds(3)
private let subprocessTimeoutGracePeriodDefault: Duration = .seconds(2)
private let observerRegistrationRetryBudget: Duration = .seconds(90)
private let observerRegistrationRetryBackoffs: [Duration] = [
    .milliseconds(500),
    .seconds(1),
    .seconds(2),
    .seconds(4),
    .seconds(8)
]

private enum UpgradeFailureRecordBaseline: Equatable {
    case none
    case installed(String?)
}

@MainActor
@Observable
public final class SolstoneInstaller {
    public var main: MainState = .detecting
    public var probedVersion: VersionProbeResult?
    public var postInstallAutoTest: AutoTestState?
    public var modelsProgress: ModelsProgress = .idle
    public var lastFailureCategory: ErrorCategory?
    public var lastFailureLog: String?
    public var lastSetupProgress: SubprocessProgress?
    public var integrityWarningMessage: String?
    public var upgradeFailureRecord: UpgradeFailureRecord?
    /// True while the bundled-journal installer owns exclusive setup/upgrade work
    /// that should defer automatic Sparkle update checks and install activation.
    public var exclusiveOperationInProgress: Bool {
        switch main {
        case .cleaningUp, .installingSolstone, .runningSolSetup, .verifyingIntegrity, .registering:
            return true
        case .detecting, .awaitingChoice, .externallyManaged, .done, .failed:
            return false
        }
    }

    /// Narrow app-managed journal upgrade signal used only to suppress journal
    /// liveness probing while an existing bundled runtime is being replaced.
    public var upgradeInProgress: Bool = false

    private weak var host: InstallerHost?
    private let uvBinaryURL: URL?
    private let bundledPythonURL: URL?
    private let wheelhouseURL: URL?
    private let runtimeRootURL: URL
    private let subprocessRunner: SubprocessRunning
    private let failureRecordStore: UpgradeFailureRecordStoring
    private let wrapperDirURL: URL
    private let solBinaryFinder: @Sendable () async -> String?
    private let solOwnershipResolver: @Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership
    private let connectionTester: (@Sendable (String, String) async -> String?)?
    private let observerRegistrar: ObserverRegistrar
    private let fileExists: @Sendable (String) -> Bool
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let pidWaitTimeout: Duration
    private let pidWaitPollInterval: Duration
    private let orphanGracePeriod: Duration
    private let journalSetupTimeout: Duration
    private let journalWarmTimeout: Duration
    private let clock: any MonotonicClock
    private let sleep: @Sendable (Duration) async throws -> Void
    private var detectionInFlight = false
    private var installTask: Task<Void, Never>?
    /// Test seam: whether an install/upgrade task is currently running.
    public var isInstallTaskActive: Bool { installTask != nil }
    private var modelsTask: Task<Void, Never>?
    private var upgradeFailureRecordBaseline: UpgradeFailureRecordBaseline = .none

    private static let rawLogLimit = 16 * 1024
    private static let stdoutTailLimit = 2 * 1024

    public convenience init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        observerRegistrar: @escaping ObserverRegistrar,
        subprocessTimeoutGracePeriod: Duration = .seconds(2),
        journalSetupTimeout: Duration = .seconds(180),
        journalWarmTimeout: Duration = .seconds(120),
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    ) {
        self.init(
            uvBinaryURL: uvBinaryURL,
            bundledPythonURL: bundledPythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: SubprocessRunner(timeoutGracePeriod: subprocessTimeoutGracePeriod),
            wrapperDirURL: wrapperDirURL,
            observerRegistrar: observerRegistrar,
            journalSetupTimeout: journalSetupTimeout,
            journalWarmTimeout: journalWarmTimeout
        )
    }

    public init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        subprocessRunner: SubprocessRunning,
        failureRecordStore: UpgradeFailureRecordStoring = UserDefaultsUpgradeFailureRecordStore(),
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        solBinaryFinder: (@Sendable () async -> String?)? = nil,
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: (@Sendable (String, String) async -> String?)? = nil,
        observerRegistrar: @escaping ObserverRegistrar,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        pidWaitTimeout: Duration = .seconds(10),
        pidWaitPollInterval: Duration = .milliseconds(250),
        orphanGracePeriod: Duration = .seconds(3),
        journalSetupTimeout: Duration = .seconds(180),
        journalWarmTimeout: Duration = .seconds(120),
        clock: any MonotonicClock = SystemMonotonicClock(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        let resolvedRuntimeRootURL = runtimeRootURL ?? SolstoneRuntimeLayout.defaultRootURL
        self.uvBinaryURL = uvBinaryURL
        self.bundledPythonURL = bundledPythonURL
        self.wheelhouseURL = wheelhouseURL
        self.runtimeRootURL = resolvedRuntimeRootURL
        self.subprocessRunner = subprocessRunner
        self.failureRecordStore = failureRecordStore
        self.wrapperDirURL = wrapperDirURL
        self.solBinaryFinder = solBinaryFinder ?? {
            let ownership = await SolOwnership.defaultResolver(
                runner: subprocessRunner,
                fileExists: fileExists,
                rootURL: resolvedRuntimeRootURL
            )(false)
            if case .appManaged(let solPath) = ownership {
                return solPath
            }
            return nil
        }
        self.fileExists = fileExists
        self.solOwnershipResolver = solOwnershipResolver ?? SolOwnership.defaultResolver(
            runner: subprocessRunner,
            fileExists: fileExists,
            rootURL: resolvedRuntimeRootURL
        )
        self.connectionTester = connectionTester
        self.observerRegistrar = observerRegistrar
        self.pidExists = pidExists
        self.terminate = terminate
        self.pidWaitTimeout = pidWaitTimeout
        self.pidWaitPollInterval = pidWaitPollInterval
        self.orphanGracePeriod = orphanGracePeriod
        self.journalSetupTimeout = journalSetupTimeout
        self.journalWarmTimeout = journalWarmTimeout
        self.clock = clock
        self.sleep = sleep
        self.upgradeFailureRecord = failureRecordStore.load()
    }

    public func attach(host: InstallerHost) {
        self.host = host
    }

    public func detect() async -> Bool {
        guard !detectionInFlight else { return true }
        detectionInFlight = true
        defer { detectionInFlight = false }

        setMain(.detecting)
        let ownership = await solOwnershipResolver(hasLocalJournalCreds())
        switch ownership {
        case .absent:
            setMain(.awaitingChoice(existingInstall: false))
            return false
        case .appManaged(let solPath):
            setMain(.awaitingChoice(existingInstall: true))
            Task {
                let result = await self.probeVersion(at: solPath)
                if case .current = result, self.upgradeFailureRecord != nil {
                    self.clearUpgradeFailureRecord()
                }
            }
            return true
        case .externallyManaged(let solPath):
            setMain(.externallyManaged(solPath: solPath))
            Task { await self.probeVersion(at: solPath) }
            return true
        }
    }

    public func start(
        journalURL: URL,
        existingInstallChoice: ExistingInstallChoice
    ) {
        beginInstall(journalURL: journalURL, existingInstallChoice: existingInstallChoice, upgradeFailureRecordBaseline: .none)
    }

    public func retryUpgradeFailure(journalURL: URL, installedVersion: String?, pinnedVersion: String) {
        if let installedVersion, installedVersion != pinnedVersion {
            beginInstall(
                journalURL: journalURL,
                existingInstallChoice: .createFresh,
                upgradeFailureRecordBaseline: .installed(installedVersion)
            )
            return
        }

        beginInstall(
            journalURL: journalURL,
            existingInstallChoice: .acceptExisting,
            upgradeFailureRecordBaseline: .installed(installedVersion)
        )
    }

    private func beginInstall(
        journalURL: URL,
        existingInstallChoice: ExistingInstallChoice,
        upgradeFailureRecordBaseline: UpgradeFailureRecordBaseline
    ) {
        guard installTask == nil else {
            Logger.setup.warning("installer: start requested while already running")
            return
        }

        if upgradeFailureRecordBaseline != .none {
            clearUpgradeFailureRecord()
            upgradeInProgress = true
            self.upgradeFailureRecordBaseline = upgradeFailureRecordBaseline
            host?.notifyInstallerUpgradeStarted()
        } else {
            upgradeInProgress = false
            self.upgradeFailureRecordBaseline = .none
        }
        lastFailureCategory = nil
        lastFailureLog = nil
        lastSetupProgress = nil
        integrityWarningMessage = nil
        modelsProgress = .idle
        installTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.installTask = nil
                self.upgradeInProgress = false
                self.upgradeFailureRecordBaseline = .none
            }
            await self.runInstall(journalURL: journalURL, existingInstallChoice: existingInstallChoice)
        }
    }

    public func cancel() {
        Logger.setup.info("installer: cancelling")
        installTask?.cancel()
        modelsTask?.cancel()
        subprocessRunner.cancelAll()
    }

    private func hasLocalJournalCreds() -> Bool {
        guard let config = host?.installerConfig,
              BundledJournalEndpoint.isBundledServiceURL(config.serverURL),
              let key = config.serverKey,
              !key.isEmpty else {
            return false
        }
        return true
    }

    private func runInstall(journalURL: URL, existingInstallChoice: ExistingInstallChoice) async {
        let existingSolPath = await solBinaryFinder()
        let setupJournalURL = journalURL
        let materializedRuntime: MaterializedRuntime
        switch existingInstallChoice {
        case .createFresh:
            if let existingSolPath {
                await runAppManagedUpgrade(oldSolPath: existingSolPath)
                return
            }
            guard let runtime = await materializeBundledRuntimeForInstaller() else { return }
            materializedRuntime = runtime
        case .acceptExisting:
            guard existingSolPath != nil else {
                failMain(
                    .installSolstone(message: "sol binary not found"),
                    category: .subprocessLaunch
                )
                return
            }
            // Accept-existing adopts the pinned app-managed runtime; materialize reuses a verified on-disk layout.
            guard let runtime = await materializeBundledRuntimeForInstaller() else { return }
            materializedRuntime = runtime
        }

        persistJournalPath(setupJournalURL)
        guard await runJournalSetup(
            journalBinary: materializedRuntime.layout.journalBinary,
            journalURL: setupJournalURL,
            layout: materializedRuntime.layout,
            skipService: true
        ) else { return }
        await enterRegistering(runtime: materializedRuntime, journalURL: setupJournalURL)
    }

    private func resolvedUVBinaryURL() -> URL {
        uvBinaryURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uv")
    }

    private func resolvedBundledPythonURL() -> URL {
        bundledPythonURL ?? SolstoneRuntimeLayout.bundledPythonURL()
    }

    private func resolvedWheelhouseURL() -> URL {
        wheelhouseURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/wheelhouse", isDirectory: true)
    }

    private func materializeBundledRuntimeForInstaller() async -> MaterializedRuntime? {
        setMain(.installingSolstone(SubprocessProgress(phase: "materialize bundled journal")))
        do {
            return try await RuntimeMaterializer(
                runtimeRootURL: runtimeRootURL,
                uvBinaryURL: resolvedUVBinaryURL(),
                bundledPythonURL: resolvedBundledPythonURL(),
                wheelhouseURL: resolvedWheelhouseURL(),
                wrapperDirURL: wrapperDirURL,
                runner: subprocessRunner
            ).materialize(excludingLiveKey: nil)
        } catch {
            failMain(
                .installSolstone(message: UICopy.JOURNAL_MATERIALIZE_FAILED),
                category: .unknown,
                logExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            )
            return nil
        }
    }

    private func resolveExistingInstallJournal(oldSolPath: String) async -> (journalURL: URL, supervisorPID: pid_t?)? {
        let phase = "upgrade pre-clean"
        setMain(.cleaningUp(SubprocessProgress(phase: phase)))
        Logger.setup.info("resolving existing journal before upgrade")

        let configJournalBinaryPath = Self.journalPath(siblingOf: oldSolPath)
        guard fileExists(configJournalBinaryPath) else {
            failCleanup(
                step: .resolveJournal,
                why: UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE,
                category: .unknown,
                logExcerpt: sanitizeJournalDiagnosticOutput("journal binary missing at \(configJournalBinaryPath)")
            )
            return nil
        }
        let configLabel = "journal config show"

        let configOutput = InstallerOutput()
        let configResult: SubprocessResult
        do {
            configResult = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: configJournalBinaryPath),
                arguments: ["config", "show"],
                environment: nil,
                stdoutHandler: { data in Self.append(data, to: configOutput, stream: .stdout) },
                stderrHandler: { data in Self.append(data, to: configOutput, stream: .stderr) }
            )
        } catch {
            failCleanup(
                step: .resolveJournal,
                why: error.localizedDescription,
                category: .subprocessLaunch,
                logExcerpt: sanitizeJournalDiagnosticOutput("\(configLabel) subprocess could not launch: \(error.localizedDescription)")
            )
            return nil
        }

        let configStdout = configOutput.stdoutString()
        let configStderr = configOutput.stderrString()
        guard configResult.exitCode == 0 else {
            failCleanup(
                step: .resolveJournal,
                why: lastUsefulLine(configStderr) ?? "\(configLabel) exited \(configResult.exitCode)",
                category: Self.categorize(stderr: configStderr),
                logExcerpt: sanitizeJournalDiagnosticOutput(Self.lastUsefulLog(stdout: configStdout, stderr: configStderr))
            )
            return nil
        }
        guard let resolvedJournalPath = parseJournalPath(from: configStdout) else {
            failCleanup(
                step: .resolveJournal,
                why: "could not find the journal",
                category: .unknown,
                logExcerpt: sanitizeJournalDiagnosticOutput(configStdout)
            )
            return nil
        }

        let resolvedJournalURL = URL(fileURLWithPath: resolvedJournalPath, isDirectory: true)
        let pidURL = resolvedJournalURL
            .appendingPathComponent("health/supervisor.pid")
        let capturedPid = readSupervisorPID(from: pidURL)

        return (resolvedJournalURL, capturedPid)
    }

    private func stopOldService(oldSolPath: String, journalURL: URL, supervisorPID: pid_t?) async -> StopOldServiceFailure? {
        let phase = "upgrade pre-clean"
        setMain(.cleaningUp(SubprocessProgress(phase: phase)))
        Logger.setup.info("stopping old service for upgrade journal \(journalURL.path, privacy: .public)")

        let journalPath = Self.journalPath(siblingOf: oldSolPath)
        guard fileExists(journalPath) else {
            return StopOldServiceFailure(
                step: .serviceUninstall,
                message: UICopy.JOURNAL_SETUP_NEEDED_BEFORE_UPGRADE,
                logExcerpt: sanitizeJournalDiagnosticOutput("journal binary missing at \(journalPath)")
            )
        }
        let uninstallArguments = ["service", "uninstall"]
        let uninstallLabel = "journal \(uninstallArguments.joined(separator: " "))"

        let uninstallOutput = InstallerOutput()
        let uninstallResult: SubprocessResult
        do {
            uninstallResult = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: journalPath),
                arguments: uninstallArguments,
                environment: nil,
                stdoutHandler: { data in Self.append(data, to: uninstallOutput, stream: .stdout) },
                stderrHandler: { data in Self.append(data, to: uninstallOutput, stream: .stderr) }
            )
        } catch {
            return StopOldServiceFailure(
                step: .serviceUninstall,
                message: error.localizedDescription,
                logExcerpt: sanitizeJournalDiagnosticOutput("\(uninstallLabel) subprocess could not launch: \(error.localizedDescription)")
            )
        }
        let uninstallStdout = uninstallOutput.stdoutString()
        let uninstallStderr = uninstallOutput.stderrString()
        guard uninstallResult.exitCode == 0 else {
            return StopOldServiceFailure(
                step: .serviceUninstall,
                message: lastUsefulLine(uninstallStderr) ?? "\(uninstallLabel) exited \(uninstallResult.exitCode)",
                logExcerpt: sanitizeJournalDiagnosticOutput(Self.lastUsefulLog(stdout: uninstallStdout, stderr: uninstallStderr))
            )
        }

        if let capturedPid = supervisorPID {
            let exited = await waitForPIDExit(
                pid: capturedPid,
                timeout: pidWaitTimeout,
                pollInterval: pidWaitPollInterval,
                pidExists: pidExists,
                clock: clock
            )
            if !exited {
                return StopOldServiceFailure(step: .waitForDeath, message: "supervisor pid \(capturedPid) still alive after 10s")
            }
        }

        if let failure = await runJournalOrphanSweep(
            journalRoot: journalURL,
            runner: subprocessRunner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock
        ) {
            return StopOldServiceFailure(step: failure.step, message: failure.message)
        }

        let directDoorPortResolution = resolveJournalDirectDoorPort(journalRoot: journalURL)
        if let failure = await assertPortsReleased(resolution: directDoorPortResolution, runner: subprocessRunner) {
            return StopOldServiceFailure(step: failure.step, message: failure.message)
        }

        return nil
    }

    private func runAppManagedUpgrade(oldSolPath: String) async {
        guard let resolved = await resolveExistingInstallJournal(oldSolPath: oldSolPath) else { return }

        if let failure = await stopOldService(oldSolPath: oldSolPath, journalURL: resolved.journalURL, supervisorPID: resolved.supervisorPID) {
            let detail = [
                Self.cleanupFailureMessage(step: failure.step, why: failure.message),
                failure.logExcerpt
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            failMain(.upgradeCutoverFailed(message: detail), category: .unknown, logExcerpt: detail)
            return
        }

        guard let materializedRuntime = await materializeBundledRuntimeForInstaller() else { return }
        persistJournalPath(resolved.journalURL)
        guard await runJournalSetup(
            journalBinary: materializedRuntime.layout.journalBinary,
            journalURL: resolved.journalURL,
            layout: materializedRuntime.layout,
            skipService: true
        ) else {
            return
        }

        await enterRegistering(runtime: materializedRuntime, journalURL: resolved.journalURL)
    }

    private func failCleanup(step: CleanupStep, why: String, category: ErrorCategory, logExcerpt: String? = nil) {
        failMain(.cleanup(step: step, message: Self.cleanupFailureMessage(step: step, why: why)), category: category, logExcerpt: logExcerpt)
    }

    private func runJournalSetup(
        journalBinary: URL,
        journalURL: URL,
        layout: SolstoneRuntimeLayout,
        skipService: Bool
    ) async -> Bool {
        let phase = "journal setup"
        setMain(.runningSolSetup(SubprocessProgress(phase: phase)))
        do {
            try layout.ensureCreated()
        } catch {
            failMain(.solSetup(errorCode: nil, message: error.localizedDescription), category: .disk, logExcerpt: "runtime directory setup failed: \(error.localizedDescription)")
            return false
        }
        let environment = layout.uvEnvironment()

        let output = InstallerOutput()
        let result: SubprocessResult
        let arguments = JournalSetupCommand.setupArguments(journalURL: journalURL, skipService: skipService)
        do {
            result = try await subprocessRunner.run(
                executable: journalBinary,
                arguments: arguments,
                environment: environment,
                timeout: journalSetupTimeout,
                stdoutHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stdout)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: true)
                    }
                },
                stderrHandler: { [output] data in
                    Self.append(data, to: output, stream: .stderr)
                }
            )
        } catch {
            failMain(.solSetup(errorCode: nil, message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "journal setup subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stdout = output.stdoutString()
        let stderr = output.stderrString()
        let parsed = parseSetupOutput(stdout, phase: phase)
        setMain(.runningSolSetup(parsed.progress))

        if result.terminationReason == .uncaughtSignal {
            let message = "journal setup timed out after \(journalSetupTimeout)"
            failMain(
                .solSetup(errorCode: "setup-timeout", message: message),
                category: .subprocessLaunch,
                logExcerpt: parsed.progress.renderedLog
            )
            return false
        }

        if let duplicateMessage = parsed.duplicateSetupCompletedMessage {
            failMain(.solSetup(errorCode: nil, message: duplicateMessage), category: .unknown, logExcerpt: parsed.progress.renderedLog)
            return false
        }

        let failedSetupCompleted = parsed.setupCompletedStatus == "failed"
        if result.exitCode != 0 || parsed.lastStepFailure != nil || failedSetupCompleted {
            let failure = parsed.lastStepFailure
            let message = failure?.message
                ?? lastUsefulLine(stderr)
                ?? parsed.lastRenderedLine
                ?? "journal setup failed"
            failMain(
                .solSetup(errorCode: failure?.errorCode, message: message),
                category: Self.categorize(stderr: stderr),
                logExcerpt: parsed.progress.renderedLog
            )
            return false
        }

        guard parsed.setupCompletedStatus == "ok" else {
            failMain(.solSetup(errorCode: nil, message: "setup did not emit setup.completed"), category: .unknown, logExcerpt: parsed.progress.renderedLog)
            return false
        }

        return true
    }

    private func enterRegistering(runtime: MaterializedRuntime, journalURL: URL) async {
        let journalBinary = runtime.layout.journalBinary
        await runJournalWarm(runtime: runtime)

        let phase = "journal observer create"
        setMain(.registering(SubprocessProgress(phase: phase)))

        modelsTask = Task { [weak self] in
            await self?.runInstallModels(runtime: runtime)
        }

        guard await runReadinessGate(runtime: runtime, phase: phase, journalURL: journalURL) else { return }

        if await runObserverCreate(journalBinary: journalBinary, phase: phase) {
            setMain(.done)
            clearUpgradeFailureRecord()
            UserDefaults.standard.removeObject(forKey: "SolstoneInProgressUpgradeMarker")
            Task {
                await probeVersion(journalBinary: journalBinary)
                await runPostInstallAutoTest()
            }
        }
    }

    private func runJournalWarm(runtime: MaterializedRuntime) async {
        let phase = "journal warm"
        setMain(.verifyingIntegrity(SubprocessProgress(phase: phase)))

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: runtime.layout.journalBinary,
                arguments: ["warm"],
                environment: runtime.layout.uvEnvironment(),
                timeout: journalWarmTimeout,
                stdoutHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stdout)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: true)
                    }
                },
                stderrHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stderr)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: true)
                    }
                }
            )
        } catch {
            recordWarmWarning(stdout: "", stderr: error.localizedDescription)
            return
        }

        if result.terminationReason == .uncaughtSignal {
            let reason = "warm-timeout: journal warm timed out after \(journalWarmTimeout)"
            Logger.setup.notice("installer: journal warm timeout; continuing detail=\(reason, privacy: .public)")
            recordWarmWarning(stdout: output.stdoutString(), stderr: reason)
            return
        }

        guard result.exitCode == 0 else {
            recordWarmWarning(stdout: output.stdoutString(), stderr: output.stderrString())
            return
        }
    }

    private func recordWarmWarning(stdout: String, stderr: String) {
        let library = Self.failedWarmLibrary(stdout: stdout, stderr: stderr)
        let detail = sanitizeJournalDiagnosticOutput(
            lastUsefulLine([stderr, stdout].joined(separator: "\n")) ?? "journal warm failed"
        ) ?? "journal warm failed"
        integrityWarningMessage = UICopy.installerVerifyIntegrityWarning(library: library)
        Logger.setup.warning("installer: journal warm failed; continuing library=\(library, privacy: .public) detail=\(detail, privacy: .public)")
    }

    private nonisolated static func failedWarmLibrary(stdout: String, stderr: String) -> String {
        let output = [stderr, stdout].joined(separator: "\n")
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = valueAfterPrefix("library=", in: line)
                ?? valueAfterPrefix("library:", in: line)
                ?? valueAfterPrefix("library ", in: line) {
                return sanitizeWarmLibraryName(value)
            }
        }
        return "a required library"
    }

    private nonisolated static func valueAfterPrefix(_ prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix, options: [.caseInsensitive]) else {
            return nil
        }
        return String(line[range.upperBound...])
    }

    private nonisolated static func sanitizeWarmLibraryName(_ value: String) -> String {
        let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;()[]{}\"'"))
        let firstToken = value
            .components(separatedBy: delimiters)
            .first(where: { !$0.isEmpty }) ?? ""
        let sanitized = firstToken
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            .prefix(80)
        return sanitized.isEmpty ? "a required library" : String(sanitized)
    }

    private func runReadinessGate(runtime: MaterializedRuntime, phase: String, journalURL: URL) async -> Bool {
        let journalBinary = runtime.layout.journalBinary
        appendRawProgress(
            Data("starting app-owned journal child\n".utf8),
            phase: phase,
            target: .main,
            includeInTail: true
        )
        if let host {
            let ready = await host.ensureBundledJournalRuntime(journalRoot: journalURL)
            if ready {
                return true
            }
            await failRegistering(
                journalBinary: journalBinary,
                message: UICopy.INSTALLER_READINESS_GATE_FAILED,
                category: .unknown,
                logExcerpt: "app-owned journal child did not become ready"
            )
            return false
        }
        // Tests can exercise installer registration without a host. Production
        // always attaches a host before installation starts, and no path may call `journal up`.
        return true
    }

    private func runObserverCreate(journalBinary: URL, phase _: String) async -> Bool {
        if host?.installerConfig.isUploadConfigured == true {
            return true
        }

        let hostname = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = ObserverRegistrationDescriptor(
            platform: "darwin",
            hostname: hostname.isEmpty ? "unknown" : hostname,
            streamType: "desktop",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        let deadline = clock.now() + observerRegistrationRetryBudget
        var attempt = 0
        var lastTransientFailure: ObserverRegistrationFailure?
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                return false
            }
            if let lastTransientFailure, clock.now() >= deadline {
                await failRegistering(
                    journalBinary: journalBinary,
                    message: lastTransientFailure.message,
                    category: lastTransientFailure.category,
                    logExcerpt: lastTransientFailure.logExcerpt
                )
                return false
            }

            switch await observerRegistrar(descriptor) {
            case .success(let registration):
                persistObserverRegistration(registration)
                return true
            case .failure(let failure):
                guard failure.retryableConnection else {
                    await failRegistering(
                        journalBinary: journalBinary,
                        message: failure.message,
                        category: failure.category,
                        logExcerpt: failure.logExcerpt
                    )
                    return false
                }
                lastTransientFailure = failure

                guard clock.now() < deadline else {
                    await failRegistering(
                        journalBinary: journalBinary,
                        message: failure.message,
                        category: failure.category,
                        logExcerpt: failure.logExcerpt
                    )
                    return false
                }

                do {
                    try Task.checkCancellation()
                    try await sleep(Self.observerRegistrationBackoff(attempt: attempt))
                    try Task.checkCancellation()
                } catch {
                    return false
                }
                attempt += 1
            }
        }
    }

    private nonisolated static func observerRegistrationBackoff(attempt: Int) -> Duration {
        if attempt < observerRegistrationRetryBackoffs.count {
            return observerRegistrationRetryBackoffs[attempt]
        }
        return .seconds(15)
    }

    private func failRegistering(journalBinary: URL, message: String, category: ErrorCategory, logExcerpt: String?) async {
        let baseline: UpgradeFailureRecordBaseline?
        if upgradeFailureRecordBaseline != .none {
            let installed = await JournalHealthCheck.version(journalBinary: journalBinary, runner: subprocessRunner)
            baseline = .installed(installed)
        } else {
            baseline = nil
        }
        failMain(
            .registering(message: message),
            category: category,
            logExcerpt: logExcerpt,
            upgradeFailureRecordInstalled: baseline
        )
    }

    private func runInstallModels(runtime: MaterializedRuntime) async {
        let phase = "journal install-models"
        modelsProgress = .running(SubprocessProgress(phase: phase))
        let environment = runtime.layout.uvEnvironment()

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: runtime.layout.journalBinary,
                arguments: ["install-models"],
                environment: environment,
                stdoutHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stdout)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .models, includeInTail: true)
                    }
                },
                stderrHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stderr)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .models, includeInTail: false)
                    }
                }
            )
        } catch {
            modelsProgress = .failed(message: error.localizedDescription)
            return
        }

        let stderr = output.stderrString()
        if result.exitCode == 0 {
            modelsProgress = .done
        } else {
            modelsProgress = .failed(message: lastUsefulLine(stderr) ?? "journal install-models failed")
        }
    }

    private func parseSetupOutput(_ stdout: String, phase: String) -> ParsedSetupOutput {
        var renderer = EventRenderer()
        var currentStep: String?
        var stepIndex: Int?
        var stepTotal: Int?
        var setupCompletedStatus: String?
        var duplicateMessage: String?
        var lastStepFailure: StepFailure?

        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(line)
            let parsedLine = SetupEventParser.parse(line: rawLine)
            renderer.append(parsedLine)

            guard case .event(let event) = parsedLine else {
                if !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Logger.setup.debug("setup-jsonl[unparsed]: \(rawLine, privacy: .public)")
                }
                continue
            }

            switch event {
            case .stepStarted(let step, let index, let total):
                currentStep = step
                stepIndex = index
                stepTotal = total
                let idx = index.map(String.init) ?? "?"
                let tot = total.map(String.init) ?? "?"
                Logger.setup.info("setup-step started: \(step, privacy: .public) (\(idx, privacy: .public)/\(tot, privacy: .public))")
            case .stepFailed(let step, let errorCode, let message, _, _):
                lastStepFailure = StepFailure(step: step, errorCode: errorCode, message: message)
                let s = step ?? "<unknown>"
                let code = errorCode ?? "<none>"
                Logger.setup.warning("setup-step failed: \(s, privacy: .public) code=\(code, privacy: .public) msg=\(message, privacy: .public)")
            case .setupCompleted(let status, _, _):
                if setupCompletedStatus != nil {
                    duplicateMessage = "setup emitted duplicate setup.completed"
                }
                setupCompletedStatus = status
                Logger.setup.info("setup-completed: status=\(status, privacy: .public)")
            case .doctorCompleted(let status, _, let summary):
                if let summary {
                    Logger.setup.info("doctor-completed: status=\(status, privacy: .public) failed=\(summary.failed) warnings=\(summary.warnings) skipped=\(summary.skipped)")
                } else {
                    Logger.setup.info("doctor-completed: status=\(status, privacy: .public) (no summary)")
                }
            case .checkCompleted(let name, _, let status, let detail, _):
                if status == "failed" || status == "warning" {
                    let det = detail ?? ""
                    Logger.setup.warning("doctor-check \(status, privacy: .public): \(name, privacy: .public) - \(det, privacy: .public)")
                }
            default:
                break
            }
        }

        let renderedLog = renderer.renderedLog
        return ParsedSetupOutput(
            progress: SubprocessProgress(
                phase: phase,
                renderedLog: renderedLog,
                stdoutTail: truncate(stdout, limit: Self.stdoutTailLimit),
                currentStep: currentStep,
                stepIndex: stepIndex,
                stepTotal: stepTotal
            ),
            setupCompletedStatus: setupCompletedStatus,
            duplicateSetupCompletedMessage: duplicateMessage,
            lastStepFailure: lastStepFailure,
            lastRenderedLine: lastUsefulLine(renderedLog)
        )
    }

    private func persistObserverRegistration(_ registration: ObserverRegistration) {
        guard let host else { return }
        var config = host.installerConfig
        config.serverURL = ServiceMode.bundledServiceURL
        config.serverKey = registration.key
        config.observerName = registration.name
        config.serviceMode = .bundled
        host.updateInstallerConfig(config)
    }

    private func persistJournalPath(_ journalURL: URL) {
        guard let host else { return }
        var config = host.installerConfig
        guard config.journalPath != journalURL.path else { return }
        config.journalPath = journalURL.path
        host.updateInstallerConfig(config)
    }

    public func probeVersion() async {
        guard let solPath = await solBinaryFinder() else {
            probedVersion = .unknown
            Logger.setup.notice("journal version probe: no sol binary located by finder pinned=\(BundleConfig.solstonePinVersion, privacy: .public)")
            return
        }
        _ = await probeVersion(at: solPath)
    }

    @discardableResult
    private func probeVersion(at solPath: String) async -> VersionProbeResult? {
        let journalBinary = URL(fileURLWithPath: Self.journalPath(siblingOf: solPath))
        return await probeVersion(journalBinary: journalBinary)
    }

    @discardableResult
    private func probeVersion(journalBinary: URL) async -> VersionProbeResult? {
        let pinned = BundleConfig.solstonePinVersion
        guard let installed = await JournalHealthCheck.version(journalBinary: journalBinary, runner: subprocessRunner) else {
            probedVersion = .unknown
            Logger.setup.notice("journal version probe: journalPath=\(journalBinary.path, privacy: .public) unknown pinned=\(pinned, privacy: .public)")
            return probedVersion
        }
        let comparison = installed.compare(pinned, options: .numeric)
        if comparison == .orderedAscending {
            probedVersion = .outdated(installed: installed, pinned: pinned)
        } else {
            probedVersion = .current(version: installed)
        }
        let resultText: String = {
            switch probedVersion {
            case .outdated(let i, let p):
                return "outdated installed=\(i) pinned=\(p)"
            case .current(let v):
                return "current installed=\(v)"
            case .unknown:
                return "unknown"
            case .none:
                return "none"
            }
        }()
        Logger.setup.notice("journal version probe: journalPath=\(journalBinary.path, privacy: .public) \(resultText, privacy: .public) pinned=\(BundleConfig.solstonePinVersion, privacy: .public)")
        return probedVersion
    }

    public func runPostInstallAutoTest() async {
        guard let host else { return }
        let url = host.installerConfig.serverURL ?? ""
        let key = host.installerConfig.serverKey ?? ""
        guard !url.isEmpty, !key.isEmpty else {
            postInstallAutoTest = .failure("missing journal credentials")
            return
        }

        postInstallAutoTest = .verifying
        let firstAttempt = await attemptConnectionTest(url: url, key: key, budgetSeconds: 5.0)
        switch firstAttempt {
        case .success:
            postInstallAutoTest = .success
            return
        case .failure(let message):
            postInstallAutoTest = .failure(message)
            return
        case .timeout:
            break
        }

        let retry = await attemptConnectionTest(url: url, key: key, budgetSeconds: 5.0)
        switch retry {
        case .success:
            postInstallAutoTest = .success
        case .failure(let message):
            postInstallAutoTest = .failure(message)
        case .timeout:
            postInstallAutoTest = .failure("timed out")
        }
    }

    private enum ConnectionTestAttemptResult {
        case success
        case failure(String)
        case timeout
    }

    private func attemptConnectionTest(url: String, key: String, budgetSeconds: Double) async -> ConnectionTestAttemptResult {
        let tester = self.connectionTester
        let host = self.host
        do {
            let error = try await withTimeout(seconds: budgetSeconds) {
                if let tester {
                    return await tester(url, key)
                }
                guard let host else { return nil }
                return await host.testInstallerConnection(serverURL: url, serverKey: key)
            }
            if let error {
                return .failure(error)
            }
            return .success
        } catch is TimeoutError {
            return .timeout
        } catch {
            return .failure("connection failed")
        }
    }

    private func setMain(_ newState: MainState) {
        if case .installingSolstone = newState {
            probedVersion = nil
            postInstallAutoTest = nil
        }
        main = newState
        Logger.setup.info("installer: \(self.stateName(newState), privacy: .public)")
    }

    private func failMain(
        _ failedState: FailedState,
        category: ErrorCategory,
        logExcerpt: String? = nil,
        upgradeFailureRecordInstalled: UpgradeFailureRecordBaseline? = nil
    ) {
        lastFailureCategory = category
        lastFailureLog = (logExcerpt?.isEmpty == false) ? logExcerpt : nil
        lastSetupProgress = currentMainProgress()
        let baseline = upgradeFailureRecordInstalled ?? upgradeFailureRecordBaseline
        if case .installed(let installedVersion) = baseline {
            persistUpgradeFailure(installed: installedVersion, details: lastFailureLog)
        }
        let msg = Self.shortMessage(failedState)
        Logger.setup.warning("installer: failed (\(Self.failedStateName(failedState), privacy: .public)): \(msg, privacy: .public)")
        if let log = lastFailureLog {
            Logger.setup.warning("installer: failure log excerpt:\n\(log, privacy: .public)")
        }
        setMain(.failed(failedState))
    }

    private func currentMainProgress() -> SubprocessProgress? {
        switch main {
        case .cleaningUp(let progress),
             .installingSolstone(let progress),
             .runningSolSetup(let progress),
             .verifyingIntegrity(let progress),
             .registering(let progress):
            return progress
        case .detecting, .awaitingChoice, .externallyManaged, .done, .failed:
            return nil
        }
    }

    private static func defaultJournalURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    }

    private nonisolated static func journalPath(siblingOf solPath: String) -> String {
        URL(fileURLWithPath: solPath)
            .deletingLastPathComponent()
            .appendingPathComponent("journal")
            .path
    }

    private func persistUpgradeFailure(installed: String?, details: String?) {
        let record = UpgradeFailureRecord(
            installed: installed,
            pinned: BundleConfig.solstonePinVersion,
            errorDetails: details ?? ""
        )
        upgradeFailureRecord = record
        failureRecordStore.save(record)
    }

    internal func clearUpgradeFailureRecord() {
        upgradeFailureRecord = nil
        failureRecordStore.clear()
    }

    nonisolated private static func shortMessage(_ failedState: FailedState) -> String {
        switch failedState {
        case .cleanup(_, let message): return message
        case .installSolstone(let message): return message
        case .solSetup(let code, let message): return code.map { "[\($0)] \(message)" } ?? message
        case .installModels(let message): return message
        case .registering(let message): return message
        case .upgradeCutoverFailed(let message): return message
        }
    }

    nonisolated private static func failedStateName(_ failedState: FailedState) -> String {
        switch failedState {
        case .cleanup: return "cleanup"
        case .installSolstone: return "installSolstone"
        case .solSetup: return "solSetup"
        case .installModels: return "installModels"
        case .registering: return "registering"
        case .upgradeCutoverFailed: return "upgradeCutoverFailed"
        }
    }

    private func appendRawProgress(_ data: Data, phase: String, target: ProgressTarget, includeInTail: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        switch target {
        case .main:
            let existing: SubprocessProgress
            switch main {
            case .cleaningUp(let progress),
                 .installingSolstone(let progress),
                 .runningSolSetup(let progress),
                 .verifyingIntegrity(let progress),
                 .registering(let progress):
                existing = progress
            default:
                existing = SubprocessProgress(phase: phase)
            }
            let updated = updatedProgress(existing, text: text, includeInTail: includeInTail)
            switch main {
            case .cleaningUp:
                main = .cleaningUp(updated)
            case .installingSolstone:
                main = .installingSolstone(updated)
            case .runningSolSetup:
                main = .runningSolSetup(updated)
            case .verifyingIntegrity:
                main = .verifyingIntegrity(updated)
            case .registering:
                main = .registering(updated)
            default:
                break
            }
        case .models:
            let existing: SubprocessProgress
            if case .running(let progress) = modelsProgress {
                existing = progress
            } else {
                existing = SubprocessProgress(phase: phase)
            }
            modelsProgress = .running(updatedProgress(existing, text: text, includeInTail: includeInTail))
        }
    }

    private func updatedProgress(_ progress: SubprocessProgress, text: String, includeInTail: Bool) -> SubprocessProgress {
        SubprocessProgress(
            phase: progress.phase,
            renderedLog: truncate(progress.renderedLog + text, limit: Self.rawLogLimit),
            stdoutTail: includeInTail ? truncate(progress.stdoutTail + text, limit: Self.stdoutTailLimit) : progress.stdoutTail,
            currentStep: progress.currentStep,
            stepIndex: progress.stepIndex,
            stepTotal: progress.stepTotal
        )
    }

    private func stateName(_ state: MainState) -> String {
        switch state {
        case .detecting:
            return "detecting"
        case .awaitingChoice(let existingInstall):
            return "awaiting choice existingInstall=\(existingInstall)"
        case .cleaningUp:
            return "cleaning up"
        case .installingSolstone:
            return "installing solstone"
        case .runningSolSetup:
            return "running journal setup"
        case .verifyingIntegrity:
            return "verifying integrity"
        case .registering:
            return "registering"
        case .externallyManaged:
            return "externally managed"
        case .done:
            return "done"
        case .failed:
            return "failed"
        }
    }

    public nonisolated static func categorize(stderr: String) -> ErrorCategory {
        let lowercased = stderr.lowercased()
        if lowercased.contains("launch failed") {
            return .subprocessLaunch
        }
        if lowercased.contains("permission denied") || lowercased.contains("operation not permitted") {
            return .permission
        }
        if lowercased.contains("no space left") ||
            lowercased.contains("disk full") ||
            lowercased.contains("i/o error") ||
            lowercased.contains("read-only file system") {
            return .disk
        }
        if lowercased.contains("dns") ||
            lowercased.contains("connection refused") ||
            lowercased.contains("could not resolve") ||
            lowercased.contains("network is unreachable") ||
            lowercased.contains("timed out") ||
            timeoutLooksNetworkRelated(lowercased) {
            return .network
        }
        return .unknown
    }

    nonisolated internal static func lastUsefulLog(stdout: String, stderr: String) -> String? {
        // Prefer the tail of stderr (errors usually here), fall back to stdout tail.
        let combined = (stderr.isEmpty ? stdout : stderr)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(20)
        let joined = combined.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }


    nonisolated private static func timeoutLooksNetworkRelated(_ value: String) -> Bool {
        guard value.contains("timeout") else { return false }
        return value.contains("http://") ||
            value.contains("https://") ||
            value.contains("dns") ||
            value.contains("connect") ||
            value.contains("network")
    }

    nonisolated private static func cleanupFailureMessage(step: CleanupStep, why: String) -> String {
        "upgrade pre-clean failed at \(step.displayName): \(why)"
    }

    nonisolated private static func append(_ data: Data, to output: InstallerOutput, stream: OutputStream) {
        output.append(data, stream: stream)
    }
}

private enum ProgressTarget {
    case main
    case models
}

private enum OutputStream: Sendable {
    case stdout
    case stderr
}

private struct StopOldServiceFailure {
    let step: CleanupStep
    let message: String
    let logExcerpt: String?

    init(step: CleanupStep, message: String, logExcerpt: String? = nil) {
        self.step = step
        self.message = message
        self.logExcerpt = logExcerpt
    }
}

private final class InstallerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, stream: OutputStream) {
        lock.withLock {
            switch stream {
            case .stdout:
                stdout.append(data)
            case .stderr:
                stderr.append(data)
            }
        }
    }

    func stdoutData() -> Data {
        lock.withLock { stdout }
    }

    func stdoutString() -> String {
        lock.withLock { String(data: stdout, encoding: .utf8) ?? "" }
    }

    func stderrString() -> String {
        lock.withLock { String(data: stderr, encoding: .utf8) ?? "" }
    }
}

private struct ParsedSetupOutput {
    let progress: SubprocessProgress
    let setupCompletedStatus: String?
    let duplicateSetupCompletedMessage: String?
    let lastStepFailure: StepFailure?
    let lastRenderedLine: String?
}

private struct StepFailure {
    let step: String?
    let errorCode: String?
    let message: String
}

public struct ObserverRegistrationDescriptor: Encodable, Sendable, Equatable {
    public let platform: String
    public let hostname: String
    public let streamType: String
    public let version: String

    public init(platform: String, hostname: String, streamType: String, version: String) {
        self.platform = platform
        self.hostname = hostname
        self.streamType = streamType
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case hostname
        case streamType = "stream_type"
        case version
    }
}

public struct ObserverRegistrationFailure: Error, Sendable, Equatable {
    public let category: ErrorCategory
    public let message: String
    public let logExcerpt: String?
    public let retryableConnection: Bool

    public init(
        category: ErrorCategory,
        message: String,
        logExcerpt: String?,
        retryableConnection: Bool = false
    ) {
        self.category = category
        self.message = message
        self.logExcerpt = logExcerpt
        self.retryableConnection = retryableConnection
    }
}

public struct ObserverRegistration: Sendable, Equatable {
    public let key: String
    public let name: String?

    public init(key: String, name: String?) {
        self.key = key
        self.name = name
    }
}

public typealias ObserverRegistrar = @Sendable (ObserverRegistrationDescriptor) async -> Result<ObserverRegistration, ObserverRegistrationFailure>

private func truncate(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.suffix(limit))
}

private func lastUsefulLine(_ value: String) -> String? {
    var lines = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let last = lines.last {
        if last.isEmpty {
            lines.removeLast()
            continue
        }
        return last
    }
    return nil
}
