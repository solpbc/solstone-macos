// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import JournalRuntime
import Observation
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
@Observable
final class JournalSupervisor {
    @MainActor
    private final class StatusBridge: @unchecked Sendable {
        weak var supervisor: JournalSupervisor?
    }

    private let materializer: any RuntimeMaterializing
    private let runner: any SupervisedChildRunning
    private let readinessGate: any JournalReadinessChecking
    private let markerURL: URL
    private let port: Int
    private let readinessTimeout: Duration

    private(set) var state: JournalSupervisorState = .idle
    private(set) var runtimeStatus: JournalRuntimeStatus = .unobserved
    private(set) var blockedReason: String?
    private(set) var activeRuntime: MaterializedRuntime?
    private(set) var activeJournalRoot: URL?

    init(
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        materializer: any RuntimeMaterializing = RuntimeMaterializer(),
        runner: (any SupervisedChildRunning)? = nil,
        readinessGate: any JournalReadinessChecking = JournalReadinessGate(),
        markerURL: URL = ExpectedExitMarker.markerURL(for: ExpectedExitMarker.journalMarkerDiscriminator),
        port: Int = 5015,
        readinessTimeout: Duration = .seconds(120)
    ) {
        let bridge = StatusBridge()
        self.materializer = materializer
        self.runner = runner ?? SupervisedJournalRunner(authorizationGate: gate, statusSink: { status in
            // The runner is silent for ordinary stop() and for a single unexpected
            // post-ready exit while backoff is pending; only terminal breaker/relaunch
            // failure reaches this sink as .stopped.
            Task { @MainActor [bridge, status] in
                bridge.supervisor?.applyRuntimeStatus(status)
            }
        })
        self.readinessGate = readinessGate
        self.markerURL = markerURL
        self.port = port
        self.readinessTimeout = readinessTimeout
        bridge.supervisor = self
    }

    var journalBinaryURL: URL? {
        activeRuntime?.layout.journalBinary
    }

    var journalRuntimeEnvironment: [String: String]? {
        activeRuntime?.layout.uvEnvironment()
    }

    func applyRuntimeStatus(_ status: JournalRuntimeStatus) {
        runtimeStatus = status
        Logger.journalSupervisor.notice("journal runtime status: \(String(describing: status), privacy: .public)")
    }

    @discardableResult
    func start(journalRoot rawJournalRoot: URL) async -> Bool {
        let journalRoot = rawJournalRoot.standardizedFileURL
        blockedReason = nil
        activeRuntime = nil
        activeJournalRoot = nil

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
            applyRuntimeStatus(.unknown(diagnostic))
            Logger.journalSupervisor.error("journal runtime materialize failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let child: JournalChildIdentity
        do {
            state = .starting
            child = try await runner.start(runtime: runtime, journalRoot: journalRoot, port: port)
        } catch SupervisedJournalRunnerError.spawnBlocked(let blockage) {
            applySpawnBlockage(blockage)
            return false
        } catch {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --app-supervised",
                outputExcerpt: error.localizedDescription
            )
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            Logger.journalSupervisor.error("journal spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        return await finishReadiness(journalRoot: journalRoot, runtime: runtime, child: child)
    }

    @discardableResult
    func stop() async -> Bool {
        blockedReason = nil
        await runner.stop()
        activeRuntime = nil
        activeJournalRoot = nil
        state = .idle
        applyRuntimeStatus(.stoppedByUser)
        return true
    }

    @discardableResult
    func restart() async -> Bool {
        blockedReason = nil
        guard let runtime = activeRuntime, let journalRoot = activeJournalRoot else {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal restart",
                outputExcerpt: "journal is not running"
            )
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            return false
        }

        let child: JournalChildIdentity
        do {
            state = .starting
            child = try await runner.restart()
        } catch SupervisedJournalRunnerError.spawnBlocked(let blockage) {
            applySpawnBlockage(blockage)
            return false
        } catch {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal restart",
                outputExcerpt: error.localizedDescription
            )
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            return false
        }

        return await finishReadiness(journalRoot: journalRoot, runtime: runtime, child: child)
    }

    private func finishReadiness(journalRoot: URL, runtime: MaterializedRuntime, child: JournalChildIdentity) async -> Bool {
        state = .waitingForReadiness
        switch await readinessGate.waitUntilReady(
            journalRoot: journalRoot,
            runtime: runtime,
            child: child,
            timeout: readinessTimeout,
            generationIsCurrent: { [runner] generation in
                await runner.isCurrentGeneration(generation)
            },
            terminalCheck: { [runner] in
                await runner.terminalReason()
            }
        ) {
        case .ready:
            guard await runner.markReady(child) else {
                let diagnostic = JournalDiagnostic(
                    commandLabel: "journal readiness",
                    outputExcerpt: "journal child identity could not be verified"
                )
                await runner.stop()
                activeRuntime = nil
                activeJournalRoot = nil
                state = .failed(diagnostic)
                applyRuntimeStatus(.unknown(diagnostic))
                Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
                return false
            }
            activeRuntime = runtime
            activeJournalRoot = journalRoot
            state = .running
            Logger.journalSupervisor.notice("journal supervisor ready")
            return true
        case .failed(let diagnostic):
            await runner.stop()
            activeRuntime = nil
            activeJournalRoot = nil
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
            return false
        case .failedTerminal(let diagnostic):
            await runner.stop()
            activeRuntime = nil
            activeJournalRoot = nil
            state = .failed(diagnostic)
            applyRuntimeStatus(.stopped(diagnostic))
            Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
            return false
        }
    }

    private func applySpawnBlockage(_ blockage: SingleSupervisorGateBlockage) {
        let diagnostic = blockage.diagnostic
        state = .blocked(diagnostic)
        blockedReason = blockage.ownerMessage
        applyRuntimeStatus(.unknown(diagnostic))
        Logger.journalSupervisor.warning("journal supervisor gate blocked: \(diagnostic.outputExcerpt ?? blockage.ownerMessage, privacy: .public)")
    }

    func terminate(reason: String = "ordinary-quit") async {
        guard state != .terminating else { return }
        state = .terminating
        blockedReason = nil
        activeRuntime = nil
        activeJournalRoot = nil
        ExpectedExitMarker.markExpectedExit(reason: reason, at: markerURL)
        await runner.stopForTermination()
        Logger.journalSupervisor.notice("journal supervisor terminated")
    }
}
