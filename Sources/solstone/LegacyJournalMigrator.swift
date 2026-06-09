// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore

internal protocol LegacyJournalMigrating: Sendable {
    func teardownLegacyAppManagedJournal(
        oldSolPath: String,
        journalRoot: URL
    ) async -> LegacyJournalMigrationResult
}

internal enum LegacyJournalMigrationResult: Equatable, Sendable {
    case success
    case failed(JournalDiagnostic)
}

internal struct LegacyJournalMigrator: LegacyJournalMigrating {
    private let runtimeRootURL: URL
    private let runner: SubprocessRunning
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let clock: any MonotonicClock
    private let pidWaitTimeout: Duration
    private let pidWaitPollInterval: Duration
    private let orphanGracePeriod: Duration

    internal init(
        runtimeRootURL: URL = SolstoneRuntimeLayout.defaultRootURL,
        runner: SubprocessRunning = SubprocessRunner(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        clock: any MonotonicClock = SystemMonotonicClock(),
        pidWaitTimeout: Duration = .seconds(10),
        pidWaitPollInterval: Duration = .milliseconds(250),
        orphanGracePeriod: Duration = .seconds(3)
    ) {
        self.runtimeRootURL = runtimeRootURL
        self.runner = runner
        self.pidExists = pidExists
        self.terminate = terminate
        self.clock = clock
        self.pidWaitTimeout = pidWaitTimeout
        self.pidWaitPollInterval = pidWaitPollInterval
        self.orphanGracePeriod = orphanGracePeriod
    }

    internal func teardownLegacyAppManagedJournal(
        oldSolPath: String,
        journalRoot: URL
    ) async -> LegacyJournalMigrationResult {
        guard hasLegacyVersionedLayout() else {
            return .success
        }

        let journalPath = journalBinaryPath(siblingOf: oldSolPath)
        let uninstallOutput = LockedMigrationOutput()
        let uninstallResult: SubprocessResult
        do {
            uninstallResult = try await runner.run(
                executable: URL(fileURLWithPath: journalPath),
                arguments: ["service", "uninstall"],
                environment: nil,
                stdoutHandler: { data in uninstallOutput.append(data) },
                stderrHandler: { data in uninstallOutput.append(data) }
            )
        } catch {
            return .failed(JournalDiagnostic(
                commandLabel: "journal service uninstall",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            ))
        }
        guard uninstallResult.exitCode == 0 else {
            return .failed(JournalDiagnostic(
                commandLabel: "journal service uninstall",
                exitCode: uninstallResult.exitCode,
                outputExcerpt: sanitizeJournalDiagnosticOutput(uninstallOutput.string())
            ))
        }

        if let pid = readSupervisorPID(from: journalRoot.appendingPathComponent("health/supervisor.pid")) {
            let exited = await waitForPIDExit(
                pid: pid,
                timeout: pidWaitTimeout,
                pollInterval: pidWaitPollInterval,
                pidExists: pidExists,
                clock: clock
            )
            guard exited else {
                return .failed(JournalDiagnostic(
                    commandLabel: "journal legacy teardown",
                    outputExcerpt: "supervisor pid \(pid) still alive after teardown"
                ))
            }
        }

        if let failure = await runJournalOrphanSweep(
            runner: runner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock
        ) {
            return .failed(JournalDiagnostic(
                commandLabel: "journal legacy teardown",
                outputExcerpt: failure.message
            ))
        }

        if let failure = await assertPortsReleased(ports: [7657, 5015], runner: runner) {
            return .failed(JournalDiagnostic(
                commandLabel: "journal legacy teardown",
                outputExcerpt: failure.message
            ))
        }

        do {
            try purgeLegacyVersionedLayout()
        } catch {
            return .failed(JournalDiagnostic(
                commandLabel: "journal legacy teardown",
                outputExcerpt: sanitizeJournalDiagnosticOutput(error.localizedDescription)
            ))
        }

        return .success
    }

    private func purgeLegacyVersionedLayout() throws {
        let layout = SolstoneRuntimeLayout(rootURL: runtimeRootURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.currentLink.path) {
            try fileManager.removeItem(at: layout.currentLink)
        }
        guard fileManager.fileExists(atPath: layout.versionsDir.path) else { return }
        let versions = try fileManager.contentsOfDirectory(
            at: layout.versionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for version in versions {
            try fileManager.removeItem(at: version)
        }
    }

    private func hasLegacyVersionedLayout() -> Bool {
        let layout = SolstoneRuntimeLayout(rootURL: runtimeRootURL)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: layout.currentLink.path) {
            return true
        }
        guard let versions = try? fileManager.contentsOfDirectory(
            at: layout.versionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return !versions.isEmpty
    }

    private func journalBinaryPath(siblingOf solPath: String) -> String {
        URL(fileURLWithPath: solPath)
            .deletingLastPathComponent()
            .appendingPathComponent("journal")
            .path
    }
}

private final class LockedMigrationOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }

    func string() -> String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}
