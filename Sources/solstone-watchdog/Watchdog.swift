// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Foundation
import os
import SolstoneCore

@MainActor
final class WatchdogCoordinator {
    private var recentRelaunches: [Date] = []
    private var pollTimer: Timer?
    private var lastKnownObserverPID: Int32?
    private let targetBundleID = SolMacIPCConstants.appBundleIdentifier

    func start() {
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        let currentObserverPID = runningApplications.first { $0.bundleIdentifier == targetBundleID }?.processIdentifier

        if shouldAdopt(runningBundleIDs: runningBundleIDs, target: targetBundleID) {
            lastKnownObserverPID = currentObserverPID
            if let currentObserverPID {
                Logger.watchdog.info("adopting running observer (pid \(currentObserverPID, privacy: .public))")
            } else {
                Logger.watchdog.info("adopting running observer")
            }
        } else {
            lastKnownObserverPID = nil
            Logger.watchdog.info("observer not running; launching")
            launch()
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollObserverPresence()
            }
        }
    }

    func launch() {
        let start = Bundle.main.executableURL ?? Bundle.main.bundleURL
        guard let appURL = enclosingAppURL(from: start) else {
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

    private func pollObserverPresence() {
        let currentObserverPID = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == targetBundleID }?.processIdentifier
        let transition = observerPresenceTransition(lastKnownPID: lastKnownObserverPID, currentObserverPID: currentObserverPID)

        lastKnownObserverPID = transition.newLastKnownPID

        if let terminatedPID = transition.terminatedPID {
            handleTermination(bundleIdentifier: targetBundleID, terminatedPID: terminatedPID)
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
        let coordinator = WatchdogCoordinator()
        coordinator.start()
        withExtendedLifetime(coordinator) {
            RunLoop.main.run()
        }
    }
}
