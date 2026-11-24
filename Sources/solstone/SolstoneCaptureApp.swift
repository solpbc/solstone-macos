// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
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

    /// Matches SwiftUI `Window` (`"<id>"`) and `WindowGroup` (`"<id>-AppWindow-<n>"`) identifiers
    /// without false-matching unrelated panels or sheets whose identifier merely contains the word.
    public static func matching(windowIdentifier: String?) -> SolstoneSceneID? {
        guard let rawID = windowIdentifier, !rawID.isEmpty else { return nil }
        return allCases.first { sceneID in
            rawID == sceneID.rawValue || rawID.hasPrefix("\(sceneID.rawValue)-AppWindow-")
        }
    }

    public func matches(windowIdentifier: String?) -> Bool {
        Self.matching(windowIdentifier: windowIdentifier) == self
    }
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
func orderSolstoneSettingsWindowFront() {
    if let settingsWindow = NSApp?.windows.first(where: {
        $0.sheetParent == nil && SolstoneSceneID.settings.matches(windowIdentifier: $0.identifier?.rawValue)
    }) {
        AppState.shared?.ensureWindowTrackedOpen(.settings)
        if settingsWindow.isMiniaturized {
            settingsWindow.deminiaturize(nil)
        }
        settingsWindow.makeKeyAndOrderFront(nil)
    }
    NSApp?.activate(ignoringOtherApps: true)
}

@MainActor
enum UpdateAnnouncementLaunchRegistry {
    private static var controller: UpdateController?

    static func register(_ updateController: UpdateController) {
        controller = updateController
    }

    static func take() -> UpdateController? {
        defer { controller = nil }
        return controller
    }
}

@MainActor
struct AppKitTerminationSeam {
    private let coordinatorLookup: @MainActor () -> AppQuitCoordinator?
    private let reply: @MainActor (Bool) -> Void

    init(
        coordinatorLookup: @escaping @MainActor () -> AppQuitCoordinator? = {
            AppState.shared?.appQuitCoordinator
        },
        reply: @escaping @MainActor (Bool) -> Void = {
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
    ) {
        self.coordinatorLookup = coordinatorLookup
        self.reply = reply
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard let coordinator = coordinatorLookup() else {
            return .terminateNow
        }
        coordinator.requestAppKitTermination(reply: reply)
        return .terminateLater
    }
}

/// Handles app termination to ensure pending remixes complete
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpenedURLs: [URL] = []
    private var menuTrackingObserver: Any?
    private var notificationObservers: [Any] = []
    private var userNotificationDelegate: UserNotificationCenterDelegate?
    private var appKitTerminationSeam = AppKitTerminationSeam()

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let state = AppState.shared else {
            pendingOpenedURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            state.handleIngressURL(url)
        }
    }

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
                    guard window.sheetParent == nil else { return }
                    let identifierForLog = window.identifier?.rawValue ?? "<nil>"
                    let identifier = window.identifier?.rawValue
                    Logger.general.debug("Window will close: identifier=\(identifierForLog, privacy: .public)")
                    if let state = AppState.shared {
                        let remainingOpenIdentifiers: [String] = NSApp.windows.compactMap { other in
                            guard other !== window,
                                  other.sheetParent == nil,
                                  other.isVisible || other.isMiniaturized
                            else { return nil }
                            return other.identifier?.rawValue
                        }
                        state.beginWindowClose(
                            windowToken: ObjectIdentifier(window),
                            identifier: identifier,
                            remainingOpenIdentifiers: remainingOpenIdentifiers
                        )
                    } else {
                        Logger.general.error("AppState.shared nil in willCloseNotification")
                    }
                }
            }
        )

        for resignName in [NSWindow.didResignMainNotification, NSWindow.didResignKeyNotification] {
            notificationObservers.append(
                NotificationCenter.default.addObserver(
                    forName: resignName,
                    object: nil,
                    queue: .main
                ) { notification in
                    nonisolated(unsafe) let observedObject = notification.object as AnyObject?
                    MainActor.assumeIsolated {
                        guard let window = observedObject as? NSWindow,
                              window.sheetParent == nil,
                              SolstoneSceneID.journal.matches(windowIdentifier: window.identifier?.rawValue) else { return }
                        AppState.shared?.importSource?.reconcile()
                    }
                }
            )
        }

        // When the status menu opens, bring any visible app windows to front.
        menuTrackingObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let hasVisibleWindow = NSApp.windows.contains { window in
                    window.isVisible &&
                        window.sheetParent == nil &&
                        SolstoneSceneID.matching(windowIdentifier: window.identifier?.rawValue) != nil
                }
                if hasVisibleWindow {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }

        if let state = AppState.shared {
            for url in pendingOpenedURLs {
                state.handleIngressURL(url)
            }
            pendingOpenedURLs.removeAll()

            state.migrateLoginItemToWatchdogIfNeeded()
            Task { @MainActor in
                await state.reconcileLoginItemRegistrationAfterUpdateIfNeeded()
            }

            let delegate = UserNotificationCenterDelegate()
            userNotificationDelegate = delegate
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
            state.ingestStep5IfNeeded()
#if DEBUG
            guard IngestV3LiveProbe.startTunnelLifecycleIfPermitted(
                appState: state,
                startTunnelLifecycle: { state.startTunnelLifecycleOwner() }
            ) else {
                NSApp.terminate(nil)
                return
            }
            IngestV3LiveProbe.startIfRequested(appState: state)
#else
            state.startTunnelLifecycleOwner()
#endif
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
                    $0.sheetParent == nil && SolstoneSceneID.settings.matches(windowIdentifier: $0.identifier?.rawValue)
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
        appKitTerminationSeam.applicationShouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let state = AppState.shared {
            state.audioDeviceMonitor.stopListening()
#if SOLSTONE_BROWSER_INTAKE_PREVIEW
            state.stopBrowserIntake()
            SafariExtensionBridge.shared.stop()
#endif
            state.isTerminating = true
            state.stopTunnelLifecycleOwner()
        } else {
            Logger.general.error("AppState.shared nil in applicationWillTerminate")
        }
        Logger.general.info("Termination: starting shutdown...")
    }
}

struct SolstoneCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var startup: SolstoneNormalStartup?

    init() {
        // Configure unbuffered output for stderr
        Stderr.setUnbuffered()
        SPLLogging.configure(subsystem: SolstoneLogSubsystem.observerSPL)

#if DEBUG
        let liveProbeLaunch = IngestV3LiveProbe.configure()
        let automaticObservationPipelineEnabled = !liveProbeLaunch.suppressesNormalPipeline
#else
        let automaticObservationPipelineEnabled = true
#endif

        _startup = State(initialValue: SolstoneStartupComposition.makeNormalStartup(
            decision: AppPlacementGate.evaluate(),
            automaticObservationPipelineEnabled: automaticObservationPipelineEnabled,
            makeStartup: { appState, updateController in
                SolstoneNormalStartup(appState: appState, updateController: updateController)
            }
        ))
    }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(startup != nil)) {
            if let startup {
                ShellMenuContent(appState: startup.appState, updateController: startup.updateController)
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

        Window(MacStrings.macos_about_solstone(), id: "settings") {
            if let startup {
                SettingsSceneRoot(appState: startup.appState, updateController: startup.updateController)
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(MacStrings.macos_solstonecaptureapp_settings()) {
                    if let appState = AppState.shared {
                        openSolstoneWindow(appState: appState, route: "observer")
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window(MacStrings.macos_desktop_shared_app_aboutsolstone(), id: "about") {
            if let startup {
                AboutView(
                    aboutBlock: { AboutPresentation.windowBlock(journal: startup.appState.tunnelLifecycleOwner.journalVersion) },
                    clipboardWrite: { text in
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        return pasteboard.setString(text, forType: .string)
                    }
                )
                .background(SceneWindowPresenceTracker(sceneID: .about, appState: startup.appState))
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [])

        Window(UICopy.JOURNAL_WINDOW_TITLE, id: SolstoneSceneID.journal.rawValue) {
            if let startup {
                JournalWindowSceneRoot(appState: startup.appState)
            } else {
                Color.clear
            }
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .handlesExternalEvents(matching: [])
    }

    static func permissionsMissing(permittedSourcesEmpty: Bool, startDeferredForProtectedVideo: Bool) -> Bool {
        capturePermissionsMissing(
            permittedSourcesEmpty: permittedSourcesEmpty,
            startDeferredForProtectedVideo: startDeferredForProtectedVideo
        )
    }
}

private struct SolstoneNormalStartup {
    let appState: AppState
    let updateController: UpdateController
}

internal func statusAccessibilityLabel(
    presentation: MenubarPresentation,
    errorMessage: String?,
    sourceStatus: String? = nil,
    siteNotes: [SiteIntakeNote] = [],
    journalVerdict: JournalConnectionVerdict? = nil,
    siteKeptOutLabel: String? = nil
) -> String {
    let baseLabel: String = switch presentation.observation {
    case .stopped:
        UICopy.SOURCES_OFF
    case .permissions:
        UICopy.MENUBAR_A11Y_PERMISSIONS_NEEDED
    case .error:
        errorMessage == nil
            ? UICopy.MENUBAR_A11Y_NEEDS_ATTENTION
            : UICopy.MENUBAR_A11Y_ERROR
    case .starting:
        UICopy.MENUBAR_A11Y_STARTING
    case .journalMigrationNeeded:
        MacStrings.macos_app_solstonejournallinkneedsattention()
    case .connectionWaiting:
        UICopy.MENUBAR_A11Y_WAITING_FOR_JOURNAL
    case .localOnly:
        UICopy.MENUBAR_A11Y_JOURNAL_SETUP_NEEDED
    case .syncPaused:
        UICopy.MENUBAR_A11Y_OBSERVING_SYNC_PAUSED
    case .offline:
        UICopy.MENUBAR_A11Y_OBSERVING_SAVED_LOCALLY
    case .paused, .protectedVideo:
        UICopy.MENUBAR_A11Y_PAUSED
    case .observing:
        UICopy.MENUBAR_A11Y_OBSERVING_CONNECTED
    case .awaitingMarkConfirmation:
        UICopy.MENUBAR_A11Y_AWAITING_MARK_CONFIRMATION
    }

    var components = [baseLabel]
    if let sourceStatus = accessibilitySourceStatus(sourceStatus, for: presentation.observation) {
        components.append(sourceStatus)
    }
    for note in siteNotes {
        switch note {
        case .safariKeptOut: components.append(siteKeptOutLabel ?? UICopy.MENUBAR_A11Y_SAFARI_KEPT_OUT)
        case .screenHeld: components.append(UICopy.MENUBAR_SITE_SCREEN_HELD)
        }
    }
    if let attention = attentionToSurface(
        presentation.attention,
        alreadySaidBy: presentation.observation,
        journalFailureCause: journalVerdict?.failureCause
    ) {
        components.append(attentionSuffix(attention, verdict: journalVerdict))
    }
    return components.joined(separator: " · ")
}

/// Drops state words that `baseLabel` already speaks so VoiceOver reads
/// "solstone · paused · microphone" instead of "solstone · paused · paused · microphone".
private func accessibilitySourceStatus(
    _ sourceStatus: String?,
    for observation: MenubarStatusRowState
) -> String? {
    guard let sourceStatus else { return nil }
    let mediaSources: [CaptureSources] = [.microphone, .screen, [.microphone, .screen]]
    switch observation {
    case .paused, .protectedVideo:
        for sources in mediaSources where sourceStatus == UICopy.sourceStatus(sources, isPaused: true) {
            return UICopy.sourceNames(sources)
        }
        if sourceStatus == MacStrings.macos_desktopactivitysource_activityispaused() {
            return MacStrings.macos_settings_activity()
        }
        if sourceStatus == MacStrings.macos_ui_terminalpaused() {
            return UICopy.Terminal.sourceTitle
        }
        return sourceStatus
    case .observing, .offline, .syncPaused:
        for sources in mediaSources where sourceStatus == UICopy.sourceStatus(sources, isPaused: false) {
            return UICopy.sourceNames(sources)
        }
        if sourceStatus == MacStrings.macos_desktopactivitysource_activityison() {
            return MacStrings.macos_settings_activity()
        }
        return sourceStatus
    case .starting:
        return sourceStatus == UICopy.SOURCES_STARTING ? nil : sourceStatus
    case .stopped:
        // "off" already says no source is on.
        return [UICopy.SOURCES_NONE, UICopy.SOURCES_OFF].contains(sourceStatus) ? nil : sourceStatus
    default:
        return sourceStatus
    }
}

private struct SettingsSceneRoot: View {
    let appState: AppState
    let updateController: UpdateController

    var body: some View {
        Group {
            if shouldRenderSettingsContent(settingsWindowOpen: appState.openSceneIds.contains(.settings)) {
                SettingsView(appState: appState, updateController: updateController)
            } else {
                Color.clear
            }
        }
        .background(SceneWindowPresenceTracker(sceneID: .settings, appState: appState))
    }
}

/// Keeps `AppState.openSceneIds` in sync whenever AppKit or SwiftUI displays a tracked scene
/// window without routing through `didOpenWindow(_:)` (for example Window menu, state restoration,
/// or external window-ordering calls). Mounted outside the open-content gate so closed off-screen
/// windows stay inert while still noticing the moment they become visible again.
struct SceneWindowPresenceTracker: NSViewRepresentable {
    let sceneID: SolstoneSceneID
    let appState: AppState

    func makeNSView(context: Context) -> SceneWindowPresenceView {
        let view = SceneWindowPresenceView()
        view.onWindowVisible = { [weak appState] in
            appState?.ensureWindowTrackedOpen(sceneID)
        }
        return view
    }

    func updateNSView(_ nsView: SceneWindowPresenceView, context: Context) {
        nsView.onWindowVisible = { [weak appState] in
            appState?.ensureWindowTrackedOpen(sceneID)
        }
    }

    static func dismantleNSView(_ nsView: SceneWindowPresenceView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class SceneWindowPresenceView: NSView {
    var onWindowVisible: (@MainActor () -> Void)?
    private var isClosing = false
    private var visibilityObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            detachObservers()
            isClosing = false
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detachObservers()
        isClosing = false
        guard let window else { return }

        visibilityObservation = window.observe(\.isVisible, options: [.old, .new]) { [weak self] _, change in
            let wasVisible = change.oldValue ?? false
            let isVisible = change.newValue ?? false
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleVisibilityChange(wasVisible: wasVisible, isVisible: isVisible)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleVisibilityChange(wasVisible: wasVisible, isVisible: isVisible)
                }
            }
        }

        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleWillClose()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.handleWillClose()
                    }
                }
            }
        )

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated {
                            self?.handleWindowActivated()
                        }
                    } else {
                        Task { @MainActor [weak self] in
                            self?.handleWindowActivated()
                        }
                    }
                }
            )
        }

        notificationTokens.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleOcclusionChange()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.handleOcclusionChange()
                    }
                }
            }
        )

        if window.isVisible {
            scheduleVisibilitySync()
        }
    }

    func stopObserving() {
        detachObservers()
        isClosing = false
        onWindowVisible = nil
    }

    private func detachObservers() {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func handleWillClose() {
        isClosing = true
    }

    private func handleVisibilityChange(wasVisible: Bool, isVisible: Bool) {
        if !isVisible {
            isClosing = false
            return
        }
        if !wasVisible {
            isClosing = false
        }
        if !isClosing {
            scheduleVisibilitySync()
        }
    }

    private func handleWindowActivated() {
        guard let window, window.isVisible else { return }
        isClosing = false
        scheduleVisibilitySync()
    }

    private func handleOcclusionChange() {
        guard !isClosing, let window, window.isVisible, window.occlusionState.contains(.visible) else { return }
        scheduleVisibilitySync()
    }

    private func scheduleVisibilitySync() {
        Task { @MainActor [weak self] in
            self?.notifyIfVisible()
        }
    }

    private func notifyIfVisible() {
        guard !isClosing, let window, window.isVisible else { return }
        onWindowVisible?()
    }
}

/// Single access point for the solstone target's resource bundle; tests reach it via `@testable import`.
enum SolstoneResources {
    static var bundle: Bundle { .module }
}

/// Loads an image from the SPM resource bundle (not an asset catalog).
/// `Image(_:bundle:)` only searches asset catalogs; this uses an explicit
/// path lookup against the bundle's `Resources/` subdirectory because
/// SwiftPM `.copy("Resources")` nests the directory inside the bundle as
/// `Contents/Resources/Resources/<file>`, and `Bundle.image(forResource:)`
/// does not recurse into subdirectories. The `inDirectory: "Resources"`
/// parameter makes the lookup work against the nested layout.
func bundleImage(_ name: String, isTemplate: Bool = false) -> Image {
    let nsImage = SolstoneResourceImage.mustLoad(
        named: name,
        in: SolstoneResources.bundle,
        isTemplate: isTemplate
    )
    return Image(nsImage: nsImage)
}

internal struct MenubarIconGlyphView: View {
    let icon: MenubarIconState
    let overlay: MenubarIconOverlayState

    var body: some View {
        let overlayPresentation = overlay.presentation

        // A menu-style MenuBarExtra keeps only the label's image and drops any overlay drawn on
        // it, so the badge is drawn into the one image the menu bar shows.
        Image(nsImage: menubarIconImage(icon: icon, badge: overlayPresentation.badgeTreatment))
            .overlay(alignment: .bottomTrailing) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier(AXID.Menubar.statusIconOverlayState)
                    .accessibilityValue(overlayPresentation.axToken)
            }
            .accessibilityIdentifier(AXID.Menubar.statusIconState)
            .accessibilityValue(icon.axToken)
    }
}

/// The menu bar icon as one image. With no badge it is the template glyph, which the menu bar
/// tints itself. With a badge, the glyph and the badge's halo take the menu bar's own ink at draw
/// time, so they follow its appearance, and the mark keeps its colour.
@MainActor
internal func menubarIconImage(icon: MenubarIconState, badge: MenubarBadgeTreatment?) -> NSImage {
    let glyph = SolstoneResourceImage.mustLoad(named: icon.iconName, in: SolstoneResources.bundle, isTemplate: true)
    guard let badge else { return glyph }
    let image = NSImage(size: glyph.size, flipped: false) { rect in
        let ink = NSColor.labelColor
        if let tinted = tintedCopy(of: glyph, color: ink) {
            tinted.draw(in: rect)
        }
        let halo = NSRect(
            x: rect.maxX - badge.haloDiameter,
            y: rect.minY,
            width: badge.haloDiameter,
            height: badge.haloDiameter
        )
        menubarBadgeColor(badge.haloTint, ink: ink).setFill()
        NSBezierPath(ovalIn: halo).fill()
        switch badge.mark {
        case let .symbol(name, pointSize, tint):
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [menubarBadgeColor(tint, ink: ink)]))
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = symbol.size
                symbol.draw(in: NSRect(
                    x: halo.midX - size.width / 2,
                    y: halo.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ))
            }
        case let .dot(diameter, tint):
            menubarBadgeColor(tint, ink: ink).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: halo.midX - diameter / 2,
                y: halo.midY - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

private func tintedCopy(of template: NSImage, color: NSColor) -> NSImage? {
    let copy = NSImage(size: template.size, flipped: false) { rect in
        template.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return copy
}

private func menubarBadgeColor(_ tint: MenubarBadgeTreatment.Tint, ink: NSColor) -> NSColor {
    switch tint {
    case .adaptiveInk:
        return ink
    case .solOrange:
        let c = SolstoneColors.solOrangeComponents
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    case .accentColor:
        return .controlAccentColor
    }
}

internal func capturePermissionsMissing(permittedSourcesEmpty: Bool, startDeferredForProtectedVideo: Bool) -> Bool {
    permittedSourcesEmpty && !startDeferredForProtectedVideo
}

public enum LaunchSettingsRoute: Equatable, Sendable {
    case setup
    case established
}

public func launchSettingsRoute(setupPhase: SetupPhase?) -> LaunchSettingsRoute {
    if setupPhase != nil {
        return .setup
    }
    return .established
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
                sourceStatus: appState.captureSourcesStatusText,
                siteNotes: appState.siteIntakeNotes,
                journalVerdict: appState.tunnelLifecycleOwner.connectionVerdict,
                siteKeptOutLabel: appState.siteKeptOutAccessibilityLabel
            ))
            .task {
                guard !hasCheckedSetup else { return }
                hasCheckedSetup = true
                let route = launchSettingsRoute(setupPhase: appState.setupModel.phase)
                switch route {
                case .setup:
                    openWindow(id: SolstoneSceneID.settings.rawValue)
                    appState.didOpenWindow(.settings)
                    NSApp.activate(ignoringOtherApps: true)
                case .established:
                    let config = appState.config
                    let openPermissions = { @MainActor in
                        openWindow(id: SolstoneSceneID.settings.rawValue)
                        appState.pendingSettingsTab = "home"
                        appState.didOpenWindow(.settings)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    let openService = { @MainActor in
                        openWindow(id: SolstoneSceneID.settings.rawValue)
                        appState.pendingSettingsTab = "home"
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
                routeOpenSettingsWindow(
                    appState: appState,
                    openWindow: { openWindow(id: $0) },
                    activate: { NSApp.activate(ignoringOtherApps: true) }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .openAboutWindow)) { _ in
                openWindow(id: SolstoneSceneID.about.rawValue)
                appState.didOpenWindow(.about)
                NSApp.activate(ignoringOtherApps: true)
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
        capturePermissionsMissing(
            permittedSourcesEmpty: appState.capture.permittedSources.isEmpty,
            startDeferredForProtectedVideo: appState.capture.isStartDeferredForProtectedVideo
        )
    }

    @ViewBuilder
    private var iconContent: some View {
        MenubarIconGlyphView(icon: presentation.icon, overlay: presentation.overlayState)
    }
}
