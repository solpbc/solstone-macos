// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit

/// The owner's prompt when an update has waited past `UpdateController.restartPromptThreshold`.
/// Only the owner's press restarts the app; choosing later leaves everything running.
///
/// The alert is shown as an ordinary window, not run modally: a modal run loop started from
/// main-actor work holds the main queue, which would stall the app and Sparkle for as long as
/// the prompt stayed open.
@MainActor
public final class UpdateRestartPrompt: NSObject {
    private let copy: UpdatesCopy
    private var alert: NSAlert?
    private var respond: (@MainActor (Bool) -> Void)?
    // Buttons hold their target weakly; the prompt keeps itself alive until it is answered.
    private var keepAlive: UpdateRestartPrompt?

    public init(copy: UpdatesCopy) {
        self.copy = copy
    }

    public func present(version: String, respond: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.restartPromptTitle(version: version)
        alert.informativeText = copy.restartPromptBody
        let install = alert.addButton(withTitle: copy.actionInstall)
        install.target = self
        install.action = #selector(installNow)
        let later = alert.addButton(withTitle: copy.actionLater)
        later.target = self
        later.action = #selector(installLater)
        later.keyEquivalent = "\u{1b}"
        alert.layout()

        self.alert = alert
        self.respond = respond
        keepAlive = self
        NSApp.activate(ignoringOtherApps: true)
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func installNow() {
        finish(true)
    }

    @objc private func installLater() {
        finish(false)
    }

    private func finish(_ restartNow: Bool) {
        alert?.window.orderOut(nil)
        alert = nil
        let respond = respond
        self.respond = nil
        keepAlive = nil
        respond?(restartNow)
    }
}
