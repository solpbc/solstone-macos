// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

public protocol JournalReadinessChecking: Sendable {
    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?,
        identityProvider: @escaping @Sendable () async -> SupervisedChildIdentity?
    ) async -> JournalReadinessResult
}

public enum JournalReadinessResult: Equatable, Sendable {
    case ready
    case failed(JournalDiagnostic)
    case failedTerminal(JournalDiagnostic)
}

public struct JournalReadinessGate: JournalReadinessChecking {
    private let clock: any MonotonicClock
    private let pollInterval: Duration
    private let startTimeToleranceSeconds: Double

    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        pollInterval: Duration = .milliseconds(250),
        startTimeToleranceSeconds: Double = journalSupervisorStartTimeToleranceSeconds
    ) {
        self.clock = clock
        self.pollInterval = pollInterval
        self.startTimeToleranceSeconds = startTimeToleranceSeconds
    }

    public func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        timeout: Duration,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?,
        identityProvider: @escaping @Sendable () async -> SupervisedChildIdentity?
    ) async -> JournalReadinessResult {
        let deadline = clock.now() + timeout

        while clock.now() < deadline {
            if let terminalDiagnostic = await terminalCheck() {
                return .failedTerminal(terminalDiagnostic)
            }
            if await markerIsReady(journalRoot: journalRoot, identityProvider: identityProvider) {
                return .ready
            }
            await clock.sleep(for: pollInterval)
        }

        if let terminalDiagnostic = await terminalCheck() {
            return .failedTerminal(terminalDiagnostic)
        }

        return .failed(JournalDiagnostic(
            commandLabel: "journal readiness",
            timedOut: true,
            outputExcerpt: UICopy.JOURNAL_READINESS_TIMEOUT
        ))
    }

    private func markerIsReady(
        journalRoot: URL,
        identityProvider: @escaping @Sendable () async -> SupervisedChildIdentity?
    ) async -> Bool {
        guard let marker = readReadyMarker(
            from: journalRoot.appendingPathComponent("health/supervisor.ready")
        ),
            let recordedPID = readPositivePID(from: journalRoot.appendingPathComponent("health/supervisor.pid")),
            let recordedStartTime = readDouble(from: journalRoot.appendingPathComponent("health/supervisor.start_time")),
            let identity = await identityProvider() else {
            return false
        }

        guard marker.pid == recordedPID,
              recordedPID == identity.pid else {
            return false
        }
        guard abs(recordedStartTime - identity.kernelStartTime) <= startTimeToleranceSeconds else {
            return false
        }
        // Python's _valid_marker() parses payload start_time but does not bind
        // it. signal_ready() writes this value from supervisor.start_time, so a
        // fresh marker matches; this stricter check only rejects stale markers
        // for a recycled PID.
        return abs(marker.startTime - identity.kernelStartTime) <= startTimeToleranceSeconds
    }

    private struct ReadyMarker: Decodable {
        let pid: pid_t
        let readyAt: Double
        let startTime: Double

        private enum CodingKeys: String, CodingKey {
            case pid
            case readyAt = "ready_at"
            case startTime = "start_time"
        }
    }

    private func readReadyMarker(from url: URL) -> ReadyMarker? {
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(ReadyMarker.self, from: data),
              marker.pid > 0,
              marker.readyAt.isFinite,
              marker.startTime.isFinite else {
            return nil
        }
        return marker
    }

    private func readPositivePID(from url: URL) -> pid_t? {
        guard let value = readInt32(from: url), value > 0 else {
            return nil
        }
        return pid_t(value)
    }

    private func readInt32(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func readDouble(from url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else {
            return nil
        }
        return value
    }
}
