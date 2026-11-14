// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

public enum SiteWindowObservation {
    public static func isProcessAliveProduction(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    public static func copyApplicationWindowsAX(_ pid: pid_t) -> [AXUIElement]? {
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.05)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let winList = windowsValue as? [AXUIElement] else {
            return nil
        }
        return winList
    }

    public static func observeSiteWindow(
        wid: CGWindowID,
        pid: pid_t,
        title: String,
        isProcessAlive: @Sendable (pid_t) -> Bool = isProcessAliveProduction,
        copyWindows: @Sendable (pid_t) -> [AXUIElement]? = copyApplicationWindowsAX
    ) -> (initialAXTitle: String?, walk: WebAreaWalkResult, finalAXTitle: String?, windowMissing: Bool) {
        guard isProcessAlive(pid) else {
            return (nil, WebAreaWalkResult(urls: [], completeness: .axError), nil, true)
        }

        guard let winList = copyWindows(pid) else {
            return (title, WebAreaWalkResult(urls: [], completeness: .axError), title, false)
        }

        guard let targetWindow = winList.first(where: {
            var w: CGWindowID = 0
            return _AXUIElementGetWindow($0, &w) == .success && w == wid
        }) else {
            return (nil, WebAreaWalkResult(urls: [], completeness: .axError), nil, true)
        }

        AXUIElementSetMessagingTimeout(targetWindow, 0.025)
        func readStr(_ attr: String) -> String? {
            var val: CFTypeRef?
            guard AXUIElementCopyAttributeValue(targetWindow, attr as CFString, &val) == .success else { return nil }
            return val as? String
        }
        let initial = readStr(kAXTitleAttribute)
        let walk = WebAreaWalker.walk(targetWindow, mode: .everyTopLevel)
        let final = readStr(kAXTitleAttribute)
        return (initial, walk, final, false)
    }
}

struct SiteVisibleWindow: Sendable, Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let layer: Int
    let title: String

    init(windowID: CGWindowID, pid: pid_t, layer: Int, title: String) {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.title = title
    }
}

struct SiteSamplerHooks: Sendable {
    var safariPIDs: @Sendable () -> Set<pid_t>
    var pipPIDs: @Sendable () -> Set<pid_t>
    var chromePIDs: @Sendable () -> Set<pid_t>
    var edgePIDs: @Sendable () -> Set<pid_t>
    var bravePIDs: @Sendable () -> Set<pid_t>
    var copyOnScreen: @Sendable () -> [SiteVisibleWindow]
    var nowTicks: @Sendable () -> UInt64
    var observe: @Sendable (CGWindowID, pid_t, String) -> (initialAXTitle: String?, walk: WebAreaWalkResult, finalAXTitle: String?, windowMissing: Bool)
    var chromiumReader: ChromiumWindowReading

    init(
        safariPIDs: @escaping @Sendable () -> Set<pid_t> = {
            let safariBundleID = PrivateBrowser.safari.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == safariBundleID }.map(\.processIdentifier))
        },
        pipPIDs: @escaping @Sendable () -> Set<pid_t> = {
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == ExclusionPlanner.pictureInPictureBundleID }.map(\.processIdentifier))
        },
        chromePIDs: @escaping @Sendable () -> Set<pid_t> = {
            let bundleID = PrivateBrowser.chrome.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier))
        },
        edgePIDs: @escaping @Sendable () -> Set<pid_t> = {
            let bundleID = PrivateBrowser.edge.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier))
        },
        bravePIDs: @escaping @Sendable () -> Set<pid_t> = {
            let bundleID = PrivateBrowser.brave.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier))
        },
        copyOnScreen: @escaping @Sendable () -> [SiteVisibleWindow] = {
            let raw = OnScreenWindowList.copyOnScreenInfo()
            return raw.compactMap { w in
                guard let wid = w[kCGWindowNumber as String] as? CGWindowID,
                      let pid = w[kCGWindowOwnerPID as String] as? Int,
                      let layer = w[kCGWindowLayer as String] as? Int else {
                    return nil
                }
                let title = w[kCGWindowName as String] as? String ?? ""
                return SiteVisibleWindow(windowID: wid, pid: pid_t(pid), layer: layer, title: title)
            }
        },
        nowTicks: @escaping @Sendable () -> UInt64 = {
            mach_absolute_time()
        },
        observe: @escaping @Sendable (CGWindowID, pid_t, String) -> (initialAXTitle: String?, walk: WebAreaWalkResult, finalAXTitle: String?, windowMissing: Bool) = { wid, pid, title in
            SiteWindowObservation.observeSiteWindow(wid: wid, pid: pid, title: title)
        },
        chromiumReader: ChromiumWindowReading = LiveChromiumWindowReader()
    ) {
        self.safariPIDs = safariPIDs
        self.pipPIDs = pipPIDs
        self.chromePIDs = chromePIDs
        self.edgePIDs = edgePIDs
        self.bravePIDs = bravePIDs
        self.copyOnScreen = copyOnScreen
        self.nowTicks = nowTicks
        self.observe = observe
        self.chromiumReader = chromiumReader
    }
}

struct AccessibilityProbe: Sendable {
    let readWorks: @Sendable () -> Bool
    let prompt: @MainActor @Sendable () -> Void

    init(
        readWorks: @escaping @Sendable () -> Bool = {
            AccessibilityTitleReader().health() == .working
        },
        prompt: @escaping @MainActor @Sendable () -> Void = {
            // macOS lists an app in that pane only after it has asked.
            AccessibilityTitleReader.ask()
            AccessibilityTitleReader.openSystemSettings()
        }
    ) {
        self.readWorks = readWorks
        self.prompt = prompt
    }
}

actor SiteSampler {
    private let walkQueue = DispatchQueue(label: "app.solstone.observer.site-walk")
    private let chromeQueue = DispatchQueue(label: "app.solstone.observer.site-chromium.chrome")
    private let edgeQueue = DispatchQueue(label: "app.solstone.observer.site-chromium.edge")
    private let braveQueue = DispatchQueue(label: "app.solstone.observer.site-chromium.brave")

    private var sites: [String] = []
    private var probe: AccessibilityProbe
    private let isSnapshot: Bool
    private let hooks: SiteSamplerHooks
    private var pollTimer: Task<Void, Never>?
    private var walkTimer: Task<Void, Never>?
    private var probeTimer: Task<Void, Never>?

    private var decisions = SiteDecision()
    private var schedulerCursor: Int = 0
    private var recentPendingKeys: [SiteDecisionKey] = []
    private var latestSafariWindows: [SitePollWindow] = []
    private var pidsByWindowID: [CGWindowID: pid_t] = [:]
    private var isWalking = false
    private var isAXWorking: Bool = false
    private var appliedGeneration: UInt64 = 0

    private var inFlight: [PrivateBrowser: Bool] = [:]
    private var failureCounts: [PrivateBrowser: Int] = [:]
    private var rule6Records: [CGWindowID: ChromiumRule6Record] = [:]
    private var previousTitles: [CGWindowID: (cg: String, ax: String)] = [:]
    private var passResults: [CGWindowID: ChromiumPassResult] = [:]
    private var rememberedHosts: [CGWindowID: [(host: String, time: TimeInterval)]] = [:]
    private var passAttemptTimes: [CGWindowID: TimeInterval] = [:]
    private var budgetCutPasses: [PrivateBrowser: Set<CGWindowID>] = [:]
    private var lastKnownKeys: [CGWindowID: (axTitle: String, docHash: Int)] = [:]

    private let onPoll: @MainActor @Sendable (SitePollSnapshot) -> Void
    private let onDecisionUpdate: @MainActor @Sendable (SiteDecision, Bool, UInt64) -> Void
    private let onChromiumReadComplete: (@MainActor @Sendable (PrivateBrowser, [CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)], TimeInterval, UInt64) -> Void)?
    private let onChromiumCautionUpdate: (@MainActor @Sendable (PrivateBrowser, Bool) -> Void)?
    private let onChromiumMiss: (@MainActor @Sendable (PrivateBrowser, CGWindowID, String, TimeInterval, UInt64) -> Void)?

    init(
        probe: AccessibilityProbe = AccessibilityProbe(),
        isSnapshot: Bool = false,
        hooks: SiteSamplerHooks = SiteSamplerHooks(),
        onPoll: @escaping @MainActor @Sendable (SitePollSnapshot) -> Void,
        onDecisionUpdate: @escaping @MainActor @Sendable (SiteDecision, Bool, UInt64) -> Void,
        onChromiumReadComplete: (@MainActor @Sendable (PrivateBrowser, [CGWindowID: (read: ChromiumPollRead, cgTitle: String, axTitle: String?)], TimeInterval, UInt64) -> Void)? = nil,
        onChromiumCautionUpdate: (@MainActor @Sendable (PrivateBrowser, Bool) -> Void)? = nil,
        onChromiumMiss: (@MainActor @Sendable (PrivateBrowser, CGWindowID, String, TimeInterval, UInt64) -> Void)? = nil
    ) {
        self.probe = probe
        self.isSnapshot = isSnapshot
        self.hooks = hooks
        self.onPoll = onPoll
        self.onDecisionUpdate = onDecisionUpdate
        self.onChromiumReadComplete = onChromiumReadComplete
        self.onChromiumCautionUpdate = onChromiumCautionUpdate
        self.onChromiumMiss = onChromiumMiss
        self.isAXWorking = false
        Task { [weak self] in
            await self?.checkProbe()
        }
    }

    func performPollForTesting() async {
        await performPoll()
    }

    func performWalkPassForTesting() async {
        await performWalkPass()
    }

    var isPollingForTesting: Bool {
        pollTimer != nil
    }

    var decisionsForTesting: SiteDecision {
        decisions
    }

    var appliedGenerationForTesting: UInt64 {
        appliedGeneration
    }

    internal private(set) var appliedSitesForTesting: [[String]] = []

    func setSitesForTesting(_ newSites: [String]) {
        self.sites = newSites
    }

    func failureCountForTesting(_ browser: PrivateBrowser) -> Int {
        failureCounts[browser, default: 0]
    }

    func rule6RecordForTesting(_ wid: CGWindowID) -> ChromiumRule6Record? {
        rule6Records[wid]
    }

    func passResultForTesting(_ wid: CGWindowID) -> ChromiumPassResult? {
        passResults[wid]
    }

    func applySites(_ newSites: [String], generation: UInt64) async {
        guard generation >= appliedGeneration else { return }
        appliedGeneration = generation
        appliedSitesForTesting.append(newSites)
        self.sites = newSites
        self.decisions = SiteDecision()
        self.recentPendingKeys.removeAll()

        let nowSec = HostClock.seconds(ticks: hooks.nowTicks())
        for (wid, entries) in rememberedHosts {
            let fresh = entries.filter { nowSec - $0.time <= 5.0 }
            for entry in fresh {
                if SiteRule.covers(sites: newSites, host: entry.host) {
                    rule6Records[wid] = ChromiumRule6Record(waitStart: nowSec, host: entry.host)
                    break
                }
            }
        }

        if newSites.isEmpty {
            stop()
        } else if pollTimer == nil {
            await start()
        }
    }

    func updateSites(_ newSites: [String]) async {
        await applySites(newSites, generation: appliedGeneration + 1)
    }

    func setProbe(_ newProbe: AccessibilityProbe) {
        self.probe = newProbe
    }

    func start() async {
        stop()
        guard !sites.isEmpty else { return }

        if isSnapshot {
            let currentProbe = probe
            let works = await Task.detached { currentProbe.readWorks() }.value
            self.isAXWorking = works
            let currentDecisions = self.decisions
            let gen = appliedGeneration
            Task { @MainActor in
                self.onDecisionUpdate(currentDecisions, works, gen)
            }
            return
        }

        // Initial probe check
        Task { [weak self] in
            await self?.checkProbe()
        }

        // 4 Hz poll loop (every 250 ms)
        pollTimer = Task { [weak self] in
            var scheduledStart = ContinuousClock.now
            while !Task.isCancelled {
                let actualStart = ContinuousClock.now
                await self?.performPoll()
                let elapsed = ContinuousClock.now - actualStart
                let targetInterval = Duration.milliseconds(250)
                if elapsed >= targetInterval {
                    scheduledStart = ContinuousClock.now
                } else {
                    let nextScheduled = scheduledStart + targetInterval
                    let remaining = nextScheduled - ContinuousClock.now
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                        scheduledStart = nextScheduled
                    } else {
                        scheduledStart = ContinuousClock.now
                    }
                }
            }
        }

        // 1 Hz walk loop (every 1000 ms)
        walkTimer = Task { [weak self] in
            var scheduledStart = ContinuousClock.now
            while !Task.isCancelled {
                let actualStart = ContinuousClock.now
                await self?.performWalkPass()
                let elapsed = ContinuousClock.now - actualStart
                let targetInterval = Duration.seconds(1)
                if elapsed >= targetInterval {
                    scheduledStart = ContinuousClock.now
                } else {
                    let nextScheduled = scheduledStart + targetInterval
                    let remaining = nextScheduled - ContinuousClock.now
                    if remaining > .zero {
                        try? await Task.sleep(for: remaining)
                        scheduledStart = nextScheduled
                    } else {
                        scheduledStart = ContinuousClock.now
                    }
                }
            }
        }

        // 2 s probe loop
        probeTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.checkProbe()
            }
        }
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        walkTimer?.cancel()
        walkTimer = nil
        probeTimer?.cancel()
        probeTimer = nil
    }

    private func checkProbe() async {
        let currentProbe = probe
        let working = await Task.detached { currentProbe.readWorks() }.value
        isAXWorking = working
        let currentDecisions = decisions
        let gen = appliedGeneration
        await onDecisionUpdate(currentDecisions, working, gen)
    }

    private func queue(for browser: PrivateBrowser) -> DispatchQueue {
        switch browser {
        case .chrome: return chromeQueue
        case .edge: return edgeQueue
        case .brave: return braveQueue
        default: return walkQueue
        }
    }

    private func performPoll() async {
        let safariPids = hooks.safariPIDs()
        let pipPids = hooks.pipPIDs()
        let chromePids = hooks.chromePIDs()
        let edgePids = hooks.edgePIDs()
        let bravePids = hooks.bravePIDs()

        let startTicks = hooks.nowTicks()
        let rawWindows = hooks.copyOnScreen()
        let endTicks = hooks.nowTicks()

        let startSec = HostClock.seconds(ticks: startTicks)
        let endSec = HostClock.seconds(ticks: endTicks)

        var safariWindows: [SitePollWindow] = []
        var pollPids: [CGWindowID: pid_t] = [:]

        // Picture in Picture holds a frame until its stream has it out, but it has no page to read,
        // so it never joins the windows that get walked.
        var pipWindows: [SitePollWindow] = []

        var chromeWindows: [(wid: CGWindowID, pid: pid_t, layer: Int, title: String)] = []
        var edgeWindows: [(wid: CGWindowID, pid: pid_t, layer: Int, title: String)] = []
        var braveWindows: [(wid: CGWindowID, pid: pid_t, layer: Int, title: String)] = []

        for w in rawWindows {
            if pipPids.contains(w.pid) {
                pipWindows.append(SitePollWindow(windowID: w.windowID, title: w.title, pid: w.pid, hasPage: false))
                continue
            }
            if w.layer == 0 && safariPids.contains(w.pid) {
                safariWindows.append(SitePollWindow(windowID: w.windowID, title: w.title, pid: w.pid))
                pollPids[w.windowID] = w.pid
                continue
            }
            if w.layer == 0 || w.layer == 3 {
                if chromePids.contains(w.pid) {
                    chromeWindows.append((wid: w.windowID, pid: w.pid, layer: w.layer, title: w.title))
                    pollPids[w.windowID] = w.pid
                } else if edgePids.contains(w.pid) {
                    edgeWindows.append((wid: w.windowID, pid: w.pid, layer: w.layer, title: w.title))
                    pollPids[w.windowID] = w.pid
                } else if bravePids.contains(w.pid) {
                    braveWindows.append((wid: w.windowID, pid: w.pid, layer: w.layer, title: w.title))
                    pollPids[w.windowID] = w.pid
                }
            }
        }

        latestSafariWindows = safariWindows
        pidsByWindowID = pollPids
        decisions.forgetCautions(notIn: Set(safariWindows.map { SiteDecisionKey(windowID: $0.windowID, title: $0.title) }))

        var chromiumPollWindows: [SitePollWindow] = []
        let browserGroups: [(browser: PrivateBrowser, windows: [(wid: CGWindowID, pid: pid_t, layer: Int, title: String)])] = [
            (.chrome, chromeWindows),
            (.edge, edgeWindows),
            (.brave, braveWindows)
        ]

        for (browser, wins) in browserGroups {
            guard !wins.isEmpty else { continue }
            let sortedWins = wins.sorted { $0.wid < $1.wid }
            if inFlight[browser] == true {
                for w in sortedWins {
                    if var r6 = rule6Records[w.wid] {
                        r6.waitStart = startSec
                        r6.firstOrdinaryAt = nil
                        rule6Records[w.wid] = r6
                    }
                    failureCounts[browser, default: 0] += 1
                    let read = ChromiumPollRead(
                        verdict: .cantTell,
                        cause: .unread,
                        host: nil,
                        readStart: startSec,
                        listGeneration: appliedGeneration,
                        browser: browser,
                        isPending: false
                    )
                    chromiumPollWindows.append(SitePollWindow(windowID: w.wid, title: w.title, pid: w.pid, hasPage: true, chromium: read))
                    let onMiss = self.onChromiumMiss
                    let gen = self.appliedGeneration
                    Task { @MainActor in
                        onMiss?(browser, w.wid, w.title, startSec, gen)
                    }
                }
                let caution = failureCounts[browser, default: 0] >= 10
                let onCaution = self.onChromiumCautionUpdate
                Task { @MainActor in
                    onCaution?(browser, caution)
                }
            } else {
                inFlight[browser] = true
                for w in sortedWins {
                    let pendingRead = ChromiumPollRead(
                        verdict: .cantTell,
                        cause: nil,
                        host: nil,
                        readStart: startSec,
                        listGeneration: appliedGeneration,
                        browser: browser,
                        isPending: true
                    )
                    chromiumPollWindows.append(SitePollWindow(windowID: w.wid, title: w.title, pid: w.pid, hasPage: true, chromium: pendingRead))
                }
                dispatchChromiumRound(browser: browser, windows: sortedWins, startSec: startSec)
            }
        }

        let snapshot = SitePollSnapshot(start: startSec, end: endSec, windows: safariWindows + pipWindows + chromiumPollWindows)
        await onPoll(snapshot)

        // Track pending keys for scheduler (newest first). fresh pending only, cap 64.
        var freshPending: [SiteDecisionKey] = []
        for win in safariWindows {
            let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
            let v = decisions.verdict(for: key, at: endSec)
            if v == .pending {
                freshPending.append(key)
            }
        }
        recentPendingKeys = freshPending.count > 64 ? Array(freshPending.prefix(64)) : freshPending
    }

    private func dispatchChromiumRound(
        browser: PrivateBrowser,
        windows: [(wid: CGWindowID, pid: pid_t, layer: Int, title: String)],
        startSec: TimeInterval
    ) {
        let queue = queue(for: browser)
        let reader = hooks.chromiumReader
        let nowTicks = hooks.nowTicks
        let currentSites = sites
        let currentGeneration = appliedGeneration
        let localRule6 = rule6Records
        let localPrevTitles = previousTitles
        let localPassResults = passResults
        let localRemembered = rememberedHosts
        let localAttemptTimes = passAttemptTimes
        let localBudgetCut = budgetCutPasses[browser] ?? []
        let localLastKnownKeys = lastKnownKeys

        queue.async { [weak self] in
            guard let self else { return }
            var results: [CGWindowID: (read: ChromiumPollRead, completed: Bool, cgTitle: String, axTitle: String?)] = [:]
            var updatedRule6 = localRule6
            var updatedPassResults = localPassResults
            var updatedPrevTitles = localPrevTitles
            var updatedRemembered = localRemembered
            var updatedAttemptTimes = localAttemptTimes
            var newBudgetCut: Set<CGWindowID> = []
            var updatedLastKnownKeys = localLastKnownKeys
            var readStarts: [CGWindowID: TimeInterval] = [:]

            // Group PIDs and copy AX windows
            let pids = Set(windows.map(\.pid))
            var axElementsByWindowID: [CGWindowID: AXUIElement] = [:]
            for pid in pids {
                if let axWins = reader.copyWindows(for: pid) {
                    for axWin in axWins {
                        if let wid = reader.windowID(for: axWin) {
                            axElementsByWindowID[wid] = axWin
                        }
                    }
                }
            }

            let sideWindows = windows.filter { $0.layer == 3 }
            let pageWindows = windows.filter { $0.layer == 0 }

            // 1. Opening title and AXDocument for every page window, back to back.
            // Stamp readStart from hooks.nowTicks immediately before opening title read.
            var openingTitles: [CGWindowID: String?] = [:]
            var docs: [CGWindowID: String?] = [:]
            var docFailed: [CGWindowID: Bool] = [:]

            for w in pageWindows {
                guard let elem = axElementsByWindowID[w.wid] else {
                    readStarts[w.wid] = startSec
                    openingTitles[w.wid] = nil
                    docs[w.wid] = nil
                    docFailed[w.wid] = true
                    continue
                }
                let winStartSec = HostClock.seconds(ticks: nowTicks())
                readStarts[w.wid] = winStartSec
                let title = reader.readTitle(for: elem)
                let (d, failed) = reader.readDocument(for: elem)
                openingTitles[w.wid] = title
                docs[w.wid] = d
                docFailed[w.wid] = failed
                if let d, let host = SiteRule.normalizeReadHost(d) {
                    let nowSec = HostClock.seconds(ticks: nowTicks())
                    var entries = updatedRemembered[w.wid, default: []].filter { nowSec - $0.time <= 5.0 }
                    entries.append((host: host, time: nowSec))
                    updatedRemembered[w.wid] = entries
                }
            }

            // 2. Closing titles for page windows with no pass due.
            var closingTitles: [CGWindowID: String?] = [:]
            var windowsNeedingPass: [CGWindowID] = []

            for w in pageWindows {
                guard let elem = axElementsByWindowID[w.wid], !(docFailed[w.wid] ?? true) else {
                    closingTitles[w.wid] = nil
                    continue
                }
                let docStr = docs[w.wid] ?? nil
                let openTitle = openingTitles[w.wid] ?? nil

                // Covered window does not need a tab-strip pass
                if let d = docStr, let h = SiteRule.normalizeReadHost(d), !currentSites.isEmpty, currentSites.contains(where: { SiteRule.covers(siteHost: $0, host: h) }) {
                    closingTitles[w.wid] = reader.readTitle(for: elem)
                    continue
                }

                let docHash = ChromiumSiteRead.documentIdentityHash(doc: docStr ?? "", axTitle: openTitle ?? "")
                if let carried = updatedPassResults[w.wid], carried.axTitle == (openTitle ?? "") && carried.docHash == docHash {
                    let age = HostClock.seconds(ticks: nowTicks()) - carried.time
                    if age < 1.0 {
                        closingTitles[w.wid] = reader.readTitle(for: elem)
                        continue
                    }
                }
                windowsNeedingPass.append(w.wid)
            }

            // 3. Side-window walks. Stamp readStart immediately before that walk.
            for w in sideWindows {
                guard let elem = axElementsByWindowID[w.wid] else {
                    readStarts[w.wid] = startSec
                    if var r6 = updatedRule6[w.wid] {
                        r6.waitStart = startSec
                        r6.firstOrdinaryAt = nil
                        updatedRule6[w.wid] = r6
                    }
                    results[w.wid] = (
                        read: ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: startSec, listGeneration: currentGeneration, browser: browser, isPending: false),
                        completed: false,
                        cgTitle: w.title,
                        axTitle: nil
                    )
                    continue
                }
                let sideStartSec = HostClock.seconds(ticks: nowTicks())
                readStarts[w.wid] = sideStartSec
                let (texts, outcome) = reader.walkSideWindow(for: elem, maxNodes: 300, timeoutSeconds: 0.150, nowTicks: nowTicks)
                let eval = ChromiumSiteRead.evaluateSideWindow(
                    windowID: w.wid,
                    staticTexts: texts,
                    walkOutcome: outcome,
                    rule6Record: &updatedRule6[w.wid],
                    sites: currentSites,
                    now: HostClock.seconds(ticks: nowTicks())
                )
                let isCompleted = (outcome != .failed && outcome != .timedOut)
                results[w.wid] = (
                    read: ChromiumPollRead(verdict: eval.verdict, cause: eval.cause, host: eval.host, readStart: sideStartSec, listGeneration: currentGeneration, browser: browser, isPending: false),
                    completed: isCompleted,
                    cgTitle: w.title,
                    axTitle: nil
                )
            }

            // 4. Passes.
            // Changed windows go first. Among refresh-due windows, promote one previous-round .budgetCut window.
            func isChanged(_ wid: CGWindowID) -> Bool {
                let openTitle = (openingTitles[wid] ?? nil) ?? ""
                let docStr = (docs[wid] ?? nil) ?? ""
                let docHash = ChromiumSiteRead.documentIdentityHash(doc: docStr, axTitle: openTitle)
                guard let prevKey = localLastKnownKeys[wid] else { return true }
                return prevKey.axTitle != openTitle || prevKey.docHash != docHash
            }

            let changedPassWindows = windowsNeedingPass.filter { isChanged($0) }.sorted(by: <)
            let refreshDuePassWindows = windowsNeedingPass.filter { !isChanged($0) }

            let budgetCutCandidates = refreshDuePassWindows.filter { localBudgetCut.contains($0) }
            let promoted = budgetCutCandidates.min { a, b in
                let aTime = updatedAttemptTimes[a] ?? 0
                let bTime = updatedAttemptTimes[b] ?? 0
                if aTime != bTime { return aTime < bTime }
                return a < b
            }

            let remainingRefreshDue = refreshDuePassWindows.filter { $0 != promoted }
            let sortedRemaining = remainingRefreshDue.sorted { a, b in
                let aTime = updatedAttemptTimes[a] ?? 0
                let bTime = updatedAttemptTimes[b] ?? 0
                if aTime != bTime { return aTime < bTime }
                return a < b
            }

            var sortedPassWindows: [CGWindowID] = changedPassWindows
            if let promoted {
                sortedPassWindows.append(promoted)
            }
            sortedPassWindows.append(contentsOf: sortedRemaining)

            var tabStripOutcomes: [CGWindowID: ChromiumTabStripOutcome] = [:]
            let passStartTicks = nowTicks()

            for wid in sortedPassWindows {
                guard let elem = axElementsByWindowID[wid] else { continue }
                let passElapsed = HostClock.seconds(ticks: nowTicks()) - HostClock.seconds(ticks: passStartTicks)
                if passElapsed >= 0.100 {
                    tabStripOutcomes[wid] = .notRun
                    closingTitles[wid] = reader.readTitle(for: elem)
                    continue
                }
                let budget = min(0.050, 0.100 - passElapsed)
                updatedAttemptTimes[wid] = HostClock.seconds(ticks: nowTicks())
                let outcome = reader.walkTabStrip(for: elem, maxNodes: 3000, timeoutSeconds: budget, nowTicks: nowTicks)
                let closeTitle = reader.readTitle(for: elem)
                closingTitles[wid] = closeTitle
                tabStripOutcomes[wid] = outcome

                let openTitle = openingTitles[wid] ?? nil
                let docStr = docs[wid] ?? nil

                switch outcome {
                case .overBudget, .timedOut:
                    updatedPassResults.removeValue(forKey: wid)
                case .budgetCut:
                    newBudgetCut.insert(wid)
                case .notRun:
                    break
                case .counts(let sel, let tot):
                    if openTitle == closeTitle {
                        let openingHash = ChromiumSiteRead.documentIdentityHash(doc: docStr ?? "", axTitle: openTitle ?? "")
                        updatedPassResults[wid] = ChromiumPassResult(
                            axTitle: openTitle ?? "",
                            docHash: openingHash,
                            host: (docStr != nil) ? SiteRule.normalizeReadHost(docStr!) : nil,
                            time: HostClock.seconds(ticks: nowTicks()),
                            selectedTabCount: sel,
                            totalTabCount: tot
                        )
                    } else {
                        updatedPassResults.removeValue(forKey: wid)
                    }
                case .failed:
                    updatedPassResults.removeValue(forKey: wid)
                }
            }

            // 5. Evaluate page windows
            for w in pageWindows {
                let docStr = docs[w.wid] ?? nil
                let dFailed = docFailed[w.wid] ?? true
                let winReadStart = readStarts[w.wid] ?? startSec
                guard let elem = axElementsByWindowID[w.wid], !dFailed, let docStr else {
                    if var r6 = updatedRule6[w.wid] {
                        r6.waitStart = HostClock.seconds(ticks: nowTicks())
                        r6.firstOrdinaryAt = nil
                        updatedRule6[w.wid] = r6
                    }
                    results[w.wid] = (
                        read: ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: winReadStart, listGeneration: currentGeneration, browser: browser, isPending: false),
                        completed: false,
                        cgTitle: w.title,
                        axTitle: nil
                    )
                    continue
                }

                let openTitle = openingTitles[w.wid] ?? nil
                guard let openTitle = openTitle else {
                    if var r6 = updatedRule6[w.wid] {
                        r6.waitStart = HostClock.seconds(ticks: nowTicks())
                        r6.firstOrdinaryAt = nil
                        updatedRule6[w.wid] = r6
                    }
                    results[w.wid] = (
                        read: ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: winReadStart, listGeneration: currentGeneration, browser: browser, isPending: false),
                        completed: false,
                        cgTitle: w.title,
                        axTitle: nil
                    )
                    continue
                }

                let openingHash = ChromiumSiteRead.documentIdentityHash(doc: docStr, axTitle: openTitle)
                updatedLastKnownKeys[w.wid] = (axTitle: openTitle, docHash: openingHash)

                let closeTitle = closingTitles[w.wid] ?? nil
                guard let closeTitle = closeTitle else {
                    // Nil closing title is can't tell, cause .unread, completed: false
                    if var r6 = updatedRule6[w.wid] {
                        r6.waitStart = HostClock.seconds(ticks: nowTicks())
                        r6.firstOrdinaryAt = nil
                        updatedRule6[w.wid] = r6
                    }
                    results[w.wid] = (
                        read: ChromiumPollRead(verdict: .cantTell, cause: .unread, host: nil, readStart: winReadStart, listGeneration: currentGeneration, browser: browser, isPending: false),
                        completed: false,
                        cgTitle: w.title,
                        axTitle: nil
                    )
                    continue
                }

                let prev = localPrevTitles[w.wid]

                let effOutcome: ChromiumTabStripOutcome
                let rawOutcome = tabStripOutcomes[w.wid]
                if rawOutcome == .budgetCut || rawOutcome == .notRun || rawOutcome == nil {
                    if let carried = updatedPassResults[w.wid],
                       carried.axTitle == openTitle && carried.docHash == openingHash {
                        effOutcome = .counts(selected: carried.selectedTabCount, total: carried.totalTabCount)
                    } else if let raw = rawOutcome {
                        effOutcome = raw
                    } else {
                        effOutcome = .notRun
                    }
                } else if let raw = rawOutcome {
                    effOutcome = raw
                } else if let carried = updatedPassResults[w.wid],
                          carried.axTitle == openTitle && carried.docHash == openingHash {
                    effOutcome = .counts(selected: carried.selectedTabCount, total: carried.totalTabCount)
                } else {
                    effOutcome = .notRun
                }

                let eval = ChromiumSiteRead.evaluatePageWindow(
                    windowID: w.wid,
                    browser: browser,
                    cgTitle: w.title,
                    initialAXTitle: openTitle,
                    finalAXTitle: closeTitle,
                    doc: docStr,
                    docReadFailed: false,
                    previousCGTitle: prev?.cg,
                    previousAXTitle: prev?.ax,
                    tabStripOutcome: effOutcome,
                    rule6Record: &updatedRule6[w.wid],
                    sites: currentSites,
                    now: HostClock.seconds(ticks: nowTicks())
                )
                updatedPrevTitles[w.wid] = (cg: w.title, ax: closeTitle)
                results[w.wid] = (
                    read: ChromiumPollRead(verdict: eval.verdict, cause: eval.cause, host: eval.host, readStart: winReadStart, listGeneration: currentGeneration, browser: browser, isPending: false),
                    completed: true,
                    cgTitle: w.title,
                    axTitle: closeTitle
                )
            }

            Task {
                await self.roundFinished(
                    browser: browser,
                    startSec: startSec,
                    generation: currentGeneration,
                    results: results,
                    rule6: updatedRule6,
                    passResults: updatedPassResults,
                    prevTitles: updatedPrevTitles,
                    rememberedHosts: updatedRemembered,
                    attemptTimes: updatedAttemptTimes,
                    budgetCut: newBudgetCut,
                    lastKnownKeys: updatedLastKnownKeys,
                    dispatchedRule6: localRule6
                )
            }
        }
    }

    func roundFinished(
        browser: PrivateBrowser,
        startSec: TimeInterval,
        generation: UInt64,
        results: [CGWindowID: (read: ChromiumPollRead, completed: Bool, cgTitle: String, axTitle: String?)],
        rule6: [CGWindowID: ChromiumRule6Record],
        passResults: [CGWindowID: ChromiumPassResult],
        prevTitles: [CGWindowID: (cg: String, ax: String)],
        rememberedHosts: [CGWindowID: [(host: String, time: TimeInterval)]],
        attemptTimes: [CGWindowID: TimeInterval],
        budgetCut: Set<CGWindowID>,
        lastKnownKeys: [CGWindowID: (axTitle: String, docHash: Int)],
        dispatchedRule6: [CGWindowID: ChromiumRule6Record]
    ) {
        inFlight[browser] = false
        let nowSec = HostClock.seconds(ticks: hooks.nowTicks())
        let deadlineMissed = nowSec >= startSec + 0.5

        let currentGeneration = self.appliedGeneration
        let currentSites = self.sites

        // Pre-merge: if the round's list generation is older than the current one and a host it read is covered under the current list, start a rule-6 record
        if generation < currentGeneration {
            for wid in results.keys {
                var candidateHosts: [String] = []
                if let h = results[wid]?.read.host {
                    candidateHosts.append(h)
                }
                if let rem = rememberedHosts[wid] {
                    candidateHosts.append(contentsOf: rem.filter { nowSec - $0.time <= 5.0 }.map(\.host))
                }
                for h in candidateHosts {
                    if currentSites.contains(where: { SiteRule.covers(siteHost: $0, host: h) }) {
                        self.rule6Records[wid] = ChromiumRule6Record(waitStart: nowSec, host: h, firstOrdinaryAt: nil)
                        break
                    }
                }
            }
        }

        // Writes rule-6, pass results, previous titles, and remembered hosts only for window ids in this round's results
        for wid in results.keys {
            if let v = passResults[wid] {
                self.passResults[wid] = v
            } else {
                self.passResults.removeValue(forKey: wid)
            }

            if let pt = prevTitles[wid] {
                self.previousTitles[wid] = pt
            }

            if let list = rememberedHosts[wid] {
                var existing = self.rememberedHosts[wid, default: []].filter { nowSec - $0.time <= 5.0 }
                for entry in list {
                    if !existing.contains(where: { $0.host == entry.host && abs($0.time - entry.time) < 1e-4 }) {
                        existing.append(entry)
                    }
                }
                self.rememberedHosts[wid] = existing
            }

            if let at = attemptTimes[wid] {
                self.passAttemptTimes[wid] = at
            }
            if let lk = lastKnownKeys[wid] {
                self.lastKnownKeys[wid] = lk
            }
        }
        self.budgetCutPasses[browser] = budgetCut

        // Rule-6 merge:
        if deadlineMissed {
            for wid in results.keys {
                if let res = results[wid], res.read.verdict == .covered, let host = res.read.host {
                    let r6 = rule6[wid] ?? ChromiumRule6Record(waitStart: nowSec, host: host, firstOrdinaryAt: nil)
                    self.rule6Records[wid] = r6
                } else if let existing = self.rule6Records[wid] {
                    self.rule6Records[wid] = ChromiumRule6Record(
                        waitStart: max(existing.waitStart, nowSec),
                        host: existing.host,
                        firstOrdinaryAt: nil
                    )
                }
            }
        } else {
            for wid in results.keys {
                if let roundR6 = rule6[wid] {
                    if let existing = self.rule6Records[wid] {
                        if roundR6.waitStart >= existing.waitStart {
                            self.rule6Records[wid] = roundR6
                        }
                    } else {
                        self.rule6Records[wid] = roundR6
                    }
                } else {
                    if let dispatched = dispatchedRule6[wid],
                       let existing = self.rule6Records[wid],
                       existing.waitStart == dispatched.waitStart {
                        self.rule6Records.removeValue(forKey: wid)
                    }
                }
            }
        }

        // Caution:
        if deadlineMissed {
            failureCounts[browser, default: 0] += results.count
        } else {
            var roundHasFault = false
            for wid in results.keys {
                guard let res = results[wid] else { continue }
                if !res.completed {
                    roundHasFault = true
                    failureCounts[browser, default: 0] += 1
                }
            }
            if !roundHasFault {
                failureCounts[browser] = 0
            }
        }

        let caution = failureCounts[browser, default: 0] >= 10
        let gen = appliedGeneration
        let onComplete = self.onChromiumReadComplete
        let onCaution = self.onChromiumCautionUpdate

        Task { @MainActor in
            onCaution?(browser, caution)
            let mapped = results.mapValues { (read: $0.read, cgTitle: $0.cgTitle, axTitle: $0.axTitle) }
            onComplete?(browser, mapped, startSec, gen)
        }
    }

    private func performWalkPass() async {
        guard !isWalking else { return }
        isWalking = true
        defer { isWalking = false }

        let nowSec = HostClock.seconds(ticks: hooks.nowTicks())

        // Collect decided windows (distinct window IDs currently on screen whose current title has a fresh verdict and age >= 3.0s)
        let decidedWindowIDs = Array(Set(latestSafariWindows.compactMap { win -> CGWindowID? in
            let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
            let v = decisions.verdict(for: key, at: nowSec)
            guard v == .ordinary || v == .covered else { return nil }
            if let entry = decisions.entries[key] {
                let age = nowSec - entry.decisionTime
                guard age >= 3.0 else { return nil }
            }
            return win.windowID
        })).sorted()

        let scheduled = SiteWalkScheduler.schedule(
            pending: recentPendingKeys,
            decided: decidedWindowIDs,
            cursor: &schedulerCursor
        )

        guard !scheduled.isEmpty else { return }

        let passGen = appliedGeneration
        for item in scheduled {
            guard passGen == appliedGeneration else { return }
            switch item {
            case .pending(let key):
                await walkWindow(key: key, isSweep: false)
            case .sweep(let wid):
                if let win = latestSafariWindows.first(where: { $0.windowID == wid }) {
                    let key = SiteDecisionKey(windowID: wid, title: win.title)
                    await walkWindow(key: key, isSweep: true)
                }
            }
        }

        guard passGen == appliedGeneration else { return }
        let currentDecisions = decisions
        let axWorking = isAXWorking
        let gen = appliedGeneration
        await onDecisionUpdate(currentDecisions, axWorking, gen)
    }

    private func observeWindow(windowID: CGWindowID, pid: pid_t, title: String) async -> (initialAXTitle: String?, walk: WebAreaWalkResult, finalAXTitle: String?, windowMissing: Bool) {
        let observeFn = hooks.observe
        return await withCheckedContinuation { continuation in
            walkQueue.async {
                let result = observeFn(windowID, pid, title)
                continuation.resume(returning: result)
            }
        }
    }

    private func walkWindow(key: SiteDecisionKey, isSweep: Bool) async {
        guard let currentWin = latestSafariWindows.first(where: { $0.windowID == key.windowID }),
              currentWin.title == key.title,
              let pid = pidsByWindowID[key.windowID],
              pid > 0 else {
            return
        }

        let walkGen = appliedGeneration
        let observation = await observeWindow(windowID: key.windowID, pid: pid, title: key.title)
        guard walkGen == appliedGeneration else { return }
        if observation.windowMissing { return }

        let nowSec = HostClock.seconds(ticks: hooks.nowTicks())
        decisions.evaluate(
            key: key,
            initialAXTitle: observation.initialAXTitle,
            finalAXTitle: observation.finalAXTitle,
            walk: observation.walk,
            sites: sites,
            now: nowSec,
            isSweep: isSweep
        )
    }
}
