// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

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
    private var sites: [String] = []
    private var probe: AccessibilityProbe
    private let isSnapshot: Bool
    private var pollTimer: Task<Void, Never>?
    private var walkTimer: Task<Void, Never>?
    private var probeTimer: Task<Void, Never>?

    private var decisions = SiteDecision()
    private var schedulerCursor: Int = 0
    private var recentPendingKeys: [SiteDecisionKey] = []
    private var latestSafariWindows: [SitePollWindow] = []
    private var isWalking = false
    private var isAXWorking: Bool = false

    private let onPoll: @MainActor @Sendable (SitePollSnapshot) -> Void
    private let onDecisionUpdate: @MainActor @Sendable (SiteDecision, Bool) -> Void

    init(
        probe: AccessibilityProbe = AccessibilityProbe(),
        isSnapshot: Bool = false,
        onPoll: @escaping @MainActor @Sendable (SitePollSnapshot) -> Void,
        onDecisionUpdate: @escaping @MainActor @Sendable (SiteDecision, Bool) -> Void
    ) {
        self.probe = probe
        self.isSnapshot = isSnapshot
        self.onPoll = onPoll
        self.onDecisionUpdate = onDecisionUpdate
    }

    func updateSites(_ newSites: [String]) {
        self.sites = newSites
        if newSites.isEmpty {
            stop()
        } else if pollTimer == nil {
            start()
        }
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
            Task { @MainActor in
                self.onDecisionUpdate(currentDecisions, works)
            }
            return
        }

        // Initial probe check
        Task { [weak self] in
            await self?.checkProbe()
        }

        // 4 Hz poll loop (every 250 ms)
        pollTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performPoll()
                try? await Task.sleep(nanoseconds: 250_000_000)
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
        await onDecisionUpdate(currentDecisions, working)
    }

    private func performPoll() async {
        let startTicks = mach_absolute_time()
        let startSec = HostClock.seconds(ticks: startTicks)

        let safariBundleID = PrivateBrowser.safari.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
        let safariPids = Set(apps.filter { $0.bundleIdentifier == safariBundleID }.map(\.processIdentifier))

        let rawWindows = OnScreenWindowList.copyOnScreenInfo()
        var safariWindows: [SitePollWindow] = []

        for w in rawWindows {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  safariPids.contains(pid_t(pid)) else {
                continue
            }
            let title = w[kCGWindowName as String] as? String ?? ""
            safariWindows.append(SitePollWindow(windowID: wid, title: title))
        }

        let endTicks = mach_absolute_time()
        let endSec = HostClock.seconds(ticks: endTicks)

        latestSafariWindows = safariWindows
        let snapshot = SitePollSnapshot(start: startSec, end: endSec, windows: safariWindows)
        await onPoll(snapshot)

        // Track pending keys for scheduler (newest first)
        var freshPending: [SiteDecisionKey] = []
        for win in safariWindows {
            let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
            let v = decisions.verdict(for: key, at: endSec)
            if v == .pending {
                freshPending.append(key)
            }
        }
        recentPendingKeys = freshPending + recentPendingKeys.filter { !freshPending.contains($0) }
        if recentPendingKeys.count > 64 {
            recentPendingKeys.removeLast(recentPendingKeys.count - 64)
        }
    }

    private func performWalkPass() async {
        guard !isWalking else { return }
        isWalking = true
        defer { isWalking = false }

        let nowSec = HostClock.seconds(ticks: mach_absolute_time())

        // Collect decided windows (distinct window IDs currently on screen whose current title has a fresh verdict)
        let decidedWindowIDs = Array(Set(latestSafariWindows.compactMap { win -> CGWindowID? in
            let key = SiteDecisionKey(windowID: win.windowID, title: win.title)
            let v = decisions.verdict(for: key, at: nowSec)
            return (v == .ordinary || v == .covered) ? win.windowID : nil
        })).sorted()

        let scheduled = SiteWalkScheduler.schedule(
            pending: recentPendingKeys,
            decided: decidedWindowIDs,
            cursor: &schedulerCursor
        )

        guard !scheduled.isEmpty else { return }

        for item in scheduled {
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

        let currentDecisions = decisions
        let axWorking = isAXWorking
        await onDecisionUpdate(currentDecisions, axWorking)
    }

    private func walkWindow(key: SiteDecisionKey, isSweep: Bool) async {
        let appRef = AXUIElementCreateApplication(pid_t(findPid(for: key.windowID)))
        AXUIElementSetMessagingTimeout(appRef, 0.05)

        // Find the matching window AXUIElement
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let winList = windowsValue as? [AXUIElement] else {
            let nowSec = HostClock.seconds(ticks: mach_absolute_time())
            decisions.evaluate(
                key: key,
                initialAXTitle: key.title,
                finalAXTitle: key.title,
                walk: WebAreaWalkResult(urls: [], completeness: .axError),
                sites: sites,
                now: nowSec,
                isSweep: isSweep
            )
            return
        }

        guard let targetWindow = winList.first(where: {
            var wid: CGWindowID = 0
            return _AXUIElementGetWindow($0, &wid) == .success && wid == key.windowID
        }) else {
            return
        }

        let initialAXTitle = readStringAttribute(targetWindow, kAXTitleAttribute)
        let walkResult = WebAreaWalker.walk(targetWindow, mode: .everyTopLevel)
        let finalAXTitle = readStringAttribute(targetWindow, kAXTitleAttribute)
        let nowSec = HostClock.seconds(ticks: mach_absolute_time())

        decisions.evaluate(
            key: key,
            initialAXTitle: initialAXTitle,
            finalAXTitle: finalAXTitle,
            walk: walkResult,
            sites: sites,
            now: nowSec,
            isSweep: isSweep
        )
    }

    private func findPid(for windowID: CGWindowID) -> pid_t {
        let raw = OnScreenWindowList.copyOnScreenInfo()
        for w in raw {
            if let wid = w[kCGWindowNumber as String] as? CGWindowID, wid == windowID,
               let pid = w[kCGWindowOwnerPID as String] as? Int {
                return pid_t(pid)
            }
        }
        return 0
    }

    private func readStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
