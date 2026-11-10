// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import ObjectiveC
import SwiftUI

@MainActor
private final class SetupWindowMemory {
    let styleMask: NSWindow.StyleMask
    let contentMinSize: NSSize
    var appliedInitialSetupSize: Bool = false

    init(window: NSWindow) {
        self.styleMask = window.styleMask
        self.contentMinSize = window.contentMinSize
    }
}

@MainActor
private var setupWindowMemoryKey: UInt8 = 0

enum SetupSettingsWindowConfigurator {
    @MainActor
    static func apply(setupShowing: Bool, groundChrome: Bool = false, to window: NSWindow) {
        if setupShowing {
            let memory: SetupWindowMemory
            if let existing = objc_getAssociatedObject(window, &setupWindowMemoryKey) as? SetupWindowMemory {
                memory = existing
            } else {
                memory = SetupWindowMemory(window: window)
                objc_setAssociatedObject(window, &setupWindowMemoryKey, memory, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }

            window.title = UICopy.SETUP_WINDOW_TITLE
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.contentMinSize = NSSize(width: 880, height: 580)

            if !memory.appliedInitialSetupSize {
                let currentContentRect = window.contentRect(forFrameRect: window.frame)
                if currentContentRect.width < 880 || currentContentRect.height < 580 {
                    window.setContentSize(NSSize(width: 880, height: 580))
                }
                memory.appliedInitialSetupSize = true
            }
        } else {
            window.title = "solstone"
            if let memory = objc_getAssociatedObject(window, &setupWindowMemoryKey) as? SetupWindowMemory {
                window.styleMask = memory.styleMask
                // Settings' own title bar: opaque, title shown. These are not read back from
                // the window when setup first shows, because SwiftUI may already have hidden the
                // title for the setup window by then, and Settings would keep it hidden.
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
                memory.appliedInitialSetupSize = false
            }
            window.contentMinSize = NSSize(width: 860, height: 600)
            if groundChrome {
                // The ground runs to the top edge: the title bar takes no band of its own, and
                // the title stays for the Window menu and app switchers only.
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
        }
    }
}

struct SetupSettingsWindowInstaller: NSViewRepresentable {
    let setupShowing: Bool
    var groundChrome = false

    func makeNSView(context: Context) -> SetupSettingsWindowHostView {
        let view = SetupSettingsWindowHostView()
        view.groundChrome = groundChrome
        view.setupShowing = setupShowing
        return view
    }

    func updateNSView(_ nsView: SetupSettingsWindowHostView, context: Context) {
        nsView.groundChrome = groundChrome
        nsView.setupShowing = setupShowing
    }
}

final class SetupSettingsWindowHostView: NSView {
    var groundChrome = false
    var setupShowing: Bool = false {
        didSet {
            applyConfigurator()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfigurator()
    }

    private func applyConfigurator() {
        guard let window else { return }
        SetupSettingsWindowConfigurator.apply(setupShowing: setupShowing, groundChrome: groundChrome, to: window)
    }
}
