// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit

/// AppKit's terminateLater handshake runs a nested event loop. Enter it from
/// the run loop, outside any main dispatch queue callout or MainActor task,
/// so asynchronous preparation and the termination reply can still run.
@MainActor
func terminateFromMainRunLoop() {
    RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
            NSApp.terminate(nil)
        }
    }
}
