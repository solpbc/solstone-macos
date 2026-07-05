// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

public protocol JournalReadinessChecking: Sendable {
    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult
}

public enum JournalReadinessResult: Equatable, Sendable {
    case ready
    case failed(JournalDiagnostic)
    case failedTerminal(JournalDiagnostic)
}

public struct JournalReadinessGate: JournalReadinessChecking {
    private let runner: SubprocessRunning
    private let fileExists: @Sendable (String) -> Bool
    private let acceptProbe: @Sendable () async -> Bool
    private let clock: any MonotonicClock
    private let pollInterval: Duration

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        acceptProbe: @escaping @Sendable () async -> Bool = {
            await JournalReadinessGate.defaultAcceptProbe()
        },
        clock: any MonotonicClock = SystemMonotonicClock(),
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.runner = runner
        self.fileExists = fileExists
        self.acceptProbe = acceptProbe
        self.clock = clock
        self.pollInterval = pollInterval
    }

    public func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult {
        let readyPath = journalRoot.appendingPathComponent("health/supervisor.ready").path
        let deadline = clock.now() + timeout
        var lastDiagnostic: JournalDiagnostic?

        while clock.now() < deadline {
            if let terminalDiagnostic = await terminalCheck() {
                return .failedTerminal(terminalDiagnostic)
            }
            let probeAccepts = await acceptProbe()
            let markerReady = fileExists(readyPath)
            var healthReady = false
            if !markerReady {
                switch await JournalHealthCheck.run(
                    journalBinary: runtime.layout.journalBinary,
                    runner: runner,
                    environment: runtime.layout.uvEnvironment()
                ) {
                case .healthy:
                    healthReady = true
                case .stopped(let diagnostic), .unknown(let diagnostic):
                    lastDiagnostic = diagnostic
                }
            }
            if probeAccepts && (markerReady || healthReady) {
                return .ready
            }
            await clock.sleep(for: pollInterval)
        }

        if let terminalDiagnostic = await terminalCheck() {
            return .failedTerminal(terminalDiagnostic)
        }

        return .failed(lastDiagnostic ?? JournalDiagnostic(
            commandLabel: "journal readiness",
            timedOut: true,
            outputExcerpt: UICopy.JOURNAL_READINESS_TIMEOUT
        ))
    }

    public static func defaultAcceptProbe() async -> Bool {
        guard let url = URL(string: ServiceMode.bundledServiceURL + "/") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 0.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }
}
