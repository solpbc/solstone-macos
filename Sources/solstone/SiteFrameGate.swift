// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CoreMedia
import Foundation

public struct ChromiumPollRead: Sendable, Equatable {
    public let verdict: ChromiumVerdict
    public let cause: ChromiumUnclearCause?
    public let host: String?
    public let readStart: TimeInterval
    public let listGeneration: UInt64
    public let browser: PrivateBrowser
    public let isPending: Bool

    public init(
        verdict: ChromiumVerdict,
        cause: ChromiumUnclearCause?,
        host: String?,
        readStart: TimeInterval,
        listGeneration: UInt64,
        browser: PrivateBrowser,
        isPending: Bool
    ) {
        self.verdict = verdict
        self.cause = cause
        self.host = host
        self.readStart = readStart
        self.listGeneration = listGeneration
        self.browser = browser
        self.isPending = isPending
    }
}

public struct SitePollWindow: Sendable, Equatable {
    public let windowID: CGWindowID
    public let title: String
    public let pid: pid_t
    /// Picture in Picture has no page to read, so it never gets a verdict of its own.
    public let hasPage: Bool
    public let chromium: ChromiumPollRead?

    public init(
        windowID: CGWindowID,
        title: String,
        pid: pid_t = 0,
        hasPage: Bool = true,
        chromium: ChromiumPollRead? = nil
    ) {
        self.windowID = windowID
        self.title = title
        self.pid = pid
        self.hasPage = hasPage
        self.chromium = chromium
    }
}

public struct SitePollSnapshot: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var windows: [SitePollWindow]

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
    /// How long a Safari window can stay unread before Safari sits out. Long enough that an
    /// ordinary tab switch, read within a second or so, doesn't change the filter.
    public static let unreadLimit: TimeInterval = 3.0

    internal private(set) var polls: [SitePollSnapshot] = []
    private var heldFrames: [CGDirectDisplayID: [SiteHeldFrame]] = [:]
    private var stashedStallDrops: [UInt64: [SiteFrameAction]] = [:]

    public private(set) var currentDecisions = SiteDecision()
    public private(set) var currentAXAvailable: Bool = false
    public private(set) var sites: [String] = []
    public private(set) var siteListGeneration: UInt64 = 0

    public func updateDecisions(_ decisions: SiteDecision, axAvailable: Bool) {
        self.currentDecisions = decisions
        self.currentAXAvailable = axAvailable
    }

    public func updateSiteList(_ sites: [String], generation: UInt64) {
        self.sites = sites
        self.siteListGeneration = generation
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
    public private(set) var heldSince: [CGDirectDisplayID: TimeInterval] = [:]
    /// What each display's stream has confirmed it keeps out right now. Idle frames never reach
    /// the gate, so this comes from the stream, not from the last frame seen.
    private var liveKeptOut: [CGDirectDisplayID: Set<pid_t>] = [:]

    /// When a Safari window on screen last stopped being one the rule has read as ordinary.
    private var notOrdinarySince: TimeInterval?

    private struct ChromiumSitOutState {
        var notOrdinarySince: TimeInterval?
        var stickyUnread: Bool = false
        var ordinarySince: TimeInterval?
    }

    private var chromiumSitOutStates: [PrivateBrowser: ChromiumSitOutState] = [:]

    /// Per-display recording ranges for the segment that is open. Nil outside one.
    var intakeLog: IntakeIntervalLog?

    public init() {}

    public func isPollComplete(_ poll: SitePollSnapshot, at now: TimeInterval) -> Bool {
        poll.windows.allSatisfy { win in
            guard let chromium = win.chromium else { return true }
            return !chromium.isPending || now >= poll.start + 0.5
        }
    }

    public func latestCompletePoll(at now: TimeInterval) -> SitePollSnapshot? {
        polls.last(where: { isPollComplete($0, at: now) })
    }

    public func effectiveChromiumVerdict(for read: ChromiumPollRead) -> (verdict: ChromiumVerdict, cause: ChromiumUnclearCause?) {
        if read.listGeneration != self.siteListGeneration {
            if let host = read.host, SiteRule.covers(sites: self.sites, host: host) {
                return (.covered, nil)
            } else {
                return (.cantTell, .unclear)
            }
        }
        return (read.verdict, read.cause)
    }

    /// Whether Safari should sit out of capture now, so a left-out page costs Safari and not the
    /// whole screen. A left-out page takes it out at once, a window that stays unread takes it out
    /// after `unreadLimit`, and only every window reading as ordinary brings it back. A frame still
    /// needs its own stream's vouch or an ordinary verdict, so being wrong here costs time.
    public func safariShouldSitOut(isOutNow: Bool) -> Bool {
        guard let poll = polls.last else {
            notOrdinarySince = nil
            return false
        }
        let now = poll.end
        let safariWindows = poll.windows.filter { $0.hasPage && $0.chromium == nil }
        guard !safariWindows.isEmpty else {
            notOrdinarySince = nil
            return false
        }
        let verdicts = safariWindows.map { window in
            let key = SiteDecisionKey(windowID: window.windowID, title: window.title)
            return currentDecisions.verdict(for: key, at: max(now, currentDecisions.entries[key]?.decisionTime ?? now))
        }
        guard verdicts.contains(where: { $0 != .ordinary }) else {
            notOrdinarySince = nil
            return false
        }
        let since = notOrdinarySince ?? now
        notOrdinarySince = since
        return isOutNow || verdicts.contains(.covered) || now - since >= Self.unreadLimit
    }

    public func chromiumShouldSitOut(
        for browser: PrivateBrowser,
        isOutNow: Bool,
        now: TimeInterval = HostClock.seconds(ticks: mach_absolute_time())
    ) -> Bool {
        guard let poll = polls.last(where: { p in p.windows.contains(where: { $0.chromium?.browser == browser }) }) else {
            chromiumSitOutStates.removeValue(forKey: browser)
            return false
        }
        var state = chromiumSitOutStates[browser, default: ChromiumSitOutState()]
        let browserWindows = poll.windows.filter { $0.chromium?.browser == browser }
        guard !browserWindows.isEmpty else {
            chromiumSitOutStates.removeValue(forKey: browser)
            return false
        }

        if browserWindows.contains(where: { $0.chromium?.isPending == true }) && now < poll.start + 0.5 {
            return isOutNow
        }

        let evaluated = browserWindows.map { win in
            effectiveChromiumVerdict(for: win.chromium!)
        }

        if evaluated.contains(where: { $0.verdict == .covered }) {
            state.notOrdinarySince = state.notOrdinarySince ?? poll.end
            state.ordinarySince = nil
            chromiumSitOutStates[browser] = state
            return true
        }

        let hasNonOrdinary = evaluated.contains(where: { $0.verdict != .ordinary })
        if hasNonOrdinary {
            state.ordinarySince = nil
            let since = state.notOrdinarySince ?? poll.end
            state.notOrdinarySince = since
            if evaluated.contains(where: { $0.cause == .unread }) {
                state.stickyUnread = true
            }
            chromiumSitOutStates[browser] = state
            return isOutNow || (poll.end - since >= Self.unreadLimit)
        }

        // Every window of this browser is ordinary
        if !state.stickyUnread {
            state.notOrdinarySince = nil
            state.ordinarySince = nil
            chromiumSitOutStates[browser] = state
            return false
        }

        // Sticky unread: requires 3 s unbroken ordinary polls
        let ordSince = state.ordinarySince ?? poll.end
        state.ordinarySince = ordSince
        if poll.end - ordSince >= Self.unreadLimit {
            state.stickyUnread = false
            state.notOrdinarySince = nil
            state.ordinarySince = nil
            chromiumSitOutStates[browser] = state
            return false
        }

        chromiumSitOutStates[browser] = state
        return isOutNow
    }

    /// Whether the rule is holding the screen now, for long enough to say so. A drop alone can't
    /// say: idle frames never reach the gate, so a quiet screen would stay held after one drop.
    /// So it also takes a window in the latest poll that would hold a frame now.
    public func isHoldingNow(now: TimeInterval, holdFor: TimeInterval = 3.0) -> Bool {
        guard !heldSince.isEmpty, let poll = polls.last else { return false }
        let hasPendingInsideDeadline = (now < poll.start + 0.5) && poll.windows.contains(where: { $0.chromium?.isPending == true })
        if hasPendingInsideDeadline {
            return heldSince.values.contains(where: { now - $0 >= holdFor })
        }
        for (display, since) in heldSince {
            let keptOut = liveKeptOut[display] ?? []
            let blocking = poll.windows.contains { window in
                guard !keptOut.contains(window.pid) else { return false }
                guard currentAXAvailable else { return true }
                if let chromium = window.chromium {
                    if let state = chromiumSitOutStates[chromium.browser], state.notOrdinarySince != nil {
                        return true
                    }
                    let (verdict, _) = effectiveChromiumVerdict(for: chromium)
                    return verdict != .ordinary
                } else {
                    let key = SiteDecisionKey(windowID: window.windowID, title: window.title)
                    return currentDecisions.verdict(for: key, at: now) != .ordinary
                }
            }
            if !blocking {
                intakeLog?.resume(display: String(display), at: now)
                heldSince[display] = nil
            } else if now - since >= holdFor {
                return true
            }
        }
        return false
    }

    public func patchChromiumPoll(start: TimeInterval, windowID: CGWindowID, read: ChromiumPollRead, at now: TimeInterval) {
        guard let pollIndex = polls.lastIndex(where: { abs($0.start - start) < 1e-4 }) else { return }
        var poll = polls[pollIndex]
        guard let winIndex = poll.windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        let existing = poll.windows[winIndex]

        let deadlineMissed = now >= poll.start + 0.5
        if deadlineMissed {
            if read.verdict == .covered {
                let updated = SitePollWindow(
                    windowID: existing.windowID,
                    title: existing.title,
                    pid: existing.pid,
                    hasPage: existing.hasPage,
                    chromium: read
                )
                poll.windows[winIndex] = updated
                polls[pollIndex] = poll
            }
            return
        }

        let updated = SitePollWindow(
            windowID: existing.windowID,
            title: existing.title,
            pid: existing.pid,
            hasPage: existing.hasPage,
            chromium: read
        )
        poll.windows[winIndex] = updated
        polls[pollIndex] = poll
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

    /// Chromium frame rule: a released frame had that window read ordinary by a read that
    /// started at or before the frame, by reads no more than 0.3 s apart, and through a read
    /// that started at least 0.5 s after the frame. A page committed for less than about half
    /// a second between two reads can be missed.
    public func evaluate(
        displayID: CGDirectDisplayID,
        owner: UInt64 = 0,
        decisions: SiteDecision? = nil,
        axAvailable: Bool? = nil,
        now: TimeInterval = HostClock.seconds(ticks: mach_absolute_time())
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
                    intakeLog?.hold(display: String(displayID), at: c)
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

            // Check pending Chromium windows with deadline
            let hasPendingDeadline = bracketRange.contains { poll in
                poll.windows.contains { win in
                    win.chromium?.isPending == true && now < poll.start + 0.5
                }
            }
            if hasPendingDeadline {
                stopOwner = true
                remainingQueue.append(frame)
                continue
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
                let hasCheckedWindows = bracketRange.contains(where: { !$0.windows.isEmpty })
                if hasCheckedWindows {
                    if now - c >= Self.holdLimitSites {
                        holdDropCount += 1
                        noteHoldDrop(displayID: displayID, c: c)
                        intakeLog?.hold(display: String(displayID), at: c)
                        actions.append(.drop(id: frame.id, reason: .hold))
                        continue
                    } else {
                        // Hold blocks newer frames of this owner
                        stopOwner = true
                        remainingQueue.append(frame)
                        continue
                    }
                } else {
                    // No checked window in range -> release
                    let pts = makeClampedPTS(displayID: displayID, displayTicks: displayTicks, originTicks: frame.originTicks)
                    relCount += 1
                    intakeLog?.resume(display: String(displayID), at: c)
                    heldSince[displayID] = nil
                    actions.append(.release(id: frame.id, pts: pts))
                    continue
                }
            }

            // Accessibility is available: evaluate window decisions
            var hasChromiumCovered = false
            var hasChromiumCantTell = false
            var hasChromiumGap = false

            var chromiumWindowsByID: [CGWindowID: [(pollIdx: Int, read: ChromiumPollRead)]] = [:]
            for (idx, poll) in bracketRange.enumerated() {
                for win in poll.windows {
                    guard let ch = win.chromium else { continue }
                    let effective = (ch.isPending && now >= poll.start + 0.5)
                        ? ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: ch.readStart, listGeneration: ch.listGeneration, browser: ch.browser, isPending: false)
                        : ch
                    chromiumWindowsByID[win.windowID, default: []].append((pollIdx: idx, read: effective))
                }
            }

            for (wid, entries) in chromiumWindowsByID {
                for entry in entries {
                    let (v, _) = effectiveChromiumVerdict(for: entry.read)
                    if v == .covered {
                        hasChromiumCovered = true
                    } else if v == .cantTell {
                        hasChromiumCantTell = true
                    }
                }

                let sortedEntries = entries.sorted { $0.read.readStart < $1.read.readStart }
                for i in 0..<(sortedEntries.count - 1) {
                    if sortedEntries[i + 1].read.readStart - sortedEntries[i].read.readStart > Self.maxPollGap + 1e-5 {
                        hasChromiumGap = true
                        break
                    }
                }
                if let firstEntry = sortedEntries.first {
                    if firstEntry.read.readStart > c {
                        var validPrev = false
                        if earlyIdx > 0 {
                            let prevPoll = polls[earlyIdx - 1]
                            if let prevWin = prevPoll.windows.first(where: { $0.windowID == wid }),
                               let prevCh = prevWin.chromium {
                                let (pv, _) = effectiveChromiumVerdict(for: prevCh)
                                if pv == .ordinary,
                                   prevCh.readStart <= c,
                                   firstEntry.read.readStart - prevCh.readStart <= Self.maxPollGap + 1e-5 {
                                    validPrev = true
                                }
                            }
                        }
                        if !validPrev {
                            hasChromiumGap = true
                        }
                    }
                }
            }

            let laterBracketPoll = bracketRange.last!
            let earlierPolls = bracketRange.dropLast()

            func lookupVerdict(for key: SiteDecisionKey) -> SiteVerdict {
                let decisionTime = decisions.entries[key]?.decisionTime ?? c
                let effectiveC = max(c, decisionTime)
                return decisions.verdict(for: key, at: effectiveC)
            }

            var hasSafariCovered = false
            for poll in bracketRange {
                for win in poll.windows where win.chromium == nil {
                    let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
                    let v = lookupVerdict(for: key)
                    if v == .covered {
                        hasSafariCovered = true
                        break
                    }
                }
                if hasSafariCovered { break }
            }

            if hasChromiumCovered || hasSafariCovered {
                covCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                intakeLog?.hold(display: String(displayID), at: c)
                actions.append(.drop(id: frame.id, reason: .cov))
                continue
            }

            if hasChromiumGap {
                gapCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                intakeLog?.hold(display: String(displayID), at: c)
                actions.append(.drop(id: frame.id, reason: .gap))
                continue
            }

            if hasChromiumCantTell {
                holdDropCount += 1
                noteHoldDrop(displayID: displayID, c: c)
                intakeLog?.hold(display: String(displayID), at: c)
                actions.append(.drop(id: frame.id, reason: .hold))
                continue
            }

            // Check Safari pending windows present earlier but absent from later bracket poll
            var hasPendingDisappeared = false
            for poll in earlierPolls {
                for win in poll.windows where win.chromium == nil {
                    let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
                    let v = lookupVerdict(for: key)
                    if v == .pending {
                        let presentInLater = laterBracketPoll.windows.contains(where: { $0.windowID == win.windowID && $0.chromium == nil })
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
                intakeLog?.hold(display: String(displayID), at: c)
                actions.append(.drop(id: frame.id, reason: .hold))
                continue
            }

            // Check Safari any other pending
            var hasOtherPending = false
            for poll in bracketRange {
                for win in poll.windows where win.chromium == nil {
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
                    intakeLog?.hold(display: String(displayID), at: c)
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
            intakeLog?.resume(display: String(displayID), at: c)
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
        var actions = evaluate(displayID: displayID, owner: owner, decisions: decisions, axAvailable: axAvailable, now: now)
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
        intakeLog?.endDisplay(String(displayID), at: HostClock.seconds(ticks: mach_absolute_time()))
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
        let now = HostClock.seconds(ticks: mach_absolute_time())
        for display in heldSince.keys {
            intakeLog?.resume(display: String(display), at: now)
        }
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
        notOrdinarySince = nil
        chromiumSitOutStates.removeAll()
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
