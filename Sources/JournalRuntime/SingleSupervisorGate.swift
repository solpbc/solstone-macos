// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

public protocol SingleSupervisorGating: Sendable {
    func prepareForSpawn(journalRoot: URL, context: LaunchAuthorizationContext) async -> SingleSupervisorGateResult
}

public extension SingleSupervisorGating {
    // Setup has no existing app-owned child to exclude; app-owned child launches pass an explicit context.
    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        await prepareForSpawn(journalRoot: journalRoot, context: LaunchAuthorizationContext())
    }
}

public struct LaunchAuthorizationContext: Equatable, Sendable {
    public let excludedChild: JournalChildIdentity?

    public init(excludedChild: JournalChildIdentity? = nil) {
        self.excludedChild = excludedChild
    }

    internal var excludedPIDs: Set<pid_t> {
        if let excludedChild {
            return [excludedChild.pid]
        }
        return []
    }
}

public enum SingleSupervisorGateResult: Equatable, Sendable {
    case success
    case blocked(SingleSupervisorGateBlockage)
}

public enum SingleSupervisorGateBlockage: Equatable, Sendable {
    case cancelled(JournalDiagnostic)
    case legacyServiceOwnershipUnverified(JournalDiagnostic)
    case legacyServiceRetirementFailed(JournalDiagnostic)
    case orphanOwnershipUnverified(JournalDiagnostic)
    case orphanRetirementFailed(JournalDiagnostic)
    case portConflict(JournalDiagnostic)
    case portVerificationFailed(JournalDiagnostic)

    public var diagnostic: JournalDiagnostic {
        switch self {
        case .cancelled(let diagnostic),
             .legacyServiceOwnershipUnverified(let diagnostic),
             .legacyServiceRetirementFailed(let diagnostic),
             .orphanOwnershipUnverified(let diagnostic),
             .orphanRetirementFailed(let diagnostic),
             .portConflict(let diagnostic),
             .portVerificationFailed(let diagnostic):
            return diagnostic
        }
    }

    public var ownerMessage: String {
        switch self {
        case .cancelled:
            return UICopy.JOURNAL_SPAWN_CANCELLED
        case .legacyServiceOwnershipUnverified:
            return UICopy.JOURNAL_SPAWN_LEGACY_SERVICE_UNVERIFIED
        case .legacyServiceRetirementFailed:
            return UICopy.JOURNAL_SPAWN_LEGACY_SERVICE_RETIRE_FAILED
        case .orphanOwnershipUnverified:
            return UICopy.JOURNAL_SPAWN_ORPHAN_UNVERIFIED
        case .orphanRetirementFailed:
            return UICopy.JOURNAL_SPAWN_ORPHAN_RETIRE_FAILED
        case .portConflict:
            return UICopy.JOURNAL_SPAWN_BLOCKED_PORTS
        case .portVerificationFailed:
            return UICopy.JOURNAL_SPAWN_PORT_CHECK_FAILED
        }
    }
}

public struct SingleSupervisorGate: SingleSupervisorGating {
    private let runner: SubprocessRunning
    private let pidExists: @Sendable (pid_t) -> Bool
    private let terminate: @Sendable (pid_t, Int32) -> Int32
    private let environmentReader: ProcessEnvironmentReading
    private let clock: any MonotonicClock
    private let orphanGracePeriod: Duration
    private let homeDirectory: URL
    private let launchdLabel: String
    private let launchdPlistURL: URL?

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        environmentReader: @escaping ProcessEnvironmentReading = defaultProcessEnvironment,
        clock: any MonotonicClock = SystemMonotonicClock(),
        orphanGracePeriod: Duration = .seconds(3),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.init(
            runner: runner,
            pidExists: pidExists,
            terminate: terminate,
            environmentReader: environmentReader,
            clock: clock,
            orphanGracePeriod: orphanGracePeriod,
            homeDirectory: homeDirectory,
            launchdLabel: legacyJournalLaunchdLabel,
            launchdPlistURL: nil
        )
    }

    internal init(
        runner: SubprocessRunning = SubprocessRunner(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        environmentReader: @escaping ProcessEnvironmentReading = defaultProcessEnvironment,
        clock: any MonotonicClock = SystemMonotonicClock(),
        orphanGracePeriod: Duration = .seconds(3),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchdLabel: String,
        launchdPlistURL: URL?
    ) {
        self.runner = runner
        self.pidExists = pidExists
        self.terminate = terminate
        self.environmentReader = environmentReader
        self.clock = clock
        self.orphanGracePeriod = orphanGracePeriod
        self.homeDirectory = homeDirectory
        self.launchdLabel = launchdLabel
        self.launchdPlistURL = launchdPlistURL
    }

    public func prepareForSpawn(journalRoot: URL, context: LaunchAuthorizationContext) async -> SingleSupervisorGateResult {
        let plistURL = launchdPlistURL ?? legacyLaunchdPlistURL(homeDirectory: homeDirectory)
        let plistState = loadLaunchdPlist(at: plistURL, expectedLabel: launchdLabel)
        let printState = await runLaunchctlPrint(label: launchdLabel, runner: runner)
        let proof = rootProof(for: plistState, knownRoot: journalRoot)
        let decision = decideLaunchdOwnership(
            plistState: plistState,
            printState: printState,
            rootProof: proof
        )
        if Task.isCancelled {
            return cancelledBlockage()
        }

        switch decision {
        case .noOp:
            Logger.setup.notice("journal-lifecycle: legacy-service verdict=no-op")
        case .block(let reason):
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service-ownership detail=\(reason, privacy: .public)")
            return .blocked(.legacyServiceOwnershipUnverified(JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: reason
            )))
        case .retire:
            Logger.setup.notice("journal-lifecycle: legacy-service verdict=retire")
            if Task.isCancelled {
                return cancelledBlockage()
            }
            if case .loaded = printState {
                guard let bootout = await runLaunchctlBootout(label: launchdLabel, runner: runner),
                      bootout.exitCode == 0 || bootout.exitCode == 3 else {
                    Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service-retire step=bootout")
                    return .blocked(.legacyServiceRetirementFailed(JournalDiagnostic(
                        commandLabel: "launchctl bootout",
                        outputExcerpt: "legacy journal service could not be retired"
                    )))
                }
                if Task.isCancelled {
                    return cancelledBlockage()
                }
                guard await waitForLaunchdAbsence(label: launchdLabel, runner: runner, clock: clock) else {
                    Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service-retire step=absence-poll")
                    return .blocked(.legacyServiceRetirementFailed(JournalDiagnostic(
                        commandLabel: "launchctl print",
                        outputExcerpt: "legacy journal service remained loaded after bootout"
                    )))
                }
            }
            if Task.isCancelled {
                return cancelledBlockage()
            }
            do {
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    try FileManager.default.removeItem(at: plistURL)
                }
            } catch {
                Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service-retire step=unlink")
                return .blocked(.legacyServiceRetirementFailed(JournalDiagnostic(
                    commandLabel: "legacy journal service cleanup",
                    outputExcerpt: "legacy journal service plist could not be removed"
                )))
            }
        }

        if Task.isCancelled {
            return cancelledBlockage()
        }
        let refreshedPrint = await runLaunchctlPrint(label: launchdLabel, runner: runner)
        let protectedLaunchdPIDs: Set<pid_t>
        switch refreshedPrint {
        case .notFound113:
            protectedLaunchdPIDs = []
        case .loaded(let job):
            if case .running = job.state, let pid = job.pid {
                protectedLaunchdPIDs = [pid]
            } else {
                protectedLaunchdPIDs = []
            }
        case .otherError(let exitCode, _):
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service-refresh exit=\(exitCode, privacy: .public)")
            return .blocked(.legacyServiceOwnershipUnverified(JournalDiagnostic(
                commandLabel: "launchctl print",
                exitCode: exitCode,
                outputExcerpt: "legacy journal service state could not be verified"
            )))
        }

        if Task.isCancelled {
            return cancelledBlockage()
        }
        if let failure = await runJournalOrphanSweep(
            journalRoot: journalRoot,
            runner: runner,
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock,
            protectedLaunchdPIDs: protectedLaunchdPIDs,
            excludedPIDs: context.excludedPIDs,
            environmentReader: environmentReader
        ) {
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=orphan-sweep kind=\(String(describing: failure.kind), privacy: .public) detail=\(failure.message, privacy: .public)")
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: failure.message
            )
            switch failure.kind {
            case .orphanOwnershipUnverified:
                return .blocked(.orphanOwnershipUnverified(diagnostic))
            case .orphanRetirementFailed:
                return .blocked(.orphanRetirementFailed(diagnostic))
            case .portConflict:
                return .blocked(.portConflict(diagnostic))
            case .portVerificationFailed:
                return .blocked(.portVerificationFailed(diagnostic))
            }
        }

        if Task.isCancelled {
            return cancelledBlockage()
        }
        if let failure = await assertStartupPortsAvailable(
            ports: [7657, 5015],
            runner: runner,
            clock: clock,
            excludedPIDs: context.excludedPIDs
        ) {
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=ports-not-released ports=7657,5015 detail=\(failure.message, privacy: .public)")
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: failure.message
            )
            switch failure.kind {
            case .conflict:
                return .blocked(.portConflict(diagnostic))
            case .couldNotVerify:
                return .blocked(.portVerificationFailed(diagnostic))
            }
        }

        return .success
    }

    private func cancelledBlockage() -> SingleSupervisorGateResult {
        Logger.setup.warning("journal-lifecycle: gate-blocked reason=cancelled")
        return .blocked(.cancelled(JournalDiagnostic(
            commandLabel: "journal supervisor gate",
            outputExcerpt: "journal launch authorization was cancelled"
        )))
    }
}
