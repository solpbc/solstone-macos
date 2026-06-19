// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

struct AppQuitStateMachine {
    enum Phase: Equatable {
        case notStarted
        case preparing
        case prepared
    }

    enum RequestExitDecision: Equatable {
        case startPreparation
        case joinPreparation
        case scheduleTerminate
    }

    private(set) var phase: Phase = .notStarted

    var isPrepared: Bool {
        phase == .prepared
    }

    mutating func requestExit() -> RequestExitDecision {
        switch phase {
        case .notStarted:
            phase = .preparing
            return .startPreparation
        case .preparing:
            return .joinPreparation
        case .prepared:
            return .scheduleTerminate
        }
    }

    mutating func markPrepared() {
        phase = .prepared
    }
}

@MainActor
final class AppQuitCoordinator {
    private var stateMachine = AppQuitStateMachine()
    private var preparationTask: Task<Void, Never>?
    private let writeMarker: @MainActor () -> Void
    private let stopObservation: @MainActor () async -> Void
    private let stopJournal: @MainActor () async -> Void
    private let scheduleTerminate: @MainActor () -> Void

    var isPrepared: Bool {
        stateMachine.isPrepared
    }

    init(
        writeMarker: @escaping @MainActor () -> Void,
        stopObservation: @escaping @MainActor () async -> Void,
        stopJournal: @escaping @MainActor () async -> Void,
        scheduleTerminate: @escaping @MainActor () -> Void
    ) {
        self.writeMarker = writeMarker
        self.stopObservation = stopObservation
        self.stopJournal = stopJournal
        self.scheduleTerminate = scheduleTerminate
    }

    func requestExit() {
        switch stateMachine.requestExit() {
        case .scheduleTerminate:
            scheduleTerminate()
        case .joinPreparation:
            return
        case .startPreparation:
            writeMarker()
            preparationTask = Task { @MainActor in
                await stopObservation()
                await stopJournal()
                stateMachine.markPrepared()
                preparationTask = nil
                scheduleTerminate()
            }
        }
    }
}
