// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreMedia
import Foundation

public struct SitePollWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let title: String
    public let pid: pid_t

    public init(windowID: CGWindowID, title: String, pid: pid_t = 0) {
        self.windowID = windowID
        self.title = title
        self.pid = pid
    }
}

public struct SitePollSnapshot: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let windows: [SitePollWindow]

    public init(start: TimeInterval, end: TimeInterval, windows: [SitePollWindow]) {
        self.start = start
        self.end = end
        self.windows = windows
    }
}

public struct SiteHeldFrame: Sendable, Equatable {
    public let id: UInt64
    public let owner: UInt64
    public let displayTicks: UInt64?
    public let c: TimeInterval?
    public let originTicks: UInt64
    /// Applications the stream that captured this frame had confirmed it keeps out whole at `c`.
    public let keptOutPIDs: Set<pid_t>

    public init(id: UInt64, owner: UInt64 = 0, displayTicks: UInt64?, c: TimeInterval?, originTicks: UInt64, keptOutPIDs: Set<pid_t> = []) {
        self.keptOutPIDs = keptOutPIDs
        self.id = id
        self.owner = owner
        self.displayTicks = displayTicks
        self.c = c
        self.originTicks = originTicks
    }
}

public enum SiteFrameAction: Sendable, Equatable {
    case release(id: UInt64, pts: CMTime)
    case drop(id: UInt64, reason: SiteDropReason)
}

public enum SiteDropReason: String, Sendable, Equatable {
    case time
    case hold
    case gap
    case cov
    case stall
    case end
}

@MainActor
public final class SiteFrameGate {
    // Note: ExclusionPlanner releases held windows after 2 s; this gate drops frames after holdLimitSites (2 s).
    public static let m: TimeInterval = 0.5
    public static let maxPollGap: TimeInterval = 0.3
    public static let holdLimitSites: TimeInterval = 2.0
    public static let capacityPerDisplay = 4

    private var polls: [SitePollSnapshot] = []
    private var heldFrames: [CGDirectDisplayID: [SiteHeldFrame]] = [:]
    private var stashedStallDrops: [UInt64: [SiteFrameAction]] = [:]

    public private(set) var currentDecisions = SiteDecision()
    public private(set) var currentAXAvailable: Bool = false

    public func updateDecisions(_ decisions: SiteDecision, axAvailable: Bool) {
        self.currentDecisions = decisions
        self.currentAXAvailable = axAvailable
    }

    // Cumulative stats
    public private(set) var heldCount: Int = 0
    public private(set) var relCount: Int = 0
    public private(set) var covCount: Int = 0
    public private(set) var gapCount: Int = 0
    public private(set) var holdDropCount: Int = 0
    public private(set) var timeDropCount: Int = 0
    public private(set) var stallCount: Int = 0
    public private(set) var endCount: Int = 0

    /// `c` of the first frame dropped since each display's last release.
    private var heldSince: [CGDirectDisplayID: TimeInterval] = [:]
    /// What each display's stream has confirmed it keeps out right now. Idle frames never reach
    /// the gate, so this comes from the stream, not from the last frame seen.
    private var liveKeptOut: [CGDirectDisplayID: Set<pid_t>] = [:]

    public init() {}

    /// Whether the rule is holding the screen now, for long enough to say so. A drop alone can't
    /// say: idle frames never reach the gate, so a quiet screen would stay held after one drop.
    /// So it also takes a window in the latest poll that would hold a frame now.
    public func isHoldingNow(now: TimeInterval, holdFor: TimeInterval = 3.0) -> Bool {
        guard !heldSince.isEmpty, let poll = polls.last else { return false }
        for (display, since) in heldSince {
            let keptOut = liveKeptOut[display] ?? []
            let blocking = poll.windows.contains { window in
                guard !keptOut.contains(window.pid) else { return false }
                guard currentAXAvailable else { return true }
                let key = SiteDecisionKey(windowID: window.windowID, title: window.title)
                return currentDecisions.verdict(for: key, at: now) != .ordinary
            }
            if !blocking {
                heldSince[display] = nil
            } else if now - since >= holdFor {
                return true
            }
        }
        return false
    }

    public func updateLiveKeptOut(displayID: CGDirectDisplayID, pids: Set<pid_t>) {
        liveKeptOut[displayID] = pids
    }

    private func noteHoldDrop(displayID: CGDirectDisplayID, c: TimeInterval?) {
        guard let c, heldSince[displayID] == nil else { return }
        heldSince[displayID] = c
    }

    public func addPoll(_ poll: SitePollSnapshot) {
        polls.append(poll)
        // Keep about 8 seconds of polls (at 4 Hz, 32-40 polls)
        if polls.count > 48 {
            polls.removeFirst(polls.count - 48)
        }
    }

    /// Enqueues a frame for gating on the specified display.
    /// Drops the oldest if exceeding capacity 4 (reason: stall).
    public func enqueue(
        displayID: CGDirectDisplayID,
        frame: SiteHeldFrame,
        owner: UInt64 = 0
    ) -> [SiteFrameAction] {
        var actions: [SiteFrameAction] = []
        var queue = heldFrames[displayID] ?? []

        if queue.count >= Self.capacityPerDisplay {
            let oldest = queue.removeFirst()
            stallCount += 1
            noteHoldDrop(displayID: displayID, c: oldest.c)
            let drop = SiteFrameAction.drop(id: oldest.id, reason: .stall)
            let effectiveOwner = owner != 0 ? owner : frame.owner
            if oldest.owner == effectiveOwner {
                actions.append(drop)
            } else {
                stashedStallDrops[oldest.owner, default: []].append(drop)
            }
        }

        queue.append(frame)
        heldFrames[displayID] = queue
        updateHeldCount()
        return actions
    }

    /// Evaluates held frames for a display, releasing a prefix of valid frames or dropping.
    public func evaluate(
        displayID: CGDirectDisplayID,
        now: TimeInterval,
        owner: UInt64 = 0,
        decisions: SiteDecision? = nil,
        axAvailable: Bool? = nil
    ) -> [SiteFrameAction] {
        let decisions = decisions ?? currentDecisions
        let axAvailable = axAvailable ?? currentAXAvailable
        var actions: [SiteFrameAction] = []
        if let stashed = stashedStallDrops.removeValue(forKey: owner) {
            actions.append(contentsOf: stashed)
        }

        guard let queue = heldFrames[displayID], !queue.isEmpty else { return actions }

        var remainingQueue: [SiteHeldFrame] = []
        var stopOwner = false

        for frame in queue {
            if frame.owner != owner {
                remainingQueue.append(frame)
                continue
            }

            if stopOwner {
                remainingQueue.append(frame)
                continue
            }

            guard let displayTicks = frame.displayTicks, let c = frame.c else {
                timeDropCount += 1
                actions.append(.drop(id: frame.id, reason: .time))
                continue
            }

            // Find bracketing polls
            let pEarlyIndex = polls.lastIndex(where: { $0.end <= c })
            let pLateIndex = polls.firstIndex(where: { $0.start >= c + Self.m })

            guard let earlyIdx = pEarlyIndex, let lateIdx = pLateIndex, earlyIdx <= lateIdx else {
                if now - c >= Self.holdLimitSites {
                    holdDropCount += 1
                    noteHoldDrop(displayID: displayID, c: c)
                    actions.append(.drop(id: frame.id, reason: .hold))
                    continue
                } else {
                    // Still waiting for bracketing polls; hold blocks newer frames of this owner
                    stopOwner = true
                    remainingQueue.append(frame)
                    continue
                }
            }

            // A window this frame's stream confirmed it keeps out can't be in this frame.
            let bracketRange = polls[earlyIdx...lateIdx].map { poll in
                SitePollSnapshot(start: poll.start, end: poll.end, windows: poll.windows.filter { !frame.keptOutPIDs.contains($0.pid) })
            }

            // Check consecutive poll gaps > 0.3 s
            var hasGap = false
            for i in 0..<(bracketRange.count - 1) {
                let gap = bracketRange[i + 1].start - bracketRange[i].end
                if gap > Self.maxPollGap + 1e-5 {
                    hasGap = true
                    break
                }
            }

            if hasGap {
                gapCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                actions.append(.drop(id: frame.id, reason: .gap))
                continue
            }

            // Check Accessibility availability
            if !axAvailable {
                let hasSafari = bracketRange.contains(where: { !$0.windows.isEmpty })
                if hasSafari {
                    if now - c >= Self.holdLimitSites {
                        holdDropCount += 1
                        noteHoldDrop(displayID: displayID, c: c)
                        actions.append(.drop(id: frame.id, reason: .hold))
                        continue
                    } else {
                        // Hold blocks newer frames of this owner
                        stopOwner = true
                        remainingQueue.append(frame)
                        continue
                    }
                } else {
                    // No Safari window in range -> release
                    let pts = makeClampedPTS(displayID: displayID, displayTicks: displayTicks, originTicks: frame.originTicks)
                    relCount += 1
                    heldSince[displayID] = nil
                    actions.append(.release(id: frame.id, pts: pts))
                    continue
                }
            }

            // Accessibility is available: evaluate window decisions
            var hasCovered = false
            var hasPendingDisappeared = false
            var hasOtherPending = false

            let laterBracketPoll = bracketRange.last!
            let earlierPolls = bracketRange.dropLast()

            func lookupVerdict(for key: SiteDecisionKey) -> SiteVerdict {
                let decisionTime = decisions.entries[key]?.decisionTime ?? c
                let effectiveC = max(c, decisionTime)
                return decisions.verdict(for: key, at: effectiveC)
            }

            for poll in bracketRange {
                for win in poll.windows {
                    let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
                    let v = lookupVerdict(for: key)
                    if v == .covered {
                        hasCovered = true
                        break
                    }
                }
                if hasCovered { break }
            }

            if hasCovered {
                covCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                actions.append(.drop(id: frame.id, reason: .cov))
                continue
            }

            // Check pending windows present earlier but absent from later bracket poll
            for poll in earlierPolls {
                for win in poll.windows {
                    let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
                    let v = lookupVerdict(for: key)
                    if v == .pending {
                        let presentInLater = laterBracketPoll.windows.contains(where: { $0.windowID == win.windowID })
                        if !presentInLater {
                            hasPendingDisappeared = true
                            break
                        }
                    }
                }
                if hasPendingDisappeared { break }
            }

            if hasPendingDisappeared {
                holdDropCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                actions.append(.drop(id: frame.id, reason: .hold))
                continue
            }

            // Check any other pending
            for poll in bracketRange {
                for win in poll.windows {
                    let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
                    let v = lookupVerdict(for: key)
                    if v == .pending {
                        hasOtherPending = true
                        break
                    }
                }
                if hasOtherPending { break }
            }

            if hasOtherPending {
                if now - c >= Self.holdLimitSites {
                    holdDropCount += 1
                    noteHoldDrop(displayID: displayID, c: c)
                    actions.append(.drop(id: frame.id, reason: .hold))
                    continue
                } else {
                    // Hold blocks newer frames of this owner
                    stopOwner = true
                    remainingQueue.append(frame)
                    continue
                }
            }

            // All windows ordinary across bracket range -> release
            let pts = makeClampedPTS(displayID: displayID, displayTicks: displayTicks, originTicks: frame.originTicks)
            relCount += 1
            heldSince[displayID] = nil
            actions.append(.release(id: frame.id, pts: pts))
        }

        heldFrames[displayID] = remainingQueue
        updateHeldCount()
        return actions
    }

    /// Drains held frames at segment completion: evaluates once more, drops the rest as `end`.
    public func drain(
        displayID: CGDirectDisplayID,
        now: TimeInterval,
        owner: UInt64 = 0,
        decisions: SiteDecision? = nil,
        axAvailable: Bool? = nil
    ) -> [SiteFrameAction] {
        var actions = evaluate(displayID: displayID, now: now, owner: owner, decisions: decisions, axAvailable: axAvailable)
        if let queue = heldFrames[displayID] {
            var remaining: [SiteHeldFrame] = []
            for frame in queue {
                if frame.owner == owner {
                    endCount += 1
                    actions.append(.drop(id: frame.id, reason: .end))
                } else {
                    remaining.append(frame)
                }
            }
            heldFrames[displayID] = remaining
            updateHeldCount()
        }
        return actions
    }

    /// Deactivating drops held frames immediately without releasing them.
    public func deactivate(displayID: CGDirectDisplayID, owner: UInt64 = 0) -> [SiteFrameAction] {
        heldSince[displayID] = nil
        guard let queue = heldFrames[displayID] else { return [] }
        var dropped: [SiteFrameAction] = []
        var remaining: [SiteHeldFrame] = []
        for frame in queue {
            if frame.owner == owner {
                endCount += 1
                dropped.append(.drop(id: frame.id, reason: .end))
            } else {
                remaining.append(frame)
            }
        }
        heldFrames[displayID] = remaining
        updateHeldCount()
        return dropped
    }

    public func deactivateAll() -> [SiteFrameAction] {
        var actions: [SiteFrameAction] = []
        for (_, queue) in heldFrames {
            for frame in queue {
                endCount += 1
                actions.append(.drop(id: frame.id, reason: .end))
            }
        }
        heldFrames.removeAll()
        stashedStallDrops.removeAll()
        heldSince.removeAll()
        liveKeptOut.removeAll()
        updateHeldCount()
        return actions
    }

    private func updateHeldCount() {
        heldCount = heldFrames.values.reduce(0) { $0 + $1.count }
    }

    internal func makeClampedPTS(displayID: CGDirectDisplayID, displayTicks: UInt64, originTicks: UInt64) -> CMTime {
        let rawSeconds = HostClock.seconds(ticks: displayTicks) - HostClock.seconds(ticks: originTicks)
        return CMTime(seconds: rawSeconds, preferredTimescale: 600)
    }
}
