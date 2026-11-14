// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import os

public struct AllowedAXRead: Hashable, Sendable {
    public let attribute: String
    public let role: String?

    public init(attribute: String, role: String?) {
        self.attribute = attribute
        self.role = role
    }
}

public final class AXReadRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (reads: Set<AllowedAXRead>(), actionCount: 0, setCount: 0))

    public init() {}

    public func recordRead(attribute: String, role: String?) {
        lock.withLock { state in
            state.reads.insert(AllowedAXRead(attribute: attribute, role: role))
        }
    }

    public func recordAction() {
        lock.withLock { state in
            state.actionCount += 1
        }
    }

    public func recordSet() {
        lock.withLock { state in
            state.setCount += 1
        }
    }

    public var recordedReads: Set<AllowedAXRead> {
        lock.withLock { $0.reads }
    }

    public var actionCount: Int {
        lock.withLock { $0.actionCount }
    }

    public var setCount: Int {
        lock.withLock { $0.setCount }
    }

    public func reset() {
        lock.withLock { state in
            state.reads.removeAll()
            state.actionCount = 0
            state.setCount = 0
        }
    }
}

public protocol ChromiumWindowReading: Sendable {
    func copyWindows(for pid: pid_t) -> [AXUIElement]?
    func focusedWindow(for pid: pid_t) -> AXUIElement?
    func windowID(for window: AXUIElement) -> CGWindowID?
    func readTitle(for window: AXUIElement) -> String?
    func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool)
    func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> ChromiumTabStripOutcome
    func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval, nowTicks: @escaping @Sendable () -> UInt64) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome)
}

public final class LiveChromiumWindowReader: ChromiumWindowReading, @unchecked Sendable {
    public let recorder: AXReadRecorder?
    public var copyAttribute: @Sendable (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    private struct LogState: @unchecked Sendable {
        var entries: [(element: AXUIElement, attribute: String)] = []
    }
    private let logLock = OSAllocatedUnfairLock(initialState: LogState())

    public var copyLog: [(element: AXUIElement, attribute: String)] {
        logLock.withLockUnchecked { $0.entries }
    }

    public init(recorder: AXReadRecorder? = nil) {
        self.recorder = recorder
        self.copyAttribute = { element, attr in
            var val: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, attr, &val)
            return (err, val)
        }
    }

    private func performCopyAttribute(_ element: AXUIElement, _ attribute: CFString, role: String?) -> (AXError, CFTypeRef?) {
        recorder?.recordRead(attribute: attribute as String, role: role)
        let attrStr = attribute as String
        logLock.withLockUnchecked { state in
            state.entries.append((element: element, attribute: attrStr))
        }
        return copyAttribute(element, attribute)
    }

    public func copyWindows(for pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let (err, val) = performCopyAttribute(app, kAXWindowsAttribute as CFString, role: kAXApplicationRole)
        guard err == .success, let wins = val as? [AXUIElement] else {
            return nil
        }
        return wins
    }

    public func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let (err, val) = performCopyAttribute(app, kAXFocusedWindowAttribute as CFString, role: kAXApplicationRole)
        guard err == .success, let window = val else {
            return nil
        }
        return unsafeDowncast(window, to: AXUIElement.self)
    }

    public func windowID(for window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &wid) == .success else { return nil }
        return wid
    }

    public func readTitle(for window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let (err, val) = performCopyAttribute(window, kAXTitleAttribute as CFString, role: kAXWindowRole)
        guard err == .success else { return nil }
        return val as? String
    }

    public func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let (err, val) = performCopyAttribute(window, "AXDocument" as CFString, role: kAXWindowRole)
        if err == .success {
            return (val as? String ?? "", false)
        }
        return (nil, true)
    }

    public func walkTabStrip(
        for window: AXUIElement,
        maxNodes: Int = 3000,
        timeoutSeconds: TimeInterval = 0.05,
        nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) -> ChromiumTabStripOutcome {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let startTicks = nowTicks()
        var visited = 0
        var selectedCount = 0
        var totalCount = 0

        var stack: [AXUIElement] = [window]

        while !stack.isEmpty {
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return .truncated
            }
            if visited >= maxNodes {
                return .truncated
            }
            let current = stack.removeLast()
            visited += 1

            AXUIElementSetMessagingTimeout(current, 0.025)
            let (roleErr, roleVal) = performCopyAttribute(current, kAXRoleAttribute as CFString, role: nil)
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return .truncated
            }
            guard roleErr == .success, let role = roleVal as? String else {
                continue
            }

            // Do not descend into tab buttons or web areas
            if role == "AXTabButton" {
                totalCount += 1
                let (valErr, val) = performCopyAttribute(current, kAXValueAttribute as CFString, role: "AXTabButton")
                if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                    return .truncated
                }
                if valErr == .success {
                    if let num = val as? NSNumber, num.intValue == 1 {
                        selectedCount += 1
                    } else if let str = val as? String, str == "1" || str.lowercased() == "true" {
                        selectedCount += 1
                    }
                }
                continue
            }
            if role == "AXWebArea" {
                continue
            }

            // Descend into children (including scroll areas)
            let (childrenErr, childrenVal) = performCopyAttribute(current, kAXChildrenAttribute as CFString, role: role)
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return .truncated
            }
            if childrenErr == .success, let children = childrenVal as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }

        return .counts(selected: selectedCount, total: totalCount)
    }

    public func walkSideWindow(
        for window: AXUIElement,
        maxNodes: Int = 300,
        timeoutSeconds: TimeInterval = 0.15,
        nowTicks: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }
    ) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let startTicks = nowTicks()
        var visited = 0
        var texts: [String] = []
        var stack: [AXUIElement] = [window]

        while !stack.isEmpty {
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return (texts, .timedOut)
            }
            if visited >= maxNodes {
                return (texts, .overBudget)
            }
            let current = stack.removeLast()
            visited += 1

            AXUIElementSetMessagingTimeout(current, 0.025)
            let (roleErr, roleVal) = performCopyAttribute(current, kAXRoleAttribute as CFString, role: nil)
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return (texts, .timedOut)
            }
            guard roleErr == .success, let role = roleVal as? String else {
                continue
            }

            if role == "AXWebArea" {
                continue
            }

            if role == "AXStaticText" {
                let (textErr, textVal) = performCopyAttribute(current, kAXValueAttribute as CFString, role: "AXStaticText")
                if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                    return (texts, .timedOut)
                }
                if textErr == .success, let str = textVal as? String, !str.isEmpty {
                    texts.append(str)
                }
            }

            let (childrenErr, childrenVal) = performCopyAttribute(current, kAXChildrenAttribute as CFString, role: role)
            if HostClock.seconds(ticks: nowTicks() &- startTicks) >= timeoutSeconds {
                return (texts, .timedOut)
            }
            if childrenErr == .success, let children = childrenVal as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }

        return (texts, .complete)
    }
}
