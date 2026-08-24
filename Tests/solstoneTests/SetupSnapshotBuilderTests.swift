// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Testing
@testable import solstone

@Suite("Setup snapshot builder")
struct SetupSnapshotBuilderTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func allRequiredRowsReadyProducesReadyVerdict() {
        let presentation = buildSetupSnapshot(input())

        #expect(presentation.verdict == .ready)
        #expect(states(in: presentation)[.solApp] == .ready)
        #expect(states(in: presentation)[.journalLink] == .ready)
        #expect(states(in: presentation)[.journalApp] == .ready)
        #expect(states(in: presentation)[.commandLineTools] == .ready)
        #expect(states(in: presentation)[.screenRecording] == .ready)
        #expect(states(in: presentation)[.microphone] == .ready)
    }

    @Test func missingRequiredRowsCountAttentionRowsOnly() {
        let presentation = buildSetupSnapshot(input(
            solAppPlacement: .needsAttention,
            serviceIsDone: false,
            screenRecording: .notGranted
        ))

        #expect(presentation.verdict == .needsAttention(count: 3))
        #expect(row(.lastDelivery, in: presentation).votes == false)
    }

    @Test func unavailableRequiredRowTakesPrecedenceOverMissingRows() {
        let presentation = buildSetupSnapshot(input(
            journalAppInstalled: .unavailable,
            microphone: .notGranted
        ))

        #expect(presentation.verdict == .someUnavailable)
        #expect(states(in: presentation)[.journalApp] == .unavailable)
        #expect(states(in: presentation)[.microphone] == .needsAttention)
        #expect(row(.microphone, in: presentation).action == .grantPermission)
    }

    @Test func checkingRequiredRowFailsClosedUnavailable() {
        let presentation = buildSetupSnapshot(input(screenRecording: .checking))

        #expect(presentation.verdict == .someUnavailable)
        #expect(states(in: presentation)[.screenRecording] == .checking)
    }

    @Test func commandLineToolMixedWrapperStatesKeepKnownMissingAction() {
        let unavailableThenMissing = buildSetupSnapshot(input(
            solWrapperExecutable: .unavailable,
            journalWrapperExecutable: .needsAttention
        ))
        #expect(states(in: unavailableThenMissing)[.commandLineTools] == .unavailable)
        #expect(row(.commandLineTools, in: unavailableThenMissing).action == .openJournalSettings)

        let missingThenUnavailable = buildSetupSnapshot(input(
            solWrapperExecutable: .needsAttention,
            journalWrapperExecutable: .unavailable
        ))
        #expect(states(in: missingThenUnavailable)[.commandLineTools] == .unavailable)
        #expect(row(.commandLineTools, in: missingThenUnavailable).action == .openJournalSettings)

        let checkingThenMissing = buildSetupSnapshot(input(
            solWrapperExecutable: .checking,
            journalWrapperExecutable: .needsAttention
        ))
        #expect(states(in: checkingThenMissing)[.commandLineTools] == .checking)
        #expect(row(.commandLineTools, in: checkingThenMissing).action == .openJournalSettings)

        let bothUnavailable = buildSetupSnapshot(input(
            solWrapperExecutable: .unavailable,
            journalWrapperExecutable: .unavailable
        ))
        #expect(states(in: bothUnavailable)[.commandLineTools] == .unavailable)
        #expect(row(.commandLineTools, in: bothUnavailable).action == nil)

        let bothMissing = buildSetupSnapshot(input(
            solWrapperExecutable: .needsAttention,
            journalWrapperExecutable: .needsAttention
        ))
        #expect(states(in: bothMissing)[.commandLineTools] == .needsAttention)
        #expect(row(.commandLineTools, in: bothMissing).action == .openJournalSettings)

        let bothReady = buildSetupSnapshot(input(
            solWrapperExecutable: .ready,
            journalWrapperExecutable: .ready
        ))
        #expect(states(in: bothReady)[.commandLineTools] == .ready)
        #expect(row(.commandLineTools, in: bothReady).action == nil)
    }

    @Test func remoteTopologyMakesLocalArtifactsNonVoting() {
        let presentation = buildSetupSnapshot(input(
            topology: .remote,
            journalAppInstalled: .needsAttention,
            solWrapperExecutable: .needsAttention,
            journalWrapperExecutable: .needsAttention
        ))

        #expect(presentation.verdict == .ready)
        #expect(states(in: presentation)[.journalApp] == .notRequired)
        #expect(states(in: presentation)[.commandLineTools] == .notRequired)
        #expect(row(.journalApp, in: presentation).votes == false)
        #expect(row(.commandLineTools, in: presentation).votes == false)
    }

    @Test func beforeJournalChoiceLocalArtifactsAreInformational() {
        let presentation = buildSetupSnapshot(input(
            topology: .local,
            journalAppInstalled: .needsAttention,
            serviceIsDone: false,
            solWrapperExecutable: .needsAttention,
            journalWrapperExecutable: .needsAttention
        ))

        #expect(states(in: presentation)[.journalLink] == .needsAttention)
        #expect(row(.journalLink, in: presentation).votes)
        #expect(states(in: presentation)[.journalApp] == .notRequired)
        #expect(!row(.journalApp, in: presentation).votes)
        #expect(states(in: presentation)[.commandLineTools] == .notRequired)
        #expect(!row(.commandLineTools, in: presentation).votes)
    }

    @Test func lastDeliveryNeverVotesAndOnlyConfirmedDeliveryIsGreen() {
        let deliveredAt = now.addingTimeInterval(-120)
        let presentation = buildSetupSnapshot(input(
            lastDeliveryOutcome: .delivered(deliveredAt)
        ))

        #expect(presentation.verdict == .ready)
        #expect(row(.lastDelivery, in: presentation).label == UICopy.SETTINGS_LAST_DELIVERY_LABEL)
        #expect(row(.lastDelivery, in: presentation).value == "2m ago")
        #expect(row(.lastDelivery, in: presentation).state == .ready)
        #expect(row(.lastDelivery, in: presentation).votes == false)

        let never = buildSetupSnapshot(input(lastDeliveryOutcome: .noDeliveryYet))
        #expect(never.verdict == .ready)
        #expect(row(.lastDelivery, in: never).value == UICopy.SETTINGS_LAST_DELIVERY_NEVER)
        #expect(row(.lastDelivery, in: never).state == .notRequired)

        let notLinked = buildSetupSnapshot(input(lastDeliveryOutcome: .notLinked))
        #expect(row(.lastDelivery, in: notLinked).value == UICopy.SETTINGS_LAST_DELIVERY_NOT_LINKED)
        #expect(row(.lastDelivery, in: notLinked).state == .notRequired)

        let unavailable = buildSetupSnapshot(input(lastDeliveryOutcome: .unavailable))
        #expect(row(.lastDelivery, in: unavailable).value == UICopy.SETTINGS_DIAGNOSTICS_COULD_NOT_CHECK)
        #expect(row(.lastDelivery, in: unavailable).state == .unavailable)
    }

    private func input(
        topology: SetupTopology = .local,
        solAppPlacement: SetupProbeOutcome = .ready,
        journalAppInstalled: SetupProbeOutcome = .ready,
        serviceIsDone: Bool = true,
        solWrapperExecutable: SetupProbeOutcome = .ready,
        journalWrapperExecutable: SetupProbeOutcome = .ready,
        screenRecording: PermissionOutcome = .granted,
        microphone: PermissionOutcome = .granted,
        lastDeliveryOutcome: LastJournalDeliveryOutcome = .noDeliveryYet
    ) -> SetupSnapshotInput {
        SetupSnapshotInput(
            topology: topology,
            solAppPlacement: solAppPlacement,
            journalAppInstalled: journalAppInstalled,
            serviceIsDone: serviceIsDone,
            solWrapperExecutable: solWrapperExecutable,
            journalWrapperExecutable: journalWrapperExecutable,
            screenRecording: screenRecording,
            microphone: microphone,
            lastDeliveryOutcome: lastDeliveryOutcome,
            now: now
        )
    }

    private func states(in presentation: SetupSnapshotPresentation) -> [SetupCheckRowID: SetupCheckRowAXState] {
        Dictionary(uniqueKeysWithValues: presentation.rows.map { ($0.id, $0.state) })
    }

    private func row(_ id: SetupCheckRowID, in presentation: SetupSnapshotPresentation) -> SetupCheckRow {
        presentation.rows.first { $0.id == id }!
    }
}
