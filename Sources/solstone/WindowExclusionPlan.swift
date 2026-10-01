// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// A browser whose private windows can be told apart, and how.
///
/// Every form below was read from a real window on macOS 27 in English. Firefox writes its private
/// mark into the window title the app already reads, so it needs no new permission. Safari, Chrome,
/// Edge and Brave show only the page title there; their mark is in the Accessibility title, which
/// needs the Accessibility permission (the opt-in second level of the private-window setting).
public enum PrivateBrowser: String, CaseIterable, Sendable {
    case firefox
    case safari
    case chrome
    case edge
    case brave

    /// Browsers matched by their Accessibility title.
    public static let accessibilityBrowsers: [PrivateBrowser] = [.safari, .chrome, .edge, .brave]

    var bundleIdentifier: String {
        switch self {
        case .firefox: return "org.mozilla.firefox"
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        }
    }

    /// Firefox 156 and 157 end a private window's title with this, after the page title. An ordinary
    /// window shows the bare page title, so a page whose own title ends this way reads the same.
    static let firefoxPrivateTitleSuffix = " \u{2014} Private Browsing"

    /// What the browser writes after the page title in a private window's Accessibility title.
    var privateAccessibilityTail: String? {
        switch self {
        case .firefox: return nil
        case .safari: return ", Private Browsing"
        case .chrome: return " - Google Chrome (Incognito)"
        case .edge: return " - Microsoft Edge (InPrivate)"
        case .brave: return " - Brave (Private)"
        }
    }

    /// What the browser writes after the page title in an ordinary window's Accessibility title.
    /// A Chromium profile name can follow it (`… - Google Chrome - Work`). Safari writes nothing.
    var ordinaryAccessibilityTail: String {
        switch self {
        case .firefox, .safari: return ""
        case .chrome: return " - Google Chrome"
        case .edge: return " - Microsoft Edge"
        case .brave: return " - Brave"
        }
    }

    static func forBundleIdentifier(_ id: String?) -> PrivateBrowser? {
        guard let id else { return nil }
        return allCases.first { $0.bundleIdentifier == id }
    }

    /// Firefox, by the window title alone.
    static func firefoxVerdict(windowTitle: String) -> TitleVerdict {
        if windowTitle.isEmpty { return .undecided }
        return windowTitle.hasSuffix(firefoxPrivateTitleSuffix) ? .privateWindow : .ordinary
    }

    /// Safari, Chrome, Edge and Brave, by the window title and the Accessibility title together.
    /// The browser appends its own tail to the page title only in the Accessibility title, so a
    /// private window reads exactly `windowTitle + privateTail`. A page that titles itself with the
    /// tail reads the same text in both titles (plus the ordinary tail), so it is never matched.
    /// Anything that fits neither form is undecided.
    func accessibilityVerdict(windowTitle: String, accessibilityTitle: String) -> TitleVerdict {
        guard let privateTail = privateAccessibilityTail, !accessibilityTitle.isEmpty else { return .undecided }
        if accessibilityTitle == windowTitle + privateTail { return .privateWindow }
        if self == .safari {
            return accessibilityTitle == windowTitle ? .ordinary : .undecided
        }
        let ordinary = windowTitle + ordinaryAccessibilityTail
        if accessibilityTitle == ordinary || accessibilityTitle.hasPrefix(ordinary + " - ") { return .ordinary }
        return .undecided
    }
}

public enum TitleVerdict: Equatable, Sendable {
    case privateWindow
    case ordinary
    case undecided
}

/// One on-screen window as the planner sees it.
struct ExclusionWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let layer: Int
}

/// One running application as the planner sees it.
struct ExclusionApp: Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
}

struct ExclusionSettings: Equatable, Sendable {
    var excludedAppNames: Set<String>  // lowercased
    var excludePrivateBrowsing: Bool
    /// The opt-in second level, and only while Accessibility reads actually work.
    var accessibilityTitlesWorking: Bool
    var titlePatterns: [String]  // lowercased

    init(excludedAppNames: [String], excludePrivateBrowsing: Bool, accessibilityTitlesWorking: Bool, titlePatterns: [String]) {
        self.excludedAppNames = Set(excludedAppNames.map { $0.lowercased() })
        self.excludePrivateBrowsing = excludePrivateBrowsing
        self.accessibilityTitlesWorking = accessibilityTitlesWorking
        self.titlePatterns = titlePatterns.map { $0.lowercased() }.filter { !$0.isEmpty }
    }
}

/// What the capture filter must say: these applications are kept out, except these windows of
/// theirs. A window of a kept-out application that is not listed is never captured, including a
/// window that did not exist when the filter was made. That is what closes the first-frame race.
struct ExclusionPlan: Equatable, Sendable {
    var hiddenPIDs: Set<pid_t> = []
    var exceptedWindowIDs: Set<CGWindowID> = []
    var excludedAppCount = 0
    var privateWindowCount = 0
    var heldWindowCount = 0
    var titlePatternCount = 0

    static let empty = ExclusionPlan()

    /// Whether a filter built from what ScreenCaptureKit listed says the whole plan. An app that
    /// is kept out but not listed stays captured, so such a plan must not be committed.
    func isFullyResolved(listedPIDs: Set<pid_t>, listedWindowIDs: Set<CGWindowID>) -> Bool {
        hiddenPIDs.isSubset(of: listedPIDs) && exceptedWindowIDs.isSubset(of: listedWindowIDs)
    }
}

/// Decides, tick by tick, which applications are kept out of capture and which of their windows are
/// let back in. Pure apart from its verdict cache, so tests drive it with captured titles.
struct ExclusionPlanner {
    /// How long a new browser window is held out while its titles cannot be read or matched.
    /// Past this it is let in (nothing is excluded on a signal the app cannot read), and it is
    /// re-checked every tick.
    static let holdLimit: TimeInterval = 2.0

    private enum Cached {
        case pending(since: Date)
        case decided(TitleVerdict)
    }

    /// Accessibility verdicts per window. Whether a window is private never changes for its whole
    /// life, so a decided window is not read again.
    private var accessibilityCache: [CGWindowID: Cached] = [:]
    /// When each Firefox window was first seen without a title.
    private var firefoxFirstSeen: [CGWindowID: Date] = [:]

    /// Windows that still need an Accessibility read, grouped by process.
    func windowsNeedingAccessibilityTitles(windows: [ExclusionWindow], apps: [ExclusionApp], settings: ExclusionSettings) -> Set<pid_t> {
        guard settings.excludePrivateBrowsing, settings.accessibilityTitlesWorking else { return [] }
        let browserPIDs = Set(apps.filter { app in
            PrivateBrowser.accessibilityBrowsers.contains { $0.bundleIdentifier == app.bundleIdentifier }
        }.map(\.pid))
        var pids = Set<pid_t>()
        for w in windows where w.layer == 0 && browserPIDs.contains(w.pid) {
            if case .decided = accessibilityCache[w.id] { continue }
            pids.insert(w.pid)
        }
        return pids
    }

    /// - Parameters:
    ///   - windows: on-screen windows, every layer
    ///   - apps: running applications
    ///   - accessibilityTitles: Accessibility titles by window id, for the processes asked for
    mutating func plan(
        windows: [ExclusionWindow],
        apps: [ExclusionApp],
        settings: ExclusionSettings,
        accessibilityTitles: [CGWindowID: String],
        now: Date
    ) -> ExclusionPlan {
        var plan = ExclusionPlan()
        let liveIDs = Set(windows.map(\.id))
        accessibilityCache = accessibilityCache.filter { liveIDs.contains($0.key) }
        firefoxFirstSeen = firefoxFirstSeen.filter { liveIDs.contains($0.key) }

        // 1. Excluded apps: every window, now and later.
        var excludedPIDs = Set<pid_t>()
        for app in apps where settings.excludedAppNames.contains(app.name.lowercased()) {
            excludedPIDs.insert(app.pid)
        }
        for w in windows where settings.excludedAppNames.contains(w.ownerName.lowercased()) {
            excludedPIDs.insert(w.pid)
        }
        plan.excludedAppCount = excludedPIDs.count

        // 2. Held browsers: kept out, each top-level window let back in once it reads ordinary.
        var heldBrowser: [pid_t: PrivateBrowser] = [:]
        if settings.excludePrivateBrowsing {
            for app in apps {
                guard let browser = PrivateBrowser.forBundleIdentifier(app.bundleIdentifier) else { continue }
                if browser == .firefox || settings.accessibilityTitlesWorking {
                    heldBrowser[app.pid] = browser
                }
            }
            // Firefox has always been matched by its owner name; keep matching windows that way.
            for w in windows where w.ownerName.lowercased() == "firefox" && heldBrowser[w.pid] == nil {
                heldBrowser[w.pid] = .firefox
            }
        }

        // 3. Title patterns: the window's whole app is kept out, its other windows let back in.
        var patternedIDs = Set<CGWindowID>()
        if !settings.titlePatterns.isEmpty {
            for w in windows where !excludedPIDs.contains(w.pid) {
                let title = w.title.lowercased()
                if settings.titlePatterns.contains(where: { title.contains($0) }) {
                    patternedIDs.insert(w.id)
                }
            }
        }
        plan.titlePatternCount = patternedIDs.count
        let patternedPIDs = Set(windows.filter { patternedIDs.contains($0.id) }.map(\.pid))

        plan.hiddenPIDs = excludedPIDs.union(heldBrowser.keys).union(patternedPIDs)

        for w in windows where plan.hiddenPIDs.contains(w.pid) && !excludedPIDs.contains(w.pid) {
            if patternedIDs.contains(w.id) { continue }
            guard let browser = heldBrowser[w.pid] else {
                plan.exceptedWindowIDs.insert(w.id)  // another window of an app with a patterned window
                continue
            }
            // Menus, tooltips and other windows above the page are let in, as before.
            guard w.layer == 0 else {
                plan.exceptedWindowIDs.insert(w.id)
                continue
            }
            switch verdict(for: w, browser: browser, accessibilityTitles: accessibilityTitles, now: now) {
            case .privateWindow:
                plan.privateWindowCount += 1
            case .ordinary:
                plan.exceptedWindowIDs.insert(w.id)
            case .undecided:
                plan.heldWindowCount += 1
            }
        }
        return plan
    }

    /// `.undecided` means held out right now. A window held past `holdLimit` comes back `.ordinary`.
    private mutating func verdict(
        for w: ExclusionWindow,
        browser: PrivateBrowser,
        accessibilityTitles: [CGWindowID: String],
        now: Date
    ) -> TitleVerdict {
        if browser == .firefox {
            // Firefox's title is re-read every tick, as it always was: a window whose title comes to
            // end with the private form is kept out from then on.
            let v = PrivateBrowser.firefoxVerdict(windowTitle: w.title)
            guard v == .undecided else {
                firefoxFirstSeen[w.id] = nil
                return v
            }
            let since = firefoxFirstSeen[w.id] ?? now
            firefoxFirstSeen[w.id] = since
            return now.timeIntervalSince(since) >= Self.holdLimit ? .ordinary : .undecided
        }
        let since: Date
        switch accessibilityCache[w.id] {
        case .decided(let v):
            return v
        case .pending(let s):
            since = s
        case nil:
            since = now
        }
        if let ax = accessibilityTitles[w.id] {
            let v = browser.accessibilityVerdict(windowTitle: w.title, accessibilityTitle: ax)
            if v != .undecided {
                accessibilityCache[w.id] = .decided(v)
                return v
            }
        }
        accessibilityCache[w.id] = .pending(since: since)
        return now.timeIntervalSince(since) >= Self.holdLimit ? .ordinary : .undecided
    }
}
