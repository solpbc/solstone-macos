// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import SolstoneCore
import Testing
@testable import JournalRuntime

@Suite("JournalProcessContainment")
struct JournalProcessContainmentTests {
    @Test func verifiesLeaderAgainstRecordedStartTimeAndDescendantsAgainstDomainLifetime() {
        let domain = makeDomain()
        let leader = evidence(pid: 100, pgid: 100, startTime: 900)
        #expect(verify(domain: domain, pid: 100, evidence: leader) == .verified(100))

        let reusedLeader = evidence(pid: 100, pgid: 100, startTime: 902)
        #expect(verify(domain: domain, pid: 100, evidence: reusedLeader) == .rejected(.leaderStartTimeMismatch))

        let descendant = evidence(pid: 101, pgid: 100, startTime: 950)
        #expect(verify(domain: domain, pid: 101, evidence: descendant) == .verified(101))

        let predatingDescendant = evidence(pid: 101, pgid: 100, startTime: 899.9)
        #expect(verify(domain: domain, pid: 101, evidence: predatingDescendant) == .rejected(.outsideDomainLifetime))
    }

    @Test func retiresVerifiedMembersWithOneSharedGraceAndEscalation() async {
        let reader = RecordingContainmentEvidenceReader(
            memberships: [[100, 101], [101], []],
            evidenceByPID: [
                100: evidence(pid: 100, pgid: 100, startTime: 900),
                101: evidence(pid: 101, pgid: 100, startTime: 950)
            ]
        )
        let signals = SignalRecorder()
        let clock = ContainmentClock()

        let result = await makeContainment(reader: reader, signals: signals, clock: clock).retire(domain: makeDomain())

        #expect(result == .clean)
        #expect(signals.snapshot() == [.init(pid: 100, signal: SIGTERM), .init(pid: 101, signal: SIGTERM), .init(pid: 101, signal: SIGKILL)])
        #expect(clock.sleeps == [.seconds(2)])
    }

    @Test func reenumeratesAndKillsDescendantThatAppearsAfterInitialMembership() async {
        let reader = RecordingContainmentEvidenceReader(
            memberships: [[100], [100, 101], []],
            evidenceByPID: [
                100: evidence(pid: 100, pgid: 100, startTime: 900),
                101: evidence(pid: 101, pgid: 100, startTime: 950)
            ]
        )
        let signals = SignalRecorder()

        let result = await makeContainment(reader: reader, signals: signals).retire(domain: makeDomain())

        #expect(result == .clean)
        #expect(signals.snapshot() == [.init(pid: 100, signal: SIGTERM), .init(pid: 100, signal: SIGKILL), .init(pid: 101, signal: SIGKILL)])
    }

    @Test func unprovenMemberBlocksCleanResultButDoesNotBlockVerifiedMemberRetirement() async {
        let reader = RecordingContainmentEvidenceReader(
            memberships: [[100, 101], [], []],
            evidenceByPID: [
                100: evidence(pid: 100, pgid: 100, startTime: 900),
                101: evidence(pid: 101, pgid: 100, startTime: 950, uid: 502, username: "other")
            ]
        )
        let signals = SignalRecorder()

        let result = await makeContainment(reader: reader, signals: signals).retire(domain: makeDomain())

        #expect(result == .unresolved([.unprovenMember(101, .wrongUser, .initial)]))
        #expect(signals.snapshot() == [.init(pid: 100, signal: SIGTERM)])
    }

    @Test func indeterminateEvidenceBlocksCleanResultAndSendsNoSignalToThatPID() async {
        let reader = RecordingContainmentEvidenceReader(
            memberships: [[100], [], []],
            evidenceByPID: [:]
        )
        let signals = SignalRecorder()

        let result = await makeContainment(reader: reader, signals: signals).retire(domain: makeDomain())

        #expect(result == .unresolved([.memberEvidenceUnavailable(100, .initial)]))
        #expect(signals.snapshot().isEmpty)
    }

    @Test func enumerationFailureIsIndeterminateAndSignalsNoMembers() async {
        let reader = RecordingContainmentEvidenceReader(memberships: [nil], evidenceByPID: [:])
        let signals = SignalRecorder()

        let result = await makeContainment(reader: reader, signals: signals).retire(domain: makeDomain())

        #expect(result == .unresolved([.enumerationFailed(.initial)]))
        #expect(signals.snapshot().isEmpty)
    }

    @Test func noDomainIsDistinctFromCleanContainment() async {
        let reader = RecordingContainmentEvidenceReader(memberships: [], evidenceByPID: [:])
        let signals = SignalRecorder()

        let result = await makeContainment(reader: reader, signals: signals).retire(domain: nil)

        #expect(result == .noActiveGeneration)
        #expect(signals.snapshot().isEmpty)
    }

    @Test func signalsReadinessObservedMemberAfterItLeavesTheAdmittedProcessGroup() async {
        let reader = RecordingContainmentEvidenceReader(
            memberships: [[], [], []],
            evidenceByPID: [
                101: evidence(pid: 101, pgid: 101, startTime: 950)
            ]
        )
        let signals = SignalRecorder()
        let containment = JournalProcessContainment(
            evidenceReader: reader,
            terminate: { pid, signal in
                signals.append(.init(pid: pid, signal: signal))
                return 0
            },
            clock: ContainmentClock(),
            gracePeriod: .seconds(2),
            pidExists: { pid in
                !signals.snapshot().contains { $0.pid == pid && $0.signal == SIGKILL }
            },
            wallTime: { 1_000 },
            currentUID: 501,
            currentUsernameValue: "owner",
            ownPID: 999,
            ownProcessGroupID: 999
        )
        let result = await containment.retire(
            domain: makeDomain(),
            observedMembers: [.init(pid: 101, kernelStartTime: 950)]
        )
        #expect(signals.snapshot() == [.init(pid: 101, signal: SIGTERM), .init(pid: 101, signal: SIGKILL)])
        #expect(result == .clean)
    }

    private func makeContainment(
        reader: RecordingContainmentEvidenceReader,
        signals: SignalRecorder,
        clock: ContainmentClock = ContainmentClock()
    ) -> JournalProcessContainment {
        JournalProcessContainment(
            evidenceReader: reader,
            terminate: { pid, signal in
                signals.append(.init(pid: pid, signal: signal))
                return 0
            },
            clock: clock,
            gracePeriod: .seconds(2),
            wallTime: { 1_000 },
            currentUID: 501,
            currentUsernameValue: "owner",
            ownPID: 999,
            ownProcessGroupID: 999
        )
    }

    private func makeDomain() -> JournalContainmentDomain {
        let leader = SupervisedChildIdentity(pid: 100, kernelStartTime: 900, generation: 7)
        return JournalContainmentDomain(
            processGroupID: 100,
            birthKernelStartTime: 900,
            generation: 7,
            leaderIdentity: leader
        )
    }

    private func evidence(
        pid: pid_t,
        pgid: pid_t,
        startTime: Double,
        uid: uid_t = 501,
        username: String = "owner"
    ) -> JournalContainmentMemberEvidence {
        JournalContainmentMemberEvidence(
            pid: pid,
            processGroupID: pgid,
            uid: uid,
            username: username,
            kernelStartTime: startTime
        )
    }

    private func verify(
        domain: JournalContainmentDomain,
        pid: pid_t,
        evidence: JournalContainmentMemberEvidence
    ) -> JournalContainmentMemberVerification {
        verifyJournalContainmentMember(
            enumeratedPID: pid,
            evidence: evidence,
            domainProcessGroupID: domain.processGroupID,
            domainBirthKernelStartTime: domain.birthKernelStartTime,
            retirementAttemptWallTime: 1_000,
            leaderIdentity: domain.leaderIdentity,
            currentUID: 501,
            currentUsername: "owner",
            ownPID: 999,
            ownProcessGroupID: 999
        )
    }
}

private final class RecordingContainmentEvidenceReader: JournalProcessContainmentEvidenceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var memberships: [[pid_t]?]
    private let evidenceByPID: [pid_t: JournalContainmentMemberEvidence]

    init(memberships: [[pid_t]?], evidenceByPID: [pid_t: JournalContainmentMemberEvidence]) {
        self.memberships = memberships
        self.evidenceByPID = evidenceByPID
    }

    func containmentEvidence(for pid: pid_t) -> JournalContainmentMemberEvidence? {
        evidenceByPID[pid]
    }

    func processIDs(inProcessGroup processGroupID: pid_t) -> [pid_t]? {
        lock.withLock {
            guard !memberships.isEmpty else { return [] }
            return memberships.removeFirst()
        }
    }
}

private final class SignalRecorder: @unchecked Sendable {
    struct Signal: Equatable, Sendable {
        let pid: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var signals: [Signal] = []

    func append(_ signal: Signal) {
        lock.withLock { signals.append(signal) }
    }

    func snapshot() -> [Signal] {
        lock.withLock { signals }
    }
}

private final class ContainmentClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sleeps: [Duration] = []

    func now() -> Duration { .zero }

    func sleep(for duration: Duration) async {
        lock.withLock { sleeps.append(duration) }
    }
}
