// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ApplicationServices
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
    func walkTabStrip(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval) -> ChromiumTabStripOutcome
    func walkSideWindow(for window: AXUIElement, maxNodes: Int, timeoutSeconds: TimeInterval) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome)
}

public final class LiveChromiumWindowReader: ChromiumWindowReading, @unchecked Sendable {
    public let recorder: AXReadRecorder?

    public init(recorder: AXReadRecorder? = nil) {
        self.recorder = recorder
    }

    public func copyWindows(for pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        recorder?.recordRead(attribute: kAXWindowsAttribute, role: kAXApplicationRole)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val) == .success,
              let wins = val as? [AXUIElement] else {
            return nil
        }
        return wins
    }

    public func focusedWindow(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        recorder?.recordRead(attribute: kAXFocusedWindowAttribute, role: kAXApplicationRole)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &val) == .success,
              let window = val else {
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
        recorder?.recordRead(attribute: kAXTitleAttribute, role: kAXWindowRole)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &val) == .success else { return nil }
        return val as? String
    }

    public func readDocument(for window: AXUIElement) -> (doc: String?, failed: Bool) {
        AXUIElementSetMessagingTimeout(window, 0.025)
        recorder?.recordRead(attribute: "AXDocument", role: kAXWindowRole)
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(window, "AXDocument" as CFString, &val)
        if err == .success {
            return (val as? String ?? "", false)
        }
        return (nil, true)
    }

    public func walkTabStrip(for window: AXUIElement, maxNodes: Int = 3000, timeoutSeconds: TimeInterval = 0.05) -> ChromiumTabStripOutcome {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        var visited = 0
        var selectedCount = 0
        var totalCount = 0

        var stack: [AXUIElement] = [window]

        while !stack.isEmpty {
            if ContinuousClock.now >= deadline {
                return .truncated
            }
            if visited >= maxNodes {
                return .truncated
            }
            let current = stack.removeLast()
            visited += 1

            AXUIElementSetMessagingTimeout(current, 0.025)
            recorder?.recordRead(attribute: kAXRoleAttribute, role: nil)
            var roleVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleVal) == .success,
                  let role = roleVal as? String else {
                continue
            }

            // Do not descend into tab buttons or web areas
            if role == "AXTabButton" {
                totalCount += 1
                recorder?.recordRead(attribute: kAXValueAttribute, role: "AXTabButton")
                var val: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, kAXValueAttribute as CFString, &val) == .success {
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
            recorder?.recordRead(attribute: kAXChildrenAttribute, role: role)
            var childrenVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenVal) == .success,
               let children = childrenVal as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }

        return .counts(selected: selectedCount, total: totalCount)
    }

    public func walkSideWindow(for window: AXUIElement, maxNodes: Int = 300, timeoutSeconds: TimeInterval = 0.15) -> (staticTexts: [String], outcome: ChromiumSiteRead.WalkOutcome) {
        AXUIElementSetMessagingTimeout(window, 0.025)
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        var visited = 0
        var texts: [String] = []
        var stack: [AXUIElement] = [window]

        while !stack.isEmpty {
            if ContinuousClock.now >= deadline {
                return (texts, .timedOut)
            }
            if visited >= maxNodes {
                return (texts, .overBudget)
            }
            let current = stack.removeLast()
            visited += 1

            AXUIElementSetMessagingTimeout(current, 0.025)
            recorder?.recordRead(attribute: kAXRoleAttribute, role: nil)
            var roleVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleVal) == .success,
                  let role = roleVal as? String else {
                continue
            }

            if role == "AXWebArea" {
                continue
            }

            if role == "AXStaticText" {
                recorder?.recordRead(attribute: kAXValueAttribute, role: "AXStaticText")
                var textVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, kAXValueAttribute as CFString, &textVal) == .success,
                   let str = textVal as? String, !str.isEmpty {
                    texts.append(str)
                }
            }

            recorder?.recordRead(attribute: kAXChildrenAttribute, role: role)
            var childrenVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenVal) == .success,
               let children = childrenVal as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }

        return (texts, .complete)
    }
}
