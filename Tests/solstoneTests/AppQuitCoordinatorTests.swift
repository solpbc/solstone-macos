// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("AppQuitCoordinator")
@MainActor
struct AppQuitCoordinatorTests {
    @Test func firstRequestWritesMarkerRunsCleanupThenSchedulesTerminate() async throws {
        let events = LockedArray<String>([])
        let coordinator = AppQuitCoordinator(
            writeMarker: { events.append("marker") },
            stopObservation: { events.append("stopObservation") },
            stopJournal: { events.append("stopJournal") },
            scheduleTerminate: { events.append("terminate") }
        )

        coordinator.requestExit()

        try await waitUntil(timeout: .seconds(1)) {
            events.all.count == 4
        }
        #expect(events.all == ["marker", "stopObservation", "stopJournal", "terminate"])
        #expect(coordinator.isPrepared)
    }

    @Test func terminateIsScheduledOnlyAfterCleanupCompletes() async throws {
        let events = LockedArray<String>([])
        let journalCanFinish = LockedValue<Bool>()
        journalCanFinish.set(false)
        let coordinator = AppQuitCoordinator(
            writeMarker: { events.append("marker") },
            stopObservation: { events.append("stopObservation") },
            stopJournal: {
                events.append("stopJournal")
                while journalCanFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            },
            scheduleTerminate: { events.append("terminate") }
        )

        coordinator.requestExit()

        try await waitUntil(timeout: .seconds(1)) {
            events.all.contains("stopJournal")
        }
        #expect(!events.all.contains("terminate"))

        journalCanFinish.set(true)

        try await waitUntil(timeout: .seconds(1)) {
            events.all.contains("terminate")
        }
        #expect(events.all == ["marker", "stopObservation", "stopJournal", "terminate"])
    }

    @Test func preparedRequestSchedulesTerminateWithoutRepeatingCleanup() async throws {
        let events = LockedArray<String>([])
        let coordinator = AppQuitCoordinator(
            writeMarker: { events.append("marker") },
            stopObservation: { events.append("stopObservation") },
            stopJournal: { events.append("stopJournal") },
            scheduleTerminate: { events.append("terminate") }
        )

        coordinator.requestExit()
        try await waitUntil(timeout: .seconds(1)) {
            events.all.contains("terminate")
        }

        coordinator.requestExit()

        try await waitUntil(timeout: .seconds(1)) {
            count(events.all, "terminate") == 2
        }
        #expect(count(events.all, "marker") == 1)
        #expect(count(events.all, "stopObservation") == 1)
        #expect(count(events.all, "stopJournal") == 1)
    }

    @Test func duplicateRequestsCoalesceIntoOnePreparation() async throws {
        let events = LockedArray<String>([])
        let coordinator = AppQuitCoordinator(
            writeMarker: { events.append("marker") },
            stopObservation: { events.append("stopObservation") },
            stopJournal: { events.append("stopJournal") },
            scheduleTerminate: { events.append("terminate") }
        )

        coordinator.requestExit()
        coordinator.requestExit()

        try await waitUntil(timeout: .seconds(1)) {
            events.all.count == 4
        }
        #expect(count(events.all, "marker") == 1)
        #expect(count(events.all, "stopObservation") == 1)
        #expect(count(events.all, "stopJournal") == 1)
        #expect(count(events.all, "terminate") == 1)
    }

    @Test func recordingActiveQuitInvokesStopObservationBeforeTerminate() async throws {
        let events = LockedArray<String>([])
        let isRecording = LockedValue<Bool>()
        isRecording.set(true)
        let coordinator = AppQuitCoordinator(
            writeMarker: { events.append("marker") },
            stopObservation: {
                if isRecording.current == true {
                    events.append("stopObservation")
                }
            },
            stopJournal: { events.append("stopJournal") },
            scheduleTerminate: { events.append("terminate") }
        )

        coordinator.requestExit()

        try await waitUntil(timeout: .seconds(1)) {
            events.all.contains("terminate")
        }
        #expect(events.all == ["marker", "stopObservation", "stopJournal", "terminate"])
    }

    @Test func delegateDecisionModelCancelsUntilPreparedThenTerminatesNow() {
        var stateMachine = AppQuitStateMachine()

        #expect(!stateMachine.isPrepared)
        #expect(stateMachine.requestExit() == .startPreparation)
        #expect(!stateMachine.isPrepared)

        stateMachine.markPrepared()

        #expect(stateMachine.isPrepared)
        #expect(stateMachine.requestExit() == .scheduleTerminate)
    }
}

private func count(_ events: [String], _ event: String) -> Int {
    events.count { $0 == event }
}
