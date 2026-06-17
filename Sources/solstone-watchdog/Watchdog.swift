// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os
import SolstoneCore

@MainActor
final class WatchdogCoordinator {
    private var recentRelaunches: [Date] = []
    private var terminationObserver: NSObjectProtocol?
    private let targetBundleID = SolMacIPCConstants.appBundleIdentifier

    func start() {
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))

        if shouldAdopt(runningBundleIDs: runningBundleIDs, target: targetBundleID) {
            let pid = runningApplications.first { $0.bundleIdentifier == targetBundleID }?.processIdentifier
            if let pid {
                Logger.watchdog.info("adopting running observer (pid \(pid, privacy: .public))")
            } else {
                Logger.watchdog.info("adopting running observer")
            }
        } else {
            Logger.watchdog.info("observer not running; launching")
            launch()
        }

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            let processIdentifier = app.map { Int32($0.processIdentifier) }

            MainActor.assumeIsolated {
                guard let bundleIdentifier, let processIdentifier else {
                    return
                }

                self?.handleTermination(bundleIdentifier: bundleIdentifier, terminatedPID: processIdentifier)
            }
        }
    }

    func launch() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        guard appURL.pathExtension == "app" else {
            Logger.watchdog.error("could not locate observer app bundle from \(Bundle.main.bundleURL.path, privacy: .public)")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            if let error {
                Logger.watchdog.error("observer launch failed: \(error.localizedDescription, privacy: .public)")
                return
            }

            if let app {
                Logger.watchdog.info(
                    "observer launch succeeded (bundle \(app.bundleIdentifier ?? "unknown", privacy: .public), pid \(app.processIdentifier, privacy: .public))"
                )
            } else {
                Logger.watchdog.info("observer launch completed without running application detail")
            }
        }
    }

    func handleTermination(bundleIdentifier: String, terminatedPID: Int32) {
        guard bundleIdentifier == targetBundleID else {
            return
        }

        let now = Date()
        Logger.watchdog.info("observer terminated (pid \(terminatedPID, privacy: .public))")

        pruneRelaunches(now: now)

        let marker = ExpectedExitMarker.readAndConsume()
        let decision = relaunchDecision(
            marker: marker,
            terminatedPID: terminatedPID,
            now: now,
            recentRelaunches: recentRelaunches
        )

        switch decision {
        case .suppress:
            Logger.watchdog.info("expected exit; suppressing relaunch")
        case .throttleStop:
            Logger.watchdog.error(
                "relaunch throttle tripped (>= \(ExpectedExitMarker.defaultThrottleLimit, privacy: .public) within \(ExpectedExitMarker.defaultThrottleWindow, privacy: .public) s); not relaunching"
            )
        case .relaunch:
            recentRelaunches.append(now)
            pruneRelaunches(now: now)
            Logger.watchdog.info("relaunching observer")
            launch()
        }
    }

    private func pruneRelaunches(now: Date) {
        recentRelaunches = recentRelaunches.filter { relaunchDate in
            let age = now.timeIntervalSince(relaunchDate)
            return age >= 0 && age <= ExpectedExitMarker.defaultThrottleWindow
        }
    }
}

@main
struct SolstoneWatchdog {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let coordinator = WatchdogCoordinator()
        coordinator.start()
        withExtendedLifetime(coordinator) {
            app.run()
        }
    }
}
