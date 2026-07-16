// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Darwin
import Foundation
import os
import SolstoneCore

public protocol SingleSupervisorGating: Sendable {
    func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult
}

public enum SingleSupervisorGateResult: Equatable, Sendable {
    case success
    case blocked(SingleSupervisorGateBlockage)
}

public enum SingleSupervisorGateBlockage: Equatable, Sendable {
    case legacyService(JournalDiagnostic)
    case legacyServiceVerificationFailed(JournalDiagnostic)
    case orphanSweep(JournalDiagnostic)
    case portConflict(JournalDiagnostic)
    case portVerificationFailed(JournalDiagnostic)

    public var diagnostic: JournalDiagnostic {
        switch self {
        case .legacyService(let diagnostic),
             .legacyServiceVerificationFailed(let diagnostic),
             .orphanSweep(let diagnostic),
             .portConflict(let diagnostic),
             .portVerificationFailed(let diagnostic):
            return diagnostic
        }
    }

    public var ownerMessage: String {
        switch self {
        case .legacyService:
            return UICopy.JOURNAL_SPAWN_BLOCKED_LEGACY_SERVICE
        case .legacyServiceVerificationFailed:
            return UICopy.JOURNAL_SPAWN_SERVICE_CHECK_FAILED
        case .orphanSweep, .portConflict:
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
    private let clock: any MonotonicClock
    private let orphanGracePeriod: Duration
    private let serviceRetirer: any LegacyJournalServiceRetiring
    private let evidenceReader: any JournalProcessEvidenceReading

    public init(
        runner: SubprocessRunning = SubprocessRunner(),
        serviceRetirer: (any LegacyJournalServiceRetiring)? = nil,
        evidenceReader: any JournalProcessEvidenceReading = LiveJournalProcessEvidenceReader(),
        pidExists: @escaping @Sendable (pid_t) -> Bool = { pid in
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        },
        terminate: @escaping @Sendable (pid_t, Int32) -> Int32 = { pid, signal in
            Darwin.kill(pid, signal)
        },
        clock: any MonotonicClock = SystemMonotonicClock(),
        orphanGracePeriod: Duration = .seconds(3)
    ) {
        self.runner = runner
        self.pidExists = pidExists
        self.terminate = terminate
        self.clock = clock
        self.orphanGracePeriod = orphanGracePeriod
        self.serviceRetirer = serviceRetirer ?? LegacyJournalServiceRetirer(runner: runner, clock: clock)
        self.evidenceReader = evidenceReader
    }

    public func prepareForSpawn(journalRoot: URL) async -> SingleSupervisorGateResult {
        switch await serviceRetirer.retireLegacyService(journalRoot: journalRoot) {
        case .success(let verdict):
            Logger.setup.notice("journal-lifecycle: gate-service-retirement verdict=\(verdict.rawValue, privacy: .public)")
        case .blocked(let verdict, let diagnostic):
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=legacy-service verdict=\(verdict.rawValue, privacy: .public)")
            return .blocked(blockage(for: verdict, diagnostic: diagnostic))
        }

        if let failure = await runJournalOrphanSweep(
            journalRoot: journalRoot,
            runner: runner,
            evidenceReader: evidenceReader,
            launchdPIDProvider: { [serviceRetirer] in
                await serviceRetirer.currentLegacyServicePID()
            },
            pidExists: pidExists,
            terminate: terminate,
            gracePeriod: orphanGracePeriod,
            clock: clock
        ) {
            Logger.setup.warning("journal-lifecycle: gate-blocked reason=orphan-sweep detail=\(failure.message, privacy: .public)")
            return .blocked(.orphanSweep(JournalDiagnostic(
                commandLabel: "journal supervisor gate",
                outputExcerpt: failure.message
            )))
        }

        if let failure = await assertStartupPortsAvailable(ports: [7657, 5015], runner: runner, clock: clock) {
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

    private func blockage(
        for verdict: LegacyJournalServiceVerdict,
        diagnostic: JournalDiagnostic
    ) -> SingleSupervisorGateBlockage {
        switch verdict {
        case .differentRoot, .provenMatchLoaded, .provenMatchUnloaded:
            return .legacyService(diagnostic)
        case .noService, .labelWithoutPlist, .plistVsJobDisagreement, .malformed, .inspectionFailure:
            return .legacyServiceVerificationFailed(diagnostic)
        }
    }
}
