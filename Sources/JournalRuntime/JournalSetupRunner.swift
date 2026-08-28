// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
import SolstoneCore

public enum JournalSetupProgressEvent: Sendable, Equatable {
    case stepStarted(step: String, index: Int?, total: Int?)
    case stepFailed(step: String?, errorCode: String?, message: String)
    case warning(step: String?, text: String, fixHint: String?)
    case completed(status: String)
}

public struct JournalSetupResult: Sendable {
    public let runtime: MaterializedRuntime
    public let stdoutTail: String
    public let renderedLog: String

    public init(runtime: MaterializedRuntime, stdoutTail: String, renderedLog: String) {
        self.runtime = runtime
        self.stdoutTail = stdoutTail
        self.renderedLog = renderedLog
    }
}

public enum JournalSetupRunnerError: Error, Equatable {
    case gateBlocked(SingleSupervisorGateBlockage)
    case materializeFailed(message: String)
    case runtimeDirectoryFailed(message: String)
    case subprocessLaunchFailed(message: String)
    case timedOut(timeout: Duration)
    case duplicateCompletion
    case setupFailed(errorCode: String?, message: String)
    case missingCompletion
}

public struct JournalSetupRunner: Sendable {
    private let subprocessRunner: any SubprocessRunning
    private let gate: any SingleSupervisorGating
    private let materializer: any RuntimeMaterializing
    private let setupTimeout: Duration

    var usesNativeRuntimeMaterializer: Bool {
        materializer is NativeJournalRuntimeMaterializer
    }

    public init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        materializer: any RuntimeMaterializing = NativeJournalRuntimeMaterializer(),
        setupTimeout: Duration = .seconds(180)
    ) {
        self.subprocessRunner = subprocessRunner
        self.gate = gate
        self.materializer = materializer
        self.setupTimeout = setupTimeout
    }

    public func run(
        journalRoot rawJournalRoot: URL,
        skipService: Bool = true,
        progress: @escaping @Sendable (JournalSetupProgressEvent) async -> Void = { _ in }
    ) async throws -> JournalSetupResult {
        let journalRoot = rawJournalRoot.standardizedFileURL

        switch await gate.prepareForSpawn(journalRoot: journalRoot) {
        case .success:
            break
        case .blocked(let blockage):
            throw JournalSetupRunnerError.gateBlocked(blockage)
        }

        let runtime: MaterializedRuntime
        do {
            runtime = try await materializer.materialize(excludingLiveKey: nil)
        } catch {
            throw JournalSetupRunnerError.materializeFailed(message: error.localizedDescription)
        }

        // Native runtime files live in the signed app bundle and can be on a
        // read-only App Translocation mount; only materialized runtimes own these directories.
        if !usesNativeRuntimeMaterializer {
            do {
                try runtime.layout.ensureCreated()
            } catch {
                throw JournalSetupRunnerError.runtimeDirectoryFailed(message: error.localizedDescription)
            }
        }

        let output = JournalSetupOutputCollector()
        let (progressStream, progressContinuation) = AsyncStream<JournalSetupProgressEvent>.makeStream()
        let progressTask = Task {
            for await event in progressStream {
                await progress(event)
            }
        }

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(
                executable: runtime.layout.journalBinary,
                arguments: JournalSetupCommand.setupArguments(journalURL: journalRoot, skipService: skipService),
                environment: runtime.environment,
                timeout: setupTimeout,
                stdoutHandler: { [output, progressContinuation] data in
                    for event in output.appendStdout(data) {
                        progressContinuation.yield(event)
                    }
                },
                stderrHandler: { [output] data in
                    output.appendStderr(data)
                }
            )
        } catch {
            finish(output: output, continuation: progressContinuation)
            await progressTask.value
            throw JournalSetupRunnerError.subprocessLaunchFailed(message: error.localizedDescription)
        }

        finish(output: output, continuation: progressContinuation)
        await progressTask.value

        let summary = output.summary()

        if result.terminationReason == .uncaughtSignal {
            throw JournalSetupRunnerError.timedOut(timeout: setupTimeout)
        }

        if summary.duplicateSetupCompleted {
            throw JournalSetupRunnerError.duplicateCompletion
        }

        let failedSetupCompleted = summary.setupCompletedStatus == "failed"
        if result.exitCode != 0 || summary.lastStepFailure != nil || failedSetupCompleted {
            let failure = summary.lastStepFailure
            let message = failure?.message
                ?? lastUsefulLine(summary.stderr)
                ?? summary.lastRenderedLine
                ?? "journal setup failed"
            throw JournalSetupRunnerError.setupFailed(errorCode: failure?.errorCode, message: message)
        }

        guard summary.setupCompletedStatus == "ok" else {
            throw JournalSetupRunnerError.missingCompletion
        }

        launchInstallModels(runtime: runtime)

        return JournalSetupResult(
            runtime: runtime,
            stdoutTail: truncate(summary.stdout, limit: Self.stdoutTailLimit),
            renderedLog: summary.renderedLog
        )
    }

    private func finish(
        output: JournalSetupOutputCollector,
        continuation: AsyncStream<JournalSetupProgressEvent>.Continuation
    ) {
        for event in output.finishParsing() {
            continuation.yield(event)
        }
        continuation.finish()
    }

    private func launchInstallModels(runtime: MaterializedRuntime) {
        let runner = subprocessRunner
        let journalBinary = runtime.layout.journalBinary
        let environment = runtime.environment
        Task {
            do {
                _ = try await runner.run(
                    executable: journalBinary,
                    arguments: ["install-models"],
                    environment: environment,
                    stdoutHandler: { _ in },
                    stderrHandler: { _ in }
                )
            } catch {
                Logger.setup.warning("journal setup runner: install-models failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let stdoutTailLimit = 16 * 1024
}

private final class JournalSetupOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var lineBuffer = ""
    private var renderer = EventRenderer()
    private var setupCompletedStatus: String?
    private var duplicateSetupCompleted = false
    private var lastStepFailure: JournalSetupStepFailure?

    func appendStdout(_ data: Data) -> [JournalSetupProgressEvent] {
        lock.withLock {
            stdout.append(data)
            lineBuffer += String(decoding: data, as: UTF8.self)
            return parseCompleteBufferedLines()
        }
    }

    func appendStderr(_ data: Data) {
        lock.withLock {
            stderr.append(data)
        }
    }

    func finishParsing() -> [JournalSetupProgressEvent] {
        lock.withLock {
            guard !lineBuffer.isEmpty else { return [] }
            let line = lineBuffer
            lineBuffer = ""
            return parse(line: line)
        }
    }

    func summary() -> JournalSetupOutputSummary {
        lock.withLock {
            JournalSetupOutputSummary(
                stdout: String(data: stdout, encoding: .utf8) ?? "",
                stderr: String(data: stderr, encoding: .utf8) ?? "",
                renderedLog: renderer.renderedLog,
                setupCompletedStatus: setupCompletedStatus,
                duplicateSetupCompleted: duplicateSetupCompleted,
                lastStepFailure: lastStepFailure,
                lastRenderedLine: lastUsefulLine(renderer.renderedLog)
            )
        }
    }

    private func parseCompleteBufferedLines() -> [JournalSetupProgressEvent] {
        var events: [JournalSetupProgressEvent] = []
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            events.append(contentsOf: parse(line: line))
        }
        return events
    }

    private func parse(line: String) -> [JournalSetupProgressEvent] {
        let parsedLine = SetupEventParser.parse(line: line)
        renderer.append(parsedLine)
        guard case .event(let event) = parsedLine else {
            return []
        }

        switch event {
        case .stepStarted(let step, let index, let total):
            return [.stepStarted(step: step, index: index, total: total)]
        case .stepFailed(let step, let errorCode, let message, _, _):
            lastStepFailure = JournalSetupStepFailure(step: step, errorCode: errorCode, message: message)
            return [.stepFailed(step: step, errorCode: errorCode, message: message)]
        case .stepWarning(let step, let text, let fixHint):
            return [.warning(step: step, text: text, fixHint: fixHint)]
        case .setupCompleted(let status, _, _):
            if setupCompletedStatus != nil {
                duplicateSetupCompleted = true
            }
            setupCompletedStatus = status
            return [.completed(status: status)]
        case .setupStarted,
             .stepCompleted,
             .doctorStarted,
             .checkCompleted,
             .doctorCompleted:
            return []
        }
    }
}

private struct JournalSetupOutputSummary {
    let stdout: String
    let stderr: String
    let renderedLog: String
    let setupCompletedStatus: String?
    let duplicateSetupCompleted: Bool
    let lastStepFailure: JournalSetupStepFailure?
    let lastRenderedLine: String?
}

private struct JournalSetupStepFailure {
    let step: String?
    let errorCode: String?
    let message: String
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
