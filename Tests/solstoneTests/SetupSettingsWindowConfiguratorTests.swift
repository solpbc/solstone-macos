// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Testing
@testable import solstone

@Suite("SetupSettingsWindowConfigurator")
struct SetupSettingsWindowConfiguratorTests {
    @MainActor
    @Test func windowConfigurationLifecycle() {
        let originalMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: originalMask,
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.contentMinSize = NSSize(width: 100, height: 100)

        // Apply setup
        SetupSettingsWindowConfigurator.apply(setupShowing: true, to: window)
        #expect(window.title == UICopy.SETUP_WINDOW_TITLE)
        #expect(window.title == "set up solstone")
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.contentMinSize == NSSize(width: 880, height: 580))
        #expect(window.styleMask.contains(.fullSizeContentView))
        let setupContentRect = window.contentRect(forFrameRect: window.frame)
        #expect(setupContentRect.size == NSSize(width: 880, height: 580))

        // Grow content size to 900x700 and re-apply setup
        window.setContentSize(NSSize(width: 900, height: 700))
        SetupSettingsWindowConfigurator.apply(setupShowing: true, to: window)
        let grownContentRect = window.contentRect(forFrameRect: window.frame)
        #expect(grownContentRect.size == NSSize(width: 900, height: 700))

        // Apply not-showing
        SetupSettingsWindowConfigurator.apply(setupShowing: false, to: window)
        #expect(window.title == "solstone settings")
        #expect(window.styleMask == originalMask)
        #expect(window.titlebarAppearsTransparent == false)
        #expect(window.titleVisibility == .visible)
        #expect(window.contentMinSize == NSSize(width: 720, height: 500))
        let settingsContentRect = window.contentRect(forFrameRect: window.frame)
        #expect(settingsContentRect.size == NSSize(width: 900, height: 700))
    }
}
