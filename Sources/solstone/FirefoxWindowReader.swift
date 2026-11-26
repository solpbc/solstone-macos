// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os

/// The website rule's reads of a Firefox process. Plain attribute reads only: never an action, never
/// a set, never `AXEnhancedUserInterface` or `AXManualAccessibility`, never into an `AXWebArea`, never
/// the address field. No element other than a window is handed out, and the caller keeps none past
/// one read.
public protocol FirefoxWindowReading: Sendable {
    /// The one `AXRole` read on the application element, which turns Firefox's accessibility engine
    /// on from 162. Only ever called for a pid that passed the version gate.
    func triggerEngine(pid: pid_t)
    /// `AXWindows` on the application element. Nil: the read failed or timed out.
    func copyWindows(for pid: pid_t) -> [AXUIElement]?
    /// The window server's id for an AX window. Nil: the pairing call failed.
    func windowID(for window: AXUIElement) -> CGWindowID?
    func readTitle(for window: AXUIElement) -> String?
    /// The window's `AXPosition` and `AXSize`. Nil: either read failed.
    func readFrame(for window: AXUIElement) -> CGRect?
    /// Breadth-first from the window to every `AXWebArea`, entering none of them nor any role that
    /// holds none.
    func walkWindow(_ window: AXUIElement, maxElements: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> FirefoxWalkResult
    /// A side window's static-text host walk, as for Chromium's.
    func walkSideWindow(_ window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome)
    /// The window server's title for this window, read now. Nil: use the poll's own title.
    func currentCGTitle(windowID: CGWindowID) -> String?
}

public final class LiveFirefoxWindowReader: FirefoxWindowReading, @unchecked Sendable {
    public let recorder: AXReadRecorder?
    public var copyAttribute: @Sendable (AXUIElement, CFString) -> (AXError, CFTypeRef?)
    public var pairWindow: @Sendable (AXUIElement) -> CGWindowID?
    public var windowServerTitle: @Sendable (CGWindowID) -> String?

    public init(recorder: AXReadRecorder? = nil) {
        self.recorder = recorder
        self.copyAttribute = { element, attr in
            var val: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, attr, &val)
            return (err, val)
        }
        self.pairWindow = { window in
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &wid) == .success else { return nil }
            return wid
        }
        self.windowServerTitle = { windowID in
            guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
                  let info = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) else {
                return nil
            }
            return info[kCGWindowName as String] as? String ?? ""
        }
    }

    private func read(_ element: AXUIElement, _ attribute: String, role: String?) -> (AXError, CFTypeRef?) {
        recorder?.recordRead(attribute: attribute, role: role)
        return copyAttribute(element, attribute as CFString)
    }

    public func triggerEngine(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        recorder?.recordApplicationRead(pid: pid, attribute: kAXRoleAttribute as String)
        _ = copyAttribute(app, kAXRoleAttribute as CFString)
    }

    public func copyWindows(for pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        recorder?.recordApplicationRead(pid: pid, attribute: kAXWindowsAttribute as String)
        let (err, val) = copyAttribute(app, kAXWindowsAttribute as CFString)
        guard err == .success, let val, let windows = val as? [AXUIElement] else { return nil }
        return windows
    }

    public func windowID(for window: AXUIElement) -> CGWindowID? {
        pairWindow(window)
    }

    public func readTitle(for window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let (err, val) = read(window, kAXTitleAttribute as String, role: kAXWindowRole as String)
        guard err == .success else { return nil }
        return val as? String
    }

    public func readFrame(for window: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(window, 0.025)
        return frame(of: window, role: kAXWindowRole as String)
    }

    private func frame(of element: AXUIElement, role: String) -> CGRect? {
        let (posErr, posVal) = read(element, kAXPositionAttribute as String, role: role)
        let (sizeErr, sizeVal) = read(element, kAXSizeAttribute as String, role: role)
        guard posErr == .success, sizeErr == .success, let posVal, let sizeVal,
              CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(posVal, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeVal, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func urlString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (unsafeDowncast(value, to: CFURL.self) as URL).absoluteString }
        return nil
    }

    public func walkWindow(
        _ window: AXUIElement,
        maxElements: Int = FirefoxSiteRead.walkMaxElements,
        timeoutSeconds: TimeInterval = FirefoxSiteRead.walkTimeout,
        nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) -> FirefoxWalkResult {
        let startTicks = nowTicks()
        func timedOut() -> Bool { HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds }

        // Elements live only in this walk's queue; none is kept once it returns.
        var queue: [(element: AXUIElement, tabPanel: Int?)] = [(window, nil)]
        var index = 0
        var areas: [FirefoxWebArea] = []
        var failed = false
        var nextPanel = 0

        while index < queue.count {
            if timedOut() { return FirefoxWalkResult(areas: areas, outcome: .timedOut, visited: index) }
            if index >= maxElements { return FirefoxWalkResult(areas: areas, outcome: failed ? .failed : .overBudget, visited: index) }
            let (element, panel) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.025)

            let (roleErr, roleVal) = read(element, kAXRoleAttribute as String, role: nil)
            guard roleErr == .success, let role = roleVal as? String else {
                // Not knowing what it is, the walk doesn't enter it; it still reads the rest, so a
                // covered address elsewhere in the window is seen.
                failed = true
                continue
            }

            if role == "AXWebArea" {
                let (urlErr, urlVal) = read(element, "AXURL", role: role)
                let url: String?
                if urlErr == .success {
                    url = Self.urlString(urlVal) ?? ""
                } else if urlErr == .noValue || urlErr == .attributeUnsupported {
                    url = ""
                } else {
                    url = nil
                    failed = true
                }
                let areaFrame = frame(of: element, role: role)
                if areaFrame == nil { failed = true }
                areas.append(FirefoxWebArea(url: url, frame: areaFrame, tabPanel: panel))
                continue
            }
            if FirefoxSiteRead.skippedRoles.contains(role) { continue }

            var childPanel = panel
            if role == "AXGroup" {
                let (subErr, subVal) = read(element, kAXSubroleAttribute as String, role: role)
                if subErr == .success {
                    if let subrole = subVal as? String {
                        if subrole == "AXTabPanel" {
                            childPanel = nextPanel
                            nextPanel += 1
                        }
                    } else {
                        failed = true
                    }
                } else if subErr != .noValue && subErr != .attributeUnsupported {
                    failed = true
                }
            }

            let (childErr, childVal) = read(element, kAXChildrenAttribute as String, role: role)
            if childErr == .success {
                guard let children = childVal as? [AXUIElement] else {
                    failed = true
                    continue
                }
                queue.append(contentsOf: children.map { ($0, childPanel) })
            } else if childErr != .noValue && childErr != .attributeUnsupported {
                failed = true
            }
        }
        if timedOut() { return FirefoxWalkResult(areas: areas, outcome: .timedOut, visited: index) }
        return FirefoxWalkResult(areas: areas, outcome: failed ? .failed : .complete, visited: index)
    }

    public func walkSideWindow(
        _ window: AXUIElement,
        maxNodes: Int = 300,
        timeoutSeconds: TimeInterval = 0.15,
        nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
        let side = LiveChromiumWindowReader(recorder: recorder)
        side.copyAttribute = copyAttribute
        return side.walkSideWindow(for: window, maxNodes: maxNodes, timeoutSeconds: timeoutSeconds, nowTicks: nowTicks)
    }

    public func currentCGTitle(windowID: CGWindowID) -> String? {
        windowServerTitle(windowID)
    }
}
