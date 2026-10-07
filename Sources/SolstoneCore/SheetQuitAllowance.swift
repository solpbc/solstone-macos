// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import SwiftUI

public extension View {
    /// AppKit refuses `NSApp.terminate` while a sheet is attached, before the app
    /// delegate is asked. Every quit path (menu, logout, AppleEvent, updater
    /// relaunch) would stall behind an unanswered sheet; this lets them through.
    func allowsAppQuitWhilePresented() -> some View {
        background(SheetQuitAllowance())
    }
}

private struct SheetQuitAllowance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SheetQuitAllowanceView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SheetQuitAllowanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.preventsApplicationTerminationWhenModal = false
    }
}
