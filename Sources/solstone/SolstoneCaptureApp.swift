// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UserNotifications
import os
import JournalMarkKit
import SolstoneCore
import SPLTunnel
import UpdateKit

/// Single source of truth for tracked SwiftUI `Window` scenes.
/// Any new `Window` scene added to the app MUST add a case here, and all
/// `openWindow` call sites MUST call `didOpenWindow(_:)` after open.
public enum SolstoneSceneID: String, CaseIterable {
    case settings
    case about
    case journal
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

@MainActor
private enum UpdateAnnouncementLaunchRegistry {
    private static var controller: UpdateController?

    static func register(_ updateController: UpdateController) {
        controller = updateController
    }

    static func take() -> UpdateController? {
        defer { controller = nil }
        return controller
    }
}

/// Handles app termination to ensure pending remixes complete
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuTrackingObserver: Any?
    private var notificationObservers: [Any] = []
    private var solChatNotificationDelegate: SolChatNotificationDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPlacementRepairCoordinator.shared.signalReadiness()
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

        // When the status menu opens, bring any visible app windows to front.
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let hasVisibleWindow = NSApp.windows.contains { window in
                    window.isVisible && SolstoneSceneID.allCases.contains { sceneID in
                        window.identifier?.rawValue.contains(sceneID.rawValue) == true
                    }
                }
                if hasVisibleWindow {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        if let state = AppState.shared {
            state.migrateLoginItemToWatchdogIfNeeded()
            Task { @MainActor in
                await state.reconcileLoginItemRegistrationAfterUpdateIfNeeded()
            }

            let delegate = SolChatNotificationDelegate()
            solChatNotificationDelegate = delegate
            UNUserNotificationCenter.current().delegate = delegate
            state.startObservingActivation()
            Task { @MainActor in
                await state.bootstrapNotificationAuthorization()
                guard let updateController = UpdateAnnouncementLaunchRegistry.take() else {
                    Logger.setup.error("Update notification launch evaluation skipped: update controller registry was nil")
                    return
                }
                updateController.evaluatePendingUpdateAnnouncement()
            }

            state.reevaluateActivationPolicy(debounced: false)
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
    @State private var startup: SolstoneNormalStartup?

    init() {
        // Configure unbuffered output for stderr
        Stderr.setUnbuffered()
        SPLLogging.configure(subsystem: "app.solstone.observer.spl")

        _startup = State(initialValue: SolstoneStartupPlanner.planStartup(
            decision: AppPlacementGate.evaluate(),
            makeNormal: {
                let appState = AppState()
                let updateAnnouncer = UpdateNotificationAnnouncer()
                let updateController = UpdateController(
                    log: Logger.setup,
                    errorDomain: "app.solstone.observer.updates",
                    exclusivity: { appState.journalHandoffActive },
                    preInstallFinalizer: { @MainActor in
                        await appState.appQuitCoordinator.prepareForUpdaterInstall()
                    },
                    installFailureRecovery: { @MainActor in
                        appState.appQuitCoordinator.resetAfterFailedUpdaterInstall()
                    },
                    terminationBegan: { @MainActor in
                        appState.appKitTerminationBegan
                    },
                    announce: { version in
                        updateAnnouncer.announce(version: version)
                    }
                )
                UpdateAnnouncementLaunchRegistry.register(updateController)
                return SolstoneNormalStartup(
                    appState: appState,
                    updateController: updateController
                )
            }
        ))
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(startup != nil)) {
            if let startup {
                MenuContent(appState: startup.appState, updateController: startup.updateController)
            } else {
                EmptyView()
            }
        } label: {
            if let startup {
                StatusIcon(appState: startup.appState, updateController: startup.updateController)
            } else {
                EmptyView()
            }
        }
        .menuBarExtraStyle(.menu)

        Window("sol settings", id: "settings") {
            if let startup {
                SettingsSceneRoot(appState: startup.appState, updateController: startup.updateController)
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Window("about sol", id: "about") {
            if startup != nil {
                AboutView()
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(UICopy.JOURNAL_WINDOW_TITLE, id: SolstoneSceneID.journal.rawValue) {
            if let startup {
                JournalWindowSceneRoot(appState: startup.appState)
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}

private struct SolstoneNormalStartup {
    let appState: AppState
    let updateController: UpdateController
}

internal func statusAccessibilityLabel(
    presentation: MenubarPresentation,
    errorMessage: String?,
    solChatStale: Bool,
    solChatPending: SolChatRequestSummary?
) -> String {
    let baseLabel: String = switch presentation.observation {
    case .permissions:
        UICopy.MENUBAR_A11Y_PERMISSIONS_NEEDED
    case .error:
        errorMessage == nil
            ? UICopy.MENUBAR_A11Y_NEEDS_ATTENTION
            : UICopy.MENUBAR_A11Y_ERROR
    case .starting:
        UICopy.MENUBAR_A11Y_STARTING
    case .journalMigrationNeeded:
        "sol · journal link needs attention"
    case .connectionWaiting:
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
        UICopy.MENUBAR_A11Y_OBSERVING_CONNECTED
    }

    var components = [baseLabel]
    if let attention = attentionToSurface(presentation.attention, alreadySaidBy: presentation.observation) {
        components.append(attentionSuffix(attention))
    }
    if solChatStale {
        components.append(SolChatLiterals.unreachableTooltip)
    } else if let pending = solChatPending {
        components.append("sol noticed: \(pending.summary)")
    }
    return components.joined(separator: " · ")
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

internal struct MenubarIconGlyphView: View {
    let icon: MenubarIconState
    let overlay: MenubarIconOverlayState

    var body: some View {
        let overlayPresentation = overlay.presentation

        bundleImage(icon.iconName, isTemplate: true)
            .overlay(alignment: .bottomTrailing) {
                overlayBadge(overlayPresentation.badgeTreatment)
                    .accessibilityIdentifier(AXID.Menubar.statusIconOverlayState)
                    .accessibilityValue(overlayPresentation.axToken)
            }
            .accessibilityIdentifier(AXID.Menubar.statusIconState)
            .accessibilityValue(icon.axToken)
    }

    @ViewBuilder
    private func overlayBadge(_ treatment: MenubarBadgeTreatment?) -> some View {
        if let treatment {
            MenubarBadgeView(treatment: treatment)
        }
    }
}

private struct MenubarBadgeView: View {
    let treatment: MenubarBadgeTreatment

    var body: some View {
        ZStack {
            Circle()
                .fill(color(for: treatment.haloTint))
                .frame(width: treatment.haloDiameter, height: treatment.haloDiameter)
            markView
        }
    }

    @ViewBuilder
    private var markView: some View {
        switch treatment.mark {
        case let .symbol(name, pointSize, tint):
            Image(systemName: name)
                .font(.system(size: pointSize))
                .foregroundStyle(color(for: tint))
        case let .dot(diameter, tint):
            Circle()
                .fill(color(for: tint))
                .frame(width: diameter, height: diameter)
        }
    }

    private func color(for tint: MenubarBadgeTreatment.Tint) -> Color {
        switch tint {
        case .adaptiveInk:
            return .primary
        case .solOrange:
            return SolstoneColors.solOrange
        case .accentColor:
            return .accentColor
        }
    }
}

@MainActor
enum FirstLaunchRouting {
    static func route(
        config: AppConfig,
        waitForPermissionCheck: @escaping @MainActor () async -> Void,
        permissionsMissing: @escaping @MainActor () -> Bool,
        openPermissions: @escaping @MainActor () -> Void,
        openService: @escaping @MainActor () -> Void
    ) async {
        await waitForPermissionCheck()
        if permissionsMissing() {
            openPermissions()
            return
        }

        if !config.isUploadConfigured || config.serviceMode == .bundled {
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

    private var presentation: MenubarPresentation {
        appState.menubarPresentation(durableUpdateStatus: updateController.durableUpdateStatus)
    }

    var body: some View {
        iconContent
            .accessibilityLabel(statusAccessibilityLabel(
                presentation: presentation,
                errorMessage: appState.errorMessage,
                solChatStale: appState.solChatStale,
                solChatPending: appState.solChatPending
            ))
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
                    openService: openService
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                routeOpenSettingsWindow(
                    appState: appState,
                    openWindow: { openWindow(id: $0) },
                    activate: { NSApp.activate(ignoringOtherApps: true) }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .openJournalWindow)) { _ in
                routeOpenJournalWindow(
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
    private var iconContent: some View {
        let content = MenubarIconGlyphView(icon: presentation.icon, overlay: presentation.overlayState)
        if appState.solChatStale {
            content.help(SolChatLiterals.unreachableTooltip)
        } else {
            content
        }
    }
}
