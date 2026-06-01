// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Darwin
import os
import SolstoneCore

private let pidWaitTimeoutDefault: Duration = .seconds(10)
private let pidWaitPollIntervalDefault: Duration = .milliseconds(250)
private let orphanGracePeriodDefault: Duration = .seconds(3)

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
    public internal(set) var upgradeInProgress: Bool = false

    private weak var appState: AppState?
    private let uvBinaryURL: URL?
    private let bundledPythonURL: URL?
    private let subprocessRunner: SubprocessRunning
    private let failureRecordStore: UpgradeFailureRecordStoring
    private let solBinaryFinder: @Sendable () async -> String?
    private let connectionTester: @Sendable (String, String) async -> String?
    private let fileExists: @Sendable (String) -> Bool
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let pidWaitTimeout: Duration
    private let pidWaitPollInterval: Duration
    private let orphanGracePeriod: Duration
    private var installTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var upgradingFromInstalledVersion: String?

    private static let rawLogLimit = 16 * 1024
    private static let stdoutTailLimit = 2 * 1024

    public convenience init(uvBinaryURL: URL? = nil, bundledPythonURL: URL? = nil) {
        self.init(uvBinaryURL: uvBinaryURL, bundledPythonURL: bundledPythonURL, subprocessRunner: SubprocessRunner())
    }

    internal convenience init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        subprocessRunner: SubprocessRunning = SubprocessRunner()
    ) {
        self.init(
            uvBinaryURL: uvBinaryURL,
            bundledPythonURL: bundledPythonURL,
            subprocessRunner: subprocessRunner,
            solBinaryFinder: { await SolBinaryLocator.findSolBinary() }
        )
    }

    internal init(
        uvBinaryURL: URL? = nil,
        bundledPythonURL: URL? = nil,
        subprocessRunner: SubprocessRunning = SubprocessRunner(),
        failureRecordStore: UpgradeFailureRecordStoring = UserDefaultsUpgradeFailureRecordStore(),
        solBinaryFinder: @escaping @Sendable () async -> String? = { await SolBinaryLocator.findSolBinary() },
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
        orphanGracePeriod: Duration = orphanGracePeriodDefault
    ) {
        self.uvBinaryURL = uvBinaryURL
        self.bundledPythonURL = bundledPythonURL
        self.subprocessRunner = subprocessRunner
        self.failureRecordStore = failureRecordStore
        self.solBinaryFinder = solBinaryFinder
        self.connectionTester = connectionTester
        self.fileExists = fileExists
        self.pidExists = pidExists
        self.terminate = terminate
        self.pidWaitTimeout = pidWaitTimeout
        self.pidWaitPollInterval = pidWaitPollInterval
        self.orphanGracePeriod = orphanGracePeriod
        self.upgradeFailureRecord = failureRecordStore.load()
    }

    internal func attach(appState: AppState) {
        self.appState = appState
    }

    public func detect() async -> Bool {
        setMain(.detecting)
        let found = await solBinaryFinder() != nil
        setMain(.awaitingChoice(existingInstall: found))
        if found {
            Task { await self.probeVersionAndAutoUpgrade() }
        }
        return found
    }

    public func start(
        journalURL: URL,
        existingInstallChoice: ExistingInstallChoice,
        upgradeFromInstalledVersion: String? = nil
    ) {
        guard installTask == nil else {
            Logger.setup.warning("installer: start requested while already running")
            return
        }

        if let upgradeFromInstalledVersion {
            clearUpgradeFailureRecord()
            upgradeInProgress = true
            upgradingFromInstalledVersion = upgradeFromInstalledVersion
            appState?.notifyUpgradeStarted()
        } else {
            upgradeInProgress = false
            upgradingFromInstalledVersion = nil
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
                self.upgradingFromInstalledVersion = nil
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

    private func runInstall(journalURL: URL, existingInstallChoice: ExistingInstallChoice) async {
        let existingSolPath = await solBinaryFinder()
        if existingInstallChoice == .createFresh {
            if let existingSolPath {
                guard await runUpgradePreclean(solPath: existingSolPath) else { return }
            }
            guard await runInstallSolstone() else { return }
        }

        let solPath: String?
        if existingInstallChoice == .createFresh {
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

        guard await runSolSetup(solPath: solPath, journalURL: journalURL) else { return }
        await enterRegistering(solPath: solPath)
    }

    private func resolvedUVBinaryURL() -> URL {
        uvBinaryURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uv")
    }

    private func resolvedBundledPythonURL() -> URL {
        bundledPythonURL ?? SolstoneRuntimeLayout.bundledPythonURL()
    }

    private func runInstallSolstone() async -> Bool {
        let phase = "uv tool install solstone"
        setMain(.installingSolstone(SubprocessProgress(phase: phase)))
        let layout = SolstoneRuntimeLayout()
        do {
            try layout.ensureCreated()
        } catch {
            failMain(.installSolstone(message: error.localizedDescription), category: .disk, logExcerpt: "runtime directory setup failed: \(error.localizedDescription)")
            return false
        }

        let pythonURL = resolvedBundledPythonURL()
        guard await preflightBundledPython(at: pythonURL) else { return false }

        let legacyToolURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/uv/tools/solstone", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyToolURL.path) {
            Logger.setup.info("installer: detected legacy uv tool state at \(legacyToolURL.path, privacy: .public); installing into \(layout.rootURL.path, privacy: .public)")
        }
        let environment = layout.uvEnvironment()

        guard let uninstall = await runUVToolCommand(
            arguments: ["tool", "uninstall", "solstone"],
            phase: phase,
            launchDescription: "uv tool uninstall",
            environment: environment
        ) else {
            return false
        }
        if uninstall.result.exitCode != 0 && !Self.uvUninstallNotInstalled(stderr: uninstall.stderr) {
            failMain(
                .installSolstone(message: lastUsefulLine(uninstall.stderr) ?? "uv tool uninstall solstone failed"),
                category: Self.categorize(stderr: uninstall.stderr),
                logExcerpt: Self.lastUsefulLog(stdout: uninstall.stdout, stderr: uninstall.stderr)
            )
            return false
        }

        guard let install = await runUVToolCommand(
            arguments: ["tool", "install", "solstone==\(BundleConfig.solstonePinVersion)", "--refresh", "--python", pythonURL.path],
            phase: phase,
            launchDescription: "uv tool install",
            environment: environment
        ) else {
            return false
        }

        if install.result.exitCode == 0 {
            return true
        }

        failMain(
            .installSolstone(message: lastUsefulLine(install.stderr) ?? "uv tool install solstone failed"),
            category: Self.categorize(stderr: install.stderr),
            logExcerpt: Self.lastUsefulLog(stdout: install.stdout, stderr: install.stderr)
        )
        return false
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

    private func runUVToolCommand(
        arguments: [String],
        phase: String,
        launchDescription: String,
        environment: [String: String]
    ) async -> (result: SubprocessResult, stdout: String, stderr: String)? {
        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: resolvedUVBinaryURL(),
                arguments: arguments,
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
            failMain(.installSolstone(message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "\(launchDescription) subprocess could not launch: \(error.localizedDescription)")
            return nil
        }
        return (result, output.stdoutString(), output.stderrString())
    }

    private func runUpgradePreclean(solPath: String) async -> Bool {
        let phase = "upgrade pre-clean"
        setMain(.cleaningUp(SubprocessProgress(phase: phase)))
        Logger.setup.info("starting upgrade pre-clean")

        let configJournalBinaryPath = SolBinaryLocator.journalPath(siblingOf: solPath)
        let configUseJournal = fileExists(configJournalBinaryPath)
        let configExecPath = configUseJournal ? configJournalBinaryPath : solPath
        let configLabel = "\(configUseJournal ? "journal" : "sol") config show"

        let configOutput = InstallerOutput()
        let configResult: SubprocessResult
        do {
            configResult = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: configExecPath),
                arguments: ["config", "show"],
                environment: nil,
                stdoutHandler: { data in Self.append(data, to: configOutput, stream: .stdout) },
                stderrHandler: { data in Self.append(data, to: configOutput, stream: .stderr) }
            )
        } catch {
            failCleanup(step: .resolveJournal, why: error.localizedDescription, category: .subprocessLaunch, logExcerpt: "\(configLabel) subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let configStdout = configOutput.stdoutString()
        let configStderr = configOutput.stderrString()
        guard configResult.exitCode == 0 else {
            failCleanup(
                step: .resolveJournal,
                why: lastUsefulLine(configStderr) ?? "\(configLabel) exited \(configResult.exitCode)",
                category: Self.categorize(stderr: configStderr),
                logExcerpt: Self.lastUsefulLog(stdout: configStdout, stderr: configStderr)
            )
            return false
        }
        guard let journalPath = parseJournalPath(from: configStdout) else {
            failCleanup(step: .resolveJournal, why: "could not find the journal", category: .unknown, logExcerpt: configStdout)
            return false
        }

        let pidURL = URL(fileURLWithPath: journalPath, isDirectory: true)
            .appendingPathComponent("health/supervisor.pid")
        let capturedPid = readSupervisorPID(from: pidURL)

        do {
            let journalPath = SolBinaryLocator.journalPath(siblingOf: solPath)
            let useJournal = fileExists(journalPath)
            let uninstallExecPath = useJournal ? journalPath : solPath
            let uninstallArguments = ["service", "uninstall"]
            let uninstallLabel = "\(useJournal ? "journal" : "sol") \(uninstallArguments.joined(separator: " "))"

            let uninstallOutput = InstallerOutput()
            let uninstallResult: SubprocessResult
            do {
                uninstallResult = try await subprocessRunner.run(
                    executable: URL(fileURLWithPath: uninstallExecPath),
                    arguments: uninstallArguments,
                    environment: nil,
                    stdoutHandler: { data in Self.append(data, to: uninstallOutput, stream: .stdout) },
                    stderrHandler: { data in Self.append(data, to: uninstallOutput, stream: .stderr) }
                )
            } catch {
                failCleanup(step: .serviceUninstall, why: error.localizedDescription, category: .subprocessLaunch, logExcerpt: "\(uninstallLabel) subprocess could not launch: \(error.localizedDescription)")
                return false
            }
            let uninstallStdout = uninstallOutput.stdoutString()
            let uninstallStderr = uninstallOutput.stderrString()
            guard uninstallResult.exitCode == 0 else {
                failCleanup(
                    step: .serviceUninstall,
                    why: lastUsefulLine(uninstallStderr) ?? "\(uninstallLabel) exited \(uninstallResult.exitCode)",
                    category: Self.categorize(stderr: uninstallStderr),
                    logExcerpt: Self.lastUsefulLog(stdout: uninstallStdout, stderr: uninstallStderr)
                )
                return false
            }
        }

        if let capturedPid {
            let clock = ContinuousClock()
            let deadline = clock.now + pidWaitTimeout
            while clock.now < deadline {
                if !pidExists(capturedPid) { break }
                try? await Task.sleep(for: pidWaitPollInterval)
            }
            if pidExists(capturedPid) {
                failCleanup(step: .waitForDeath, why: "supervisor pid \(capturedPid) still alive after 10s", category: .unknown)
                return false
            }
        }

        if let failure = await runInstallerOrphanSweep(
            runner: subprocessRunner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod
        ) {
            failCleanup(step: failure.step, why: failure.message, category: .unknown)
            return false
        }

        for port in [7657, 5015] {
            let result: SubprocessResult
            do {
                result = try await subprocessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                    arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
                    environment: nil,
                    stdoutHandler: { _ in },
                    stderrHandler: { _ in }
                )
            } catch {
                failCleanup(step: .ports, why: "lsof failed to launch probing port \(port)", category: .subprocessLaunch, logExcerpt: error.localizedDescription)
                return false
            }

            switch result.exitCode {
            case 1:
                continue
            case 0:
                failCleanup(step: .ports, why: "port \(port) still bound after sweep", category: .unknown)
                return false
            default:
                failCleanup(step: .ports, why: "lsof exited \(result.exitCode) probing port \(port)", category: .unknown)
                return false
            }
        }

        return true
    }

    private func failCleanup(step: CleanupStep, why: String, category: ErrorCategory, logExcerpt: String? = nil) {
        failMain(.cleanup(step: step, message: Self.cleanupFailureMessage(step: step, why: why)), category: category, logExcerpt: logExcerpt)
    }

    private func runSolSetup(solPath: String, journalURL: URL) async -> Bool {
        let journalPath = SolBinaryLocator.journalPath(siblingOf: solPath)
        let phase = "journal setup"
        setMain(.runningSolSetup(SubprocessProgress(phase: phase)))
        let layout = SolstoneRuntimeLayout()
        do {
            try layout.ensureCreated()
        } catch {
            failMain(.solSetup(errorCode: nil, message: error.localizedDescription), category: .disk, logExcerpt: "runtime directory setup failed: \(error.localizedDescription)")
            return false
        }
        let environment = layout.uvEnvironment()

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: journalPath),
                arguments: ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", journalURL.path],
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

    private func enterRegistering(solPath: String) async {
        let phase = "journal observer create"
        setMain(.registering(SubprocessProgress(phase: phase)))

        modelsTask = Task { [weak self] in
            await self?.runInstallModels(solPath: solPath)
        }

        if await runObserverCreate(solPath: solPath, phase: phase) {
            setMain(.done)
            clearUpgradeFailureRecord()
            Task {
                await probeVersion()
                await runPostInstallAutoTest()
            }
        }
    }

    private func runObserverCreate(solPath: String, phase: String) async -> Bool {
        let journalPath = SolBinaryLocator.journalPath(siblingOf: solPath)
        let environment = SolstoneRuntimeLayout().uvEnvironment()
        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: journalPath),
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
            failMain(.registering(message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "journal observer create subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stdout = output.stdoutData()
        let stderr = output.stderrString()
        guard result.exitCode == 0 else {
            failMain(.registering(message: lastUsefulLine(stderr) ?? "observer create failed"), category: Self.categorize(stderr: stderr), logExcerpt: Self.lastUsefulLog(stdout: String(decoding: stdout, as: UTF8.self), stderr: stderr))
            return false
        }

        do {
            let response = try JSONDecoder().decode(ObserverCreateResponse.self, from: stdout)
            persistObserverKey(response.key)
            return true
        } catch {
            failMain(.registering(message: "could not parse JSON response"), category: .unknown, logExcerpt: String(decoding: stdout, as: UTF8.self))
            return false
        }
    }

    private func runInstallModels(solPath: String) async {
        let journalPath = SolBinaryLocator.journalPath(siblingOf: solPath)
        let phase = "journal install-models"
        modelsProgress = .running(SubprocessProgress(phase: phase))
        let environment = SolstoneRuntimeLayout().uvEnvironment()

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: journalPath),
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

    public func probeVersion() async {
        guard let solPath = await solBinaryFinder() else {
            probedVersion = nil
            return
        }
        guard let installed = await SolHealthCheck.version(solPath: solPath, runner: subprocessRunner) else {
            probedVersion = .unknown
            return
        }
        let pinned = BundleConfig.solstonePinVersion
        let comparison = installed.compare(pinned, options: .numeric)
        if comparison == .orderedAscending {
            probedVersion = .outdated(installed: installed, pinned: pinned)
        } else {
            probedVersion = .current(version: installed)
        }
    }

    internal func probeVersionAndAutoUpgrade() async {
        await probeVersion()
        switch probedVersion {
        case .current:
            if upgradeFailureRecord != nil {
                clearUpgradeFailureRecord()
            }
        case .outdated(let installed, _):
            start(
                journalURL: Self.defaultJournalURL(),
                existingInstallChoice: .createFresh,
                upgradeFromInstalledVersion: installed
            )
        case .unknown, .none:
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

    private func failMain(_ failedState: FailedState, category: ErrorCategory, logExcerpt: String? = nil) {
        lastFailureCategory = category
        lastFailureLog = (logExcerpt?.isEmpty == false) ? logExcerpt : nil
        lastSetupProgress = currentMainProgress()
        if let upgradingFromInstalledVersion {
            persistUpgradeFailure(installed: upgradingFromInstalledVersion, details: lastFailureLog)
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
             .registering(let progress):
            return progress
        case .detecting, .awaitingChoice, .done, .failed:
            return nil
        }
    }

    private static func defaultJournalURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("journal")
    }

    private func persistUpgradeFailure(installed: String, details: String?) {
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
        }
    }

    nonisolated private static func failedStateName(_ failedState: FailedState) -> String {
        switch failedState {
        case .cleanup: return "cleanup"
        case .installSolstone: return "installSolstone"
        case .solSetup: return "solSetup"
        case .installModels: return "installModels"
        case .registering: return "registering"
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

    nonisolated private static func uvUninstallNotInstalled(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("is not installed") || lower.contains("not currently installed")
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

private struct CleanupFailure {
    let step: CleanupStep
    let message: String
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

private func runInstallerOrphanSweep(
    runner: SubprocessRunning,
    pidExists: @Sendable (pid_t) -> Bool,
    terminate: @Sendable (pid_t, Int32) -> Int32,
    gracePeriod: Duration
) async -> CleanupFailure? {
    let output = InstallerOutput()
    let result: SubprocessResult
    do {
        result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,comm="],
            environment: nil,
            stdoutHandler: { data in
                output.append(data, stream: .stdout)
            },
            stderrHandler: { _ in }
        )
    } catch {
        return CleanupFailure(step: .orphanSweep, message: "ps failed to launch")
    }

    guard result.exitCode == 0 else {
        return CleanupFailure(step: .orphanSweep, message: "ps exited \(result.exitCode)")
    }

    let pids = parsePsOrphanRows(output.stdoutString())
    var termCount = 0
    for pid in pids {
        _ = terminate(pid, SIGTERM)
        termCount += 1
    }

    try? await Task.sleep(for: gracePeriod)

    let survivors = pids.filter(pidExists)
    for pid in survivors {
        _ = terminate(pid, SIGKILL)
    }

    Logger.setup.info("preclean orphan sweep parsed=\(pids.count, privacy: .public) term=\(termCount, privacy: .public) survivors=\(survivors.count, privacy: .public)")
    return nil
}

private func readSupervisorPID(from url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int32(trimmed), value > 0 else { return nil }
    return pid_t(value)
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
