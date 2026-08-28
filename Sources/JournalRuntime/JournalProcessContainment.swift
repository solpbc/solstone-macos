// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

/// A process group created by one admitted supervisor generation. Membership is
/// always read live at retirement time; this type intentionally keeps no
/// descendant registry or polling task.
internal struct JournalContainmentDomain: Equatable, Sendable {
    let processGroupID: pid_t
    let birthKernelStartTime: Double
    let generation: UInt64
    let leaderIdentity: SupervisedChildIdentity
}

internal enum JournalContainmentReadPhase: String, Equatable, Sendable {
    case initial = "initial"
    case postGrace = "post-grace"
    case final = "final"
}

internal enum JournalContainmentUnresolvedReason: Equatable, Sendable {
    case missingDomainAdmission
    case unsafeCallerProcessGroup
    case enumerationFailed(JournalContainmentReadPhase)
    case memberEvidenceUnavailable(pid_t, JournalContainmentReadPhase)
    case unprovenMember(pid_t, JournalContainmentMemberRejection, JournalContainmentReadPhase)
    case postSignalSurvivor(pid_t)

    var logValue: String {
        switch self {
        case .missingDomainAdmission:
            return "missing-domain-admission"
        case .unsafeCallerProcessGroup:
            return "unsafe-caller-process-group"
        case .enumerationFailed(let phase):
            return "enumeration-failed-\(phase.rawValue)"
        case .memberEvidenceUnavailable(let pid, let phase):
            return "member-evidence-unavailable-\(phase.rawValue)-pid-\(pid)"
        case .unprovenMember(let pid, let rejection, let phase):
            return "unproven-member-\(phase.rawValue)-pid-\(pid)-\(rejection.rawValue)"
        case .postSignalSurvivor(let pid):
            return "post-signal-survivor-pid-\(pid)"
        }
    }
}

internal enum JournalContainmentResult: Equatable, Sendable {
    case noActiveGeneration
    case clean
    case unresolved([JournalContainmentUnresolvedReason])
}

/// Retires one admitted containment domain. It only signals process IDs that
/// individually pass fresh provenance checks; it never signals a process group.
internal struct JournalProcessContainment {
    private let evidenceReader: any JournalProcessContainmentEvidenceReading
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let clock: any MonotonicClock
    private let gracePeriod: Duration
    private let wallTime: @Sendable () -> Double
    private let currentUID: uid_t
    private let currentUsernameValue: String
    private let ownPID: pid_t
    private let ownProcessGroupID: pid_t

    init(
        evidenceReader: any JournalProcessContainmentEvidenceReading = LiveJournalProcessContainmentEvidenceReader(),
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32,
        clock: any MonotonicClock,
        gracePeriod: Duration,
        wallTime: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        currentUID: uid_t = getuid(),
        currentUsernameValue: String = currentUsername(),
        ownPID: pid_t = getpid(),
        ownProcessGroupID: pid_t = getpgrp()
    ) {
        self.evidenceReader = evidenceReader
        self.terminate = terminate
        self.clock = clock
        self.gracePeriod = gracePeriod
        self.wallTime = wallTime
        self.currentUID = currentUID
        self.currentUsernameValue = currentUsernameValue
        self.ownPID = ownPID
        self.ownProcessGroupID = ownProcessGroupID
    }

    func retire(domain: JournalContainmentDomain?) async -> JournalContainmentResult {
        guard let domain else { return .noActiveGeneration }
        guard domain.processGroupID != ownProcessGroupID else {
            return unresolved([.unsafeCallerProcessGroup], domain: domain)
        }

        let retirementAttemptWallTime = wallTime()
        guard let initialPIDs = evidenceReader.processIDs(inProcessGroup: domain.processGroupID) else {
            return unresolved([.enumerationFailed(.initial)], domain: domain)
        }

        var gaps: [JournalContainmentUnresolvedReason] = []
        let initialVerified = verifiedPIDs(
            initialPIDs,
            domain: domain,
            retirementAttemptWallTime: retirementAttemptWallTime,
            phase: .initial,
            gaps: &gaps
        )
        signal(initialVerified, signal: SIGTERM)

        await clock.sleep(for: gracePeriod)

        guard let postGracePIDs = evidenceReader.processIDs(inProcessGroup: domain.processGroupID) else {
            gaps.append(.enumerationFailed(.postGrace))
            return unresolved(gaps, domain: domain)
        }
        let postGraceVerified = verifiedPIDs(
            postGracePIDs,
            domain: domain,
            retirementAttemptWallTime: retirementAttemptWallTime,
            phase: .postGrace,
            gaps: &gaps
        )
        signal(postGraceVerified, signal: SIGKILL)

        guard let finalPIDs = evidenceReader.processIDs(inProcessGroup: domain.processGroupID) else {
            gaps.append(.enumerationFailed(.final))
            return unresolved(gaps, domain: domain)
        }
        if !finalPIDs.isEmpty {
            _ = verifiedPIDs(
                finalPIDs,
                domain: domain,
                retirementAttemptWallTime: retirementAttemptWallTime,
                phase: .final,
                gaps: &gaps
            )
            gaps.append(contentsOf: finalPIDs.sorted().map(JournalContainmentUnresolvedReason.postSignalSurvivor))
        }
        guard gaps.isEmpty else {
            return unresolved(gaps, domain: domain)
        }

        Logger.setup.notice("journal containment outcome=clean generation=\(domain.generation, privacy: .public) pgid=\(domain.processGroupID, privacy: .public) terminated=\(initialVerified.count + postGraceVerified.count, privacy: .public)")
        return .clean
    }

    private func verifiedPIDs(
        _ pids: [pid_t],
        domain: JournalContainmentDomain,
        retirementAttemptWallTime: Double,
        phase: JournalContainmentReadPhase,
        gaps: inout [JournalContainmentUnresolvedReason]
    ) -> [pid_t] {
        var verified: [pid_t] = []
        for pid in Set(pids).sorted() {
            guard let evidence = evidenceReader.containmentEvidence(for: pid) else {
                gaps.append(.memberEvidenceUnavailable(pid, phase))
                continue
            }
            switch verifyJournalContainmentMember(
                enumeratedPID: pid,
                evidence: evidence,
                domainProcessGroupID: domain.processGroupID,
                domainBirthKernelStartTime: domain.birthKernelStartTime,
                retirementAttemptWallTime: retirementAttemptWallTime,
                leaderIdentity: domain.leaderIdentity,
                currentUID: currentUID,
                currentUsername: currentUsernameValue,
                ownPID: ownPID,
                ownProcessGroupID: ownProcessGroupID
            ) {
            case .verified(let verifiedPID):
                verified.append(verifiedPID)
            case .rejected(let rejection):
                gaps.append(.unprovenMember(pid, rejection, phase))
            }
        }
        return verified
    }

    private func signal(_ pids: [pid_t], signal: Int32) {
        for pid in pids {
            _ = terminate(pid, signal)
        }
    }

    private func unresolved(
        _ reasons: [JournalContainmentUnresolvedReason],
        domain: JournalContainmentDomain
    ) -> JournalContainmentResult {
        let summary = reasons.map(\.logValue).joined(separator: ",")
        Logger.setup.error("journal containment outcome=unresolved generation=\(domain.generation, privacy: .public) pgid=\(domain.processGroupID, privacy: .public) reasons=\(summary, privacy: .public)")
        return .unresolved(reasons)
    }
}
