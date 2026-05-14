// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os
import SolstoneCore

@MainActor
@Observable
public final class SolstoneInstaller {
    public internal(set) var main: MainState = .detecting
    public internal(set) var modelsProgress: ModelsProgress = .idle
    public internal(set) var lastFailureCategory: ErrorCategory?
    public internal(set) var lastFailureLog: String?

    private weak var appState: AppState?
    private let uvBinaryURL: URL?
    private let subprocessRunner: SubprocessRunning
    private let solBinaryFinder: @Sendable () async -> String?
    private let browserOpener: @MainActor @Sendable (URL) -> Bool
    private var installTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?

    private static let localServerURL = "http://localhost:5015"
    private static let rawLogLimit = 16 * 1024
    private static let stdoutTailLimit = 2 * 1024

    public convenience init(uvBinaryURL: URL? = nil) {
        self.init(uvBinaryURL: uvBinaryURL, subprocessRunner: SubprocessRunner())
    }

    internal convenience init(
        uvBinaryURL: URL? = nil,
        subprocessRunner: SubprocessRunning = SubprocessRunner()
    ) {
        self.init(
            uvBinaryURL: uvBinaryURL,
            subprocessRunner: subprocessRunner,
            solBinaryFinder: { await SolBinaryLocator.findSolBinary() },
            browserOpener: { NSWorkspace.shared.open($0) }
        )
    }

    internal init(
        uvBinaryURL: URL? = nil,
        subprocessRunner: SubprocessRunning = SubprocessRunner(),
        solBinaryFinder: @escaping @Sendable () async -> String? = { await SolBinaryLocator.findSolBinary() },
        browserOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.uvBinaryURL = uvBinaryURL
        self.subprocessRunner = subprocessRunner
        self.solBinaryFinder = solBinaryFinder
        self.browserOpener = browserOpener
    }

    internal func attach(appState: AppState) {
        self.appState = appState
    }

    public func detect() async -> Bool {
        setMain(.detecting)
        let found = await solBinaryFinder() != nil
        setMain(.awaitingChoice(existingInstall: found))
        return found
    }

    public func start(journalURL: URL, existingInstallChoice: ExistingInstallChoice) {
        guard installTask == nil else {
            Logger.setup.warning("installer: start requested while already running")
            return
        }

        lastFailureCategory = nil
        lastFailureLog = nil
        modelsProgress = .idle
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
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
        if existingInstallChoice == .createFresh {
            guard await runInstallSolstone() else { return }
        }

        guard let solPath = await solBinaryFinder() else {
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

    private func runInstallSolstone() async -> Bool {
        let phase = "uv tool install solstone"
        setMain(.installingSolstone(SubprocessProgress(phase: phase)))

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: resolvedUVBinaryURL(),
                arguments: ["tool", "install", "solstone==\(BundleConfig.solstonePinVersion)", "--reinstall", "--refresh"],
                environment: nil,
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
            failMain(.installSolstone(message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "uv tool install subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stderr = await output.stderrString()
        let stdoutText = await output.stdoutString()
        if result.exitCode == 0 {
            return true
        }

        failMain(
            .installSolstone(message: lastUsefulLine(stderr) ?? "uv tool install solstone failed"),
            category: Self.categorize(stderr: stderr),
            logExcerpt: Self.lastUsefulLog(stdout: stdoutText, stderr: stderr)
        )
        return false
    }

    private func runSolSetup(solPath: String, journalURL: URL) async -> Bool {
        let phase = "sol setup"
        setMain(.runningSolSetup(SubprocessProgress(phase: phase)))

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: solPath),
                arguments: ["setup", "--jsonl", "--yes", "--skip-models", "--accept-existing-journal", "--journal", journalURL.path],
                environment: nil,
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
            failMain(.solSetup(errorCode: nil, message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "sol setup subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stdout = await output.stdoutString()
        let stderr = await output.stderrString()
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
                ?? "sol setup failed"
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
        let phase = "sol observer create"
        setMain(.registering(SubprocessProgress(phase: phase)))

        modelsTask = Task { [weak self] in
            await self?.runInstallModels(solPath: solPath)
        }

        async let observerSucceeded = runObserverCreate(solPath: solPath, phase: phase)
        let opened = browserOpener(URL(string: Self.localServerURL)!)
        if !opened {
            Logger.setup.warning("installer: browser open failed")
        }

        if await observerSucceeded {
            setMain(.done)
        }
    }

    private func runObserverCreate(solPath: String, phase: String) async -> Bool {
        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: solPath),
                arguments: ["observer", "--json", "create", "solstone-macos"],
                environment: nil,
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
            failMain(.registering(message: error.localizedDescription), category: .subprocessLaunch, logExcerpt: "sol observer create subprocess could not launch: \(error.localizedDescription)")
            return false
        }

        let stdout = await output.stdoutData()
        let stderr = await output.stderrString()
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
        let phase = "sol install-models"
        modelsProgress = .running(SubprocessProgress(phase: phase))

        let output = InstallerOutput()
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: URL(fileURLWithPath: solPath),
                arguments: ["install-models"],
                environment: nil,
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

        let stderr = await output.stderrString()
        if result.exitCode == 0 {
            modelsProgress = .done
        } else {
            modelsProgress = .failed(message: lastUsefulLine(stderr) ?? "sol install-models failed")
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
        config.serverURL = Self.localServerURL
        config.serverKey = key
        appState.updateConfig(config)
    }

    private func setMain(_ newState: MainState) {
        main = newState
        Logger.setup.info("installer: \(self.stateName(newState), privacy: .public)")
    }

    private func failMain(_ failedState: FailedState, category: ErrorCategory, logExcerpt: String? = nil) {
        lastFailureCategory = category
        lastFailureLog = (logExcerpt?.isEmpty == false) ? logExcerpt : nil
        let msg = Self.shortMessage(failedState)
        Logger.setup.warning("installer: failed (\(Self.failedStateName(failedState), privacy: .public)): \(msg, privacy: .public)")
        if let log = lastFailureLog {
            Logger.setup.warning("installer: failure log excerpt:\n\(log, privacy: .public)")
        }
        setMain(.failed(failedState))
    }

    nonisolated private static func shortMessage(_ failedState: FailedState) -> String {
        switch failedState {
        case .installSolstone(let message): return message
        case .solSetup(let code, let message): return code.map { "[\($0)] \(message)" } ?? message
        case .installModels(let message): return message
        case .registering(let message): return message
        }
    }

    nonisolated private static func failedStateName(_ failedState: FailedState) -> String {
        switch failedState {
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
            case .installingSolstone(let progress),
                 .runningSolSetup(let progress),
                 .registering(let progress):
                existing = progress
            default:
                existing = SubprocessProgress(phase: phase)
            }
            let updated = updatedProgress(existing, text: text, includeInTail: includeInTail)
            switch main {
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
        case .installingSolstone:
            return "installing solstone"
        case .runningSolSetup:
            return "running sol setup"
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

    nonisolated private static func append(_ data: Data, to output: InstallerOutput, stream: OutputStream) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await output.append(data, stream: stream)
            semaphore.signal()
        }
        semaphore.wait()
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

private actor InstallerOutput {
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, stream: OutputStream) {
        switch stream {
        case .stdout:
            stdout.append(data)
        case .stderr:
            stderr.append(data)
        }
    }

    func stdoutData() -> Data {
        stdout
    }

    func stdoutString() -> String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    func stderrString() -> String {
        String(data: stderr, encoding: .utf8) ?? ""
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
