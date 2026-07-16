// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import JournalRuntimeTestSupport
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("Journal process evidence")
struct JournalProcessEvidenceTests {
    @Test func verifierSelectsProvenSameRootOrphan() {
        let candidate = evidence(pid: 101, startTime: 1_000.0)

        let result = verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: candidate
        )

        #expect(result == .selected(101))
    }

    @Test func verifierRejectsMissingPID() {
        #expect(verifyForTest(
            claimedPID: nil,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, startTime: 1_000.0)
        ) == .notSelected(.missingPID))
        #expect(verifyForTest(
            claimedPID: 0,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, startTime: 1_000.0)
        ) == .notSelected(.missingPID))
    }

    @Test func verifierRejectsMissingStartTime() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: nil,
            evidence: evidence(pid: 101, startTime: 1_000.0)
        ) == .notSelected(.missingStartTime))
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: .nan,
            evidence: evidence(pid: 101, startTime: 1_000.0)
        ) == .notSelected(.missingStartTime))
    }

    @Test func verifierRejectsDeadPID() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: nil
        ) == .notSelected(.deadPID))
    }

    @Test func verifierRejectsPIDMismatch() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 102, startTime: 1_000.0)
        ) == .notSelected(.pidMismatch))
    }

    @Test func verifierRejectsOwnPID() {
        #expect(verifyForTest(
            claimedPID: getpid(),
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: getpid(), startTime: 1_000.0)
        ) == .notSelected(.ownPID))
    }

    @Test func verifierRejectsLaunchdOwnedPID() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, startTime: 1_000.0),
            launchdReportedPID: 101
        ) == .notSelected(.launchdOwned))
    }

    @Test func verifierRejectsWrongParent() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, ppid: 42, startTime: 1_000.0)
        ) == .notSelected(.wrongParent))
    }

    @Test func verifierRejectsWrongUser() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, uid: getuid() + 1, username: "other", startTime: 1_000.0)
        ) == .notSelected(.wrongUser))
    }

    @Test func verifierRejectsMissingKernelStartTime() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, startTime: nil)
        ) == .notSelected(.missingKernelStartTime))
    }

    @Test func verifierRejectsStartTimeMismatch() {
        #expect(verifyForTest(
            claimedPID: 101,
            recordedStartTime: 1_000.0,
            evidence: evidence(pid: 101, startTime: 1_002.0)
        ) == .notSelected(.startTimeMismatch))
    }

    @Test func missingOrMalformedClaimFilesProtectWithoutSignal() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = TerminationRecorder()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("health", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("not-a-pid\n".utf8)
            .write(to: root.appendingPathComponent("health/supervisor.pid"))
        try Data("not-a-start-time\n".utf8)
            .write(to: root.appendingPathComponent("health/supervisor.start_time"))

        let failure = await runJournalOrphanSweep(
            journalRoot: root,
            runner: FakeSubprocessRunner(),
            evidenceReader: FakeJournalProcessEvidenceReader(evidenceByPID: [:]),
            launchdPIDProvider: { .known(nil) },
            pidExists: { _ in false },
            terminate: { pid, signal in
                recorder.append(pid: pid, signal: signal)
                return 0
            },
            gracePeriod: .zero,
            clock: NoopClock()
        )

        #expect(failure == nil)
        #expect(recorder.snapshot().isEmpty)
    }

    @Test func rootedSweepSignalsOnlyClaimedVerifiedPID() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeClaim(root: root, pid: 101, startTime: 1_000.0)
        let recorder = TerminationRecorder()
        let reader = FakeJournalProcessEvidenceReader(evidenceByPID: [
            101: evidence(pid: 101, startTime: 1_000.0),
            102: evidence(pid: 102, startTime: 1_000.0)
        ])

        let failure = await runJournalOrphanSweep(
            journalRoot: root,
            runner: FakeSubprocessRunner(),
            evidenceReader: reader,
            launchdPIDProvider: { .known(nil) },
            pidExists: { _ in false },
            terminate: { pid, signal in
                recorder.append(pid: pid, signal: signal)
                return 0
            },
            gracePeriod: .zero,
            clock: NoopClock()
        )

        #expect(failure == nil)
        #expect(recorder.snapshot() == [.init(pid: 101, signal: SIGTERM)])
    }

    @Test func rootedSweepBlocksWithoutSignalWhenRecheckChanges() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeClaim(root: root, pid: 101, startTime: 1_000.0)
        let recorder = TerminationRecorder()
        let reader = SequencedJournalProcessEvidenceReader(sequence: [
            evidence(pid: 101, startTime: 1_000.0),
            evidence(pid: 101, startTime: 1_002.0)
        ])

        let failure = await runJournalOrphanSweep(
            journalRoot: root,
            runner: FakeSubprocessRunner(),
            evidenceReader: reader,
            launchdPIDProvider: { .known(nil) },
            pidExists: { _ in false },
            terminate: { pid, signal in
                recorder.append(pid: pid, signal: signal)
                return 0
            },
            gracePeriod: .zero,
            clock: NoopClock()
        )

        #expect(failure?.step == .orphanSweep)
        #expect(recorder.snapshot().isEmpty)
    }

    @Test func rootedSweepBlocksWithoutSignalWhenLaunchdStateCannotBeRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeClaim(root: root, pid: 101, startTime: 1_000.0)
        let recorder = TerminationRecorder()

        let failure = await runJournalOrphanSweep(
            journalRoot: root,
            runner: FakeSubprocessRunner(),
            evidenceReader: FakeJournalProcessEvidenceReader(evidenceByPID: [
                101: evidence(pid: 101, startTime: 1_000.0)
            ]),
            launchdPIDProvider: { .failed },
            pidExists: { _ in false },
            terminate: { pid, signal in
                recorder.append(pid: pid, signal: signal)
                return 0
            },
            gracePeriod: .zero,
            clock: NoopClock()
        )

        #expect(failure?.step == .orphanSweep)
        #expect(recorder.snapshot().isEmpty)
    }
}

private func verifyForTest(
    claimedPID: pid_t?,
    recordedStartTime: Double?,
    evidence: JournalProcessEvidence?,
    launchdReportedPID: pid_t? = nil
) -> JournalOrphanClaimVerification {
    verifyJournalOrphanClaim(
        claimedPID: claimedPID,
        recordedStartTime: recordedStartTime,
        evidence: evidence,
        currentUID: getuid(),
        currentUsername: currentUsername(),
        ownPID: getpid(),
        launchdReportedPID: launchdReportedPID
    )
}

private func evidence(
    pid: pid_t,
    ppid: pid_t = 1,
    uid: uid_t = getuid(),
    username: String = currentUsername(),
    startTime: Double?
) -> JournalProcessEvidence {
    JournalProcessEvidence(
        pid: pid,
        ppid: ppid,
        uid: uid,
        username: username,
        kernelStartTime: startTime
    )
}

private func writeClaim(root: URL, pid: pid_t, startTime: Double) throws {
    let health = root.appendingPathComponent("health", isDirectory: true)
    try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
    try Data("\(pid)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.pid"))
    try Data("\(startTime)\n".utf8)
        .write(to: health.appendingPathComponent("supervisor.start_time"))
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("journal-process-evidence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class FakeJournalProcessEvidenceReader: JournalProcessEvidenceReading, @unchecked Sendable {
    private let evidenceByPID: [pid_t: JournalProcessEvidence]

    init(evidenceByPID: [pid_t: JournalProcessEvidence]) {
        self.evidenceByPID = evidenceByPID
    }

    func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        evidenceByPID[pid]
    }
}

private final class SequencedJournalProcessEvidenceReader: JournalProcessEvidenceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: [JournalProcessEvidence?]

    init(sequence: [JournalProcessEvidence?]) {
        self.sequence = sequence
    }

    func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        lock.withLock {
            guard !sequence.isEmpty else { return nil }
            return sequence.removeFirst()
        }
    }
}

private struct Termination: Equatable {
    let pid: pid_t
    let signal: Int32
}

private final class TerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Termination] = []

    func append(pid: pid_t, signal: Int32) {
        lock.withLock {
            values.append(Termination(pid: pid, signal: signal))
        }
    }

    func snapshot() -> [Termination] {
        lock.withLock { values }
    }
}

private final class NoopClock: MonotonicClock, @unchecked Sendable {
    func now() -> Duration { .zero }
    func sleep(for duration: Duration) async {}
}
