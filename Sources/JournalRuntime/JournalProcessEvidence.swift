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

/// Process-table facts used only while retiring a process group that this app
/// admitted during its current lifetime. This is deliberately separate from
/// `JournalProcessEvidence`: the latter is the durable, single-PID orphan
/// claim used at cold start.
internal struct JournalContainmentMemberEvidence: Equatable, Sendable {
    let pid: pid_t
    let processGroupID: pid_t
    let uid: uid_t
    let username: String
    let kernelStartTime: Double?
}

internal protocol JournalProcessContainmentEvidenceReading: Sendable {
    func containmentEvidence(for pid: pid_t) -> JournalContainmentMemberEvidence?
    /// `nil` is an indeterminate sysctl failure, not an empty group.
    func processIDs(inProcessGroup processGroupID: pid_t) -> [pid_t]?
    /// `nil` is an indeterminate sysctl failure, not an empty descendant set.
    func descendantProcessIDs(of rootPID: pid_t) -> [pid_t]?
}

extension JournalProcessContainmentEvidenceReading {
    func descendantProcessIDs(of rootPID: pid_t) -> [pid_t]? {
        []
    }
}

internal struct LiveJournalProcessContainmentEvidenceReader: JournalProcessContainmentEvidenceReading {
    init() {}

    func containmentEvidence(for pid: pid_t) -> JournalContainmentMemberEvidence? {
        liveJournalContainmentMemberEvidence(for: pid)
    }

    func processIDs(inProcessGroup processGroupID: pid_t) -> [pid_t]? {
        liveProcessIDs(inProcessGroup: processGroupID)
    }

    func descendantProcessIDs(of rootPID: pid_t) -> [pid_t]? {
        liveDescendantProcessIDs(of: rootPID)
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

internal func liveJournalContainmentMemberEvidence(for pid: pid_t) -> JournalContainmentMemberEvidence? {
    guard let row = readProcessRow(pid: pid) else { return nil }
    let pid = row.kp_proc.p_pid
    guard pid > 0 else { return nil }
    let uid = row.kp_eproc.e_ucred.cr_uid
    return JournalContainmentMemberEvidence(
        pid: pid,
        processGroupID: row.kp_eproc.e_pgid,
        uid: uid,
        username: username(for: uid),
        kernelStartTime: processStartTime(row)
    )
}

internal enum JournalContainmentMemberVerification: Equatable, Sendable {
    case verified(pid_t)
    case rejected(JournalContainmentMemberRejection)
}

internal enum JournalContainmentMemberRejection: String, Equatable, Sendable {
    case pidMismatch = "pid-mismatch"
    case processGroupMismatch = "process-group-mismatch"
    case rootPID = "root-pid"
    case ownPID = "own-pid"
    case unsafeCallerProcessGroup = "unsafe-caller-process-group"
    case wrongUser = "wrong-user"
    case missingKernelStartTime = "missing-kernel-start-time"
    case leaderStartTimeMismatch = "leader-start-time-mismatch"
    case outsideDomainLifetime = "outside-domain-lifetime"
    case observedStartTimeMismatch = "observed-start-time-mismatch"
}

internal func verifyJournalContainmentMember(
    enumeratedPID: pid_t,
    evidence: JournalContainmentMemberEvidence,
    domainProcessGroupID: pid_t,
    domainBirthKernelStartTime: Double,
    retirementAttemptWallTime: Double,
    leaderIdentity: SupervisedChildIdentity,
    currentUID: uid_t,
    currentUsername: String,
    ownPID: pid_t,
    ownProcessGroupID: pid_t
) -> JournalContainmentMemberVerification {
    guard evidence.pid == enumeratedPID else {
        return .rejected(.pidMismatch)
    }
    guard domainProcessGroupID != ownProcessGroupID else {
        return .rejected(.unsafeCallerProcessGroup)
    }
    guard evidence.processGroupID == domainProcessGroupID else {
        return .rejected(.processGroupMismatch)
    }
    guard enumeratedPID != 1 else {
        return .rejected(.rootPID)
    }
    guard enumeratedPID != ownPID else {
        return .rejected(.ownPID)
    }
    guard evidence.uid == currentUID, evidence.username == currentUsername else {
        return .rejected(.wrongUser)
    }
    guard let startTime = evidence.kernelStartTime, startTime.isFinite else {
        return .rejected(.missingKernelStartTime)
    }
    if enumeratedPID == leaderIdentity.pid {
        guard abs(startTime - leaderIdentity.kernelStartTime) <= journalSupervisorStartTimeToleranceSeconds else {
            return .rejected(.leaderStartTimeMismatch)
        }
    } else {
        guard startTime >= domainBirthKernelStartTime, startTime <= retirementAttemptWallTime else {
            return .rejected(.outsideDomainLifetime)
        }
    }
    return .verified(enumeratedPID)
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

private func liveProcessIDs(inProcessGroup processGroupID: pid_t) -> [pid_t]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, processGroupID]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
        return nil
    }
    guard size > 0 else { return [] }

    let stride = MemoryLayout<kinfo_proc>.stride
    var rows = Array(repeating: kinfo_proc(), count: (size + stride - 1) / stride)
    var actualSize = rows.count * stride
    guard sysctl(&mib, u_int(mib.count), &rows, &actualSize, nil, 0) == 0 else {
        return nil
    }
    let rowCount = min(rows.count, actualSize / stride)
    return rows.prefix(rowCount).compactMap { row in
        let pid = row.kp_proc.p_pid
        return pid > 0 ? pid : nil
    }
}

private func liveDescendantProcessIDs(of rootPID: pid_t) -> [pid_t]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
        return nil
    }
    guard size > 0 else { return [] }

    let stride = MemoryLayout<kinfo_proc>.stride
    var rows = Array(repeating: kinfo_proc(), count: (size + stride - 1) / stride)
    var actualSize = rows.count * stride
    guard sysctl(&mib, u_int(mib.count), &rows, &actualSize, nil, 0) == 0 else {
        return nil
    }
    let rowCount = min(rows.count, actualSize / stride)
    var children: [pid_t: [pid_t]] = [:]
    for row in rows.prefix(rowCount) {
        let pid = row.kp_proc.p_pid
        let parent = row.kp_eproc.e_ppid
        guard pid > 0, parent > 0 else { continue }
        children[parent, default: []].append(pid)
    }
    var result: [pid_t] = []
    var pending = children[rootPID] ?? []
    while let pid = pending.popLast() {
        result.append(pid)
        pending.append(contentsOf: children[pid] ?? [])
    }
    return result.sorted()
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
