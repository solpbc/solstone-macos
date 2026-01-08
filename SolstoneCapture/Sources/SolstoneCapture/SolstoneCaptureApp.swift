// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import SolstoneCaptureCore

/// Handles app termination to ensure pending remixes complete
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Request time to complete pending work before termination
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Completing pending work before termination"
        )

        // Use a run loop approach to avoid deadlocking MainActor
        // We need to let the main run loop process events while waiting
        let done = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        done.initialize(to: false)
        defer {
            done.deinitialize(count: 1)
            done.deallocate()
        }

        Task { @MainActor in
            // Clear callback to prevent issues during remix
            await RemixQueue.shared.setOnSegmentComplete(nil)

            // Stop recording - this finishes current segment
            await AppState.shared?.captureManager?.stopRecording()

            // Wait for any pending remixes
            await RemixQueue.shared.waitForCompletion()

            done.pointee = true
        }

        // Spin the run loop while waiting, with timeout
        let deadline = Date().addingTimeInterval(30)
        while !done.pointee && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        if !done.pointee {
            Log.warn("Timeout waiting for shutdown during termination")
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
