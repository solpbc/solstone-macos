// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCaptureCore

/// Handles app termination to ensure pending remixes complete
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Request time to complete pending remixes before termination
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Completing pending audio remixes before termination"
        )

        // Block until all pending remixes complete
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await RemixQueue.shared.waitForCompletion()
            semaphore.signal()
        }

        // Wait up to 30 seconds for remixes to complete
        let timeout = DispatchTime.now() + .seconds(30)
        if semaphore.wait(timeout: timeout) == .timedOut {
            Log.warn("Timeout waiting for pending remixes during termination")
        }

        ProcessInfo.processInfo.endActivity(activity)
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
