// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

struct AppQuitStateMachine {
    enum Phase: Equatable {
        case notStarted
        case preparing
        case prepared
    }

    enum PreparationDecision: Equatable {
        case startPreparation
        case joinPreparation
        case alreadyPrepared
    }

    private(set) var phase: Phase = .notStarted

    var isPrepared: Bool {
        phase == .prepared
    }

    mutating func requestPreparation() -> PreparationDecision {
        switch phase {
        case .notStarted:
            phase = .preparing
            return .startPreparation
        case .preparing:
            return .joinPreparation
        case .prepared:
            return .alreadyPrepared
        }
    }

    mutating func markPrepared() {
        phase = .prepared
    }

    mutating func reset() {
        phase = .notStarted
    }
}

@MainActor
final class AppQuitCoordinator {
    internal static let diagnosticEvidenceDrainCutoffSeconds: Double = 2

    struct Dependencies {
        let setCommitted: @MainActor (Bool) -> Void
        let writeMarker: @MainActor (ExitReason) -> Void
        let invalidateMarker: @MainActor () -> Void
        let prepareForQuit: @MainActor () async -> Void
        let prepareForUpdate: @MainActor () async -> Void
        let terminate: @MainActor () -> Void
        let launchReplacement: @MainActor () -> Void

        init(
            setCommitted: @escaping @MainActor (Bool) -> Void = { _ in },
            writeMarker: @escaping @MainActor (ExitReason) -> Void = {
                ExpectedExitMarker.markExpectedExit(reason: $0.markerString)
            },
            invalidateMarker: @escaping @MainActor () -> Void = {
                ExpectedExitMarker.invalidate()
            },
            prepareForQuit: @escaping @MainActor () async -> Void = {},
            prepareForUpdate: @escaping @MainActor () async -> Void = {},
            terminate: @escaping @MainActor () -> Void = {},
            launchReplacement: @escaping @MainActor () -> Void = {}
        ) {
            self.setCommitted = setCommitted
            self.writeMarker = writeMarker
            self.invalidateMarker = invalidateMarker
            self.prepareForQuit = prepareForQuit
            self.prepareForUpdate = prepareForUpdate
            self.terminate = terminate
            self.launchReplacement = launchReplacement
        }
    }

    private struct ExitIntent {
        let reason: ExitReason
        let prepare: @MainActor () async -> Void
        let finalize: (@MainActor () -> Void)?
    }

    private var stateMachine = AppQuitStateMachine()
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var committedIntent: ExitIntent?
    private var finalActionPerformed = false
    private var externalReplies: [@MainActor (Bool) -> Void] = []
    private var hasRecordedAppKitTerminationAttempt = false
    private var externalReplyDrainInFlight = false
    internal private(set) var externalReplyDrainCountForTesting = 0
    private let dependencies: Dependencies
    private let recorder: DiagnosticEvidenceRecorder
    private let logAdapter: DiagnosticEvidenceLoggingAdapter
    private let evidenceDrainCutoffSeconds: Double

    var isPrepared: Bool {
        stateMachine.isPrepared
    }

    init(
        dependencies: Dependencies,
        recorder: DiagnosticEvidenceRecorder = .dormant,
        logAdapter: DiagnosticEvidenceLoggingAdapter = .live,
        evidenceDrainCutoffSeconds: Double = AppQuitCoordinator.diagnosticEvidenceDrainCutoffSeconds
    ) {
        self.dependencies = dependencies
        self.recorder = recorder
        self.logAdapter = logAdapter
        self.evidenceDrainCutoffSeconds = evidenceDrainCutoffSeconds
    }

    func requestAppOwnedQuit() {
        begin(intent: appOwnedQuitIntent())
    }

    func requestAppKitTermination(reply: @escaping @MainActor (Bool) -> Void) {
        if !hasRecordedAppKitTerminationAttempt {
            hasRecordedAppKitTerminationAttempt = true
            recorder.enqueue(.terminationAppKitBegan)
            logAdapter.terminationAppKitBegan()
        }
        begin(intent: externalTerminationIntent(), externalReply: reply)
    }

    func requestSettingsRestart() {
        begin(intent: settingsRestartIntent())
    }

    func prepareForUpdaterInstall() async {
        guard let task = begin(intent: updaterInstallIntent()) else { return }
        await task.value
    }

    func resetAfterFailedUpdaterInstall() {
        dependencies.invalidateMarker()
        dependencies.setCommitted(false)
        stateMachine.reset()
        preparationGeneration &+= 1
        hasRecordedAppKitTerminationAttempt = false
        externalReplyDrainInFlight = false
        committedIntent = nil
        preparationTask = nil
        finalActionPerformed = false
        // Reply false and fence stale AppKit work; do not cancel the recorder tail,
        // which must persist the historical attempt after recovery.
        drainExternalReplies(proceed: false)
    }

    @discardableResult
    private func begin(
        intent: ExitIntent,
        externalReply: (@MainActor (Bool) -> Void)? = nil
    ) -> Task<Void, Never>? {
        if let externalReply {
            externalReplies.append(externalReply)
        }

        switch stateMachine.requestPreparation() {
        case .startPreparation:
            committedIntent = intent
            preparationGeneration &+= 1
            let generation = preparationGeneration
            dependencies.setCommitted(true)
            recorder.enqueue(.terminationCommitted)
            logAdapter.terminationCommitted()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performPreparation(generation: generation)
            }
            preparationTask = task
            return task
        case .joinPreparation:
            return preparationTask
        case .alreadyPrepared:
            if externalReply != nil {
                scheduleExternalReplyDrainIfNeeded(generation: preparationGeneration)
            }
            if let finalize = intent.finalize, !finalActionPerformed {
                finalActionPerformed = true
                finalize()
            }
            return nil
        }
    }

    private func performPreparation(generation: Int) async {
        guard generation == preparationGeneration, let intent = committedIntent else { return }
        await intent.prepare()
        guard generation == preparationGeneration else { return }
        dependencies.writeMarker(intent.reason)
        stateMachine.markPrepared()
        preparationTask = nil
        if claimExternalReplyDrainIfNeeded() {
            await drainClaimedExternalReplies(generation: generation)
        }
        guard generation == preparationGeneration else { return }
        if let finalize = intent.finalize {
            finalActionPerformed = true
            finalize()
        }
    }

    private func drainExternalReplies(proceed: Bool) {
        let replies = externalReplies
        externalReplies.removeAll()
        for reply in replies {
            reply(proceed)
        }
    }

    private func claimExternalReplyDrainIfNeeded() -> Bool {
        guard !externalReplies.isEmpty, !externalReplyDrainInFlight else { return false }
        externalReplyDrainInFlight = true
        return true
    }

    private func scheduleExternalReplyDrainIfNeeded(generation: Int) {
        guard claimExternalReplyDrainIfNeeded() else { return }
        Task { @MainActor [weak self] in
            await self?.drainClaimedExternalReplies(generation: generation)
        }
    }

    private func drainClaimedExternalReplies(generation: Int) async {
        externalReplyDrainCountForTesting += 1
        defer { releaseExternalReplyDrainClaim(generation: generation) }
        guard generation == preparationGeneration else { return }

        let drainTask = Task { @MainActor in
            await recorder.drain()
        }
        _ = try? await withTimeout(seconds: evidenceDrainCutoffSeconds) {
            await drainTask.value
        }

        guard generation == preparationGeneration else { return }
        drainExternalReplies(proceed: true)
    }

    private func releaseExternalReplyDrainClaim(generation: Int) {
        guard generation == preparationGeneration else { return }
        externalReplyDrainInFlight = false
    }

    private func appOwnedQuitIntent() -> ExitIntent {
        ExitIntent(
            reason: .ordinaryQuit,
            prepare: dependencies.prepareForQuit,
            finalize: dependencies.terminate
        )
    }

    private func externalTerminationIntent() -> ExitIntent {
        ExitIntent(
            reason: .externalQuit,
            prepare: dependencies.prepareForQuit,
            finalize: nil
        )
    }

    private func settingsRestartIntent() -> ExitIntent {
        ExitIntent(
            reason: .settingsRestart,
            prepare: dependencies.prepareForQuit,
            finalize: { [dependencies] in
                dependencies.launchReplacement()
                dependencies.terminate()
            }
        )
    }

    private func updaterInstallIntent() -> ExitIntent {
        ExitIntent(
            reason: .updaterInstall,
            prepare: dependencies.prepareForUpdate,
            finalize: nil
        )
    }
}
