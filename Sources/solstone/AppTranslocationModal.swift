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

        // Translocation aborts launch before observation/journal startup; use the
        // coordinator's empty-prepare intent when available, with a direct marker
        // fallback so translocation detection never depends on app state readiness.
        if let coordinator = AppState.shared?.appQuitCoordinator {
            coordinator.requestTranslocationRepair()
        } else {
            ExpectedExitMarker.markExpectedExit(reason: ExitReason.translocation.markerString)
            NSApp.terminate(nil)
        }
    }
}
