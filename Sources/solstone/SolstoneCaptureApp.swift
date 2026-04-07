// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

/// Handles app termination to ensure pending remixes complete
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuTrackingObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When the status menu opens, bring any visible app windows (settings, about) to front
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let hasVisibleWindow = NSApp.windows.contains { window in
                    window.isVisible && (window.identifier?.rawValue.contains("settings") == true
                        || window.identifier?.rawValue.contains("about") == true)
                }
                if hasVisibleWindow {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.general.info("Termination: starting shutdown...")

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
            Logger.general.warning("Timeout waiting for remix queue during termination")
        } else {
            Logger.general.info("Termination: shutdown complete")
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
            return "solstone observer — error"
        }
        if appState.pauseManager.isPaused || appState.isPaused {
            return "solstone observer — paused"
        }
        if appState.isRecording {
            switch appState.uploadCoordinator.status {
            case .offline:
                return "solstone observer — recording, sync offline"
            case .retrying:
                return "solstone observer — recording, sync retrying"
            default:
                return "solstone observer — recording"
            }
        }
        return "solstone observer — stopped"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            StatusIcon(appState: appState)
                .accessibilityLabel(statusAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)

        Window("solstone observer settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("about solstone observer", id: "about") {
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
    @State private var hasCheckedSetup = false

    private var iconName: String {
        if appState.errorMessage != nil {
            return "sol-ring-icon-error-template"
        }
        if !appState.isRecording || appState.isPaused || appState.pauseManager.isPaused {
            return "sol-ring-icon-paused-template"
        }
        switch appState.uploadCoordinator.status {
        case .synced, .syncing, .uploading:
            return "sol-ring-template"
        case .notSynced, .retrying, .offline:
            return "sol-ring-icon-half-template"
        }
    }

    var body: some View {
        bundleImage(iconName, isTemplate: true)
        .task {
            guard !hasCheckedSetup else { return }
            hasCheckedSetup = true
            // Wait for the first real permission check to complete before deciding
            // whether to open settings — avoids false-positive on startup.
            while !appState.initialPermissionCheckComplete {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !appState.screenRecordingGranted || !appState.microphoneGranted {
                appState.pendingSettingsTab = "permissions"
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
