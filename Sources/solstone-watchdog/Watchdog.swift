// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppKit
import Darwin
import Foundation
import os
import SolstoneCore

@MainActor
enum WatchdogStartResult: Equatable {
    case polling
    case terminated
}

@MainActor
final class WatchdogCoordinator {
    @MainActor
    struct Dependencies {
        var writerExecutableURL: () -> URL
        var cachesURL: () -> URL
        var temporaryDirectoryURL: () -> URL
        var volumeIsLocal: (URL) -> Bool?
        var runningCandidates: () -> [WatchdogRunningCandidate]
        var openApplication: (URL, @escaping @Sendable (NSRunningApplication?, Error?) -> Void) -> Void
        var writeStateRecord: (WatchdogStateRecord) throws -> Void
        var logBootstrapFault: (String) -> Void
        var terminator: (Int32) -> Void
        var schedulePollTimer: (@escaping @MainActor @Sendable () -> Void) -> Timer

        static let live = Dependencies(
            writerExecutableURL: { Bundle.main.executableURL ?? Bundle.main.bundleURL },
            cachesURL: { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] },
            temporaryDirectoryURL: { FileManager.default.temporaryDirectory },
            volumeIsLocal: { url in
                try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
            },
            runningCandidates: {
                NSWorkspace.shared.runningApplications.map { application in
                    WatchdogCoordinator.candidate(from: application)
                }
            },
            openApplication: { url, completion in
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: completion)
            },
            writeStateRecord: { try WatchdogStateRecordStore.write($0) },
            logBootstrapFault: { message in
                Logger.watchdogBootstrap.fault("\(message, privacy: .public)")
            },
            terminator: { status in exit(status) },
            schedulePollTimer: { callback in
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                    Task { @MainActor in callback() }
                }
            }
        )
    }

    private enum AdoptionOrigin {
        case startup
        case poll
        case launchCompletion
    }

    private let dependencies: Dependencies
    private var recentRelaunches: [Date] = []
    private var pollTimer: Timer?
    private var lastKnownObserverPID: Int32?
    private var identity: WatchdogIdentity?
    private var productLogger: Logger?
    private var isLaunchInFlight = false
    private var lastConflictFingerprint: String?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func start() -> WatchdogStartResult {
        let resolution = WatchdogIdentityResolver.resolve(
            writerExecutableURL: dependencies.writerExecutableURL(),
            cachesURL: dependencies.cachesURL(),
            temporaryDirectoryURL: dependencies.temporaryDirectoryURL(),
            volumeIsLocal: dependencies.volumeIsLocal
        )

        switch resolution {
        case .resolved(let identity):
            self.identity = identity
            productLogger = Logger.watchdog(for: identity.product)
        case .permanentRefusal(let refusal):
            refuse(refusal, status: 0)
            return .terminated
        case .transientRefusal(let refusal):
            refuse(refusal, status: 1)
            return .terminated
        }

        evaluateCandidates(dependencies.runningCandidates(), origin: .startup)
        pollTimer = dependencies.schedulePollTimer { [weak self] in
            self?.pollObserverPresence()
        }
        return .polling
    }

    func launch() {
        guard let identity, !isLaunchInFlight else { return }
        isLaunchInFlight = true
        activeLogger.info("observer not running; launching")
        dependencies.openApplication(identity.enclosingBundleURL) { [weak self] app, error in
            MainActor.assumeIsolated {
                self?.handleLaunchCompletion(app: app, error: error)
            }
        }
    }

    func handleTermination(bundleIdentifier: String, terminatedPID: Int32) {
        guard bundleIdentifier == identity?.product.targetBundleID else {
            return
        }

        let now = Date()
        activeLogger.info("observer terminated (pid \(terminatedPID, privacy: .public))")

        pruneRelaunches(now: now)

        guard let identity else { return }
        let marker = ExpectedExitMarker.readAndConsume(at: ExpectedExitMarker.markerURL(for: identity.product.markerDiscriminator))
        let decision = relaunchDecision(
            marker: marker,
            terminatedPID: terminatedPID,
            now: now,
            recentRelaunches: recentRelaunches
        )

        switch decision {
        case .suppress:
            activeLogger.info("expected exit; suppressing relaunch")
        case .throttleStop:
            activeLogger.error(
                "relaunch throttle tripped (>= \(ExpectedExitMarker.defaultThrottleLimit, privacy: .public) within \(ExpectedExitMarker.defaultThrottleWindow, privacy: .public) s); not relaunching"
            )
        case .relaunch:
            recentRelaunches.append(now)
            pruneRelaunches(now: now)
            activeLogger.info("relaunching observer")
            launch()
        }
    }

    private var activeLogger: Logger {
        productLogger ?? .watchdogBootstrap
    }

    private func refuse(_ refusal: WatchdogRefusal, status: Int32) {
        let record = WatchdogStateRecord(refusal: refusal)
        do {
            try dependencies.writeStateRecord(record)
        } catch {
            dependencies.logBootstrapFault(
                "watchdog refusal record write failed cause=\(refusal.cause.rawValue) writer=\(refusal.writerExecutableURL.path) app=\(refusal.enclosingBundleURL?.path ?? "none") error=\(error.localizedDescription)"
            )
        }
        Logger.watchdogBootstrap.error(
            "watchdog refusal cause=\(refusal.cause.rawValue, privacy: .public) writer=\(refusal.writerExecutableURL.path, privacy: .public) app=\(refusal.enclosingBundleURL?.path ?? "none", privacy: .public)"
        )
        dependencies.terminator(status)
    }

    private func pollObserverPresence() {
        evaluateCandidates(dependencies.runningCandidates(), origin: .poll)
    }

    private func handleLaunchCompletion(app: NSRunningApplication?, error: Error?) {
        isLaunchInFlight = false
        if let error {
            activeLogger.error("observer launch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        evaluateCandidates(app.map { [Self.candidate(from: $0)] } ?? [], origin: .launchCompletion)
    }

    private func evaluateCandidates(_ candidates: [WatchdogRunningCandidate], origin: AdoptionOrigin) {
        guard let identity else { return }
        let decision = watchdogAdoptionDecision(
            product: identity.product,
            ownerBundleURL: identity.enclosingBundleURL,
            candidates: candidates
        )

        switch decision {
        case .adopt(let pid):
            lastConflictFingerprint = nil
            let transition = observerPresenceTransition(lastKnownPID: lastKnownObserverPID, currentObserverPID: pid)
            lastKnownObserverPID = transition.newLastKnownPID
            if let terminatedPID = transition.terminatedPID {
                handleTermination(bundleIdentifier: identity.product.targetBundleID, terminatedPID: terminatedPID)
            } else if origin != .poll {
                activeLogger.info("adopting running observer (pid \(pid, privacy: .public))")
            }
        case .conflictingCopy(let bundleURL, let shortVersion, let buildVersion):
            lastKnownObserverPID = nil
            noteConflict(
                bundleURL: bundleURL,
                shortVersion: shortVersion,
                buildVersion: buildVersion,
                identity: identity
            )
        case .noCandidate:
            lastConflictFingerprint = nil
            if let terminatedPID = lastKnownObserverPID {
                lastKnownObserverPID = nil
                handleTermination(bundleIdentifier: identity.product.targetBundleID, terminatedPID: terminatedPID)
            } else if origin != .launchCompletion {
                launch()
            }
        }
    }

    nonisolated private static func candidate(from application: NSRunningApplication) -> WatchdogRunningCandidate {
        let info = application.bundleURL.flatMap { try? WatchdogBundleInfoReader.read(fromEnclosingBundleAt: $0) }
        return WatchdogRunningCandidate(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            shortVersion: info?.shortVersion,
            buildVersion: info?.buildVersion
        )
    }

    private func noteConflict(
        bundleURL: URL?,
        shortVersion: String?,
        buildVersion: String?,
        identity: WatchdogIdentity
    ) {
        let fingerprint = "\(bundleURL?.absoluteString ?? "none")|\(shortVersion ?? "none")|\(buildVersion ?? "none")"
        guard fingerprint != lastConflictFingerprint else { return }
        lastConflictFingerprint = fingerprint
        let record = WatchdogStateRecord(
            cause: .conflictingCopy,
            enclosingBundleURL: identity.enclosingBundleURL,
            enclosingBundleIdentifier: identity.enclosingBundleIdentifier,
            writerExecutableURL: identity.writerExecutableURL,
            conflictingBundleURL: bundleURL,
            conflictingBundleShortVersion: shortVersion,
            conflictingBundleBuild: buildVersion
        )
        do {
            try dependencies.writeStateRecord(record)
        } catch {
            dependencies.logBootstrapFault(
                "watchdog conflict record write failed cause=\(WatchdogStateCause.conflictingCopy.rawValue) writer=\(identity.writerExecutableURL.path) conflict=\(bundleURL?.path ?? "none") error=\(error.localizedDescription)"
            )
        }
        activeLogger.fault(
            "conflicting watchdog copy observed bundle=\(bundleURL?.path ?? "none", privacy: .public) short_version=\(shortVersion ?? "none", privacy: .public) build=\(buildVersion ?? "none", privacy: .public)"
        )
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
        guard coordinator.start() == .polling else { return }
        withExtendedLifetime(coordinator) {
            RunLoop.main.run()
        }
    }
}
