// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation

public let journalSupervisorStartTimeToleranceSeconds = 1.5

public struct JournalProcessEvidence: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let username: String
    public let kernelStartTime: Double?

    public init(
        pid: pid_t,
        ppid: pid_t,
        uid: uid_t,
        username: String,
        kernelStartTime: Double?
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.username = username
        self.kernelStartTime = kernelStartTime
    }
}

public protocol JournalProcessEvidenceReading: Sendable {
    func evidence(for pid: pid_t) async -> JournalProcessEvidence?
}

extension JournalProcessEvidenceReading {
    public func kernelStartTime(for pid: pid_t) async -> Double? {
        await evidence(for: pid)?.kernelStartTime
    }
}

public struct LiveJournalProcessEvidenceReader: JournalProcessEvidenceReading {
    public init() {}

    public func evidence(for pid: pid_t) async -> JournalProcessEvidence? {
        liveJournalProcessEvidence(for: pid)
    }
}

internal func liveJournalProcessEvidence(for pid: pid_t) -> JournalProcessEvidence? {
    guard let row = readProcessRow(pid: pid) else { return nil }
    let pid = row.kp_proc.p_pid
    guard pid > 0 else { return nil }
    let uid = row.kp_eproc.e_ucred.cr_uid
    return JournalProcessEvidence(
        pid: pid,
        ppid: row.kp_eproc.e_ppid,
        uid: uid,
        username: username(for: uid),
        kernelStartTime: processStartTime(row)
    )
}

internal enum JournalOrphanClaimVerification: Equatable, Sendable {
    case selected(pid_t)
    case notSelected(JournalOrphanClaimRejection)

    var selectedPID: pid_t? {
        if case .selected(let pid) = self { return pid }
        return nil
    }
}

internal enum JournalOrphanClaimRejection: String, Equatable, Sendable {
    case missingPID = "missing-pid"
    case missingStartTime = "missing-start-time"
    case deadPID = "dead-pid"
    case pidMismatch = "pid-mismatch"
    case ownPID = "own-pid"
    case launchdOwned = "launchd-owned"
    case wrongParent = "wrong-parent"
    case wrongUser = "wrong-user"
    case missingKernelStartTime = "missing-kernel-start-time"
    case startTimeMismatch = "start-time-mismatch"
}

internal func verifyJournalOrphanClaim(
    claimedPID: pid_t?,
    recordedStartTime: Double?,
    evidence: JournalProcessEvidence?,
    currentUID: uid_t,
    currentUsername: String,
    ownPID: pid_t,
    launchdReportedPID: pid_t?
) -> JournalOrphanClaimVerification {
    // Verified on macOS: `setproctitle` in sol_cli.py:528 creates the
    // `journal:*` title by clobbering the contiguous argv/env area read by
    // KERN_PROCARGS2. A `journal:*` title plus readable inherited env is
    // therefore an empty set. Provenance must come from the root's durable
    // supervisor.pid + supervisor.start_time claim, then be bound to the
    // kernel process identity here.
    guard let claimedPID, claimedPID > 0 else {
        return .notSelected(.missingPID)
    }
    guard let recordedStartTime, recordedStartTime.isFinite else {
        return .notSelected(.missingStartTime)
    }
    guard let evidence else {
        return .notSelected(.deadPID)
    }
    guard evidence.pid == claimedPID else {
        return .notSelected(.pidMismatch)
    }
    guard claimedPID != ownPID else {
        return .notSelected(.ownPID)
    }
    if let launchdReportedPID, claimedPID == launchdReportedPID {
        return .notSelected(.launchdOwned)
    }
    guard evidence.ppid == 1 else {
        return .notSelected(.wrongParent)
    }
    guard evidence.uid == currentUID, evidence.username == currentUsername else {
        return .notSelected(.wrongUser)
    }
    guard let kernelStartTime = evidence.kernelStartTime else {
        return .notSelected(.missingKernelStartTime)
    }
    guard abs(recordedStartTime - kernelStartTime) <= journalSupervisorStartTimeToleranceSeconds else {
        return .notSelected(.startTimeMismatch)
    }
    return .selected(claimedPID)
}

internal func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

internal func currentUsername() -> String {
    username(for: getuid())
}

private func readProcessRow(pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var row = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &row, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    return row
}

private func processStartTime(_ row: kinfo_proc) -> Double? {
    let value = row.kp_proc.p_starttime
    guard value.tv_sec > 0 else { return nil }
    return Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000.0
}

private func username(for uid: uid_t) -> String {
    guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else {
        return String(uid)
    }
    return String(cString: name)
}
