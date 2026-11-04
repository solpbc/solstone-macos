// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// The journal connection as every surface shows it. The menu bar icon, the menu's
/// status row and the Settings status card all read this one value, so they can
/// never disagree about whether this Mac is connected.
enum PresentedJournalConnection: Sendable, Equatable {
    case connecting
    case connected
    case offline
}

/// What the presenter is told about the connection.
struct JournalConnectionEvidence: Sendable, Equatable {
    /// Whether this Mac is trying to reach a journal at all. False with no pairing,
    /// no route to try, or a stop that only the owner can lift.
    var trying: Bool
    /// The tunnel is connected and its local route is installed.
    var linkUp: Bool
    /// When the journal was last heard over the current connection: the handshake
    /// finishing, any inbound bytes (keepalive answers, upload replies), or a
    /// liveness check answered. A check that was only sent is not hearing anything.
    var lastHeardAt: Date?
    /// Whether the system reports a usable network path.
    var networkAvailable: Bool
}

/// Decides when the connection reads connected, connecting… or offline.
///
/// Connected is earned: the link is up and the journal was heard within the lease.
/// One slow or failed check changes nothing; the lease running out, or the link
/// going down, does. Recovery shows at once, but a drop is shown for at least a
/// second so the indicator never flashes. Connecting… becomes offline on a timer,
/// or at once when there is no network and no link. After a wake, unlock or a
/// suspension the last state is held briefly while a fresh check answers.
///
/// Pure: the caller passes the time, and re-evaluates at `nextChange(after:)`.
struct JournalConnectionPresenter: Sendable, Equatable {
    /// How long one piece of evidence keeps the connection reading connected. One
    /// healthy but slow liveness cycle fits inside it: the check starts after 3 s of
    /// silence and may take up to 6 s to answer.
    static let lease: TimeInterval = 10
    /// A drop from connected is shown at least this long before connected returns.
    static let minimumDropDwell: TimeInterval = 1
    /// Continuously not reaching the journal this long reads offline.
    static let offlineAfter: TimeInterval = 30
    /// After a wake, unlock or suspension, the last state is held at most this long.
    static let resumeGrace: TimeInterval = 0.5
    /// An evaluation this late while connected means the process was suspended
    /// (the Mac slept, or its timers were held back), so it counts as a resume.
    static let suspensionGap: TimeInterval = lease + 1

    private(set) var shown: PresentedJournalConnection = .connecting
    private var evidence: JournalConnectionEvidence?
    /// When the current drop from connected was first shown.
    private var droppedAt: Date?
    /// When the current stretch of not reaching the journal began.
    private var unreachedSince: Date?
    private var holdUntil: Date?
    private var lastEvaluatedAt: Date?

    /// A fresh launch: nothing has been heard, so the connection reads connecting…
    init(now: Date) {
        unreachedSince = now
    }

    /// A wake, unlock or return to the foreground. A new attempt begins, and what
    /// is shown holds for a moment while a fresh liveness check answers.
    mutating func resume(at now: Date) {
        holdUntil = now.addingTimeInterval(Self.resumeGrace)
        unreachedSince = now
    }

    @discardableResult
    mutating func update(_ next: JournalConnectionEvidence, at now: Date) -> PresentedJournalConnection {
        defer {
            evidence = next
            lastEvaluatedAt = now
        }
        if shown == .connected, let lastEvaluatedAt,
           now.timeIntervalSince(lastEvaluatedAt) >= Self.suspensionGap {
            resume(at: now)
        }
        if let previous = evidence,
           (!previous.networkAvailable && next.networkAvailable) || (!previous.trying && next.trying) {
            unreachedSince = now
        }

        if Self.isHeard(next, at: now) {
            holdUntil = nil
            unreachedSince = nil
            if shown != .connected {
                if let droppedAt, now < droppedAt.addingTimeInterval(Self.minimumDropDwell) {
                    return shown
                }
                droppedAt = nil
                shown = .connected
            }
            return shown
        }

        let hardDrop = !next.trying || !next.linkUp
        if let holdUntil, now < holdUntil, !(shown == .connected && hardDrop) {
            return shown
        }
        holdUntil = nil
        let since = unreachedSince ?? now
        unreachedSince = since
        let target: PresentedJournalConnection
        if !next.trying
            || (!next.networkAvailable && !next.linkUp)
            || now.timeIntervalSince(since) >= Self.offlineAfter {
            target = .offline
        } else {
            target = .connecting
        }
        if shown == .connected {
            droppedAt = now
        }
        shown = target
        return shown
    }

    /// The next moment the shown state could change without new evidence.
    func nextChange(after now: Date) -> Date? {
        guard let evidence else { return nil }
        var deadlines: [Date] = []
        if let holdUntil, holdUntil > now {
            deadlines.append(holdUntil)
        }
        if Self.isHeard(evidence, at: now) {
            if let lastHeardAt = evidence.lastHeardAt {
                deadlines.append(lastHeardAt.addingTimeInterval(Self.lease))
            }
            if shown != .connected, let droppedAt {
                deadlines.append(droppedAt.addingTimeInterval(Self.minimumDropDwell))
            }
        } else if shown == .connecting, evidence.trying, let unreachedSince {
            deadlines.append(unreachedSince.addingTimeInterval(Self.offlineAfter))
        }
        return deadlines.filter { $0 > now }.min()
    }

    private static func isHeard(_ evidence: JournalConnectionEvidence, at now: Date) -> Bool {
        guard evidence.trying, evidence.linkUp, let lastHeardAt = evidence.lastHeardAt else {
            return false
        }
        return now.timeIntervalSince(lastHeardAt) < lease
    }
}

/// Keeps the sync status showing its last in-progress value for a moment after
/// the queue drains, so consecutive items read as one catch-up instead of
/// strobing between syncing and caught up. Anything other than caught up shows
/// at once.
struct SyncingPresenter: Sendable, Equatable {
    static let linger: TimeInterval = 1.5

    private(set) var shown: UploadCoordinator.Status
    private var drainedAt: Date?

    init(_ status: UploadCoordinator.Status = .notSynced) {
        shown = status
    }

    @discardableResult
    mutating func update(_ status: UploadCoordinator.Status, at now: Date) -> UploadCoordinator.Status {
        guard status == .synced, Self.isInProgress(shown) else {
            drainedAt = nil
            shown = status
            return shown
        }
        let drained = drainedAt ?? now
        drainedAt = drained
        if now >= drained.addingTimeInterval(Self.linger) {
            drainedAt = nil
            shown = status
        }
        return shown
    }

    func nextChange(after now: Date) -> Date? {
        guard let drainedAt else { return nil }
        let end = drainedAt.addingTimeInterval(Self.linger)
        return end > now ? end : nil
    }

    static func isInProgress(_ status: UploadCoordinator.Status) -> Bool {
        switch status {
        case .syncing, .uploading, .retrying:
            return true
        case .notSynced, .synced, .offline, .awaitingTunnel, .blocked:
            return false
        }
    }
}
