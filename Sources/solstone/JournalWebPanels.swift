// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import WebKit

/// The journal's pages ask the owner with `alert()`, `confirm()` and `prompt()`
/// before unpairing a device, closing a door or redoing a day. `WKWebView` draws
/// no dialog for these on its own: without its panel delegate methods it answers
/// every one as cancel, and the action silently does nothing. This draws each
/// one as a sheet on the journal window and answers with what the owner chose.
/// A sheet still open when the window goes away answers cancel, so the page is
/// never left waiting.
@MainActor
final class JournalWebPanels {
    enum Kind: Equatable {
        case alert
        case confirm
        case prompt(defaultText: String?)
    }

    enum Answer: Equatable {
        case accepted(text: String?)
        case cancelled
    }

    private struct Open {
        let alert: NSAlert
        let window: NSWindow
        let field: NSTextField?
        let continuation: CheckedContinuation<Answer, Never>
    }

    private var open: Open?
    private var isTornDown = false

    /// The sheet on screen now, if any.
    var openAlert: NSAlert? {
        open?.alert
    }

    func present(_ kind: Kind, message: String, over webView: WKWebView) async -> Answer {
        guard !isTornDown, open == nil, let window = webView.window, window.attachedSheet == nil else {
            return .cancelled
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: UICopy.JOURNAL_PANEL_OK)
        if kind != .alert {
            alert.addButton(withTitle: UICopy.JOURNAL_PANEL_CANCEL).keyEquivalent = "\u{1b}"
        }
        var field: NSTextField?
        if case .prompt(let defaultText) = kind {
            let input = NSTextField(string: defaultText ?? "")
            input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
        }
        // A sheet keeps AppKit from quitting the app; an unanswered page question
        // must not hold up a quit, a logout or an update's relaunch.
        alert.window.preventsApplicationTerminationWhenModal = false
        return await withCheckedContinuation { continuation in
            open = Open(alert: alert, window: window, field: field, continuation: continuation)
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.resolve(response == .alertFirstButtonReturn)
            }
        }
    }

    /// The owner's choice, as pressing the sheet's button would give it.
    func answer(accepted: Bool) {
        guard let open else { return }
        open.window.endSheet(
            open.alert.window,
            returnCode: accepted ? .alertFirstButtonReturn : .alertSecondButtonReturn
        )
    }

    func tearDown() {
        isTornDown = true
        answer(accepted: false)
        resolve(false)
    }

    private func resolve(_ accepted: Bool) {
        guard let open else { return }
        self.open = nil
        open.continuation.resume(returning: accepted ? .accepted(text: open.field?.stringValue) : .cancelled)
    }
}
