// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import os
import SolstoneCore

enum JournalSupervisorState: Equatable {
    case idle
    case blocked(JournalDiagnostic)
    case materializing
    case starting
    case waitingForReadiness
    case running
    case failed(JournalDiagnostic)
    case terminating
}

@MainActor
final class JournalSupervisor {
    private let gate: any SingleSupervisorGating
    private let materializer: any RuntimeMaterializing
    private let runner: any SupervisedChildRunning
    private let readinessGate: any JournalReadinessChecking
    private let markerURL: URL
    private let port: Int
    private let readinessTimeout: Duration

    private(set) var state: JournalSupervisorState = .idle

    init(
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        materializer: any RuntimeMaterializing = RuntimeMaterializer(),
        runner: any SupervisedChildRunning = SupervisedJournalRunner(statusSink: { status in
            Logger.journalSupervisor.notice("journal runtime status: \(String(describing: status), privacy: .public)")
        }),
        readinessGate: any JournalReadinessChecking = JournalReadinessGate(),
        markerURL: URL = ExpectedExitMarker.markerURL(for: ExpectedExitMarker.journalMarkerDiscriminator),
        port: Int = 5015,
        readinessTimeout: Duration = .seconds(120)
    ) {
        self.gate = gate
        self.materializer = materializer
        self.runner = runner
        self.readinessGate = readinessGate
        self.markerURL = markerURL
        self.port = port
        self.readinessTimeout = readinessTimeout
    }

    @discardableResult
    func start(journalRoot rawJournalRoot: URL) async -> Bool {
        let journalRoot = rawJournalRoot.standardizedFileURL

        switch await gate.prepareForSpawn(journalRoot: journalRoot) {
        case .success:
            Logger.journalSupervisor.notice("journal supervisor gate open")
        case .blocked(let blockage):
            let diagnostic = blockage.diagnostic
            state = .blocked(diagnostic)
            Logger.journalSupervisor.warning("journal supervisor gate blocked: \(diagnostic.outputExcerpt ?? blockage.ownerMessage, privacy: .public)")
            return false
        }

        let runtime: MaterializedRuntime
        do {
            state = .materializing
            let liveKey = await runner.currentRuntimeKey()
            runtime = try await materializer.materialize(excludingLiveKey: liveKey)
        } catch {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal runtime materialize",
                outputExcerpt: error.localizedDescription
            )
            state = .failed(diagnostic)
            Logger.journalSupervisor.error("journal runtime materialize failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        do {
            state = .starting
            try await runner.start(runtime: runtime, journalRoot: journalRoot, port: port)
        } catch {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: error.localizedDescription
            )
            state = .failed(diagnostic)
            Logger.journalSupervisor.error("journal spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        state = .waitingForReadiness
        switch await readinessGate.waitUntilReady(
            journalRoot: journalRoot,
            runtime: runtime,
            timeout: readinessTimeout,
            terminalCheck: { [runner] in
                await runner.terminalReason()
            }
        ) {
        case .ready:
            await runner.markReady()
            state = .running
            Logger.journalSupervisor.notice("journal supervisor ready")
            return true
        case .failed(let diagnostic), .failedTerminal(let diagnostic):
            await runner.stop()
            state = .failed(diagnostic)
            Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
            return false
        }
    }

    func terminate(reason: String = "ordinary-quit") async {
        guard state != .terminating else { return }
        state = .terminating
        ExpectedExitMarker.markExpectedExit(reason: reason, at: markerURL)
        await runner.stopForTermination()
        Logger.journalSupervisor.notice("journal supervisor terminated")
    }
}
