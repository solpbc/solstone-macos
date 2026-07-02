// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Testing
@testable import solstone

@Suite("AppQuitCoordinator")
@MainActor
struct AppQuitCoordinatorTests {
    @Test func appOwnedQuitWritesMarkerRunsCleanupThenTerminates() async throws {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        coordinator.requestAppOwnedQuit()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(events.all == [
            "committed:true",
            "prepareForQuit",
            "marker:ordinary-quit",
            "terminate"
        ])
        #expect(coordinator.isPrepared)
    }

    @Test func appOwnedQuitSchedulesTerminateOnlyAfterCleanupCompletes() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit:start")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                events.append("prepareForQuit:end")
            }
        )

        coordinator.requestAppOwnedQuit()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit:start")
        }
        #expect(!events.all.contains("terminate"))

        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(events.all == [
            "committed:true",
            "prepareForQuit:start",
            "prepareForQuit:end",
            "marker:ordinary-quit",
            "terminate"
        ])
    }

    @Test func prepareDelayLongerThanFreshnessWritesMarkerAfterPrepareCompletes() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit:start")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                events.append("prepareForQuit:end")
            }
        )

        coordinator.requestAppOwnedQuit()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit:start")
        }
        #expect(!events.all.contains("marker:ordinary-quit"))

        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(events.all == [
            "committed:true",
            "prepareForQuit:start",
            "prepareForQuit:end",
            "marker:ordinary-quit",
            "terminate"
        ])
        #expect(coordinator.isPrepared)
    }

    @Test func ordinaryQuitPreparedThenLaterAppOwnedRequestIsNoOp() async throws {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        coordinator.requestAppOwnedQuit()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(coordinator.isPrepared)

        // Pins the performPreparation flag-set so later app-owned requests cannot re-finalize.
        coordinator.requestAppOwnedQuit()
        coordinator.requestSettingsRestart()

        #expect(count(events.all, "terminate") == 1)
        #expect(count(events.all, "launchReplacement") == 0)
        #expect(count(events.all, "prepareForQuit") == 1)
        #expect(count(events.all, "committed:true") == 1)
    }

    @Test func externalTerminationPreparesRepliesTrueAndDoesNotTerminate() async throws {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        coordinator.requestExternalTermination { proceed in
            events.append("reply:\(proceed)")
        }

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("reply:true")
        }
        #expect(events.all == [
            "committed:true",
            "prepareForQuit",
            "marker:external-quit",
            "reply:true"
        ])
        #expect(!events.all.contains("terminate"))
        #expect(coordinator.isPrepared)
    }

    @Test func duplicateExternalTerminationsCoalesceAndAllRepliesFireOnce() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        coordinator.requestExternalTermination { proceed in
            events.append("reply1:\(proceed)")
        }
        coordinator.requestExternalTermination { proceed in
            events.append("reply2:\(proceed)")
        }

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit")
        }
        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("reply1:true") && events.all.contains("reply2:true")
        }
        #expect(count(events.all, "committed:true") == 1)
        #expect(count(events.all, "marker:external-quit") == 1)
        #expect(count(events.all, "prepareForQuit") == 1)
        #expect(count(events.all, "reply1:true") == 1)
        #expect(count(events.all, "reply2:true") == 1)
        #expect(!events.all.contains("terminate"))
    }

    @Test func appOwnedThenExternalFiresReplyAndTerminate() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        coordinator.requestAppOwnedQuit()
        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit")
        }

        coordinator.requestExternalTermination { proceed in
            events.append("reply:\(proceed)")
        }
        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("reply:true") && events.all.contains("terminate")
        }
        #expect(events.all == [
            "committed:true",
            "prepareForQuit",
            "marker:ordinary-quit",
            "reply:true",
            "terminate"
        ])
    }

    @Test func settingsRestartSingleFlightLaunchesReplacementOnce() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        coordinator.requestSettingsRestart()
        coordinator.requestSettingsRestart()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit")
        }
        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(count(events.all, "marker:settings-restart") == 1)
        #expect(count(events.all, "prepareForQuit") == 1)
        #expect(count(events.all, "launchReplacement") == 1)
        #expect(count(events.all, "terminate") == 1)
    }

    @Test func translocationWritesMarkerUsesEmptyPrepareThenTerminates() async throws {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("unexpectedPrepareForQuit")
            },
            prepareForUpdate: {
                events.append("unexpectedPrepareForUpdate")
            }
        )

        coordinator.requestTranslocationRepair()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("terminate")
        }
        #expect(events.all == [
            "committed:true",
            "marker:translocation",
            "terminate"
        ])
    }

    @Test func prepareForUpdaterInstallRunsSharedBodyAndMarksPrepared() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()

        #expect(events.all == [
            "committed:true",
            "prepareForUpdate",
            "marker:sparkle-update"
        ])
        #expect(coordinator.isPrepared)
    }

    @Test func prepareForUpdaterInstallThenAppOwnedQuitTerminatesOnceWithoutCleanupRerun() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()

        #expect(events.all == [
            "committed:true",
            "prepareForUpdate",
            "marker:sparkle-update"
        ])
        #expect(coordinator.isPrepared)

        coordinator.requestAppOwnedQuit()

        #expect(count(events.all, "terminate") == 1)
        #expect(count(events.all, "prepareForUpdate") == 1)
        #expect(count(events.all, "prepareForQuit") == 0)
        #expect(count(events.all, "committed:true") == 1)
        #expect(count(events.all, "marker:sparkle-update") == 1)
        #expect(count(events.all, "marker:ordinary-quit") == 0)
    }

    @Test func prepareForUpdaterInstallThenSettingsRestartLaunchesAndTerminatesOnceNoCleanupRerun() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()
        coordinator.requestSettingsRestart()

        #expect(count(events.all, "launchReplacement") == 1)
        #expect(count(events.all, "terminate") == 1)
        #expect(count(events.all, "prepareForUpdate") == 1)
        #expect(count(events.all, "prepareForQuit") == 0)
    }

    @Test func duplicateAppOwnedFinalizationAfterUpdaterPreparationIsIdempotent() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()
        coordinator.requestAppOwnedQuit()
        coordinator.requestAppOwnedQuit()
        coordinator.requestSettingsRestart()

        #expect(count(events.all, "terminate") == 1)
        #expect(count(events.all, "launchReplacement") <= 1)
        #expect(count(events.all, "prepareForQuit") == 0)
        #expect(count(events.all, "prepareForUpdate") == 1)
    }

    @Test func externalTerminationAfterPreparedRepliesTrueImmediatelyWithoutTerminate() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()
        coordinator.requestExternalTermination { proceed in
            events.append("reply:\(proceed)")
        }

        #expect(events.all.contains("reply:true"))
        #expect(!events.all.contains("terminate"))
    }

    @Test func regressionUpdaterPreparedStillAliveAppOwnedQuitDoesNotSilentlyNoOp() async {
        let events = LockedArray<String>([])
        let coordinator = makeCoordinator(events: events)

        await coordinator.prepareForUpdaterInstall()
        coordinator.requestAppOwnedQuit()

        // Pins the updater-prepared/still-alive window where app-owned quit used to silently no-op.
        #expect(count(events.all, "terminate") == 1)
    }

    @Test func resetAfterFailedUpdaterInstallWithoutPreparationIsSafeNoOp() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForQuit: {
                events.append("prepareForQuit")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        coordinator.resetAfterFailedUpdaterInstall()

        #expect(events.all == ["invalidateMarker", "committed:false"])
        #expect(!coordinator.isPrepared)

        coordinator.requestAppOwnedQuit()

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForQuit")
        }
        #expect(!events.all.contains("marker:ordinary-quit"))
        #expect(!events.all.contains("terminate"))

        canFinish.set(true)

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("marker:ordinary-quit")
        }
        #expect(events.all.contains("marker:ordinary-quit"))
        #expect(!events.all.contains("prepareForUpdate"))
    }

    @Test func resetAfterFailedUpdaterInstallInvalidatesResetsAndCancelsQueuedReplies() async throws {
        let events = LockedArray<String>([])
        let canFinish = LockedValue<Bool>()
        canFinish.set(false)
        let coordinator = makeCoordinator(
            events: events,
            prepareForUpdate: {
                events.append("prepareForUpdate:start")
                while canFinish.current != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                events.append("prepareForUpdate:end")
            }
        )
        let updaterTask = Task { @MainActor in
            await coordinator.prepareForUpdaterInstall()
        }

        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("prepareForUpdate:start")
        }
        coordinator.requestExternalTermination { proceed in
            events.append("reply:\(proceed)")
        }

        coordinator.resetAfterFailedUpdaterInstall()

        #expect(events.all.contains("reply:false"))
        #expect(events.all.contains("invalidateMarker"))
        #expect(events.all.contains("committed:false"))
        #expect(!coordinator.isPrepared)

        canFinish.set(true)
        await updaterTask.value
        #expect(!events.all.contains("reply:true"))
        #expect(!events.all.contains("terminate"))
        #expect(!coordinator.isPrepared)

        coordinator.requestAppOwnedQuit()
        try await waitUntil(timeout: .seconds(5)) {
            events.all.contains("marker:ordinary-quit")
        }
        #expect(events.all.contains("marker:ordinary-quit"))
    }

    @Test func stateMachineTransitionsAndReset() {
        var stateMachine = AppQuitStateMachine()

        #expect(!stateMachine.isPrepared)
        #expect(stateMachine.requestPreparation() == .startPreparation)
        #expect(stateMachine.requestPreparation() == .joinPreparation)
        #expect(!stateMachine.isPrepared)

        stateMachine.markPrepared()

        #expect(stateMachine.isPrepared)
        #expect(stateMachine.requestPreparation() == .alreadyPrepared)

        stateMachine.reset()

        #expect(!stateMachine.isPrepared)
        #expect(stateMachine.requestPreparation() == .startPreparation)
    }

    private func makeCoordinator(
        events: LockedArray<String>,
        prepareForQuit: (@MainActor () async -> Void)? = nil,
        prepareForUpdate: (@MainActor () async -> Void)? = nil
    ) -> AppQuitCoordinator {
        AppQuitCoordinator(dependencies: AppQuitCoordinator.Dependencies(
            setCommitted: { committed in
                events.append("committed:\(committed)")
            },
            writeMarker: { reason in
                events.append("marker:\(reason.markerString)")
            },
            invalidateMarker: {
                events.append("invalidateMarker")
            },
            prepareForQuit: prepareForQuit ?? {
                events.append("prepareForQuit")
            },
            prepareForUpdate: prepareForUpdate ?? {
                events.append("prepareForUpdate")
            },
            terminate: {
                events.append("terminate")
            },
            launchReplacement: {
                events.append("launchReplacement")
            }
        ))
    }
}

private func count(_ events: [String], _ event: String) -> Int {
    events.count { $0 == event }
}
