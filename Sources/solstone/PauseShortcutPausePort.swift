// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Port abstracting pause control for keyboard shortcuts.
@MainActor
public protocol PauseShortcutPausePort: AnyObject {
    var isOwnerPaused: Bool { get }
    func pauseIndefinitely()
    func resumeOwnerPause()
}

extension PauseManager: PauseShortcutPausePort {
    public var isOwnerPaused: Bool {
        isPaused
    }

    public func pauseIndefinitely() {
        pause(for: .indefinite)
    }

    public func resumeOwnerPause() {
        resume()
    }
}
