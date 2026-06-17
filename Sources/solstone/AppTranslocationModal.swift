// SPDX-License-Identifier: AGPL-3.0-only
//
// Copyright (c) 2026 sol pbc

import AppKit
import SolstoneCore

@MainActor
public enum AppTranslocationModal {
    public static func presentAndQuit() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SolMacCopy.TRANSLOCATION_MODAL_TITLE
        alert.informativeText = SolMacCopy.TRANSLOCATION_MODAL_BODY
        alert.addButton(withTitle: SolMacCopy.TRANSLOCATION_MODAL_BUTTON)
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
        ExpectedExitMarker.markExpectedExit(reason: "translocation")
        NSApp.terminate(nil)
    }
}
