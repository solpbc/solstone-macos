// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

public protocol JournalRequiredModelsReconciling: Sendable {
    func reconcile(runtime: MaterializedRuntime, journalRoot: URL) async throws
}

/// Reconcile the installed model cache against this signed runtime before starting it.
/// The native command checks existing bytes and repairs only bundled required assets.
public struct JournalRequiredModelsReconciler: JournalRequiredModelsReconciling {
    private let makeRunner: @Sendable (URL) -> any SubprocessRunning
    private let timeout: Duration

    public init(timeout: Duration = .seconds(120)) {
        self.timeout = timeout
        makeRunner = { SubprocessRunner(currentDirectoryURL: $0) }
    }

    init(
        timeout: Duration = .seconds(120),
        makeRunner: @escaping @Sendable (URL) -> any SubprocessRunning
    ) {
        self.timeout = timeout
        self.makeRunner = makeRunner
    }

    public func reconcile(runtime: MaterializedRuntime, journalRoot: URL) async throws {
        let runner = makeRunner(journalRoot)
        var environment = runtime.environment
        // Select this journal through cwd, without an inherited journal override.
        environment.removeValue(forKey: "SOLSTONE_JOURNAL")
        let inheritedPath = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = runtime.layout.binDir.path + ":" + inheritedPath
        let commandEnvironment = environment
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            try await runner.run(
                executable: runtime.layout.journalBinary,
                arguments: ["install-models", "--required-only"],
                environment: commandEnvironment,
                timeout: timeout,
                stdoutHandler: { data in
                    Logger.journal.info("required models: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                },
                stderrHandler: { data in
                    Logger.journal.warning("required models: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                }
            )
        } onCancel: {
            runner.cancelAll()
        }
        try Task.checkCancellation()
        guard result.terminationReason == .exit, result.exitCode == 0 else {
            throw SupervisedJournalRunnerError.launchFailed(
                "journal install-models --required-only failed (exit \(result.exitCode), termination \(result.terminationReason.rawValue))"
            )
        }
    }
}
