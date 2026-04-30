// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

/// Single source of truth for tracked SwiftUI `Window` scenes.
/// Any new `Window` scene added to the app MUST add a case here, and all
/// `openWindow` call sites MUST call `didOpenWindow(_:)` after open.
public enum SolstoneSceneID: String, CaseIterable {
    case settings
    case about
}

public enum DockMode: String {
    case auto
    case alwaysAccessory = "always-accessory"
    case alwaysRegular = "always-regular"
}

/// Handles app termination to ensure pending remixes complete
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuTrackingObserver: Any?
    private var notificationObservers: [Any] = []
    private var ipcService: SolMacIPCService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppTranslocationDetector.isTranslocated() {
            AppTranslocationModal.presentAndQuit()
            return
        }

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { notification in
                nonisolated(unsafe) let observedObject = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let window = observedObject as? NSWindow else { return }
                    let identifierForLog = window.identifier?.rawValue ?? "<nil>"
                    let identifier = window.identifier?.rawValue
                    Logger.general.debug("Window will close: identifier=\(identifierForLog, privacy: .public)")
                    if let state = AppState.shared {
                        state.handleWindowWillClose(identifier: identifier)
                    } else {
                        Logger.general.error("AppState.shared nil in willCloseNotification")
                    }
                }
            }
        )

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

        if let state = AppState.shared {
            state.reevaluateActivationPolicy(debounced: false)
            SolMacSymlinkInstaller.ensureInstalled()
            let responder = SolMacResponder(appState: state)
            let service = SolMacIPCService(responder: responder)
            service.start()
            ipcService = service
        } else {
            Logger.general.error("AppState.shared nil in applicationDidFinishLaunching")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Fires when the user clicks the Dock tile (including the macOS 26 "recent
        // apps" tile that shows after the app drops back to .accessory). With no
        // visible windows, the click means "bring the main window back" — open Settings.
        if !flag {
            if let state = AppState.shared,
               let settingsWindow = NSApp.windows.first(where: {
                   $0.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
               }) {
                state.didOpenWindow(.settings)
                settingsWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if AppState.shared == nil {
                Logger.general.error("AppState.shared nil in applicationShouldHandleReopen")
            } else {
                Logger.general.info("applicationShouldHandleReopen: no settings NSWindow found; falling through to default")
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let state = AppState.shared {
            state.isTerminating = true
            Task { await state.heartbeatService.stop() }
        } else {
            Logger.general.error("AppState.shared nil in applicationWillTerminate")
        }
        ipcService?.stop()
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
    @State private var updateController = UpdateController()

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
            MenuContent(appState: appState, updateController: updateController)
        } label: {
            StatusIcon(appState: appState)
                .accessibilityLabel(statusAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)

        Window("solstone observer settings", id: "settings") {
            SettingsView(appState: appState, updateController: updateController)
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
/// `Image(_:bundle:)` only searches asset catalogs; this uses an explicit
/// path lookup against the bundle's `Resources/` subdirectory because
/// SwiftPM `.copy("Resources")` nests the directory inside the bundle as
/// `Contents/Resources/Resources/<file>`, and `Bundle.image(forResource:)`
/// does not recurse into subdirectories. The `inDirectory: "Resources"`
/// parameter makes the lookup work against the nested layout.
func bundleImage(_ name: String, isTemplate: Bool = false) -> Image {
    let nsImage: NSImage
    if let path = Bundle.module.path(forResource: name, ofType: "png", inDirectory: "Resources"),
       let img = NSImage(contentsOfFile: path) {
        nsImage = img
    } else {
        nsImage = NSImage()
    }
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
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .solMacOpenSettings)) { _ in
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
