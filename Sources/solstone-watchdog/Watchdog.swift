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
        var now: () -> Date
        var markerURL: (String) -> URL
        var clock: any MonotonicClock
        var recordSupervisionTransition: @MainActor (WatchdogSupervisionTransition) -> Void
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
            now: Date.init,
            markerURL: { ExpectedExitMarker.markerURL(for: $0) },
            clock: SystemMonotonicClock(),
            recordSupervisionTransition: { _ in },
            schedulePollTimer: { callback in
                Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                    Task { @MainActor in callback() }
                }
            }
        )
    }

    private struct ActiveAttempt {
        let sequence: UInt64
        let startedAt: Duration
    }

    private let dependencies: Dependencies
    private var pollTimer: Timer?
    private var identity: WatchdogIdentity?
    private var productLogger: Logger?
    private var supervisionState: WatchdogSupervisionState = .retrying(failureCount: 0, nextAttemptAt: .zero)
    private var activeAttempt: ActiveAttempt?
    private var nextAttemptSequence: UInt64 = 0
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

        let now = dependencies.clock.now()
        transition(to: .retrying(failureCount: 0, nextAttemptAt: now), cause: .startup)
        reconcileCandidates(dependencies.runningCandidates())
        pollTimer = dependencies.schedulePollTimer { [weak self] in
            self?.pollObserverPresence()
        }
        return .polling
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
        reconcileCandidates(dependencies.runningCandidates())
    }

    private func handleLaunchCompletion(sequence: UInt64, app: NSRunningApplication?, error: Error?) {
        guard activeAttempt?.sequence == sequence else { return }
        if let error {
            activeLogger.error("supervised app launch failed: \(error.localizedDescription, privacy: .public)")
            recordAttemptFailure(cause: .attemptFailed, now: dependencies.clock.now())
            return
        }
        guard app != nil else {
            activeLogger.error("supervised app launch completed without an app")
            recordAttemptFailure(cause: .attemptFailed, now: dependencies.clock.now())
            return
        }
    }

    private func reconcileCandidates(_ candidates: [WatchdogRunningCandidate]) {
        guard let identity else { return }
        let monotonicNow = dependencies.clock.now()
        let matching = candidates.filter { $0.bundleIdentifier == identity.product.targetBundleID }
        let normalizedOwner = WatchdogAppLocationEligibility.normalized(identity.enclosingBundleURL)
        let owner = matching.first { candidate in
            guard let bundleURL = candidate.bundleURL else { return false }
            return WatchdogAppLocationEligibility.normalized(bundleURL) == normalizedOwner
        }
        let foreign = matching.first { candidate in
            guard let bundleURL = candidate.bundleURL else { return true }
            return WatchdogAppLocationEligibility.normalized(bundleURL) != normalizedOwner
        }

        if let owner {
            adoptOwner(pid: owner.processIdentifier, now: monotonicNow)
        }

        if let foreign {
            noteConflict(
                bundleURL: foreign.bundleURL,
                shortVersion: foreign.shortVersion,
                buildVersion: foreign.buildVersion,
                identity: identity
            )
        } else {
            lastConflictFingerprint = nil
        }

        guard owner == nil else { return }

        switch supervisionState {
        case .supervising(let pid, let stableSince, let misses, let failureCount):
            let updatedMisses = misses + 1
            if updatedMisses < WatchdogSupervisionPolicy.confirmingReads {
                supervisionState = .supervising(
                    pid: pid,
                    stableSince: stableSince,
                    consecutiveMisses: updatedMisses,
                    failureCount: failureCount
                )
                return
            }
            handleOwnerExit(
                pid: pid,
                stableSince: stableSince,
                failureCount: failureCount,
                now: monotonicNow,
                allowAttempt: foreign == nil
            )
        case .suppressed(let deadline):
            guard foreign == nil else { return }
            guard let deadline, monotonicNow >= deadline else { return }
            transition(
                to: .retrying(failureCount: 0, nextAttemptAt: monotonicNow),
                cause: .suppressionExpired
            )
            issueAttemptIfDue(now: monotonicNow)
        case .retrying:
            guard foreign == nil else { return }
            settleTimedOutAttemptIfNeeded(now: monotonicNow)
            issueAttemptIfDue(now: monotonicNow)
        }
    }

    private func adoptOwner(pid: Int32, now: Duration) {
        let nextState: WatchdogSupervisionState
        let cause: WatchdogSupervisionTransitionCause
        switch supervisionState {
        case .supervising(let currentPID, let stableSince, _, let failureCount) where currentPID == pid:
            let stableFailureCount = now - stableSince >= WatchdogSupervisionPolicy.stabilityWindow ? 0 : failureCount
            supervisionState = .supervising(
                pid: pid,
                stableSince: stableSince,
                consecutiveMisses: 0,
                failureCount: stableFailureCount
            )
            return
        case .supervising(_, _, _, let failureCount):
            nextState = .supervising(pid: pid, stableSince: now, consecutiveMisses: 0, failureCount: failureCount)
            cause = .ownerPIDChanged
        case .retrying(let failureCount, _):
            nextState = .supervising(pid: pid, stableSince: now, consecutiveMisses: 0, failureCount: failureCount)
            cause = .ownerObserved
        case .suppressed:
            nextState = .supervising(pid: pid, stableSince: now, consecutiveMisses: 0, failureCount: 0)
            cause = .ownerObserved
        }
        activeAttempt = nil
        transition(to: nextState, cause: cause)
    }

    private func handleOwnerExit(
        pid: Int32,
        stableSince: Duration,
        failureCount: Int,
        now: Duration,
        allowAttempt: Bool
    ) {
        guard let identity else { return }
        activeLogger.info("supervised owner exited (pid \(pid, privacy: .public))")
        let markerURL = dependencies.markerURL(identity.product.markerDiscriminator)
        let marker = ExpectedExitMarker.read(at: markerURL)
        guard ExpectedExitMarker.isExpectedExit(
            marker: marker,
            terminatedPID: pid,
            now: dependencies.now()
        ) else {
            if marker != nil {
                ExpectedExitMarker.invalidate(at: markerURL)
            }
            if now - stableSince >= WatchdogSupervisionPolicy.stabilityWindow {
                transition(to: .retrying(failureCount: 0, nextAttemptAt: now), cause: .ownerExit)
                if allowAttempt {
                    issueAttemptIfDue(now: now)
                }
            } else {
                recordAttemptFailure(cause: .unstableOwnerExit, now: now, currentFailureCount: failureCount)
            }
            return
        }

        let exitClass = ExitReason(markerString: marker!.reason)?.watchdogExitClass
        switch exitClass {
        case .ownerIntent:
            transition(to: .suppressed(until: nil), cause: .ownerExit)
        case .selfRelaunch(let bound):
            transition(to: .suppressed(until: now + bound), cause: .ownerExit)
        case nil:
            transition(
                to: .suppressed(until: now + WatchdogSupervisionPolicy.updaterOrUnrecognizedBound),
                cause: .ownerExit
            )
        }
        ExpectedExitMarker.invalidate(at: markerURL)
    }

    private func settleTimedOutAttemptIfNeeded(now: Duration) {
        guard let activeAttempt,
              now - activeAttempt.startedAt >= WatchdogSupervisionPolicy.inFlightTimeout else {
            return
        }
        recordAttemptFailure(cause: .attemptTimedOut, now: now)
    }

    private func issueAttemptIfDue(now: Duration) {
        guard activeAttempt == nil,
              case .retrying(_, let nextAttemptAt) = supervisionState,
              now >= nextAttemptAt,
              let identity else {
            return
        }
        nextAttemptSequence &+= 1
        let sequence = nextAttemptSequence
        activeAttempt = ActiveAttempt(sequence: sequence, startedAt: now)
        activeLogger.info("supervised app not running; launching")
        dependencies.openApplication(identity.enclosingBundleURL) { [weak self] app, error in
            MainActor.assumeIsolated {
                self?.handleLaunchCompletion(sequence: sequence, app: app, error: error)
            }
        }
    }

    private func recordAttemptFailure(
        cause: WatchdogSupervisionTransitionCause,
        now: Duration,
        currentFailureCount: Int? = nil
    ) {
        let failureCount: Int
        if let currentFailureCount {
            failureCount = currentFailureCount
        } else if case .retrying(let current, _) = supervisionState {
            failureCount = current
        } else {
            failureCount = 0
        }
        let nextFailureCount = failureCount + 1
        activeAttempt = nil
        transition(
            to: .retrying(
                failureCount: nextFailureCount,
                nextAttemptAt: now + backoffDelay(for: nextFailureCount)
            ),
            cause: cause
        )
    }

    private func backoffDelay(for failureCount: Int) -> Duration {
        var delay = WatchdogSupervisionPolicy.firstBackoff
        for _ in 1..<failureCount {
            delay = min(delay * WatchdogSupervisionPolicy.backoffMultiplier, WatchdogSupervisionPolicy.backoffCeiling)
        }
        return delay
    }

    private func transition(to destination: WatchdogSupervisionState, cause: WatchdogSupervisionTransitionCause) {
        supervisionState = destination
        let event = WatchdogSupervisionTransition(destination: destination, cause: cause)
        activeLogger.info("watchdog supervision transition \(String(describing: event), privacy: .public)")
        dependencies.recordSupervisionTransition(event)
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
