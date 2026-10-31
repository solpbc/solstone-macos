// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
    var copyOnScreen: @Sendable () -> [SiteVisibleWindow]
    var nowTicks: @Sendable () -> UInt64
    var observe: @Sendable (CGWindowID, pid_t, String) -> (initialAXTitle: String?, walk: WebAreaWalkResult, finalAXTitle: String?, windowMissing: Bool)

    init(
        safariPIDs: @escaping @Sendable () -> Set<pid_t> = {
            let safariBundleID = PrivateBrowser.safari.bundleIdentifier
            let apps = NSWorkspace.shared.runningApplications
            return Set(apps.filter { $0.bundleIdentifier == safariBundleID }.map(\.processIdentifier))
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
            let appRef = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appRef, 0.05)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let winList = windowsValue as? [AXUIElement] else {
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
    ) {
        self.safariPIDs = safariPIDs
        self.copyOnScreen = copyOnScreen
        self.nowTicks = nowTicks
        self.observe = observe
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
            AccessibilityTitleReader.ask()
        }
    ) {
        self.readWorks = readWorks
        self.prompt = prompt
    }
}

actor SiteSampler {
    private let walkQueue = DispatchQueue(label: "app.solstone.observer.site-walk")

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

    private let onPoll: @MainActor @Sendable (SitePollSnapshot) -> Void
    private let onDecisionUpdate: @MainActor @Sendable (SiteDecision, Bool, UInt64) -> Void

    init(
        probe: AccessibilityProbe = AccessibilityProbe(),
        isSnapshot: Bool = false,
        hooks: SiteSamplerHooks = SiteSamplerHooks(),
        onPoll: @escaping @MainActor @Sendable (SitePollSnapshot) -> Void,
        onDecisionUpdate: @escaping @MainActor @Sendable (SiteDecision, Bool, UInt64) -> Void
    ) {
        self.probe = probe
        self.isSnapshot = isSnapshot
        self.hooks = hooks
        self.onPoll = onPoll
        self.onDecisionUpdate = onDecisionUpdate
        self.isAXWorking = probe.readWorks()
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

    func applySites(_ newSites: [String], generation: UInt64) {
        guard generation >= appliedGeneration else { return }
        appliedGeneration = generation
        appliedSitesForTesting.append(newSites)
        self.sites = newSites
        self.decisions = SiteDecision()
        self.recentPendingKeys.removeAll()
        if newSites.isEmpty {
            stop()
        } else if pollTimer == nil {
            start()
        }
    }

    func updateSites(_ newSites: [String]) {
        applySites(newSites, generation: appliedGeneration + 1)
    }

    func setProbe(_ newProbe: AccessibilityProbe) {
        self.probe = newProbe
    }

    func start() {
        stop()
        guard !sites.isEmpty else { return }

        if isSnapshot {
            let works = probe.readWorks()
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
            while !Task.isCancelled {
                await self?.performWalkPass()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        let working = probe.readWorks()
        isAXWorking = working
        let currentDecisions = decisions
        let gen = appliedGeneration
        await onDecisionUpdate(currentDecisions, working, gen)
    }

    private func performPoll() async {
        let safariPids = hooks.safariPIDs()

        let startTicks = hooks.nowTicks()
        let rawWindows = hooks.copyOnScreen()
        let endTicks = hooks.nowTicks()

        let startSec = HostClock.seconds(ticks: startTicks)
        let endSec = HostClock.seconds(ticks: endTicks)

        var safariWindows: [SitePollWindow] = []
        var pollPids: [CGWindowID: pid_t] = [:]

        for w in rawWindows {
            guard w.layer == 0, safariPids.contains(w.pid) else {
                continue
            }
            safariWindows.append(SitePollWindow(windowID: w.windowID, title: w.title))
            pollPids[w.windowID] = w.pid
        }

        latestSafariWindows = safariWindows
        pidsByWindowID = pollPids

        let snapshot = SitePollSnapshot(start: startSec, end: endSec, windows: safariWindows)
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

    private func performWalkPass() async {
        guard !isWalking else { return }
        isWalking = true
        defer { isWalking = false }

        let nowSec = HostClock.seconds(ticks: hooks.nowTicks())

        // Collect decided windows (distinct window IDs currently on screen whose current title has a fresh verdict and age >= 4.0s)
        let decidedWindowIDs = Array(Set(latestSafariWindows.compactMap { win -> CGWindowID? in
            let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
            let v = decisions.verdict(for: key, at: nowSec)
            guard v == .ordinary || v == .covered else { return nil }
            if let entry = decisions.entries[key] {
                let age = nowSec - entry.decisionTime
                guard age >= 4.0 else { return nil }
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
