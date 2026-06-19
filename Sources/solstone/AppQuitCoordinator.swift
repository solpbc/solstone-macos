// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SolstoneCore

enum ExitReason: Equatable {
    case ordinaryQuit
    case externalQuit
    case settingsRestart
    case updaterInstall
    case translocation

    var markerString: String {
        switch self {
        case .ordinaryQuit:
            return "ordinary-quit"
        case .externalQuit:
            return "external-quit"
        case .settingsRestart:
            return "settings-restart"
        case .updaterInstall:
            return "sparkle-update"
        case .translocation:
            return "translocation"
        }
    }
}

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
    private let dependencies: Dependencies

    var isPrepared: Bool {
        stateMachine.isPrepared
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func requestAppOwnedQuit() {
        begin(intent: appOwnedQuitIntent())
    }

    func requestExternalTermination(reply: @escaping @MainActor (Bool) -> Void) {
        begin(intent: externalTerminationIntent(), externalReply: reply)
    }

    func requestSettingsRestart() {
        begin(intent: settingsRestartIntent())
    }

    func requestTranslocationRepair() {
        begin(intent: translocationRepairIntent())
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
        committedIntent = nil
        preparationTask = nil
        finalActionPerformed = false
        // If AppKit termination joined a failed updater preparation, cancel it
        // because recovery returns the app to a usable, non-terminating state.
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
            dependencies.writeMarker(intent.reason)
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
                drainExternalReplies(proceed: true)
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
        stateMachine.markPrepared()
        preparationTask = nil
        drainExternalReplies(proceed: true)
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

    private func translocationRepairIntent() -> ExitIntent {
        ExitIntent(
            reason: .translocation,
            prepare: {},
            finalize: dependencies.terminate
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
