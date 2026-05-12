// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UserNotifications
import os

/// Single source of truth for tracked SwiftUI `Window` scenes.
/// Any new `Window` scene added to the app MUST add a case here, and all
/// `openWindow` call sites MUST call `didOpenWindow(_:)` after open.
public enum SolstoneSceneID: String, CaseIterable {
    case settings
    case about
    case installerSetup = "installer-setup"
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
    private var solChatNotificationDelegate: SolChatNotificationDelegate?

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
            let delegate = SolChatNotificationDelegate()
            solChatNotificationDelegate = delegate
            UNUserNotificationCenter.current().delegate = delegate

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
            state.installer.cancel()
            state.isTerminating = true
            Task { await state.heartbeatService.stop() }
            Task { await state.solChatBridge.stop() }
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
        let baseLabel: String
        if appState.errorMessage != nil {
            baseLabel = "solstone observer — error"
        } else if appState.pauseManager.isPaused || appState.isPaused {
            baseLabel = "solstone observer — paused"
        } else if appState.isRecording {
            switch appState.uploadCoordinator.status {
            case .offline:
                baseLabel = "solstone observer — recording, sync offline"
            case .retrying:
                baseLabel = "solstone observer — recording, sync retrying"
            default:
                baseLabel = "solstone observer — recording"
            }
        } else {
            baseLabel = "solstone observer — stopped"
        }

        if appState.solChatStale {
            return "\(baseLabel) · \(SolChatLiterals.unreachableTooltip)"
        }
        if let pending = appState.solChatPending {
            return "\(baseLabel) · sol noticed: \(pending.summary)"
        }
        return baseLabel
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState, updateController: updateController)
        } label: {
            StatusIcon(appState: appState, updateController: updateController)
                .accessibilityLabel(statusAccessibilityLabel)
        }
        .menuBarExtraStyle(.menu)

        Window("solstone observer settings", id: "settings") {
            SettingsView(appState: appState, updateController: updateController)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("about solstone observer", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("set up solstone", id: SolstoneSceneID.installerSetup.rawValue) {
            InstallerSetupSceneContent(appState: appState)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

/// Loads an image from the SPM resource bundle (not an asset catalog).
/// `Image(_:bundle:)` only searches asset catalogs; this uses an explicit
/// path lookup against the bundle's `Resources/` subdirectory because
/// SwiftPM `.copy("Resources")` nests the directory inside the bundle as
/// `Contents/Resources/Resources/<file>`, and `Bundle.image(forResource:)`
/// does not recurse into subdirectories. The `inDirectory: "Resources"`
/// parameter makes the lookup work against the nested layout.
///
/// Prefers PDF (vector, resolution-independent — renders crisp at any
/// menu-bar density and on any Retina factor) and falls back to PNG for
/// raster-only assets like the wordmark.
func bundleImage(_ name: String, isTemplate: Bool = false) -> Image {
    let nsImage: NSImage
    if let pdfPath = Bundle.module.path(forResource: name, ofType: "pdf", inDirectory: "Resources"),
       let img = NSImage(contentsOfFile: pdfPath) {
        nsImage = img
    } else if let pngPath = Bundle.module.path(forResource: name, ofType: "png", inDirectory: "Resources"),
              let img = NSImage(contentsOfFile: pngPath) {
        nsImage = img
    } else {
        nsImage = NSImage()
    }
    if isTemplate { nsImage.isTemplate = true }
    return Image(nsImage: nsImage)
}

@MainActor
enum FirstLaunchRouting {
    static func route(
        installer: SolstoneInstaller,
        waitForPermissionCheck: @escaping @MainActor () async -> Void,
        permissionsMissing: @escaping @MainActor () -> Bool,
        openInstallerSetup: @escaping @MainActor () -> Void,
        openPermissions: @escaping @MainActor () -> Void,
        findSolBinary: @escaping @Sendable () async -> String? = { await SolBinaryLocator.findSolBinary() },
        healthCheck: @escaping @Sendable (String) async -> Bool = { await SolHealthCheck.run(solPath: $0) }
    ) async {
        let solPresent = await installer.detect()
        if !solPresent {
            openInstallerSetup()
            return
        }

        guard let path = await findSolBinary() else {
            openInstallerSetup()
            return
        }

        let healthy = await healthCheck(path)
        if !healthy {
            openInstallerSetup()
            return
        }

        await waitForPermissionCheck()
        if permissionsMissing() {
            openPermissions()
        }
    }
}

@MainActor
enum InstallerSceneRouting {
    static func install(installer: SolstoneInstaller, journalURL: URL, choice: ExistingInstallChoice) {
        installer.start(journalURL: journalURL, existingInstallChoice: choice)
    }

    static func existing(
        appState: AppState,
        openSettings: () -> Void,
        dismissInstaller: () -> Void,
        activate: () -> Void
    ) {
        appState.pendingSettingsTab = "service"
        openSettings()
        dismissInstaller()
        activate()
    }

    static func dismiss(
        appState: AppState,
        openPermissions: () -> Void,
        dismissInstaller: () -> Void,
        activate: () -> Void
    ) {
        dismissInstaller()
        if !appState.screenRecordingGranted || !appState.microphoneGranted {
            appState.pendingSettingsTab = "permissions"
            openPermissions()
            activate()
        }
    }
}

private struct InstallerSetupSceneContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        InstallerSetupWindow(
            installer: appState.installer,
            onInstall: { url, choice in
                InstallerSceneRouting.install(installer: appState.installer, journalURL: url, choice: choice)
            },
            onExisting: {
                InstallerSceneRouting.existing(
                    appState: appState,
                    openSettings: {
                        openWindow(id: SolstoneSceneID.settings.rawValue)
                        appState.didOpenWindow(.settings)
                    },
                    dismissInstaller: {
                        dismissWindow(id: SolstoneSceneID.installerSetup.rawValue)
                    },
                    activate: {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )
            },
            onDismiss: {
                InstallerSceneRouting.dismiss(
                    appState: appState,
                    openPermissions: {
                        openWindow(id: SolstoneSceneID.settings.rawValue)
                        appState.didOpenWindow(.settings)
                    },
                    dismissInstaller: {
                        dismissWindow(id: SolstoneSceneID.installerSetup.rawValue)
                    },
                    activate: {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )
            }
        )
    }
}

/// Menu bar icon that opens the setup window on first launch
private struct StatusIcon: View {
    let appState: AppState
    let updateController: UpdateController
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
            .overlay(alignment: .bottomTrailing) {
                overlayView
            }
            .task {
                guard !hasCheckedSetup else { return }
                hasCheckedSetup = true
                await FirstLaunchRouting.route(
                    installer: appState.installer,
                    waitForPermissionCheck: waitForInitialPermissionCheck,
                    permissionsMissing: permissionsMissing,
                    openInstallerSetup: openInstallerSetup,
                    openPermissions: openPermissionsSettings
                )
            }
            .onChange(of: appState.installer.main) { _, newState in
                switch newState {
                case .installingSolstone, .runningSolSetup, .registering:
                    updateController.installerDidStart()
                case .done, .failed:
                    updateController.installerDidFinish()
                case .detecting, .awaitingChoice:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .solMacOpenSettings)) { _ in
                openWindow(id: "settings")
                appState.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private func waitForInitialPermissionCheck() async {
        while !appState.initialPermissionCheckComplete {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func permissionsMissing() -> Bool {
        !appState.screenRecordingGranted || !appState.microphoneGranted
    }

    private func openInstallerSetup() {
        openWindow(id: SolstoneSceneID.installerSetup.rawValue)
        appState.didOpenWindow(.installerSetup)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPermissionsSettings() {
        appState.pendingSettingsTab = "permissions"
        openWindow(id: SolstoneSceneID.settings.rawValue)
        appState.didOpenWindow(.settings)
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var overlayView: some View {
        if appState.solChatStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.orange)
                .help(SolChatLiterals.unreachableTooltip)
        } else if appState.solChatPending != nil {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
        } else {
            EmptyView()
        }
    }
}
