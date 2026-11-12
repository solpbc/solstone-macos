// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit

/// The owner's prompt when an update has waited past `UpdateController.restartPromptThreshold`.
/// Only the owner's press restarts the app; closing the prompt or choosing later leaves
/// everything running.
@MainActor
public struct UpdateRestartPrompt {
    private let copy: UpdatesCopy

    public init(copy: UpdatesCopy) {
        self.copy = copy
    }

    public func present(version: String, respond: @escaping @MainActor (Bool) -> Void) {
        let copy = copy
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = copy.restartPromptTitle(version: version)
            alert.informativeText = copy.restartPromptBody
            alert.addButton(withTitle: copy.actionInstall)
            alert.addButton(withTitle: copy.actionLater)
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            respond(response == .alertFirstButtonReturn)
        }
    }
}
