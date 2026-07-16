// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore

public protocol JournalReadinessChecking: Sendable {
    func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        child: JournalChildIdentity,
        timeout: Duration,
        generationIsCurrent: @escaping @Sendable (UInt64) async -> Bool,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult
}

public enum JournalReadinessResult: Equatable, Sendable {
    case ready
    case failed(JournalDiagnostic)
    case failedTerminal(JournalDiagnostic)
}

public struct JournalReadinessGate: JournalReadinessChecking {
    private let readTextFile: @Sendable (String) -> String?
    private let processStartTime: ProcessStartTimeReading
    private let acceptProbe: @Sendable () async -> Bool
    private let clock: any MonotonicClock
    private let pollInterval: Duration

    public init(
        readTextFile: @escaping @Sendable (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        },
        processStartTime: @escaping ProcessStartTimeReading = defaultProcessStartTime,
        acceptProbe: @escaping @Sendable () async -> Bool = {
            await JournalReadinessGate.defaultAcceptProbe()
        },
        clock: any MonotonicClock = SystemMonotonicClock(),
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.readTextFile = readTextFile
        self.processStartTime = processStartTime
        self.acceptProbe = acceptProbe
        self.clock = clock
        self.pollInterval = pollInterval
    }

    public func waitUntilReady(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        child: JournalChildIdentity,
        timeout: Duration,
        generationIsCurrent: @escaping @Sendable (UInt64) async -> Bool,
        terminalCheck: @escaping @Sendable () async -> JournalDiagnostic?
    ) async -> JournalReadinessResult {
        let readyPath = journalRoot.appendingPathComponent("health/supervisor.ready").path
        let pidPath = journalRoot.appendingPathComponent("health/supervisor.pid").path
        let deadline = clock.now() + timeout
        var lastDiagnostic: JournalDiagnostic?

        while clock.now() < deadline {
            if let terminalDiagnostic = await terminalCheck() {
                return .failedTerminal(terminalDiagnostic)
            }
            let probeAccepts = await acceptProbe()
            switch markerIsValid(readyPath: readyPath, pidPath: pidPath, child: child) {
            case .valid:
                if probeAccepts,
                   await generationIsCurrent(child.generation),
                   sameProcessStillAlive(child) {
                    return .ready
                }
            case .invalid(let diagnostic):
                lastDiagnostic = diagnostic
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

    private enum MarkerState {
        case valid
        case invalid(JournalDiagnostic?)
    }

    private struct ReadinessMarker: Decodable {
        let pid: Int
        let readyAt: TimeInterval
        let startTime: TimeInterval

        enum CodingKeys: String, CodingKey {
            case pid
            case readyAt = "ready_at"
            case startTime = "start_time"
        }
    }

    private func markerIsValid(
        readyPath: String,
        pidPath: String,
        child: JournalChildIdentity
    ) -> MarkerState {
        guard let markerText = readTextFile(readyPath),
              let markerData = markerText.data(using: .utf8),
              let marker = try? JSONDecoder().decode(ReadinessMarker.self, from: markerData) else {
            return .invalid(nil)
        }
        guard marker.readyAt.isFinite else {
            return .invalid(JournalDiagnostic(
                commandLabel: "journal readiness",
                outputExcerpt: "journal readiness marker timestamp is invalid"
            ))
        }
        guard let pidText = readTextFile(pidPath),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return .invalid(JournalDiagnostic(
                commandLabel: "journal readiness",
                outputExcerpt: "journal supervisor pid marker is invalid"
            ))
        }
        guard marker.pid == Int(pid), marker.pid == Int(child.pid) else {
            return .invalid(JournalDiagnostic(
                commandLabel: "journal readiness",
                outputExcerpt: "journal readiness marker does not match the launched child"
            ))
        }
        guard let childStartTime = processStartTime(child.pid),
              abs(marker.startTime - childStartTime) <= journalStartTimeToleranceS else {
            return .invalid(JournalDiagnostic(
                commandLabel: "journal readiness",
                outputExcerpt: "journal child identity could not be verified"
            ))
        }
        return .valid
    }

    private func sameProcessStillAlive(_ child: JournalChildIdentity) -> Bool {
        guard let startTime = processStartTime(child.pid) else {
            return false
        }
        return abs(startTime - child.startTime) <= journalStartTimeToleranceS
    }
}
