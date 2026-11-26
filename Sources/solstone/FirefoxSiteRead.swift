// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

/// One `AXWebArea` a Firefox window walk collected. Only its address, its frame and where it sits
/// are kept, and only for the read that found it: no element outlives a read.
public struct FirefoxWebArea: Sendable, Equatable {
    /// Its `AXURL`. Nil: the read failed. An `AXURL` with no value reads as "".
    public let url: String?
    /// Nil: the read failed.
    public let frame: CGRect?
    /// Which `AXTabPanel` group it sits under, numbered in walk order. Nil: none, an other area
    /// (a sidebar, for example).
    public let tabPanel: Int?

    public init(url: String?, frame: CGRect?, tabPanel: Int?) {
        self.url = url
        self.frame = frame
        self.tabPanel = tabPanel
    }

    public var isTabArea: Bool { tabPanel != nil }
}

public struct FirefoxWalkResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case complete
        case overBudget
        case timedOut
        case failed
    }

    public let areas: [FirefoxWebArea]
    public let outcome: Outcome
    public let visited: Int

    public init(areas: [FirefoxWebArea], outcome: Outcome, visited: Int = 0) {
        self.areas = areas
        self.outcome = outcome
        self.visited = visited
    }
}

/// The website rule's read of a Firefox window: which website its page shows, from the `AXURL` of
/// the web areas a cheap walk from the window finds.
public enum FirefoxSiteRead {
    /// Roles that hold no web area. The walk reads their role and goes no further, so the tab strip
    /// costs the same at any tab count.
    public static let skippedRoles: Set<String> = [
        "AXToolbar", "AXTabGroup", "AXRadioButton", "AXButton", "AXMenuButton", "AXPopUpButton",
        "AXComboBox", "AXTextField", "AXStaticText", "AXImage", "AXSplitter", "AXCheckBox",
        "AXMenuBar", "AXMenu",
    ]
    public static let walkMaxElements = 200
    public static let walkTimeout: TimeInterval = 0.025
    /// How long a pid's engine may take to come up after its first trigger before its rounds count
    /// as failed reads, and how often it is re-triggered meanwhile.
    public static let engineGrace: TimeInterval = 5.0

    /// About pages that are Firefox's own, never a website.
    public static let ordinaryAboutPages: Set<String> = [
        "newtab", "home", "welcome", "privatebrowsing", "preferences", "settings", "addons",
        "support", "config", "downloads", "logins", "profiles", "protections", "firefoxview",
        "certificate", "policies", "processes", "telemetry", "debugging",
    ]

    /// Browser documents that are ordinary only outside a tab panel: Firefox's own sidebars, and an
    /// extension's sidebar host, whose document is the extension's own page.
    public static let ordinarySidebarDocuments: Set<String> = [
        "chrome://browser/content/places/bookmarksSidebar.xhtml",
        "chrome://browser/content/places/historySidebar.xhtml",
        "chrome://browser/content/syncedtabs/sidebar.xhtml",
        "chrome://browser/content/webext-panels.xhtml",
    ]

    public enum Value: Sendable, Equatable {
        case covered(host: String)
        /// A website the list doesn't cover (with its host), or a page that isn't a website (nil).
        case ordinary(host: String?)
        case cantTell
    }

    /// The one value rule, used everywhere a Firefox address is read or remembered.
    public static func value(of url: String, inTabArea: Bool, sites: [String]) -> Value {
        classify(url, inTabArea: inTabArea, sites: sites, unwrapped: false)
    }

    /// The host an address names under the value rule, for remembering. Nil: none.
    public static func host(of url: String) -> String? {
        switch classify(url, inTabArea: true, sites: [], unwrapped: false) {
        case .covered(let host): return host
        case .ordinary(let host): return host
        case .cantTell: return nil
        }
    }

    private static func classify(_ raw: String, inTabArea: Bool, sites: [String], unwrapped: Bool) -> Value {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .cantTell }
        let lower = url.lowercased()

        if SiteRule.isReaderViewURL(url) {
            guard !unwrapped, let inner = SiteRule.readerViewInnerURL(url), !SiteRule.isReaderViewURL(inner) else {
                return .cantTell
            }
            return classify(inner, inTabArea: inTabArea, sites: sites, unwrapped: true)
        }

        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("view-source:") || lower.hasPrefix("blob:") {
            guard let host = SiteRule.normalizeReadHost(url) else { return .cantTell }
            return SiteRule.covers(sites: sites, host: host) ? .covered(host: host) : .ordinary(host: host)
        }

        if lower.hasPrefix("about:") {
            let name = lower.dropFirst("about:".count).prefix { $0 != "?" && $0 != "#" }
            return ordinaryAboutPages.contains(String(name)) ? .ordinary(host: nil) : .cantTell
        }

        if lower.hasPrefix("moz-extension:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") {
            return .ordinary(host: nil)
        }

        if lower.hasPrefix("chrome:") {
            let document = url.prefix { $0 != "?" }
            return !inTabArea && ordinarySidebarDocuments.contains(String(document)) ? .ordinary(host: nil) : .cantTell
        }

        return .cantTell
    }

    static func isDevtools(_ url: String?) -> Bool {
        guard let url else { return false }
        return url.lowercased().hasPrefix("about:devtools-toolbox")
    }

    /// A non-zero frame inside the window's frame, within 1 pt.
    public static func isShown(_ area: FirefoxWebArea, in window: CGRect) -> Bool {
        guard let f = area.frame, f.width > 0, f.height > 0 else { return false }
        return f.minX >= window.minX - 1 && f.minY >= window.minY - 1
            && f.maxX <= window.maxX + 1 && f.maxY <= window.maxY + 1
    }

    /// The page a window shows: its one shown tab area that isn't devtools. Nil when there is none,
    /// or more than one.
    public static func shownPage(_ walk: FirefoxWalkResult, windowFrame: CGRect?) -> FirefoxWebArea? {
        guard let windowFrame else { return nil }
        let pages = walk.areas.filter { $0.isTabArea && !isDevtools($0.url) && isShown($0, in: windowFrame) }
        return pages.count == 1 ? pages[0] : nil
    }

    /// One page window's read: the window's two AX titles, the walk and the window's frame between
    /// them, and the window server's title read straight after the closing title.
    public struct PageRead: Sendable, Equatable {
        public var cgTitle: String
        public var openingTitle: String?
        public var closingTitle: String?
        public var walk: FirefoxWalkResult
        public var windowFrame: CGRect?

        public init(cgTitle: String, openingTitle: String?, closingTitle: String?, walk: FirefoxWalkResult, windowFrame: CGRect?) {
            self.cgTitle = cgTitle
            self.openingTitle = openingTitle
            self.closingTitle = closingTitle
            self.walk = walk
            self.windowFrame = windowFrame
        }
    }

    /// The verdict on one read, before rule 6's wait: what the window shows, and the shown page's address.
    struct Judgement {
        var verdict: ChromiumVerdict
        var cause: ChromiumUnclearCause?
        var host: String?
        var pageURL: String?
    }

    static func judge(
        _ read: PageRead,
        previousCGTitle: String?,
        previousAXTitle: String?,
        previousOrdinaryURL: String?,
        sites: [String]
    ) -> Judgement {
        // Covered wins: any collected area, tab or other, shown or not, whose address names a
        // covered host, whatever else the read says.
        for area in read.walk.areas {
            guard let url = area.url else { continue }
            if case .covered(let host) = value(of: url, inTabArea: area.isTabArea, sites: sites) {
                return Judgement(verdict: .covered, cause: nil, host: host, pageURL: nil)
            }
        }

        let page = shownPage(read.walk, windowFrame: read.windowFrame)
        let pageHost = page?.url.flatMap { host(of: $0) }

        guard let opening = read.openingTitle, let closing = read.closingTitle, read.windowFrame != nil else {
            return Judgement(verdict: .cantTell, cause: .unread, host: pageHost, pageURL: nil)
        }
        switch read.walk.outcome {
        case .failed, .timedOut:
            return Judgement(verdict: .cantTell, cause: .unread, host: pageHost, pageURL: nil)
        case .overBudget:
            return Judgement(verdict: .cantTell, cause: .unclear, host: pageHost, pageURL: nil)
        case .complete:
            break
        }
        if opening != closing {
            return Judgement(verdict: .cantTell, cause: .unclear, host: pageHost, pageURL: nil)
        }

        // The AX title leads the window server's by about 0.2 s. On the page the window's previous
        // ordinary read showed, a disagreement is the page's own title changing, not a new page.
        let samePage = page?.url != nil && page?.url == previousOrdinaryURL
        if read.cgTitle != opening && !samePage {
            return Judgement(verdict: .cantTell, cause: .unclear, host: pageHost, pageURL: nil)
        }
        if let prevCG = previousCGTitle, let prevAX = previousAXTitle,
           read.cgTitle != prevCG, opening == prevAX, !samePage {
            return Judgement(verdict: .cantTell, cause: .unclear, host: pageHost, pageURL: nil)
        }

        guard let page, let pageURL = page.url, let windowFrame = read.windowFrame else {
            return Judgement(verdict: .cantTell, cause: .unclear, host: nil, pageURL: nil)
        }

        // Other documents: every shown other area by its own value. Docked devtools, sharing a tab
        // panel with exactly one page, inspect that page and are left to it.
        let shownPagesByPanel = Dictionary(grouping: read.walk.areas.filter {
            $0.isTabArea && !isDevtools($0.url) && isShown($0, in: windowFrame)
        }, by: { $0.tabPanel! })
        for area in read.walk.areas where isShown(area, in: windowFrame) && area != page {
            if area.isTabArea {
                guard isDevtools(area.url) else { continue }
                if shownPagesByPanel[area.tabPanel!]?.count == 1 { continue }
            }
            guard let url = area.url, value(of: url, inTabArea: area.isTabArea, sites: sites) != .cantTell else {
                return Judgement(verdict: .cantTell, cause: .unclear, host: pageHost, pageURL: nil)
            }
        }

        switch value(of: pageURL, inTabArea: true, sites: sites) {
        case .covered(let host):
            return Judgement(verdict: .covered, cause: nil, host: host, pageURL: pageURL)
        case .ordinary(let host):
            return Judgement(verdict: .ordinary, cause: nil, host: host, pageURL: pageURL)
        case .cantTell:
            return Judgement(verdict: .cantTell, cause: .unclear, host: nil, pageURL: nil)
        }
    }

    /// One page window's read, with rule 6: once a window has read covered, it reads can't tell until
    /// its reads have been ordinary without a break for 5 s. Returns the shown page's address when the
    /// read is ordinary, for the next read's title check.
    public static func evaluatePageWindow(
        _ read: PageRead,
        previousCGTitle: String?,
        previousAXTitle: String?,
        previousOrdinaryURL: String?,
        rule6Record: inout ChromiumRule6Record?,
        sites: [String],
        now: TimeInterval
    ) -> (evaluation: ChromiumPageEvaluation, ordinaryURL: String?) {
        let j = judge(read, previousCGTitle: previousCGTitle, previousAXTitle: previousAXTitle,
                      previousOrdinaryURL: previousOrdinaryURL, sites: sites)
        switch j.verdict {
        case .covered:
            rule6Record = ChromiumRule6Record(waitStart: now, host: j.host ?? "", firstOrdinaryAt: nil)
            return (ChromiumPageEvaluation(verdict: .covered, cause: nil, host: j.host), nil)
        case .cantTell:
            if rule6Record != nil {
                rule6Record?.waitStart = now
                rule6Record?.firstOrdinaryAt = nil
            }
            return (ChromiumPageEvaluation(verdict: .cantTell, cause: j.cause, host: j.host), nil)
        case .ordinary:
            if var r6 = rule6Record {
                let first = r6.firstOrdinaryAt ?? now
                r6.firstOrdinaryAt = first
                if now - first < 5.0 {
                    rule6Record = r6
                    return (ChromiumPageEvaluation(verdict: .cantTell, cause: .unclear, host: j.host), nil)
                }
                rule6Record = nil
            }
            return (ChromiumPageEvaluation(verdict: .ordinary, cause: nil, host: j.host), j.pageURL)
        }
    }

    /// A read for desktop activity: the page rules without rule 6's wait, which the sampler's own
    /// read carries. Returns the shown page's address when the read is ordinary.
    public static func evaluateActivity(
        _ read: PageRead,
        previousCGTitle: String?,
        previousAXTitle: String?,
        sites: [String]
    ) -> (evaluation: ChromiumPageEvaluation, pageURL: String?) {
        let j = judge(read, previousCGTitle: previousCGTitle, previousAXTitle: previousAXTitle,
                      previousOrdinaryURL: nil, sites: sites)
        return (ChromiumPageEvaluation(verdict: j.verdict, cause: j.cause, host: j.host), j.verdict == .ordinary ? j.pageURL : nil)
    }

    /// Every host a walk's areas name, for list changes: a list that comes to cover one starts rule 6.
    public static func collectedHosts(_ walk: FirefoxWalkResult) -> [String] {
        walk.areas.compactMap { $0.url.flatMap { host(of: $0) } }
    }
}
