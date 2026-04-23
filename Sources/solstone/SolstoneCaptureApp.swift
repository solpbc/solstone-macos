// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

/// Single source of truth for tracked SwiftUI `Window` scenes.
/// Any new `Window` scene added to the app MUST add a case here, and all
/// `openWindow` call sites MUST call `didOpenWindow(_:)` after open.
enum SolstoneSceneID: String, CaseIterable {
    case settings
    case about
}

enum DockMode: String {
    case auto
    case alwaysAccessory = "always-accessory"
    case alwaysRegular = "always-regular"
}

/// Handles app termination to ensure pending remixes complete
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuTrackingObserver: Any?
    private var notificationObservers: [Any] = []
    private var activationPolicyWorkItem: DispatchWorkItem?
    private var quitRequestedViaMenuBar = false
    private(set) var currentPolicy: NSApplication.ActivationPolicy = .accessory
    var openSceneIds: Set<SolstoneSceneID> = []
    var dockMode: DockMode = .auto
    var loginLaunchSuppressionExpires: Date?
    var isTerminating: Bool = false

    private static let dockBehaviorDefaultsKey = "SolstoneDockBehavior"
    private static let loginLaunchSuppressionInterval: TimeInterval = 2.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Suppress Dock activation for the first ~2s of launch so that auto-opening
        // the permissions window from cold-start doesn't flash the Dock icon.
        // This runs on every launch — the window is too short to matter for user-
        // initiated launches, and avoids a brittle login-vs-user-launch heuristic.
        loginLaunchSuppressionExpires = Date().addingTimeInterval(Self.loginLaunchSuppressionInterval)

        dockMode = loadDockModeFromDefaults()

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                nonisolated(unsafe) let observedObject = notification.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self, let window = observedObject as? NSWindow else { return }
                    let identifierForLog = window.identifier?.rawValue ?? "<nil>"
                    let identifierForMatch = window.identifier?.rawValue ?? ""
                    Logger.general.debug("Window will close: identifier=\(identifierForLog, privacy: .public)")
                    self.handleWindowWillClose(identifier: identifierForMatch)
                }
            }
        )

        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let newDockMode = self.loadDockModeFromDefaults()
                    guard newDockMode != self.dockMode else { return }
                    self.dockMode = newDockMode
                    self.reevaluateActivationPolicy(debounced: false)
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

        reevaluateActivationPolicy(debounced: false)
    }

    func didOpenWindow(_ id: SolstoneSceneID) {
        openSceneIds.insert(id)
        reevaluateActivationPolicy(debounced: false)
    }

    func requestMenuBarQuit() {
        quitRequestedViaMenuBar = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitRequestedViaMenuBar {
            return .terminateNow
        }

        for window in NSApp.windows {
            guard window.isVisible, let identifier = window.identifier?.rawValue else { continue }
            if identifier.contains(SolstoneSceneID.settings.rawValue) || identifier.contains(SolstoneSceneID.about.rawValue) {
                window.close()
            }
        }

        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
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

    func handleWindowWillClose(identifier rawID: String) {
        let matchedSceneIDs = SolstoneSceneID.allCases.filter { rawID.contains($0.rawValue) }
        guard !matchedSceneIDs.isEmpty else { return }

        for sceneID in matchedSceneIDs {
            openSceneIds.remove(sceneID)
        }
        reevaluateActivationPolicy(debounced: true)
    }

    func reevaluateActivationPolicy(debounced: Bool) {
        activationPolicyWorkItem?.cancel()
        activationPolicyWorkItem = nil

        if debounced {
            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.reevaluateActivationPolicy(debounced: false)
                }
            }
            activationPolicyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
            return
        }

        let desiredPolicy = computeDesiredPolicy(now: Date())
        applyPolicy(desiredPolicy)
    }

    func computeDesiredPolicy(now: Date = Date()) -> NSApplication.ActivationPolicy {
        if isTerminating {
            return currentPolicy
        }
        if dockMode == .alwaysRegular {
            return .regular
        }
        if dockMode == .alwaysAccessory {
            return .accessory
        }
        if loginLaunchSuppressionExpires.map({ now < $0 }) == true {
            return .accessory
        }
        return openSceneIds.isEmpty ? .accessory : .regular
    }

    func applyPolicy(_ policy: NSApplication.ActivationPolicy) {
        if policy == currentPolicy {
            return
        }

        NSApp.setActivationPolicy(policy)
        currentPolicy = policy

        let name = policy == .regular ? "regular" : "accessory"
        let idsString = self.openSceneIds.map(\.rawValue).sorted().joined(separator: ",")
        Logger.general.info("Activation policy → \(name, privacy: .public) (openScenes=\(self.openSceneIds.count, privacy: .public), ids=[\(idsString, privacy: .public)])")

        if policy == .accessory {
            let hasVisibleTrackedWindow = NSApp.windows.contains { window in
                guard window.isVisible, let identifier = window.identifier?.rawValue else { return false }
                return identifier.contains(SolstoneSceneID.settings.rawValue) || identifier.contains(SolstoneSceneID.about.rawValue)
            }
            if hasVisibleTrackedWindow {
                Logger.general.warning("Activation policy drift: set to accessory but visible solstone window still in NSApp.windows")
            }
        }
    }

    private func loadDockModeFromDefaults() -> DockMode {
        guard let rawValue = UserDefaults.standard.string(forKey: Self.dockBehaviorDefaultsKey) else {
            return .auto
        }
        return DockMode(rawValue: rawValue) ?? .auto
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
                (NSApp.delegate as? AppDelegate)?.didOpenWindow(.settings)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
