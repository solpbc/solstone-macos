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
    private let receiptContextFactory: () -> JournalRuntimeEntryReceiptContext
    private var receiptContext: JournalRuntimeEntryReceiptContext?
    private var replacementReadinessTask: Task<Void, Never>?
    private var replacementReadinessGeneration: UInt64?

    private(set) var state: JournalSupervisorState = .idle
    private(set) var runtimeStatus: JournalRuntimeStatus = .unobserved
    private(set) var blockedReason: String?
    private(set) var activeRuntime: MaterializedRuntime?
    private(set) var activeJournalRoot: URL?

    init(
        gate: any SingleSupervisorGating = SingleSupervisorGate(),
        materializer: any RuntimeMaterializing = NativeJournalRuntimeMaterializer(),
        runner: (any SupervisedChildRunning)? = nil,
        readinessGate: any JournalReadinessChecking = JournalReadinessGate(),
        markerURL: URL = ExpectedExitMarker.markerURL(for: ExpectedExitMarker.journalMarkerDiscriminator),
        port: Int = 5015,
        readinessTimeout: Duration = .seconds(120),
        receiptContextFactory: @escaping () -> JournalRuntimeEntryReceiptContext = {
            JournalRuntimeEntryReceiptLaunch.begin(provenanceBundle: .module)
        }
    ) {
        let bridge = StatusBridge()
        self.materializer = materializer
        self.runner = runner ?? SupervisedJournalRunner(statusSink: { status in
            // The runner is silent for ordinary stop() and for a single unexpected
            // post-ready exit while backoff is pending; only terminal breaker/relaunch
            // failure reaches this sink as .stopped.
            Task { @MainActor [bridge, status] in
                bridge.supervisor?.applyRuntimeStatus(status)
            }
        }, gate: gate)
        self.readinessGate = readinessGate
        self.markerURL = markerURL
        self.port = port
        self.readinessTimeout = readinessTimeout
        self.receiptContextFactory = receiptContextFactory
        bridge.supervisor = self
    }

    var journalBinaryURL: URL? {
        activeRuntime?.layout.journalBinary
    }

    var journalRuntimeEnvironment: [String: String]? {
        activeRuntime?.environment
    }

    func applyRuntimeStatus(_ status: JournalRuntimeStatus) {
        runtimeStatus = status
        Logger.journalSupervisor.notice("journal runtime status: \(String(describing: status), privacy: .public)")
        guard case .restarting(let generation?) = status else { return }
        beginReplacementReadiness(generation: generation)
    }

    func configureReceiptContext(_ context: JournalRuntimeEntryReceiptContext) {
        guard receiptContext == nil else { return }
        receiptContext = context
    }

    @discardableResult
    func start(journalRoot rawJournalRoot: URL) async -> Bool {
        cancelReplacementReadiness()
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

        do {
            state = .starting
            try await runner.start(
                runtime: runtime,
                journalRoot: journalRoot,
                port: port,
                receiptContext: resolvedReceiptContext()
            )
        } catch SupervisedJournalRunnerError.gateBlocked(let blockage) {
            let diagnostic = blockage.diagnostic
            state = .blocked(diagnostic)
            blockedReason = blockage.ownerMessage
            Logger.journalSupervisor.warning("journal supervisor gate blocked: \(diagnostic.outputExcerpt ?? blockage.ownerMessage, privacy: .public)")
            return false
        } catch {
            let diagnostic = JournalDiagnostic(
                commandLabel: "journal start --hosted-parent",
                outputExcerpt: error.localizedDescription
            )
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            Logger.journalSupervisor.error("journal spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        return await finishReadiness(journalRoot: journalRoot, runtime: runtime)
    }

    @discardableResult
    func stop() async -> Bool {
        cancelReplacementReadiness()
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
        cancelReplacementReadiness()
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

        do {
            state = .starting
            try await runner.restart()
        } catch SupervisedJournalRunnerError.gateBlocked(let blockage) {
            let diagnostic = blockage.diagnostic
            state = .blocked(diagnostic)
            blockedReason = blockage.ownerMessage
            Logger.journalSupervisor.warning("journal supervisor gate blocked: \(diagnostic.outputExcerpt ?? blockage.ownerMessage, privacy: .public)")
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

        return await finishReadiness(journalRoot: journalRoot, runtime: runtime)
    }

    private func finishReadiness(
        journalRoot: URL,
        runtime: MaterializedRuntime,
        replacementGeneration: UInt64? = nil
    ) async -> Bool {
        guard readinessAttemptIsCurrent(replacementGeneration) else { return false }
        state = .waitingForReadiness
        switch await readinessGate.waitUntilReady(
            journalRoot: journalRoot,
            runtime: runtime,
            timeout: readinessTimeout,
            terminalCheck: { [runner] in
                await runner.terminalReason()
            },
            identityProvider: { [runner] in
                guard let identity = await runner.currentIdentity() else { return nil }
                guard replacementGeneration == nil || identity.generation == replacementGeneration else { return nil }
                return identity
            },
            readinessAcceptance: { [runner] identity in
                await runner.markReady(identity: identity)
            }
        ) {
        case .ready:
            guard readinessAttemptIsCurrent(replacementGeneration) else { return false }
            finishReplacementReadiness(generation: replacementGeneration)
            activeRuntime = runtime
            activeJournalRoot = journalRoot
            state = .running
            Logger.journalSupervisor.notice("journal supervisor ready")
            return true
        case .failed(let diagnostic):
            guard readinessAttemptIsCurrent(replacementGeneration) else { return false }
            finishReplacementReadiness(generation: replacementGeneration)
            await runner.stop()
            activeRuntime = nil
            activeJournalRoot = nil
            state = .failed(diagnostic)
            applyRuntimeStatus(.unknown(diagnostic))
            Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
            return false
        case .failedTerminal(let diagnostic):
            guard readinessAttemptIsCurrent(replacementGeneration) else { return false }
            finishReplacementReadiness(generation: replacementGeneration)
            await runner.stop()
            activeRuntime = nil
            activeJournalRoot = nil
            state = .failed(diagnostic)
            applyRuntimeStatus(.stopped(diagnostic))
            Logger.journalSupervisor.warning("journal readiness failed: \(diagnostic.outputExcerpt ?? diagnostic.commandLabel, privacy: .public)")
            return false
        }
    }

    private func resolvedReceiptContext() -> JournalRuntimeEntryReceiptContext {
        if let receiptContext {
            return receiptContext
        }
        let context = receiptContextFactory()
        receiptContext = context
        return context
    }

    func terminate(reason: String = "ordinary-quit") async {
        guard state != .terminating else { return }
        cancelReplacementReadiness()
        state = .terminating
        blockedReason = nil
        activeRuntime = nil
        activeJournalRoot = nil
        ExpectedExitMarker.markExpectedExit(reason: reason, at: markerURL)
        await runner.stopForTermination()
        Logger.journalSupervisor.notice("journal supervisor terminated")
    }

    private func beginReplacementReadiness(generation: UInt64) {
        cancelReplacementReadiness()
        guard let runtime = activeRuntime, let journalRoot = activeJournalRoot else { return }
        replacementReadinessGeneration = generation
        replacementReadinessTask = Task { @MainActor [weak self] in
            guard let self,
                  self.readinessAttemptIsCurrent(generation),
                  let identity = await self.runner.currentIdentity(),
                  identity.generation == generation else { return }
            _ = await self.finishReadiness(
                journalRoot: journalRoot,
                runtime: runtime,
                replacementGeneration: generation
            )
        }
    }

    private func cancelReplacementReadiness() {
        replacementReadinessTask?.cancel()
        replacementReadinessTask = nil
        replacementReadinessGeneration = nil
    }

    private func finishReplacementReadiness(generation: UInt64?) {
        guard let generation, replacementReadinessGeneration == generation else { return }
        replacementReadinessTask = nil
        replacementReadinessGeneration = nil
    }

    private func readinessAttemptIsCurrent(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return replacementReadinessGeneration == generation && !Task.isCancelled
    }
}
