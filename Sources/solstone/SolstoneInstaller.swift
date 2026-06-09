// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import os
import SolstoneCore

private let pidWaitTimeoutDefault: Duration = .seconds(10)
private let pidWaitPollIntervalDefault: Duration = .milliseconds(250)
private let orphanGracePeriodDefault: Duration = .seconds(3)
private let stagedInstallTimeoutDefault: Duration = .seconds(120)
private let stagedVerifyTimeoutDefault: Duration = .seconds(10)
private let stagedInstallMaxAttemptsDefault: Int = 3
private let stagedInstallRetryBackoffDefault: Duration = .seconds(2)
private let subprocessTimeoutGracePeriodDefault: Duration = .seconds(2)

private enum UpgradeFailureRecordBaseline: Equatable {
    case none
    case installed(String?)
}

@MainActor
@Observable
public final class SolstoneInstaller {
    public internal(set) var main: MainState = .detecting
    public internal(set) var probedVersion: VersionProbeResult?
    public internal(set) var postInstallAutoTest: AutoTestState?
    public internal(set) var modelsProgress: ModelsProgress = .idle
    public internal(set) var lastFailureCategory: ErrorCategory?
    public internal(set) var lastFailureLog: String?
    public internal(set) var lastSetupProgress: SubprocessProgress?
    public internal(set) var upgradeFailureRecord: UpgradeFailureRecord?
    /// True while the bundled-journal installer owns exclusive setup/upgrade work
    /// that should defer automatic Sparkle update checks and install activation.
    public var exclusiveOperationInProgress: Bool {
        switch main {
        case .cleaningUp, .installingSolstone, .runningSolSetup, .registering:
            return true
        case .detecting, .awaitingChoice, .externallyManaged, .done, .failed:
            return false
        }
    }

    /// Narrow app-managed journal upgrade signal used only to suppress journal
    /// liveness probing while an existing bundled runtime is being replaced.
    public internal(set) var upgradeInProgress: Bool = false

    private weak var appState: AppState?
    private let uvBinaryURL: URL?
    private let bundledPythonURL: URL?
    private let wheelhouseURL: URL?
    private let runtimeRootURL: URL
    private let subprocessRunner: SubprocessRunning
    private let failureRecordStore: UpgradeFailureRecordStoring
    private let inProgressMarkerStore: InProgressUpgradeMarkerStoring
    private let runtimeVersionTokenProvider: @Sendable () -> String
    private let wrapperDirURL: URL
    private let solBinaryFinder: @Sendable () async -> String?
    private let solOwnershipResolver: @Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership
    private let connectionTester: @Sendable (String, String) async -> String?
    private let fileExists: @Sendable (String) -> Bool
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let pidWaitTimeout: Duration
    private let pidWaitPollInterval: Duration
    private let orphanGracePeriod: Duration
    private let clock: any MonotonicClock
    private let stagedInstallTimeout: Duration
    private let stagedInstallMaxAttempts: Int
    private let stagedInstallRetryBackoff: Duration
    private let stagedVerifyTimeout: Duration
    private var detectionInFlight = false
    private var installTask: Task<Void, Never>?
    /// Test seam: whether an install/upgrade task is currently running.
    var isInstallTaskActive: Bool { installTask != nil }
    private var modelsTask: Task<Void, Never>?
    private var upgradeFailureRecordBaseline: UpgradeFailureRecordBaseline = .none

    private static let rawLogLimit = 16 * 1024
    private static let stdoutTailLimit = 2 * 1024

    public convenience init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        stagedInstallTimeout: Duration = .seconds(120),
        stagedInstallMaxAttempts: Int = 3,
        stagedInstallRetryBackoff: Duration = .seconds(2),
        stagedVerifyTimeout: Duration = .seconds(10),
        subprocessTimeoutGracePeriod: Duration = .seconds(2),
        inProgressMarkerStore: InProgressUpgradeMarkerStoring = UserDefaultsInProgressUpgradeMarkerStore(),
        runtimeVersionTokenProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    ) {
        self.init(
            uvBinaryURL: uvBinaryURL,
            bundledPythonURL: bundledPythonURL,
            wheelhouseURL: wheelhouseURL,
            runtimeRootURL: runtimeRootURL,
            subprocessRunner: SubprocessRunner(timeoutGracePeriod: subprocessTimeoutGracePeriod),
            inProgressMarkerStore: inProgressMarkerStore,
            runtimeVersionTokenProvider: runtimeVersionTokenProvider,
            wrapperDirURL: wrapperDirURL,
            stagedInstallTimeout: stagedInstallTimeout,
            stagedInstallMaxAttempts: stagedInstallMaxAttempts,
            stagedInstallRetryBackoff: stagedInstallRetryBackoff,
            stagedVerifyTimeout: stagedVerifyTimeout
        )
    }

    internal init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        wheelhouseURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        subprocessRunner: SubprocessRunning,
        failureRecordStore: UpgradeFailureRecordStoring = UserDefaultsUpgradeFailureRecordStore(),
        inProgressMarkerStore: InProgressUpgradeMarkerStoring = UserDefaultsInProgressUpgradeMarkerStore(),
        runtimeVersionTokenProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        wrapperDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true),
        solBinaryFinder: (@Sendable () async -> String?)? = nil,
        solOwnershipResolver: (@Sendable (_ hasLocalJournalCreds: Bool) async -> SolOwnership)? = nil,
        connectionTester: @escaping @Sendable (String, String) async -> String? = { url, key in
            await UploadCoordinator.testConnection(serverURL: url, serverKey: key)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        pidWaitTimeout: Duration = pidWaitTimeoutDefault,
        pidWaitPollInterval: Duration = pidWaitPollIntervalDefault,
        orphanGracePeriod: Duration = orphanGracePeriodDefault,
        clock: any MonotonicClock = SystemMonotonicClock(),
        stagedInstallTimeout: Duration = stagedInstallTimeoutDefault,
        stagedInstallMaxAttempts: Int = stagedInstallMaxAttemptsDefault,
        stagedInstallRetryBackoff: Duration = stagedInstallRetryBackoffDefault,
        stagedVerifyTimeout: Duration = stagedVerifyTimeoutDefault
    ) {
        let resolvedRuntimeRootURL = runtimeRootURL ?? SolstoneRuntimeLayout.defaultRootURL
        self.uvBinaryURL = uvBinaryURL
        self.bundledPythonURL = bundledPythonURL
        self.wheelhouseURL = wheelhouseURL
        self.runtimeRootURL = resolvedRuntimeRootURL
        self.subprocessRunner = subprocessRunner
        self.failureRecordStore = failureRecordStore
        self.inProgressMarkerStore = inProgressMarkerStore
        self.runtimeVersionTokenProvider = runtimeVersionTokenProvider
        self.wrapperDirURL = wrapperDirURL
        self.solBinaryFinder = solBinaryFinder ?? {
            Self.findAppManagedSolBinary(rootURL: resolvedRuntimeRootURL, fileExists: fileExists)
        }
        self.fileExists = fileExists
        self.solOwnershipResolver = solOwnershipResolver ?? SolOwnership.defaultResolver(
            runner: subprocessRunner,
            fileExists: fileExists,
            rootURL: resolvedRuntimeRootURL
        )
        self.connectionTester = connectionTester
        self.pidExists = pidExists
        self.terminate = terminate
        self.pidWaitTimeout = pidWaitTimeout
        self.pidWaitPollInterval = pidWaitPollInterval
        self.orphanGracePeriod = orphanGracePeriod
        self.clock = clock
        self.stagedInstallTimeout = stagedInstallTimeout
        self.stagedInstallMaxAttempts = stagedInstallMaxAttempts
        self.stagedInstallRetryBackoff = stagedInstallRetryBackoff
        self.stagedVerifyTimeout = stagedVerifyTimeout
        self.upgradeFailureRecord = failureRecordStore.load()
    }

    internal func attach(appState: AppState) {
        self.appState = appState
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
            Task { await self.probeVersionAndAutoUpgrade(solPath: solPath) }
            return true
        case .externallyManaged(let solPath):
            setMain(.externallyManaged(solPath: solPath))
            Task { await self.probeVersion(at: solPath) }
            return true
        }
    }

    public func start(
        journalURL: URL,
        existingInstallChoice: ExistingInstallChoice,
        upgradeFromInstalledVersion: String? = nil
    ) {
        let baseline = upgradeFromInstalledVersion.map { UpgradeFailureRecordBaseline.installed($0) } ?? .none
        beginInstall(journalURL: journalURL, existingInstallChoice: existingInstallChoice, upgradeFailureRecordBaseline: baseline)
    }

    internal func retryUpgradeFailure(journalURL: URL, installedVersion: String?, pinnedVersion: String) {
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
            appState?.notifyUpgradeStarted()
        } else {
            upgradeInProgress = false
            self.upgradeFailureRecordBaseline = .none
        }
        lastFailureCategory = nil
        lastFailureLog = nil
        lastSetupProgress = nil
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
        guard let config = appState?.config,
              LoopbackHost.isLocalhost(config.serverURL),
              let key = config.serverKey,
              !key.isEmpty else {
            return false
        }
        return true
    }

    private func runInstall(journalURL: URL, existingInstallChoice: ExistingInstallChoice) async {
        let existingSolPath = await solBinaryFinder()
        let setupJournalURL = journalURL
        var materializedRuntime: MaterializedRuntime?
        if existingInstallChoice == .createFresh {
            if let existingSolPath {
                await runAppManagedUpgrade(oldSolPath: existingSolPath)
                return
            } else {
                guard let runtime = await materializeBundledRuntimeForInstaller() else { return }
                materializedRuntime = runtime
            }
        }

        let solPath: String?
        if let materializedRuntime {
            solPath = materializedRuntime.layout.solBinary.path
        } else if existingInstallChoice == .createFresh {
            solPath = await solBinaryFinder()
        } else if let existingSolPath {
            solPath = existingSolPath
        } else {
            solPath = await solBinaryFinder()
        }
        guard let solPath else {
            failMain(
                .installSolstone(message: existingInstallChoice == .createFresh ? "sol binary not found after install" : "sol binary not found"),
                category: .subprocessLaunch
            )
            return
        }

        persistJournalPath(setupJournalURL)
        let journalBinary = URL(fileURLWithPath: Self.journalPath(siblingOf: solPath))
        guard await runJournalSetup(
            journalBinary: journalBinary,
            journalURL: setupJournalURL,
            layout: materializedRuntime?.layout ?? .active(rootURL: runtimeRootURL),
            skipService: true
        ) else { return }
        await enterRegistering(journalBinary: journalBinary, journalURL: setupJournalURL)
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

    private func runStagedInstall() async -> Bool {
        // L4: bypassed for app-owned child; delete in L4
        let pin = BundleConfig.solstonePinVersion
        guard let layout = await stageAndVerifySolstone(versionID: pin) else { return false }

        do {
            try layout.activate()
            Logger.setup.info("installer: activated staged solstone \(pin, privacy: .public)")
            return true
        } catch {
            failMain(.installSolstone(message: error.localizedDescription), category: .disk, logExcerpt: "failed to activate staged runtime: \(error.localizedDescription)")
            return false
        }
    }

    private func stageAndVerifySolstone(versionID: String) async -> SolstoneRuntimeLayout? {
        let phase = "uv tool install solstone"
        setMain(.installingSolstone(SubprocessProgress(phase: phase)))
        let pin = BundleConfig.solstonePinVersion
        let layout = SolstoneRuntimeLayout.staging(rootURL: runtimeRootURL, version: versionID)
        let fileManager = FileManager.default
        let versionURL = layout.versionsDir.appendingPathComponent(versionID, isDirectory: true)

        Logger.setup.info("installer: staging solstone \(pin, privacy: .public) into \(versionURL.path, privacy: .public)")
        if fileManager.fileExists(atPath: versionURL.path) {
            if SolstoneRuntimeLayout.readActiveVersion(rootURL: runtimeRootURL) == versionID {
                failMain(
                    .installSolstone(message: "cannot re-stage the active version (out of scope this lode)"),
                    category: .disk,
                    logExcerpt: "staged version directory is active: \(versionURL.path)"
                )
                return nil
            }
            do {
                try fileManager.removeItem(at: versionURL)
            } catch {
                failMain(
                    .installSolstone(message: error.localizedDescription),
                    category: .disk,
                    logExcerpt: "failed to remove stale staged version \(versionURL.path): \(error.localizedDescription)"
                )
                return nil
            }
        }

        do {
            try layout.ensureCreated()
        } catch {
            failMain(.installSolstone(message: error.localizedDescription), category: .disk, logExcerpt: "staged runtime directory setup failed: \(error.localizedDescription)")
            return nil
        }

        let pythonURL = resolvedBundledPythonURL()
        guard await preflightBundledPython(at: pythonURL) else { return nil }

        let wheelhouse = resolvedWheelhouseURL()
        let wheels: [URL]
        do {
            wheels = try fileManager.contentsOfDirectory(
                at: wheelhouse,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("solstone-\(pin)-") && name.hasSuffix(".whl")
            }
            .sorted { $0.path < $1.path }
        } catch {
            failMain(
                .installSolstone(message: "bundled wheelhouse not found at \(wheelhouse.path)"),
                category: .disk,
                logExcerpt: error.localizedDescription
            )
            return nil
        }

        guard wheels.count == 1, let projectWheel = wheels.first else {
            failMain(
                .installSolstone(message: "expected exactly one bundled solstone-\(pin)-*.whl in \(wheelhouse.path), found \(wheels.count)"),
                category: .disk
            )
            return nil
        }

        let environment = layout.uvEnvironment()
        let arguments = [
            "tool",
            "install",
            projectWheel.path,
            "--find-links",
            wheelhouse.path,
            "--no-index",
            "--offline",
            "--python",
            pythonURL.path,
            "--no-python-downloads",
            "--force"
        ]
        let maxAttempts = stagedInstallMaxAttempts
        let retryBackoff = stagedInstallRetryBackoff
        var attempt = 1
        installLoop:
        while true {
            if maxAttempts > 1 {
                Logger.setup.info("installer: uv tool install attempt \(attempt, privacy: .public) of \(maxAttempts, privacy: .public)")
            }
            let outcome = await runUVToolCommand(
                arguments: arguments,
                phase: phase,
                environment: environment,
                timeout: stagedInstallTimeout
            )
            switch outcome {
            case .ran(result: let result, stdout: _, stderr: _) where result.exitCode == 0:
                break installLoop
            case .ran(result: _, stdout: let stdout, stderr: let stderr):
                if attempt >= maxAttempts {
                    failMain(
                        .installSolstone(message: lastUsefulLine(stderr) ?? "uv tool install solstone failed"),
                        category: Self.categorize(stderr: stderr),
                        logExcerpt: Self.lastUsefulLog(stdout: stdout, stderr: stderr)
                    )
                    return nil
                }
            case .launchFailed(message: let message):
                if attempt >= maxAttempts {
                    failMain(
                        .installSolstone(message: message),
                        category: .subprocessLaunch,
                        logExcerpt: "uv tool install subprocess could not launch: \(message)"
                    )
                    return nil
                }
            }
            if retryBackoff > .zero {
                do {
                    try await Task.sleep(for: retryBackoff)
                } catch {
                    return nil
                }
            }
            attempt += 1
        }

        let installedVersion = await stagedJournalVersion(journalBinary: layout.journalBinary, environment: environment)
        guard installedVersion == pin else {
            failMain(
                .installSolstone(message: "staged solstone version mismatch"),
                category: .unknown,
                logExcerpt: "expected \(pin), got \(installedVersion ?? "unknown")"
            )
            return nil
        }

        return layout
    }

    private func stagedJournalVersion(journalBinary: URL, environment: [String: String]) async -> String? {
        await JournalHealthCheck.version(
            journalBinary: journalBinary,
            runner: subprocessRunner,
            environment: environment,
            timeout: stagedVerifyTimeout
        )
    }

    private func preflightBundledPython(at url: URL) async -> Bool {
        let path = url.path
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            failMain(.installSolstone(message: "bundled python not found at \(path)"), category: .disk)
            return false
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            failMain(.installSolstone(message: "bundled python is not executable at \(path)"), category: .permission)
            return false
        }

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["-dvvv", path],
                environment: nil,
                stdoutHandler: { data in Self.append(data, to: output, stream: .stdout) },
                stderrHandler: { data in Self.append(data, to: output, stream: .stderr) }
            )
        } catch {
            failMain(
                .installSolstone(message: error.localizedDescription),
                category: .subprocessLaunch,
                logExcerpt: "bundled python codesign check could not launch: \(error.localizedDescription)"
            )
            return false
        }

        let stdout = output.stdoutString()
        let stderr = output.stderrString()
        let codesignOutput = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard result.exitCode == 0, codesignOutput.contains("Identifier=app.solstone.observer.python") else {
            failMain(
                .installSolstone(message: "bundled python signature identifier mismatch"),
                category: .unknown,
                logExcerpt: codesignOutput
            )
            return false
        }
        return true
    }

    private enum UVToolOutcome {
        case ran(result: SubprocessResult, stdout: String, stderr: String)
        case launchFailed(message: String)
    }

    private func runUVToolCommand(
        arguments: [String],
        phase: String,
        environment: [String: String],
        timeout: Duration? = nil
    ) async -> UVToolOutcome {
        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: resolvedUVBinaryURL(),
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                stdoutHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stdout)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: true)
                    }
                },
                stderrHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stderr)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: false)
                    }
                }
            )
        } catch {
            return .launchFailed(message: error.localizedDescription)
        }
        return .ran(result: result, stdout: output.stdoutString(), stderr: output.stderrString())
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
            runner: subprocessRunner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock
        ) {
            return StopOldServiceFailure(step: failure.step, message: failure.message)
        }

        if let failure = await assertPortsReleased(ports: [7657, 5015], runner: subprocessRunner) {
            return StopOldServiceFailure(step: failure.step, message: failure.message)
        }

        return nil
    }

    private func runAppManagedUpgrade(oldSolPath: String) async {
        guard let resolved = await resolveExistingInstallJournal(oldSolPath: oldSolPath) else { return }

        // L4: bypassed for app-owned child; delete in L4
        // R3 materialization replaces versions/<id>, current activation, and upgrade markers.
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

        await enterRegistering(journalBinary: materializedRuntime.layout.journalBinary, journalURL: resolved.journalURL)
    }

    private func saveInProgressMarker(
        upgradeID: String,
        versionID: String,
        oldSolPath: String,
        resolvedJournal: URL,
        stagedLayout: SolstoneRuntimeLayout,
        phase: InProgressUpgradePhase
    ) {
        inProgressMarkerStore.save(InProgressUpgradeMarker(
            upgradeID: upgradeID,
            pinned: BundleConfig.solstonePinVersion,
            oldVersion: upgradeFailureBaselineVersion() ?? "",
            oldSolPath: oldSolPath,
            resolvedJournalPath: resolvedJournal.path,
            stagedRuntimeID: versionID,
            stagedRuntimePath: stagedLayout.rootURL.appendingPathComponent("versions/\(versionID)", isDirectory: true).path,
            phase: phase
        ))
    }

    private func snapshotWrappers() -> WrapperSnapshot {
        WrapperSnapshot(
            sol: readWrapperSnapshot(named: "sol"),
            journal: readWrapperSnapshot(named: "journal")
        )
    }

    private func readWrapperSnapshot(named name: String) -> Data? {
        let url = wrapperDirURL.appendingPathComponent(name)
        return try? Data(contentsOf: url)
    }

    private func snapshotCurrentLink() -> String? {
        let currentLink = SolstoneRuntimeLayout(rootURL: runtimeRootURL).currentLink
        return try? FileManager.default.destinationOfSymbolicLink(atPath: currentLink.path)
    }

    private func recover(
        resolvedJournal: URL,
        oldSolPath: String,
        wrapperSnapshot: WrapperSnapshot,
        currentSnapshot: String?,
        didActivate: Bool,
        underlyingDetail: String
    ) async {
        let currentResult = didActivate ? rollbackCurrentLink(to: currentSnapshot) : "not needed"
        let wrapperResult = restoreWrappers(from: wrapperSnapshot)
        // L4: bypassed for app-owned child; delete in L4
        let oldServiceResult = "bypassed for app-owned child"
        let loud = [
            "upgrade cutover failed: \(underlyingDetail)",
            "journal: \(resolvedJournal.path)",
            "wrapper restore: \(wrapperResult)",
            "current rollback: \(currentResult)",
            "old service restart: \(oldServiceResult)"
        ].joined(separator: "\n")
        failMain(.upgradeCutoverFailed(message: loud), category: .unknown, logExcerpt: loud)
    }

    private func rollbackCurrentLink(to snapshot: String?) -> String {
        let layout = SolstoneRuntimeLayout(rootURL: runtimeRootURL)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: true)
            if let snapshot {
                let tempLink = layout.rootURL.appendingPathComponent(".current.rollback-\(UUID().uuidString)")
                do {
                    try fileManager.createSymbolicLink(atPath: tempLink.path, withDestinationPath: snapshot)
                    if Darwin.rename(tempLink.path, layout.currentLink.path) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    try? fileManager.removeItem(at: tempLink)
                    throw error
                }
                return "restored \(snapshot)"
            }
            if fileManager.fileExists(atPath: layout.currentLink.path) {
                try fileManager.removeItem(at: layout.currentLink)
            }
            return "removed current"
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    private func restoreWrappers(from snapshot: WrapperSnapshot) -> String {
        let results = [
            restoreWrapper(named: "sol", data: snapshot.sol),
            restoreWrapper(named: "journal", data: snapshot.journal)
        ]
        return results.joined(separator: "; ")
    }

    private func restoreWrapper(named name: String, data: Data?) -> String {
        guard let data else { return "\(name): not snapshotted" }
        let url = wrapperDirURL.appendingPathComponent(name)
        do {
            let current = try? Data(contentsOf: url)
            guard current != data else { return "\(name): unchanged" }
            try FileManager.default.createDirectory(at: wrapperDirURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return "\(name): restored"
        } catch {
            return "\(name): failed \(error.localizedDescription)"
        }
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
        var arguments = ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", journalURL.path]
        if skipService {
            arguments.append("--skip-service")
        }
        do {
            result = try await subprocessRunner.run(
                executable: journalBinary,
                arguments: arguments,
                environment: environment,
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

    private func enterRegistering(journalBinary: URL, journalURL: URL) async {
        let phase = "journal observer create"
        setMain(.registering(SubprocessProgress(phase: phase)))

        modelsTask = Task { [weak self] in
            await self?.runInstallModels(journalBinary: journalBinary)
        }

        guard await runReadinessGate(journalBinary: journalBinary, phase: phase, journalURL: journalURL) else { return }

        if await runObserverCreate(journalBinary: journalBinary, phase: phase) {
            setMain(.done)
            clearUpgradeFailureRecord()
            inProgressMarkerStore.clear()
            Task {
                await probeVersion()
                await runPostInstallAutoTest()
            }
        }
    }

    private func runReadinessGate(journalBinary: URL, phase: String, journalURL: URL) async -> Bool {
        appendRawProgress(
            Data("starting app-owned journal child\n".utf8),
            phase: phase,
            target: .main,
            includeInTail: true
        )
        if let appState {
            let ready = await appState.ensureBundledJournalRuntime(journalRoot: journalURL)
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
        // Tests can exercise installer registration without an AppState. Production
        // always attaches AppState before installation starts, and no path may call `journal up`.
        return true
    }

    private func runObserverCreate(journalBinary: URL, phase: String) async -> Bool {
        let environment = SolstoneRuntimeLayout.active(rootURL: runtimeRootURL).uvEnvironment()
        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: journalBinary,
                arguments: ["observer", "--json", "create", "solstone-macos", "--reuse-existing"],
                environment: environment,
                stdoutHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stdout)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: true)
                    }
                },
                stderrHandler: { [weak self, output] data in
                    Self.append(data, to: output, stream: .stderr)
                    Task { @MainActor in
                        self?.appendRawProgress(data, phase: phase, target: .main, includeInTail: false)
                    }
                }
            )
        } catch {
            await failRegistering(journalBinary: journalBinary, message: error.localizedDescription, category: .subprocessLaunch, logExcerpt: "journal observer create subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stdout = output.stdoutData()
        let stderr = output.stderrString()
        guard result.exitCode == 0 else {
            await failRegistering(journalBinary: journalBinary, message: lastUsefulLine(stderr) ?? "observer create failed", category: Self.categorize(stderr: stderr), logExcerpt: Self.lastUsefulLog(stdout: String(decoding: stdout, as: UTF8.self), stderr: stderr))
            return false
        }

        do {
            let response = try JSONDecoder().decode(ObserverCreateResponse.self, from: stdout)
            persistObserverKey(response.key)
            return true
        } catch {
            await failRegistering(journalBinary: journalBinary, message: "could not parse JSON response", category: .unknown, logExcerpt: String(decoding: stdout, as: UTF8.self))
            return false
        }
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

    private func runInstallModels(journalBinary: URL) async {
        let phase = "journal install-models"
        modelsProgress = .running(SubprocessProgress(phase: phase))
        let environment = SolstoneRuntimeLayout.active(rootURL: runtimeRootURL).uvEnvironment()

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: journalBinary,
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

    private func persistObserverKey(_ key: String) {
        guard let appState else { return }
        var config = appState.config
        config.serverURL = ServiceMode.bundledServiceURL
        config.serverKey = key
        config.serviceMode = .bundled
        appState.updateConfig(config)
    }

    private func persistJournalPath(_ journalURL: URL) {
        guard let appState else { return }
        var config = appState.config
        guard config.journalPath != journalURL.path else { return }
        config.journalPath = journalURL.path
        appState.updateConfig(config)
    }

    public func probeVersion() async {
        guard let solPath = await solBinaryFinder() else {
            probedVersion = nil
            return
        }
        _ = await probeVersion(at: solPath)
    }

    @discardableResult
    private func probeVersion(at solPath: String) async -> VersionProbeResult? {
        let pinned = BundleConfig.solstonePinVersion
        let journalBinary = URL(fileURLWithPath: Self.journalPath(siblingOf: solPath))
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

    internal func probeVersionAndAutoUpgrade(solPath knownSolPath: String? = nil) async {
        if let knownSolPath {
            _ = await probeVersion(at: knownSolPath)
        } else {
            await probeVersion()
        }
        switch probedVersion {
        case .current:
            Logger.setup.notice("sol materialization decision: result=current action=none")
            if upgradeFailureRecord != nil {
                clearUpgradeFailureRecord()
            }
        case .outdated(let installed, _):
            Logger.setup.notice("sol materialization decision: result=outdated installed=\(installed, privacy: .public) pinned=\(BundleConfig.solstonePinVersion, privacy: .public) action=start-upgrade")
            start(
                journalURL: Self.defaultJournalURL(),
                existingInstallChoice: .createFresh,
                upgradeFromInstalledVersion: installed
            )
        case .unknown, .none:
            Logger.setup.notice("sol materialization decision: result=unknown action=none")
            break
        }
    }

    public func runPostInstallAutoTest() async {
        guard let appState else { return }
        let url = appState.config.serverURL ?? ""
        let key = appState.config.serverKey ?? ""
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
        do {
            let error = try await withTimeout(seconds: budgetSeconds) {
                await tester(url, key)
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

    private func upgradeFailureBaselineVersion() -> String? {
        if case .installed(let installedVersion) = upgradeFailureRecordBaseline {
            return installedVersion
        }
        return nil
    }

    private func currentMainProgress() -> SubprocessProgress? {
        switch main {
        case .cleaningUp(let progress),
             .installingSolstone(let progress),
             .runningSolSetup(let progress),
             .registering(let progress):
            return progress
        case .detecting, .awaitingChoice, .externallyManaged, .done, .failed:
            return nil
        }
    }

    private static func defaultJournalURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    }

    private nonisolated static func findAppManagedSolBinary(
        rootURL: URL,
        fileExists: @Sendable (String) -> Bool
    ) -> String? {
        SolstoneRuntimeLayout.solCandidatePaths(rootURL: rootURL).first(where: fileExists)
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

    nonisolated internal static func categorize(stderr: String) -> ErrorCategory {
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
        "upgrade pre-clean failed at \(step.displayName) — \(why)"
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

private struct WrapperSnapshot {
    let sol: Data?
    let journal: Data?
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

private struct ObserverCreateResponse: Decodable {
    let name: String
    let key: String
    let prefix: String
}

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
