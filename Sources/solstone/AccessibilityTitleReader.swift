// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ApplicationServices
import CoreGraphics
import os

/// The window server's id for an Accessibility window. Not public API, and long stable: without it
/// an Accessibility window can only be paired with a capture window by its frame.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Reads browser window titles through Accessibility, for the opt-in second level of the
/// private-window setting. It reads one attribute, each window's title, of Safari, Chrome, Edge and
/// Brave only, and the titles are used for the exclusion decision and nothing else: never logged,
/// stored or sent.
///
/// Whether reads work is judged by doing one. `AXIsProcessTrusted()` was measured to stay stale in a
/// running process in both directions on macOS 27 (still `true` after access was removed, still
/// `false` after it was given), while real reads followed the switch within a second.
struct AccessibilityTitleReader: Sendable {
    enum Health: Equatable, Sendable {
        case working
        case notPermitted
    }

    /// A hung browser makes an Accessibility read block for 1.5 s by default; this bounds it.
    static let messagingTimeout: Float = 0.25

    /// Titles of every window of `pid`, keyed by window id. Empty when the process cannot be read.
    func titles(pid: pid_t) -> [CGWindowID: String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        var result: [CGWindowID: String] = [:]
        for window in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success else { continue }
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String else { continue }
            result[id] = text
        }
        return result
    }

    /// Reads Finder's window list (not its titles), since Finder is always running. Only a read
    /// that succeeds counts as working: refused, timed out or unreadable all mean the setting is
    /// not doing its job, whatever System Settings shows.
    func health() -> Health {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return .notPermitted
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        return error == .success ? .working : .notPermitted
    }

    /// Raises the system's Accessibility prompt. Called only when the owner turns on the second
    /// level of the private-window setting, never at install or first run.
    @MainActor
    static func ask() {
        // The value of `kAXTrustedCheckOptionPrompt`, which Swift 6 will not read as a global var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Logger.capture.info("Asked for Accessibility access for the private-window setting")
    }

    /// The Accessibility list in System Settings (named Device Control and Data Access on macOS 27).
    @MainActor
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What the private-window setting's second level shows the owner. It comes from a real read, so
/// the setting never reads "on" while it is doing nothing.
public enum PrivateWindowAccessibilityState: String, CaseIterable, Equatable, Sendable {
    case off
    case checking
    /// Turned on in this session and not working yet: the owner is still answering macOS.
    case waiting
    case working
    /// Was working and stopped, or is on from an earlier session and does not work.
    case notWorking

    public var axToken: String {
        switch self {
        case .off: return "off"
        case .checking: return "checking"
        case .waiting: return "waiting"
        case .working: return "working"
        case .notWorking: return "not_working"
        }
    }

    /// The state to show after a read.
    static func after(readWorks: Bool, askedThisSession: Bool, hasWorkedSinceAsking: Bool) -> Self {
        if readWorks { return .working }
        return askedThisSession && !hasWorkedSinceAsking ? .waiting : .notWorking
    }
}
