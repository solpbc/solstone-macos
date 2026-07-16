// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import Testing
@testable import JournalRuntime

@Suite("JournalRestartRunner")
struct JournalRestartRunnerTests {
    @Test func orphanSweepRunsBeforeStaleStateMoveAside() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeClaim(root: root, pid: 101, startTime: 1_000.0)
        let pidURL = root.appendingPathComponent("health/supervisor.pid")
        let startURL = root.appendingPathComponent("health/supervisor.start_time")
        let terminateRecorder = RestartTerminateRecorder(pidURL: pidURL, startURL: startURL)
        let events = RestartEventRecorder()
        let subprocess = FakeSubprocessRunner()
        subprocess.enqueue("service", .success())
        let runner = JournalRestartRunner(
            runner: subprocess,
            journalPathProvider: { _ in root.path },
            terminate: { pid in
                terminateRecorder.record(pid: pid)
            },
            evidenceReader: RestartEvidenceReader(evidence: evidence(pid: 101, startTime: 1_000.0)),
            reprobe: { .reachable },
            logSink: { event in
                events.append(event)
            },
            journalBinary: root.appendingPathComponent("journal")
        )

        let outcome = await runner.run()

        #expect(outcome == .success)
        #expect(terminateRecorder.snapshot() == [
            .init(pid: 101, pidFilePresent: true, startFilePresent: true)
        ])
        #expect(!FileManager.default.fileExists(atPath: pidURL.path))
        #expect(FileManager.default.fileExists(atPath: pidURL.path + ".bak"))
        let steps = events.snapshot().map(\.step)
        let sweepIndex = try #require(steps.firstIndex(of: .orphanSweep))
        let moveAsideIndex = try #require(steps.firstIndex(of: .staleStateMoveAside))
        #expect(sweepIndex < moveAsideIndex)
    }
}

private func writeClaim(root: URL, pid: pid_t, startTime: Double) throws {
    let health = root.appendingPathComponent("health", isDirectory: true)
    try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
    try Data("\(pid)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.pid"))
    try Data("\(startTime)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.start_time"))
}

private func evidence(pid: pid_t, startTime: Double) -> JournalProcessEvidence {
    JournalProcessEvidence(
        pid: pid,
        ppid: 1,
        uid: getuid(),
        username: currentUsername(),
        kernelStartTime: startTime
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-restart-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct RestartTerminateRecord: Equatable {
    let pid: pid_t
    let pidFilePresent: Bool
    let startFilePresent: Bool
}

private final class RestartTerminateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let pidURL: URL
    private let startURL: URL
    private var records: [RestartTerminateRecord] = []

    init(pidURL: URL, startURL: URL) {
        self.pidURL = pidURL
        self.startURL = startURL
    }

    func record(pid: pid_t) {
        lock.withLock {
            records.append(RestartTerminateRecord(
                pid: pid,
                pidFilePresent: FileManager.default.fileExists(atPath: pidURL.path),
                startFilePresent: FileManager.default.fileExists(atPath: startURL.path)
            ))
        }
    }

    func snapshot() -> [RestartTerminateRecord] {
        lock.withLock { records }
    }
}

private final class RestartEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [JournalRestartLogEvent] = []

    func append(_ event: JournalRestartLogEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [JournalRestartLogEvent] {
        lock.withLock { events }
    }
}

private struct RestartEvidenceReader: JournalProcessEvidenceReading {
    let evidence: JournalProcessEvidence

    func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        evidence.pid == pid ? evidence : nil
    }
}
