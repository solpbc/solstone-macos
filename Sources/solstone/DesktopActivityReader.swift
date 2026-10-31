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

struct DesktopActivityObservation: Sendable {
    var rows: [DesktopActivityRow]
    var windowID: UInt32?
    var titleUnavailable = false
    var urlUnavailable = false
}

/// Cross-app work stays off the UI actor. Only the foreground window's title and a browser's
/// document URL are read; editable address values are deliberately never read.
final class DesktopActivityReadPermit: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)
    var isValid: Bool { state.withLock { $0 } }
    func revoke() { state.withLock { $0 = false } }
}

struct DesktopActivityReader: Sendable {
    public typealias WalkSeam = @Sendable (AXUIElement, WebAreaWalkMode, DesktopActivityReadPermit?) -> WebAreaWalkResult

    let permit: DesktopActivityReadPermit
    let walkSeam: WalkSeam

    init(
        permit: DesktopActivityReadPermit,
        walkSeam: @escaping WalkSeam = { WebAreaWalker.walk($0, mode: $1, permit: $2) }
    ) {
        self.permit = permit
        self.walkSeam = walkSeam
    }

    func read(app: DesktopActivityApp, settings: DesktopActivitySettings) -> DesktopActivityObservation {
        guard permit.isValid, !settings.excludes(app) else { return DesktopActivityObservation(rows: []) }
        let screenGranted = permit.isValid && CGPreflightScreenCaptureAccess()
        guard permit.isValid else { return DesktopActivityObservation(rows: []) }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let window = windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0 }
        let cgTitle = screenGranted ? window?[kCGWindowName as String] as? String : nil
        let browser = PrivateBrowser.forBundleIdentifier(app.bundleID)
        let needsAX = (settings.accessibility && (settings.titles || settings.urls)) ||
            (settings.excludePrivate && settings.privateAccessibility && browser != nil) ||
            (!settings.excludedSites.isEmpty && (browser == .safari || browser == .firefox))
        var axTitle: String?
        var axDenied = false
        var focusedWindow: AXUIElement?
        var windowID = window?[kCGWindowNumber as String] as? UInt32
        if needsAX {
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let focusedRead = element(application, kAXFocusedWindowAttribute)
            axDenied = focusedRead.error == .apiDisabled
            if let focused = focusedRead.element,
               string(focused, kAXRoleAttribute) == kAXWindowRole {
                // A focused AX window is authoritative for the title and document URL.
                var axID: CGWindowID = 0
                if permit.isValid, _AXUIElementGetWindow(focused, &axID) == .success,
                   windowID == nil || windowID == axID {
                    windowID = axID
                    focusedWindow = focused
                    axTitle = string(focused, kAXTitleAttribute)
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
        if !settings.excludedSites.isEmpty && (browser == .safari || browser == .firefox) {
            let targetWindow = focusedWindow ?? AXUIElementCreateApplication(app.pid)
            let walk = walkSeam(targetWindow, .everyTopLevel, permit)
            for urlStr in walk.urls.compactMap({ $0 }) {
                if let host = SiteRule.normalizeReadHost(urlStr) {
                    if settings.excludedSites.contains(where: { SiteRule.covers(siteHost: $0, host: host) }) {
                        return DesktopActivityObservation(rows: [])
                    }
                }
            }
            if settings.urls && settings.accessibility {
                documentURL = walk.urls.compactMap({ $0 }).first
            }
        } else if settings.urls && settings.accessibility && browser != nil, let focusedWindow {
            let walk = walkSeam(focusedWindow, .firstDocument, permit)
            documentURL = walk.urls.compactMap({ $0 }).first
        }
        var row = DesktopActivityRow(kind: "foreground", method: screenGranted ? "cg-window" : (axTitle != nil && settings.accessibility ? "ax" : "nsworkspace"), app: app.name, app_id: app.bundleID)
        if settings.titles { row.title = title.flatMap { $0.isEmpty ? nil : String($0.prefix(2048)) } }
        // No address-bar AXValue is used. AXURL belongs to the currently committed document.
        if settings.urls && settings.accessibility { row.url = documentURL.flatMap(desktopActivityURL) }
        var rows = [row]
        let titleMissing = settings.titles && row.title == nil
        let urlMissing = settings.urls && row.url == nil
        if titleMissing {
            rows.append(DesktopActivityRow(kind: "availability", method: "ax", capability: "title", status: (!screenGranted && !settings.accessibility || axDenied) ? "denied" : "unavailable"))
        }
        if urlMissing {
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
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? UInt32
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> (element: AXUIElement?, error: AXError) {
        guard permit.isValid else { return (nil, .cannotComplete) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(parent, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        return (unsafeDowncast(value, to: AXUIElement.self), .success)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard permit.isValid, AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func pageURL(in window: AXUIElement) -> String? {
        var pending = [window]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        // Traverse references and roles only. No generic title/name/value/text attributes.
        while permit.isValid && !pending.isEmpty && visited < 128 && ProcessInfo.processInfo.systemUptime < deadline {
            let node = pending.removeLast(); visited += 1
            AXUIElementSetMessagingTimeout(node, 0.025)
            let role = string(node, kAXRoleAttribute)
            // Browser chrome may contain hundreds of tabs and toolbar icons. None can
            // supply a committed document URL, so keep them out of the traversal budget.
            guard ![kAXTextFieldRole, kAXTextAreaRole, "AXToolbar", "AXButton",
                    "AXRadioButton", "AXImage", "AXMenuButton", "AXStaticText"].contains(role ?? "") else { continue }
            if role == "AXWebArea" {
                var value: CFTypeRef?
                if permit.isValid, AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &value) == .success {
                    if let url = value as? URL { return url.absoluteString }
                    if let url = value as? String { return url }
                }
                // Do not enter page contents.
                continue
            }
            var children: CFTypeRef?
            if permit.isValid, AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let elements = children as? [AXUIElement] {
                // Depth first reaches the selected document before enumerating tab chrome.
                pending.append(contentsOf: elements.prefix(max(0, 128 - pending.count)).reversed())
            }
        }
        return nil
    }
}
