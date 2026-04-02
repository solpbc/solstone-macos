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

    private var statusAccessibilityLabel: String {
        if appState.errorMessage != nil {
            return "solstone — error"
        }
        if appState.isPaused {
            return "solstone — paused"
        }
        if appState.muteManager.isMuted {
            return "solstone — muted"
        }
        if appState.isRecording {
            return "solstone — recording"
        }
        return "solstone — not recording"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            StatusIcon(appState: appState)
                .accessibilityLabel(statusAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)

        Window("solstone setup", id: "setup") {
            SetupView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("solstone settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("About solstone", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Loads a PNG image from the SPM resource bundle (not an asset catalog).
/// `Image(_:bundle:)` only searches asset catalogs; this uses `Bundle.image(forResource:)`.
func bundleImage(_ name: String, isTemplate: Bool = false) -> Image {
    let nsImage = Bundle.module.image(forResource: name) ?? NSImage()
    if isTemplate { nsImage.isTemplate = true }
    return Image(nsImage: nsImage)
}

/// Menu bar icon that opens the setup window on first launch
private struct StatusIcon: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            bundleImage("sol-ring-template", isTemplate: true)

            if appState.errorMessage != nil {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            } else if appState.isRecording && !appState.isPaused {
                if appState.muteManager.isMuted {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                } else {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .task {
            if appState.config.serverURL == nil {
                openWindow(id: "setup")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
