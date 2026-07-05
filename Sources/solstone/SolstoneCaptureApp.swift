// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UserNotifications
import os
import JournalMarkKit
import JournalRuntime
import SolstoneCore

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

/// Encodes the open⇒render / closed⇒inert invariant for the settings scene root.
/// Takes the authoritative window-open Bool (`.settings ∈ openSceneIds`), deliberately not ScenePhase.
func shouldRenderSettingsContent(settingsWindowOpen: Bool) -> Bool { settingsWindowOpen }

@MainActor
func routeOpenSettingsWindow(
    appState: AppState,
    openWindow: (String) -> Void,
    activate: () -> Void
) {
    openWindow(SolstoneSceneID.settings.rawValue)
    appState.didOpenWindow(.settings)
    activate()
}

/// Handles app termination to ensure pending remixes complete
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuTrackingObserver: Any?
    private var notificationObservers: [Any] = []
    private var solChatNotificationDelegate: SolChatNotificationDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppTranslocationDetector.isTranslocated() {
            AppTranslocationModal.presentAndQuit()
            return
        }

        JournalMarkFont.register()

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
            state.migrateLoginItemToWatchdogIfNeeded(isTranslocated: false)

            let delegate = SolChatNotificationDelegate()
            solChatNotificationDelegate = delegate
            UNUserNotificationCenter.current().delegate = delegate
            state.startObservingActivation()
            Task { await state.bootstrapNotificationAuthorization() }

            state.reevaluateActivationPolicy(debounced: false)
            Task { await state.startBundledJournalDetectionIfNeeded() }
            state.startTunnelLifecycleOwner()
        } else {
            Logger.general.error("AppState.shared nil in applicationDidFinishLaunching")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Fires when the user clicks the Dock tile (including the macOS 26 "recent
        // apps" tile that shows after the app drops back to .accessory). With no
        // visible windows, the click means "bring the main window back" — open Settings.
        if !flag {
            if let state = AppState.shared {
                if let settingsWindow = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.contains(SolstoneSceneID.settings.rawValue) == true
                }) {
                    state.didOpenWindow(.settings)
                    settingsWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    Logger.general.info("applicationShouldHandleReopen: no settings NSWindow found; posting open settings notification")
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                }
            } else {
                Logger.general.error("AppState.shared nil in applicationShouldHandleReopen")
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = AppState.shared?.appQuitCoordinator else {
            return .terminateNow
        }
        if coordinator.isPrepared { return .terminateNow }
        coordinator.requestExternalTermination { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let state = AppState.shared {
            state.audioDeviceMonitor.stopListening()
            state.installer.cancel()
            state.isTerminating = true
            state.appKitTerminationBegan = true
            Task { await state.heartbeatService.stop() }
            Task { await state.solChatBridge.stop() }
            state.stopTunnelLifecycleOwner()
        } else {
            Logger.general.error("AppState.shared nil in applicationWillTerminate")
        }
        Logger.general.info("Termination: starting shutdown...")
    }
}

@main
struct SolstoneCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState
    @State private var updateController: UpdateController

    init() {
        // Configure unbuffered output for stderr
        Stderr.setUnbuffered()

        let appState = AppState()
        _appState = State(initialValue: appState)
        _updateController = State(initialValue: UpdateController(
            exclusivity: { appState.installer.exclusiveOperationInProgress },
            preInstallFinalizer: { @MainActor in
                await appState.appQuitCoordinator.prepareForUpdaterInstall()
            },
            installFailureRecovery: { @MainActor in
                appState.appQuitCoordinator.resetAfterFailedUpdaterInstall()
                await appState.reestablishSupervisedJournalAfterFailedUpdate()
            },
            terminationBegan: { @MainActor in
                appState.appKitTerminationBegan
            }
        ))
    }

    private var statusAccessibilityLabel: String {
        let baseLabel: String = switch appState.observationRowState {
        case .permissions:
            UICopy.MENUBAR_A11Y_PERMISSIONS_NEEDED
        case .error:
            appState.errorMessage == nil
                ? UICopy.MENUBAR_A11Y_NEEDS_ATTENTION
                : UICopy.MENUBAR_A11Y_ERROR
        case .starting:
            UICopy.MENUBAR_A11Y_STARTING
        case .journalSetupNeeded:
            UICopy.MENUBAR_A11Y_JOURNAL_SETUP_NEEDED
        case .journalRestarting:
            UICopy.MENUBAR_A11Y_JOURNAL_RESTARTING
        case .journalStopped, .journalUnknown:
            UICopy.MENUBAR_A11Y_JOURNAL_NEEDS_ATTENTION
        case .journalStoppedByUser:
            UICopy.MENUBAR_A11Y_JOURNAL_NOT_RUNNING
        case .journalWaiting:
            UICopy.MENUBAR_A11Y_WAITING_FOR_JOURNAL
        case .localOnly:
            UICopy.MENUBAR_A11Y_JOURNAL_SETUP_NEEDED
        case .syncPaused:
            UICopy.MENUBAR_A11Y_OBSERVING_SYNC_PAUSED
        case .offline:
            UICopy.MENUBAR_A11Y_OBSERVING_SAVED_LOCALLY
        case .paused:
            UICopy.MENUBAR_A11Y_PAUSED
        case .observing:
            appState.bundledJournalStatusAvailable
                ? UICopy.MENUBAR_A11Y_OBSERVING_BUNDLED
                : UICopy.MENUBAR_A11Y_OBSERVING_CONNECTED
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

        Window("sol settings", id: "settings") {
            SettingsSceneRoot(appState: appState, updateController: updateController)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("about sol", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct SettingsSceneRoot: View {
    let appState: AppState
    let updateController: UpdateController

    var body: some View {
        if shouldRenderSettingsContent(settingsWindowOpen: appState.openSceneIds.contains(.settings)) {
            SettingsView(appState: appState, updateController: updateController)
        } else {
            Color.clear
        }
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
        config: AppConfig,
        waitForPermissionCheck: @escaping @MainActor () async -> Void,
        permissionsMissing: @escaping @MainActor () -> Bool,
        openPermissions: @escaping @MainActor () -> Void,
        openService: @escaping @MainActor () -> Void,
        journalBinary: @escaping @MainActor () -> URL?,
        healthCheck: @escaping @MainActor (URL) async -> Bool,
        bundledOutdated: @escaping @MainActor (URL) async -> Bool
    ) async {
        await waitForPermissionCheck()
        if permissionsMissing() {
            openPermissions()
            return
        }

        if !config.isUploadConfigured {
            openService()
            return
        }

        guard config.serviceMode != .external else { return }
        guard let binary = journalBinary() else { return }
        if config.serviceMode == .bundled, await bundledOutdated(binary) {
            openService()
            return
        }
        guard BundledJournalEndpoint.isBundledServiceURL(config.serverURL) else { return }
        guard await healthCheck(binary) else {
            openService()
            return
        }
    }
}

/// Menu bar icon that opens setup surfaces on first launch
private struct StatusIcon: View {
    let appState: AppState
    let updateController: UpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var hasCheckedSetup = false

    private var iconState: MenubarIconState {
        appState.observationRowState.iconState
    }

    private var iconName: String {
        iconState.iconName
    }

    var body: some View {
        bundleImage(iconName, isTemplate: true)
            .overlay(alignment: .bottomTrailing) {
                overlayView
            }
            .accessibilityIdentifier(AXID.Menubar.statusIconState)
            .accessibilityValue(iconState.axToken)
            .task {
                guard !hasCheckedSetup else { return }
                hasCheckedSetup = true
                let config = appState.config
                let openPermissions = { @MainActor in
                    openWindow(id: SolstoneSceneID.settings.rawValue)
                    appState.pendingSettingsTab = "permissions"
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                }
                let openService = { @MainActor in
                    openWindow(id: SolstoneSceneID.settings.rawValue)
                    appState.pendingSettingsTab = "journal"
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                }
                await FirstLaunchRouting.route(
                    config: config,
                    waitForPermissionCheck: waitForInitialPermissionCheck,
                    permissionsMissing: permissionsMissing,
                    openPermissions: openPermissions,
                    openService: openService,
                    journalBinary: { appState.journalBinaryProvider() },
                    healthCheck: {
                        await JournalRuntimeProbe.run(journalBinary: $0) == .reachable
                    },
                    bundledOutdated: { binary in
                        guard let installed = await JournalHealthCheck.version(journalBinary: binary) else {
                            return false
                        }
                        return installed.compare(BundleConfig.solstonePinVersion, options: .numeric) == .orderedAscending
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                routeOpenSettingsWindow(
                    appState: appState,
                    openWindow: { openWindow(id: $0) },
                    activate: { NSApp.activate(ignoringOtherApps: true) }
                )
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
