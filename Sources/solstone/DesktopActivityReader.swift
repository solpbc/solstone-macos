// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

struct DesktopActivityApp: Equatable, Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String

    @MainActor static func frontmost() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self(pid: app.processIdentifier, name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "")
    }
}

struct DesktopActivitySettings: Equatable, Sendable {
    var enabled: Bool
    var throughPause: Bool
    var titles: Bool
    var urls: Bool
    var accessibility: Bool
    var excludedApps: Set<String>
    var excludedIDs: Set<String>
    var excludedTitles: [String]
    var excludePrivate: Bool
    var privateAccessibility: Bool
    var excludedSites: [String]

    init(_ config: AppConfig) {
        enabled = config.isActivitySourceOn
        throughPause = config.activityContinuesThroughPause
        titles = config.activityTitlesEnabled
        urls = config.activityURLsEnabled
        accessibility = config.activityAccessibilityEnabled
        excludedApps = Set(config.excludedAppNames.map { $0.lowercased() })
        excludedIDs = Set(config.excludedApps.map(\.bundleID))
        excludedTitles = config.excludedTitlePatterns.map { $0.lowercased() }.filter { !$0.isEmpty }
        excludePrivate = config.excludePrivateBrowsing
        privateAccessibility = config.excludePrivateBrowsingAccessibility
        excludedSites = config.excludedSites
    }

    func excludes(_ app: DesktopActivityApp) -> Bool {
        excludedIDs.contains(app.bundleID) || excludedApps.contains(app.name.lowercased())
    }
}

/// What one read says a window shows: the two titles it can be read by, and its pages.
struct DesktopActivityPairRead: Equatable, Sendable {
    var cgTitle: String?
    var axTitle: String?
    var urls: [String?]
    var complete: Bool
}

struct DesktopActivityObservation: Sendable {
    var rows: [DesktopActivityRow]
    var windowID: UInt32?
    var titleUnavailable = false
    var urlUnavailable = false
}

struct DesktopActivityFrontWindow: Sendable, Equatable {
    var windowID: UInt32?
    var title: String?

    init(windowID: UInt32? = nil, title: String? = nil) {
        self.windowID = windowID
        self.title = title
    }
}

struct DesktopActivityReadSeams: Sendable {
    var chromiumReader: ChromiumWindowReading
    var preflightScreenCapture: @Sendable () -> Bool
    var frontWindow: @Sendable (pid_t) -> DesktopActivityFrontWindow?
    var focusedRead: @Sendable (AXUIElement) -> (element: AXUIElement?, error: AXError)
    var role: @Sendable (AXUIElement) -> String?
    var axWindowID: @Sendable (AXUIElement) -> CGWindowID?
    var axTitle: @Sendable (AXUIElement) -> String?
    var cgTitle: @Sendable (pid_t, Bool) -> String?
    var readDocument: @Sendable (AXUIElement) -> (doc: String?, failed: Bool)
    var settle: @Sendable () -> Void
    var nowTicks: @Sendable () -> UInt64

    init(
        chromiumReader: ChromiumWindowReading,
        preflightScreenCapture: @escaping @Sendable () -> Bool,
        frontWindow: @escaping @Sendable (pid_t) -> DesktopActivityFrontWindow?,
        focusedRead: @escaping @Sendable (AXUIElement) -> (element: AXUIElement?, error: AXError),
        role: @escaping @Sendable (AXUIElement) -> String?,
        axWindowID: @escaping @Sendable (AXUIElement) -> CGWindowID?,
        axTitle: @escaping @Sendable (AXUIElement) -> String?,
        cgTitle: @escaping @Sendable (pid_t, Bool) -> String?,
        readDocument: @escaping @Sendable (AXUIElement) -> (doc: String?, failed: Bool),
        settle: @escaping @Sendable () -> Void,
        nowTicks: @escaping @Sendable () -> UInt64
    ) {
        self.chromiumReader = chromiumReader
        self.preflightScreenCapture = preflightScreenCapture
        self.frontWindow = frontWindow
        self.focusedRead = focusedRead
        self.role = role
        self.axWindowID = axWindowID
        self.axTitle = axTitle
        self.cgTitle = cgTitle
        self.readDocument = readDocument
        self.settle = settle
        self.nowTicks = nowTicks
    }

    static func production(permit: DesktopActivityReadPermit) -> DesktopActivityReadSeams {
        DesktopActivityReadSeams(
            chromiumReader: LiveChromiumWindowReader(),
            preflightScreenCapture: { CGPreflightScreenCaptureAccess() },
            frontWindow: { pid in
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                guard let win = windows.first(where: {
                    ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                }) else { return nil }
                return DesktopActivityFrontWindow(
                    windowID: win[kCGWindowNumber as String] as? UInt32,
                    title: win[kCGWindowName as String] as? String
                )
            },
            focusedRead: { parent in
                DesktopActivityReader.element(parent, kAXFocusedWindowAttribute, permit: permit)
            },
            role: { el in
                DesktopActivityReader.string(el, kAXRoleAttribute, permit: permit)
            },
            axWindowID: { window in
                var wid: CGWindowID = 0
                guard permit.isValid, _AXUIElementGetWindow(window, &wid) == .success else { return nil }
                return wid
            },
            axTitle: { el in
                DesktopActivityReader.string(el, kAXTitleAttribute, permit: permit)
            },
            cgTitle: { pid, screenGranted in
                guard screenGranted else { return nil }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
                    ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowName as String] as? String
            },
            readDocument: { window in
                DesktopActivityReader.readAXDocument(window)
            },
            settle: {
                if DesktopActivityReader.pairSettle > 0 {
                    Thread.sleep(forTimeInterval: DesktopActivityReader.pairSettle)
                }
            },
            nowTicks: {
                mach_absolute_time()
            }
        )
    }
}

/// Cross-app work stays off the UI actor. Only the foreground window's title and a browser's
/// document URL are read; editable address values are deliberately never read.
final class DesktopActivityReadPermit: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)
    var isValid: Bool { state.withLock { $0 } }
    func revoke() { state.withLock { $0 = false } }
}

struct DesktopActivityReader: Sendable {
    public static let activityElementTimeout: Float = 0.05
    /// The gap between the two reads of a title and address. Measured in Safari 27, on a tab switch
    /// or a page change the window list's title trailed the address by 40-50 ms.
    public static let pairSettle: TimeInterval = 0.15
    public typealias WalkSeam = @Sendable (AXUIElement, WebAreaWalkMode, DesktopActivityReadPermit?, Float) -> WebAreaWalkResult

    let permit: DesktopActivityReadPermit
    let walkSeam: WalkSeam
    let seams: DesktopActivityReadSeams

    init(
        permit: DesktopActivityReadPermit,
        walkSeam: @escaping WalkSeam = { WebAreaWalker.walk($0, mode: $1, permit: $2, elementTimeout: $3) },
        seams: DesktopActivityReadSeams? = nil
    ) {
        self.permit = permit
        self.walkSeam = walkSeam
        self.seams = seams ?? .production(permit: permit)
    }

    /// A Safari read that can't vouch for the window: cut short, or with a page whose address
    /// didn't come back.
    static func siteReadIsShort(_ walk: WebAreaWalkResult) -> Bool {
        walk.completeness != .complete || walk.urls.contains { $0 == nil }
    }

    /// With Accessibility denied, no read can vouch for a window, whatever the walk reports.
    static func siteUndecided(_ walk: WebAreaWalkResult, accessibilityDenied: Bool) -> Bool {
        accessibilityDenied || siteReadIsShort(walk)
    }

    /// A title and an address come from separate reads, and they don't change together: through a
    /// tab switch or a page change one tab's title sits beside the next page's address. So a row
    /// pairs them only when two complete reads apart agree and the window shows one page, since a
    /// page with its predecessor still attached is mid-change. In Safari the window list and
    /// Accessibility also have to name the same title. Other browsers add their own name to one.
    static func titleGoesWithAddress(_ first: DesktopActivityPairRead, _ second: DesktopActivityPairRead, titlesMustMatch: Bool) -> Bool {
        guard first == second, first.complete, first.urls.count <= 1 else { return false }
        guard titlesMustMatch, let cgTitle = first.cgTitle else { return true }
        return SiteDecision.titleMatches(axTitle: first.axTitle, cgTitle: cgTitle)
    }

    func read(
        app: DesktopActivityApp,
        settings: DesktopActivitySettings,
        snapshot: ChromiumActivitySnapshot = ChromiumActivitySnapshot()
    ) -> DesktopActivityObservation {
        guard permit.isValid, !settings.excludes(app) else { return DesktopActivityObservation(rows: []) }
        let screenGranted = permit.isValid && seams.preflightScreenCapture()
        guard permit.isValid else { return DesktopActivityObservation(rows: []) }
        let window = seams.frontWindow(app.pid)
        let cgTitle = screenGranted ? window?.title : nil
        let browser = PrivateBrowser.forBundleIdentifier(app.bundleID)
        let needsAX = (settings.accessibility && (settings.titles || settings.urls)) ||
            (settings.excludePrivate && settings.privateAccessibility && browser != nil) ||
            (!settings.excludedSites.isEmpty && browser != nil)
        var axTitle: String?
        var axDenied = false
        var focusedWindow: AXUIElement?
        var windowID = window?.windowID
        if needsAX {
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let focusedRead = seams.focusedRead(application)
            axDenied = focusedRead.error == .apiDisabled
            if let focused = focusedRead.element,
               seams.role(focused) == kAXWindowRole {
                // A focused AX window is authoritative for the title and document URL.
                var axID: CGWindowID = 0
                if permit.isValid, let id = seams.axWindowID(focused),
                   windowID == nil || windowID == id {
                    windowID = id
                    focusedWindow = focused
                    axTitle = seams.axTitle(focused)
                }
            } else {
                windowID = nil
            }
        }
        let title = cgTitle ?? (settings.accessibility ? axTitle : nil)
        let exclusionTitle = cgTitle ?? axTitle ?? ""
        if settings.excludedTitles.contains(where: { exclusionTitle.lowercased().contains($0) }) {
            return DesktopActivityObservation(rows: [])
        }
        if settings.excludePrivate, let browser {
            let verdict: TitleVerdict
            if browser == .firefox {
                verdict = PrivateBrowser.firefoxVerdict(windowTitle: exclusionTitle)
            } else if settings.privateAccessibility, let axTitle, cgTitle != nil, windowID != nil {
                verdict = browser.accessibilityVerdict(windowTitle: cgTitle ?? "", accessibilityTitle: axTitle)
            } else { verdict = .undecided }
            if verdict == .privateWindow { return DesktopActivityObservation(rows: []) }
        }

        var documentURL: String?
        var siteUndecided = false
        if !settings.excludedSites.isEmpty && browser == .safari {
            let targetWindow = focusedWindow ?? AXUIElementCreateApplication(app.pid)
            let walk = walkSeam(targetWindow, .everyTopLevel, permit, Self.activityElementTimeout)
            if isLeftOut(walk.urls, settings: settings) { return DesktopActivityObservation(rows: []) }
            // A read that can't vouch for this window keeps its title and address out of this
            // sample, as its frames stay off the screen.
            // With no focused window paired to the window list, the title is one window's and the
            // walk is every window's. A window with no page read yet may be a left-out page whose
            // address hasn't appeared: a frame takes two empty walks a second apart to trust that.
            if Self.siteUndecided(walk, accessibilityDenied: axDenied) || focusedWindow == nil || walk.urls.isEmpty {
                siteUndecided = true
            } else {
                let first = DesktopActivityPairRead(cgTitle: cgTitle, axTitle: axTitle, urls: walk.urls, complete: walk.completeness == .complete)
                let second = readPairAgain(app: app, screenGranted: screenGranted, focused: targetWindow, mode: .everyTopLevel)
                if isLeftOut(second.urls, settings: settings) { return DesktopActivityObservation(rows: []) }
                if !Self.titleGoesWithAddress(first, second, titlesMustMatch: true) {
                    siteUndecided = true
                } else if settings.urls && settings.accessibility {
                    documentURL = walk.urls.compactMap({ $0 }).first
                }
            }
        } else if let browser, (browser == .chrome || browser == .edge || browser == .brave) {
            if focusedWindow == nil {
                siteUndecided = true
                documentURL = nil
            } else {
                let win = focusedWindow!
                let cg1 = cgTitle
                let ax1 = axTitle
                let (doc1, docFailed1) = seams.readDocument(win)

                seams.settle()

                let cg2 = seams.cgTitle(app.pid, screenGranted)
                let ax2 = seams.axTitle(win)
                let (doc2, docFailed2) = seams.readDocument(win)

                let wid = windowID.map { CGWindowID($0) }
                let prevCG = wid != nil ? snapshot.latestCGTitle[wid!] : nil
                let prevAX = wid != nil ? snapshot.latestAXTitle[wid!] : nil

                func tabStripOutcome(cg: String?, ax: String?, doc: String?) -> ChromiumTabStripOutcome {
                    if ax == cg || (doc?.isEmpty == true) {
                        return seams.chromiumReader.walkTabStrip(for: win, maxNodes: 3000, timeoutSeconds: 0.050, nowTicks: { mach_absolute_time() })
                    }
                    return .notRun
                }

                let outcome1 = tabStripOutcome(cg: cg1, ax: ax1, doc: doc1)
                let outcome2 = tabStripOutcome(cg: cg2, ax: ax2, doc: doc2)

                if !settings.excludedSites.isEmpty {
                    let eval1 = ChromiumSiteRead.evaluateActivity(
                        browser: browser,
                        cgTitle: cg1 ?? "",
                        axTitle: ax1 ?? "",
                        doc: doc1,
                        docReadFailed: docFailed1,
                        previousCGTitle: prevCG,
                        previousAXTitle: prevAX,
                        tabStripOutcome: outcome1,
                        sites: settings.excludedSites
                    )
                    let eval2 = ChromiumSiteRead.evaluateActivity(
                        browser: browser,
                        cgTitle: cg2 ?? "",
                        axTitle: ax2 ?? "",
                        doc: doc2,
                        docReadFailed: docFailed2,
                        previousCGTitle: prevCG,
                        previousAXTitle: prevAX,
                        tabStripOutcome: outcome2,
                        sites: settings.excludedSites
                    )

                    let snap = wid != nil ? snapshot.latestCompleteRead[wid!] : nil
                    if eval1.verdict == .covered || eval2.verdict == .covered || snap?.verdict == .covered {
                        return DesktopActivityObservation(rows: [])
                    }

                    var valid = true
                    if eval1.verdict != .ordinary || eval2.verdict != .ordinary { valid = false }
                    if eval1.host == nil || eval2.host == nil || eval1.host != eval2.host { valid = false }
                    if let snap {
                        let nowSec = HostClock.seconds(ticks: seams.nowTicks())
                        if snap.verdict != .ordinary { valid = false }
                        if nowSec - snap.start > 1.0 { valid = false }
                        if snap.host != eval1.host { valid = false }
                        if snap.listGeneration < snapshot.currentGeneration { valid = false }
                    } else {
                        valid = false
                    }

                    if !valid {
                        siteUndecided = true
                        documentURL = nil
                    } else {
                        if settings.urls && settings.accessibility {
                            documentURL = doc2
                        }
                    }
                } else {
                    let eval1 = ChromiumSiteRead.evaluateActivity(
                        browser: browser,
                        cgTitle: cg1 ?? "",
                        axTitle: ax1 ?? "",
                        doc: doc1,
                        docReadFailed: docFailed1,
                        previousCGTitle: prevCG,
                        previousAXTitle: prevAX,
                        tabStripOutcome: outcome1,
                        sites: []
                    )
                    let eval2 = ChromiumSiteRead.evaluateActivity(
                        browser: browser,
                        cgTitle: cg2 ?? "",
                        axTitle: ax2 ?? "",
                        doc: doc2,
                        docReadFailed: docFailed2,
                        previousCGTitle: prevCG,
                        previousAXTitle: prevAX,
                        tabStripOutcome: outcome2,
                        sites: []
                    )

                    if eval1.verdict != .cantTell && eval2.verdict != .cantTell && doc1 == doc2 && doc1 != nil {
                        if settings.urls && settings.accessibility {
                            documentURL = doc1
                        }
                    }
                }
            }
        } else if (settings.urls && settings.accessibility || !settings.excludedSites.isEmpty) && browser != nil, let focusedWindow {
            // Another browser (e.g. Firefox): wherever its page address can be read, a left-out website stays
            // out of activity, title and address alike, whether addresses are recorded or not.
            let walk = walkSeam(focusedWindow, .firstDocument, permit, Self.activityElementTimeout)
            if isLeftOut(walk.urls, settings: settings) { return DesktopActivityObservation(rows: []) }
            documentURL = walk.urls.compactMap({ $0 }).first
            if documentURL != nil {
                let first = DesktopActivityPairRead(cgTitle: cgTitle, axTitle: axTitle, urls: walk.urls, complete: walk.completeness == .complete)
                let second = readPairAgain(app: app, screenGranted: screenGranted, focused: focusedWindow, mode: .firstDocument)
                if isLeftOut(second.urls, settings: settings) { return DesktopActivityObservation(rows: []) }
                // A title is held back only to keep it from pairing with the wrong address.
                if !Self.titleGoesWithAddress(first, second, titlesMustMatch: browser == .safari),
                   settings.urls && settings.accessibility {
                    siteUndecided = true
                    documentURL = nil
                }
            }
        }
        var row = DesktopActivityRow(kind: "foreground", method: screenGranted ? "cg-window" : (axTitle != nil && settings.accessibility ? "ax" : "nsworkspace"), app: app.name, app_id: app.bundleID)
        if settings.titles, !siteUndecided { row.title = title.flatMap { $0.isEmpty ? nil : String($0.prefix(2048)) } }
        // No address-bar AXValue is used. AXDocument is the committed document for Chrome, Edge, and Brave. The address field stays unread.
        if settings.urls && settings.accessibility { row.url = documentURL.flatMap(desktopActivityURL) }
        var rows = [row]
        let titleMissing = settings.titles && row.title == nil
        let urlMissing = settings.urls && row.url == nil && browser != nil
        if titleMissing {
            rows.append(DesktopActivityRow(kind: "availability", method: "ax", capability: "title", status: (!screenGranted && !settings.accessibility || axDenied) ? "denied" : "unavailable"))
        }
        if settings.urls && row.url == nil {
            rows.append(DesktopActivityRow(kind: "availability", method: "ax", capability: "url", status: browser == nil ? "unsupported" : (!settings.accessibility || axDenied ? "denied" : "unavailable")))
        }
        guard permit.isValid else { return DesktopActivityObservation(rows: []) }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        if idle.isFinite && idle >= 0 {
            rows.append(DesktopActivityRow(kind: "activity", method: "quartz", state: idle >= 60 ? "idle" : "active"))
        } else {
            rows.append(DesktopActivityRow(kind: "availability", method: "quartz", capability: "idle", status: "unavailable"))
        }
        return DesktopActivityObservation(rows: rows, windowID: windowID, titleUnavailable: titleMissing, urlUnavailable: urlMissing)
    }

    static func frontWindowID(pid: pid_t) -> UInt32? {
        frontWindow(pid: pid)?[kCGWindowNumber as String] as? UInt32
    }

    private static func frontWindow(pid: pid_t) -> [String: Any]? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private func isLeftOut(_ urls: [String?], settings: DesktopActivitySettings) -> Bool {
        urls.compactMap { $0 }.contains { url in
            guard let host = SiteRule.normalizeReadHost(url) else { return false }
            return settings.excludedSites.contains { SiteRule.covers(siteHost: $0, host: host) }
        }
    }

    private func readPairAgain(app: DesktopActivityApp, screenGranted: Bool, focused: AXUIElement, mode: WebAreaWalkMode) -> DesktopActivityPairRead {
        seams.settle()
        let walk = walkSeam(focused, mode, permit, Self.activityElementTimeout)
        return DesktopActivityPairRead(
            cgTitle: seams.cgTitle(app.pid, screenGranted),
            axTitle: seams.axTitle(focused),
            urls: walk.urls,
            complete: walk.completeness == .complete
        )
    }

    fileprivate static func element(_ parent: AXUIElement, _ attribute: String, permit: DesktopActivityReadPermit) -> (element: AXUIElement?, error: AXError) {
        guard permit.isValid else { return (nil, .cannotComplete) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        return (unsafeDowncast(value, to: AXUIElement.self), .success)
    }

    fileprivate static func readAXDocument(_ window: AXUIElement) -> (doc: String?, failed: Bool) {
        AXUIElementSetMessagingTimeout(window, 0.025)
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window, "AXDocument" as CFString, &val)
        guard err == .success, let s = val as? String else {
            return (nil, true)
        }
        return (s, false)
    }

    fileprivate static func string(_ element: AXUIElement, _ attribute: String, permit: DesktopActivityReadPermit) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var value: CFTypeRef?
        guard permit.isValid, AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
