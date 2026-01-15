// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCaptureCore

/// Handles app termination to ensure pending remixes complete
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("Termination: starting shutdown...")

        // Request time to complete pending work before termination
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Completing pending work before termination"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Recording is already stopped by MenuContent's quit handler.
        // Just wait for any pending remix jobs using a semaphore.
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            // Clear the callback to prevent issues during final remix
            await RemixQueue.shared.setOnSegmentComplete(nil)
            await RemixQueue.shared.waitForCompletion()
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 30)
        if result == .timedOut {
            Log.warn("Timeout waiting for remix queue during termination")
        } else {
            Log.info("Termination: shutdown complete")
        }
    }
}

@main
struct SolstoneCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    init() {
        // Configure unbuffered output for stderr
        Stderr.setUnbuffered()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            Image(systemName: appState.statusIconName)
        }
        .menuBarExtraStyle(.menu)

        Window("Solstone Settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
